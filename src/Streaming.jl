function grpc_async_stream_request(
        req::gRPCRequest,
        channel::Channel{TRequest},
    ) where {TRequest <: Any}
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
                # Once the request has completed (cancelled, deadline exceeded, done)
                # the easy handle is gone and curl_done_reading will never be notified
                # by curl again, so there is nothing left to hand off. cleanup_request
                # notifies curl_done_reading, so a wait racing the completion still
                # wakes, and the completed re-check under req.lock below (the lock
                # cleanup runs under) keeps curl_easy_pause off the freed easy handle.
                if encode_buf.size > 0 && !req.completed
                    seekstart(encode_buf)

                    # Wait for libCURL to not be reading anymore
                    wait(req.curl_done_reading)

                    # Stage the batch and resume the transfer as one critical section.
                    # read_callback runs under this same lock, so it cannot land between
                    # the un-pause and the buffer it is meant to pick up, and cannot pause
                    # again behind our back. Any pause it takes afterwards is a fresh one
                    # against an empty buffer, which the next batch resumes.
                    lock(req.lock) do
                        req.completed && return

                        # Write all of the encoded protobufs to the request read buffer
                        write(req.request, encode_buf)

                        # Block on the next wait until cleared by the curl read_callback
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
            # End of stream. Skip the handoff if the request already completed: the
            # easy handle is gone and curl will never signal curl_done_reading again
            # (cleanup_request notifies it, so a wait racing the completion still
            # wakes; the re-check under req.lock keeps curl_easy_pause off the freed
            # easy handle).
            if !req.completed
                # Wait for any request data to be flushed by curl
                wait(req.curl_done_reading)

                # Marking the stream ended and resuming the transfer must be one critical
                # section. read_callback only returns 0 (which is what ends the request)
                # once it sees the stream ended, and the un-pause is what draws that
                # callback: were the mark to land after the un-pause, a callback in between
                # would still see an open stream, pause again, and leave the transfer
                # paused with nobody to resume it, hanging the call until its deadline even
                # though both peers are done.
                #
                # Nothing in here may block. This holds the lock that serializes every
                # transfer on the handle, so a task descheduled inside it stalls all of
                # them. A field write and reset(::Event) are stores, curl_easy_pause with
                # no paused receive direction draws no callback, and write(::IOBuffer)
                # above only allocates. close(::Channel) would not qualify, which is why
                # `request_eof` exists.
                lock(req.lock) do
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
        # However this pump exits, no further request data will ever be staged, so end the
        # upload the way a normal end of stream does. Under the lock for the same ordering
        # against read_callback as the end-of-stream handoff above, and idempotent with it.
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
            response = _decode_message(response_buf, TResponse)
            put!(channel, response)
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
        Channel{IOBuffer}(16),
        options
    )

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
        Channel{IOBuffer}(16),
        _merge_options(client.options, options)
    )

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
