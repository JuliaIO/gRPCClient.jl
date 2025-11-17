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
        close(channel)
        close(req.request_c)

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
        close(channel)
        close(req.response_c)

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

    end

    nothing
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}) where {TRequest<:Any,TResponse<:Any}

Start a requesting streaming gRPC request.

```julia 
using gRPCClient

grpc_init()
include("test/gen/test/test_pb.jl")

client = TestService_TestClientStreamRPC_Client("localhost", 8001)
request_c = Channel{TestRequest}(16)
put!(request_c, TestRequest(1, zeros(UInt64, 1)))

req = grpc_async_request(client, request_c)

# Must close the request channel when done sending requests
close(request_c)

# Get the response
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

Start a response streaming gRPC request.

```julia
using gRPCClient

grpc_init()
include("test/gen/test/test_pb.jl")

client = TestService_TestServerStreamRPC_Client("localhost", 8001)

response_c = Channel{TestResponse}(16)

req = grpc_async_request(
    client,
    TestRequest(1, zeros(UInt64, 1)),
    response_c,
)
test_response = take!(response_c)

# Raise any exceptions encountered during the request
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

Start a bidirectional gRPC request.

```julia
using gRPCClient

grpc_init()
include("test/gen/test/test_pb.jl")

client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)

request_c = Channel{TestRequest}(16)
response_c = Channel{TestResponse}(16)

put!(request_c, TestRequest(1, zeros(UInt64, 1)))
req = grpc_async_request(client, request_c, response_c)
test_response = take!(response_c)

# Must close the request channel when done sending requests
close(request_c)
# Raise any exceptions encountered during the request
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
