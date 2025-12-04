@static if VERSION >= v"1.12"

function grpc_async_stream_request(
    req::gRPCRequest,
    channel::Channel{TRequest},
) where {TRequest<:Any}
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
                if encode_buf.size > 0
                    seekstart(encode_buf)

                    # Wait for libCURL to not be reading anymore 
                    wait(req.curl_done_reading)

                    # Write all of the encoded protobufs to the request read buffer
                    write(req.request, encode_buf)

                    # Block on the next wait until cleared by the curl read_callback
                    reset(req.curl_done_reading)

                    # Tell curl we have more to send
                    lock(req.lock) do
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
            # Wait for any request data to be flushed by curl
            wait(req.curl_done_reading)

            # Trigger a "return 0" in read_callback so curl ends the current request
            reset(req.curl_done_reading)
            lock(req.lock) do
                curl_easy_pause(req.easy, CURLPAUSE_CONT)
            end

        elseif isa(ex, gRPCServiceCallException)
            if isnothing(req.ex)
                req.ex = ex
                notify(req.ready)
            end
        else
            if isnothing(req.ex)
                req.ex = ex
                notify(req.ready)
            end
            @error "grpc_async_stream_request: unexpected exception" exception = ex
        end
    finally
        close(channel)
        close(req.request_c)
    end

    nothing
end

function grpc_async_stream_response(
    req::gRPCRequest,
    channel::Channel{TResponse},
) where {TResponse<:Any}
    try
        while isnothing(req.ex)
            response_buf = take!(req.response_c)
            response = decode(ProtoDecoder(response_buf), TResponse)
            put!(channel, response)
        end
    catch ex
        if isa(ex, InvalidStateException)

        elseif isa(ex, gRPCServiceCallException)
            if isnothing(req.ex)
                req.ex = ex
                notify(req.ready)
            end
        else
            if isnothing(req.ex)
                req.ex = ex
                notify(req.ready)
            end
            @error "grpc_async_stream_response: unexpected exception" exception = ex
        end
    finally
        close(channel)
        close(req.response_c)
    end

    nothing
end

else 

function grpc_async_stream_request(
    req::gRPCRequest,
    channel::Channel{TRequest},
) where {TRequest<:Any}
    ex = AssertionError("Streaming not supported with Julia < 1.12")
    @error exception=ex
    req.ex = ex
    close(channel)
    notify(req.ready)
end

function grpc_async_stream_response(
    req::gRPCRequest,
    channel::Channel{TResponse},
) where {TResponse<:Any}
    ex = AssertionError("Streaming not supported with Julia < 1.12")
    @error exception=ex
    req.ex = ex
    close(channel)
    notify(req.ready)
end

end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}) where {TRequest<:Any,TResponse<:Any}

Start a client streaming gRPC request (multiple requests, single response).

