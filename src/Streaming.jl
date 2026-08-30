function grpc_async_stream_request(
        req::gRPCRequest,
        channel::Channel{TRequest},
    ) where {TRequest <: Any}
    # Pumps the caller's request messages into the upload buffer curl sends from.
    #
    # The caller puts messages into `channel` and closes it once there are no more. This
    # task takes them out, encodes them, and hands them to curl a batch at a time: curl
    # stays paused while we fill the buffer and is resumed once a batch is staged. It runs
    # until the channel is closed and drained, or the request ends some other way.
    try
        encode_buf = IOBuffer()
        reqs_ready = 0

        while isnothing(req.ex)
            try
                # Always do a blocking take! once so we don't spin
                request = take!(channel)
                grpc_encode_request_iobuffer(
                    request,
                    encode_buf;
                    max_send_message_length = req.max_send_message_length,
                )
                reqs_ready += 1

                # Try to get get more requests within reason to reduce request overhead interfacing with libcurl
                while !isempty(channel) && reqs_ready < 100 && encode_buf.size < 65535
                    request = take!(channel)
                    grpc_encode_request_iobuffer(
                        request,
                        encode_buf;
                        max_send_message_length = req.max_send_message_length,
                    )
                    reqs_ready += 1
                end
            catch ex
                rethrow(ex)
            finally
                # A batch is ready, so hand it to curl. Unless the request is already over
                # (cancelled, deadline exceeded, finished, failed): curl has torn down the
                # handle we would be handing it to and will never ask us for data again, so
                # there is nothing to hand off and nothing that would ever wake us up.
                # cleanup_request wakes curl_done_reading on its way out, so a wait that
                # started just before the request ended still returns instead of hanging
                # here forever, and the second req.completed check below keeps us from
                # touching a handle that was freed while we waited.
                if encode_buf.size > 0 && !req.completed
                    seekstart(encode_buf)

                    # curl may still be copying the previous batch out of req.request.
                    # Block here until it signals it has taken every byte, so we never
                    # overwrite data that has not gone out on the wire yet.
                    wait(req.curl_done_reading)

                    # Staging the batch and resuming the transfer have to happen together,
                    # with nothing able to look at the buffer in between.
                    #
                    # req.lock is the same lock curl's read_callback runs under, so no
                    # callback can run while we hold it. That keeps a callback from landing
                    # between the resume and the buffer it is meant to pick up, and from
                    # pausing the transfer again behind our back. Any pause it takes after
                    # we let go of the lock is a fresh one against an empty buffer, which
                    # the next batch resumes.
                    lock(req.lock) do
                        # The request ended while we were waiting above, so the handle we
                        # would be staging for no longer exists. Drop the batch.
                        req.completed && return

                        # Write all of the encoded protobufs to the request read buffer
                        write(req.request, encode_buf)

                        # Re-arm the signal, so the wait above blocks the next time around
                        # until read_callback reports this batch has been taken
                        reset(req.curl_done_reading)

                        # Tell curl we have more to send
                        curl_easy_pause(req.easy, CURLPAUSE_CONT)
                    end

                    # Reset the encode buffer
                    reqs_ready = 0
                    seekstart(encode_buf)
                    truncate(encode_buf, 0)
                end
            end
        end
    catch ex
        if isa(ex, InvalidStateException)
            # The caller closed the request channel and we have now drained it. This is the
            # normal, successful way out of the loop above, not a failure.
            #
            # Closing a channel does not throw anything away: take! keeps handing back
            # whatever is still buffered in it and only raises this exception once the
            # buffer is empty. So reaching here means every message the caller ever put in
            # the channel has already been encoded and handed to curl by the loop above.
            # All that is left to do is tell curl there will be no more.
            #
            # Unless the request is already over, in which case there is no longer a handle
            # to tell and nothing that would wake us up; see the same check in the loop.
            if !req.completed
                # Let curl finish copying the last batch out of req.request first.
                wait(req.curl_done_reading)

                # Marking the stream ended and resuming the transfer have to happen
                # together, with nothing able to run in between.
                #
                # curl's read_callback is what actually ends the upload: it reports "no
                # more data" to curl only once it sees request_eof set, and resuming the
                # transfer is what makes curl call it. If we resumed first and set the flag
                # second, a callback landing in between would see a stream that is still
                # open, pause the transfer again, and go back to sleep with nobody left to
                # wake it. The call would then sit idle until its deadline even though both
                # sides are done talking. Holding req.lock, which read_callback also runs
                # under, closes that window.
                #
                # Nothing in here may wait for anything. This is the lock that serializes
                # every transfer sharing this connection, so if this task were paused while
                # holding it, all of them would stall behind it. Setting a field and
                # resuming a transfer both return immediately. Closing a Channel does not
                # qualify, because it takes the channel's own lock and can wait on it,
                # which is why end of stream is signalled with the plain `request_eof`
                # field rather than by closing req.request_c in here.
                lock(req.lock) do
                    # The request ended while we were waiting above, so curl has already
                    # stopped asking for data and there is nobody left to tell
                    req.completed && return

                    req.request_eof = true

                    # Trigger a "return 0" in read_callback so curl ends the current request
                    curl_easy_pause(req.easy, CURLPAUSE_CONT)
                end
            end

        elseif isa(ex, gRPCServiceCallException)
            handle_exception(req, ex; notify_ready = true)
        else
            handle_exception(req, ex; notify_ready = true)
            @error "grpc_async_stream_request: unexpected exception" exception = ex
        end
    finally
        close(channel)
        # However this pump exits, including on an error, no further request data will ever
        # be staged, so end the upload the same way a clean end of stream does. Held under
        # req.lock for the same reason as above, and harmless to repeat if the end of
        # stream path already set it.
        lock(req.lock) do
            req.request_eof = true
        end
        close(req.request_c)
    end

    return nothing
