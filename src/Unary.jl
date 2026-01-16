# Unary RPC

"""
    grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}

Initiate an asynchronous gRPC request: send the request to the server and then immediately return a `gRPCRequest` object without waiting for the response.
In order to wait on / retrieve the result once its ready, call `grpc_async_await`.
This is ideal when you need to send many requests in parallel and waiting on each response before sending the next request would things down.

```julia
using gRPCClient

# ============================================================================
# Step 1: Initialize gRPC
# ============================================================================
# This must be called once before making any gRPC requests.
# It initializes the underlying libcurl multi handle and other resources.
grpc_init()

# ============================================================================
# Step 2: Include Generated Protocol Buffer Bindings
# ============================================================================
# These bindings define the message types (e.g., TestRequest, TestResponse)
# and client stubs for your gRPC service. They are generated from .proto files.
include("test/gen/test/test_pb.jl")

# ============================================================================
# Step 3: Create a Client for Your RPC Method
# ============================================================================
# The client is bound to a specific RPC method on your gRPC service.
# Arguments: hostname, port
client = TestService_TestRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Send Multiple Async Requests
# ============================================================================
# Use grpc_async_request when you want to send requests without blocking.
# This is useful for sending many requests in parallel.

# Send all requests without waiting for responses
requests = Vector{gRPCRequest}()
for i in 1:10
    # Each request is sent immediately and returns a gRPCRequest handle
    push!(
        requests,
        grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
    )
end

# ============================================================================
# Step 5: Wait for and Process Responses
# ============================================================================
# Use grpc_async_await to retrieve the response when you need it.
for request in requests
    # This blocks until the specific request completes
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
# Step 3: Create a Client for Your RPC Method
# ============================================================================
client = TestService_TestRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Create a Channel to Receive Responses
# ============================================================================
# Use the channel-based pattern when you want to process responses as soon
# as they arrive, regardless of the order they were sent.
N = 10
channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(N)

# ============================================================================
# Step 5: Send All Requests
# ============================================================================
# The index parameter allows you to track which request each response
# corresponds to, since responses may arrive out of order.
for (index, request) in enumerate([TestRequest(i, zeros(UInt64, i)) for i in 1:N])
    grpc_async_request(client, request, channel, index)
end

# ============================================================================
# Step 6: Process Responses as They Arrive
# ============================================================================
# Responses are pushed to the channel as they complete. You can process
# them immediately without waiting for all requests to finish first.
for i in 1:N
    cr = take!(channel)

    # Check if an exception was thrown during the request
    !isnothing(cr.ex) && throw(cr.ex)

    # Use the index to match responses to requests
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
# Step 3: Create a Client for Your RPC Method
# ============================================================================
client = TestService_TestRPC_Client("localhost", 8001)

# ============================================================================
# Step 4: Make a Synchronous Request
# ============================================================================
# This blocks until the response is ready. It's the simplest way to make
# a single gRPC request when you don't need parallelism.
response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
@info response
```
"""
grpc_sync_request(
    client::gRPCServiceClient{TRequest,false,TResponse,false},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} =
    grpc_async_await(grpc_async_request(client, request), TResponse)