```julia
using gRPCClient

# ============================================================================
# Step 1: Initialize gRPC
# ============================================================================
# This must be called once before making any gRPC requests.
grpc_init()

# ============================================================================
# Step 2: Include Generated Protocol Buffer Bindings
# ============================================================================
include("test/gen/test/test_pb.jl")

# ============================================================================
# Step 3: Create a Client for Your Streaming RPC Method
# ============================================================================
client = TestService_TestClientStreamRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Create a Request Channel and Send Requests
# ============================================================================
# The channel buffers requests that will be streamed to the server.
# Buffer size of 16 means up to 16 requests can be queued.
request_c = Channel{TestRequest}(16)

# Send one or more requests through the channel
put!(request_c, TestRequest(1, zeros(UInt64, 1)))

# ============================================================================
# Step 5: Initiate the Streaming Request
# ============================================================================
req = grpc_async_request(client, request_c)

# ============================================================================
# Step 6: Close the Request Channel When Done
# ============================================================================
# IMPORTANT: You must close the channel to signal that no more requests
# will be sent. The server won't send the response until the stream ends.
close(request_c)

# ============================================================================
# Step 7: Wait for the Single Response
# ============================================================================
# After all requests are sent and processed, the server returns one response.
test_response = grpc_async_await(client, req)
```
"""
function grpc_async_request(
    client::gRPCServiceClient{TRequest,true,TResponse,false},
    request::Channel{TRequest},
) where {TRequest<:Any,TResponse<:Any}

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        nothing;
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    request_task = Threads.@spawn grpc_async_stream_request(req, request)
    errormonitor(request_task)

    req
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,true},request::TRequest,response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}

Start a server streaming gRPC request (single request, multiple responses).

```julia
using gRPCClient

# ============================================================================
# Step 1: Initialize gRPC
# ============================================================================
# This must be called once before making any gRPC requests.
grpc_init()

# ============================================================================
# Step 2: Include Generated Protocol Buffer Bindings
# ============================================================================
include("test/gen/test/test_pb.jl")

# ============================================================================
# Step 3: Create a Client for Your Streaming RPC Method
# ============================================================================
client = TestService_TestServerStreamRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Create a Response Channel
# ============================================================================
# The channel will receive multiple responses from the server.
# Buffer size of 16 means up to 16 responses can be queued.
response_c = Channel{TestResponse}(16)

# ============================================================================
# Step 5: Initiate the Streaming Request
# ============================================================================
# Send a single request. The server will respond with multiple messages.
req = grpc_async_request(
    client,
    TestRequest(1, zeros(UInt64, 1)),
    response_c,
)

# ============================================================================
# Step 6: Process Streaming Responses
# ============================================================================
# Read responses from the channel as they arrive. The channel will be closed
# when the server finishes sending all responses.
for test_response in response_c
    @info test_response
end

# ============================================================================
# Step 7: Check for Exceptions
# ============================================================================
# Call grpc_async_await to raise any exceptions that occurred during the request.
grpc_async_await(req)
```
"""
function grpc_async_request(
    client::gRPCServiceClient{TRequest,false,TResponse,true},
    request::TRequest,
    response::Channel{TResponse},
) where {TRequest<:Any,TResponse<:Any}

    request_buf = grpc_encode_request_iobuffer(
        request;
        max_send_message_length = client.max_send_message_length,
    )
    seekstart(request_buf)

    req = gRPCRequest(
        client.grpc,
        url(client),
        request_buf,
        IOBuffer(),
        nothing,
        Channel{IOBuffer}(16);
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    response_task = Threads.@spawn grpc_async_stream_response(req, response)
    errormonitor(response_task)

    req
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,true},request::Channel{TRequest},response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}

Start a bidirectional streaming gRPC request (multiple requests, multiple responses).

```julia
using gRPCClient

# ============================================================================
# Step 1: Initialize gRPC
# ============================================================================
# This must be called once before making any gRPC requests.
grpc_init()

# ============================================================================
# Step 2: Include Generated Protocol Buffer Bindings
# ============================================================================
include("test/gen/test/test_pb.jl")

# ============================================================================
# Step 3: Create a Client for Your Streaming RPC Method
# ============================================================================
client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Create Request and Response Channels
# ============================================================================
# Both channels allow streaming in both directions simultaneously.
# Buffer size of 16 means up to 16 messages can be queued in each direction.
request_c = Channel{TestRequest}(16)
response_c = Channel{TestResponse}(16)

# ============================================================================
# Step 5: Initiate the Bidirectional Streaming Request
# ============================================================================
req = grpc_async_request(client, request_c, response_c)

# ============================================================================
# Step 6: Send Requests and Receive Responses Concurrently
# ============================================================================
# In bidirectional streaming, you can send and receive at the same time.
# This example shows a simple pattern, but you can use tasks for more
# complex concurrent communication patterns.

# Send a request
put!(request_c, TestRequest(1, zeros(UInt64, 1)))

# Receive responses as they arrive
for test_response in response_c
    @info test_response
    # Optionally send more requests based on responses
    # put!(request_c, ...)
    break  # Exit after first response for this example
end

# ============================================================================
# Step 7: Close the Request Channel When Done
# ============================================================================
# IMPORTANT: You must close the request channel to signal that no more
# requests will be sent.
close(request_c)

# ============================================================================
# Step 8: Check for Exceptions
# ============================================================================
# Call grpc_async_await to raise any exceptions that occurred during the request.
grpc_async_await(req)
```
"""
function grpc_async_request(
    client::gRPCServiceClient{TRequest,true,TResponse,true},
    request::Channel{TRequest},
    response::Channel{TResponse},
) where {TRequest<:Any,TResponse<:Any}

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        Channel{IOBuffer}(16);
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    request_task = Threads.@spawn grpc_async_stream_request(req, request)
    errormonitor(request_task)

    response_task = Threads.@spawn grpc_async_stream_response(req, response)
    errormonitor(response_task)

    req
end


"""
    grpc_async_await(client::gRPCServiceClient{TRequest,true,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any} 

Raise any exceptions encountered during the streaming request.
"""
grpc_async_await(
    client::gRPCServiceClient{TRequest,true,TResponse,false},
    request::gRPCRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_await(request, TResponse)