end

function grpc_async_stream_response(
        req::gRPCRequest,
        channel::Channel{TResponse},
    ) where {TResponse <: Any}
    try
        while isnothing(req.ex)
            response_buf = take!(req.response_c)
            if response_buf === nothing
                continue
            end
            # Credit the bytes back to the budget as soon as the pump owns the
            # message, before put! can block on a slow consumer
            atomic_sub!(req.recv_queued_bytes, Int64(response_buf.size))
            response = _decode_message(response_buf, TResponse)
            put!(channel, response)

            # Resume once drained to the low watermark (_response_c_drained).
            # curl_easy_pause may synchronously re-enter write_callback, which
            # is safe under the req.lock held here; recv_paused is re-checked
            # inside it, and the frame-boundary gate re-pauses if the consumer
            # is still slow. The completed/easy guards keep the FFI call off a
            # cleaned-up handle.
            if req.recv_paused && _response_c_drained(req)
                lock(req.lock) do
                    if req.recv_paused
                        req.recv_paused = false
                        if !req.completed && req.easy != C_NULL
                            curl_easy_pause(req.easy, CURLPAUSE_CONT)
                        end
                    end
                end
            end
        end
    catch ex
        if !isa(ex, InvalidStateException)
            handle_exception(req, ex; notify_ready = true)
            @error "grpc_async_stream_response: unexpected exception" exception = ex
        end
    finally
        close(channel)
        close(req.response_c)
    end

    return nothing
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}; options...) where {TRequest<:Any,TResponse<:Any}

Start a client streaming gRPC request (multiple requests, single response).

The connection may be configured further by providing a set of options as keyword arguments. 
Available options are listed in the docstring of `gRPCServiceClient`. 

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client
client = TestService_TestClientStreamRPC_Client("localhost", 8001)

# Step 3: Create a request channel and send requests
request_c = Channel{TestRequest}(16)
put!(request_c, TestRequest(1, zeros(UInt64, 1)))

# Step 4: Initiate the streaming request
req = grpc_async_request(client, request_c)

# Step 5: Close the channel to signal no more requests will be sent
# (the server won't respond until the stream ends)
close(request_c)

