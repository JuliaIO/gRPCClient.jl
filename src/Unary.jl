# Unary RPC

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}

Initiate an asynchronous gRPC request: send the request to the server and then immediately return a `gRPCRequest` object without waiting for the response.
In order to wait on / retrieve the result once its ready, call `grpc_async_await`.
This is ideal when you need to send many requests in parallel and waiting on each response before sending the next request would things down.

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client for your RPC method (hostname, port)
client = TestService_TestRPC_Client("localhost", 8001)

# Step 3: Send all requests without waiting for responses
requests = Vector{gRPCRequest}()
for i in 1:10
    push!(requests, grpc_async_request(client, TestRequest(1, zeros(UInt64, 1))))
end

# Step 4: Wait for and process responses
for request in requests
    response = grpc_async_await(client, request)
    @info response
end
```
"""
function grpc_async_request(
    client::gRPCServiceClient{TRequest,false,TResponse,false},
    request::TRequest;
    deadline = client.deadline,
    keepalive = client.keepalive,
    max_send_message_length = client.max_send_message_length,
    max_recieve_message_length = client.max_recieve_message_length,
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
        NOCHANNEL,
        NOCHANNEL;
        deadline = deadline,
        keepalive = keepalive,
        max_send_message_length = max_send_message_length,
        max_recieve_message_length = max_recieve_message_length,
    )

    req
end


mutable struct gRPCAsyncChannelResponse{TResponse}
    index::Int64
    response::Union{Nothing,TResponse}
    ex::Union{Nothing,Exception}
end

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}

Initiate an asynchronous gRPC request: send the request to the server and then immediately return. When the request is complete a background task will put the response in the provided channel.
This has the advantage over the request / await patern in that you can handle responses immediately after they are recieved in any order.

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client
client = TestService_TestRPC_Client("localhost", 8001)

# Step 3: Create a channel to receive responses (processes responses as they arrive, in any order)
N = 10
channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(N)

# Step 4: Send all requests (the index tracks which response corresponds to which request)
for (index, request) in enumerate([TestRequest(i, zeros(UInt64, i)) for i in 1:N])
    grpc_async_request(client, request, channel, index)
end

# Step 5: Process responses as they arrive
for i in 1:N
    cr = take!(channel)
    !isnothing(cr.ex) && throw(cr.ex)
    @assert length(cr.response.data) == cr.index
end
```
"""
function grpc_async_request(
    client::gRPCServiceClient{TRequest,false,TResponse,false},
    request::TRequest,
    channel::Channel{gRPCAsyncChannelResponse{TResponse}},
    index::Int64;
    deadline = client.deadline,
    keepalive = client.keepalive,
    max_send_message_length = client.max_send_message_length,
    max_recieve_message_length = client.max_recieve_message_length,
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
        NOCHANNEL,
        NOCHANNEL;
        deadline = deadline,
        keepalive = keepalive,
        max_send_message_length = max_send_message_length,
        max_recieve_message_length = max_recieve_message_length,
    )

    Threads.@spawn begin
        try
            response = grpc_async_await(client, req)
            put!(channel, gRPCAsyncChannelResponse{TResponse}(index, response, nothing))
        catch ex
            put!(channel, gRPCAsyncChannelResponse{TResponse}(index, nothing, ex))
        end
    end

    nothing
end


"""
    grpc_async_await(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}

Wait for the request to complete and return the response when it is ready. Throws any exceptions that were encountered during handling of the request.
"""
grpc_async_await(
    client::gRPCServiceClient{TRequest,false,TResponse,false},
    request::gRPCRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_await(request, TResponse)


"""
    grpc_sync_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}

Do a synchronous gRPC request: send the request and wait for the response before returning it.
Under the hood this just calls `grpc_async_request` and `grpc_async_await`.
Use this when you want the simplest possible interface for a single request.

```julia
using gRPCClient

# Step 1: Include generated Protocol Buffer bindings
include("test/gen/test/test_pb.jl")

# Step 2: Create a client
client = TestService_TestRPC_Client("localhost", 8001)

# Step 3: Make a synchronous request (blocks until response is ready)
response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
@info response
```
"""
grpc_sync_request(
    client::gRPCServiceClient{TRequest,false,TResponse,false},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} =
    grpc_async_await(grpc_async_request(client, request), TResponse)