# Step 6: Wait for the single response
test_response = grpc_async_await(client, req)
```
"""
function grpc_async_request(
        client::gRPCServiceClient{TRequest, true, TResponse, false},
        request::Channel{TRequest};
        options...
    ) where {TRequest <: Any, TResponse <: Any}

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        NOCHANNEL,
        _merge_options(client.options, options)
    )

    request_task = _spawn(() -> grpc_async_stream_request(req, request), client)
    errormonitor(request_task)

    return req
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,true},request::TRequest,response::Channel{TResponse}; options...) where {TRequest<:Any,TResponse<:Any}

Start a server streaming gRPC request (single request, multiple responses).

The connection may be configured further by providing a set of options as keyword arguments. 
Available options are listed in the docstring of `gRPCServiceClient`. 

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client
client = TestService_TestServerStreamRPC_Client("localhost", 8001)

# Step 3: Create a response channel to receive multiple responses
response_c = Channel{TestResponse}(16)

# Step 4: Send a single request (the server will respond with multiple messages)
req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)), response_c)

# Step 5: Process streaming responses (channel closes when server finishes)
for test_response in response_c
    @info test_response
end

# Step 6: Check for exceptions
grpc_async_await(req)
```
"""
function grpc_async_request(
        client::gRPCServiceClient{TRequest, false, TResponse, true},
        request::TRequest,
        response::Channel{TResponse};
        kws...
    ) where {TRequest <: Any, TResponse <: Any}

    options = _merge_options(client.options, kws)

    request_buf = grpc_encode_request_iobuffer(
        request;
        max_send_message_length = options.max_send_message_length,
    )
    seekstart(request_buf)

    req = gRPCRequest(
        client.grpc,
        url(client),
        request_buf,
        IOBuffer(),
        NOCHANNEL,
        # Unbounded on purpose: write_callback must never block on it; the byte
        # budget bounds it instead
        Channel{IOBuffer}(typemax(Int)),
        options
    )
    # Let cleanup_request reach the caller's channel on abnormal ends; see
    # response_user_c
    req.response_user_c = response

    response_task = _spawn(() -> grpc_async_stream_response(req, response), client)
    errormonitor(response_task)

    return req
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,true},request::Channel{TRequest},response::Channel{TResponse}; options...) where {TRequest<:Any,TResponse<:Any}

Start a bidirectional streaming gRPC request (multiple requests, multiple responses).

The connection may be configured further by providing a set of keyword arguments. 
Available options are listed in the docstring of `gRPCServiceClient`. 

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client
client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)

# Step 3: Create request and response channels (streaming in both directions simultaneously)
request_c = Channel{TestRequest}(16)
response_c = Channel{TestResponse}(16)

# Step 4: Initiate the bidirectional streaming request
req = grpc_async_request(client, request_c, response_c)

# Step 5: Send requests and receive responses concurrently
put!(request_c, TestRequest(1, zeros(UInt64, 1)))
for test_response in response_c
    @info test_response
    break  # Exit after first response for this example
end

# Step 6: Close the request channel to signal no more requests will be sent
close(request_c)

# Step 7: Check for exceptions
grpc_async_await(req)
```
"""
function grpc_async_request(
        client::gRPCServiceClient{TRequest, true, TResponse, true},
        request::Channel{TRequest},
        response::Channel{TResponse};
        options...
    ) where {TRequest <: Any, TResponse <: Any}

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        # Unbounded on purpose: write_callback must never block on it; the byte
        # budget bounds it instead
        Channel{IOBuffer}(typemax(Int)),
        _merge_options(client.options, options)
    )
    # Let cleanup_request reach the caller's channel on abnormal ends; see
    # response_user_c
    req.response_user_c = response

    request_task = _spawn(() -> grpc_async_stream_request(req, request), client)
    errormonitor(request_task)

    response_task = _spawn(() -> grpc_async_stream_response(req, response), client)
    errormonitor(response_task)

    return req
end


"""
    grpc_async_await(client::gRPCServiceClient{TRequest,true,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any} 

Raise any exceptions encountered during the streaming request.
"""
grpc_async_await(
    client::gRPCServiceClient{TRequest, true, TResponse, false},
    request::gRPCRequest,
) where {TRequest <: Any, TResponse <: Any} = grpc_async_await(request, TResponse)
