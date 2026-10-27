```@meta
CurrentModule = gRPCClient
```

# Legacy API

## Generated ServiceClient Constructors

When you generate service stubs using ProtoBuf.jl, a constructor method is automatically created for each RPC endpoint. These constructors create `gRPCServiceClient` instances that are used to make RPC calls.

### Constructor Signature

For a service method named `TestRPC` in service `TestService`, the generated constructor will have the form:

```julia
TestService_TestRPC_Client(
    host, port;
    secure=false,
    grpc=grpc_global_handle(),
    options...
)
```

### Parameters

- **`host`**: The hostname or IP address of the gRPC server (e.g., `"localhost"`, `"api.example.com"`)
- **`port`**: The port number the gRPC server is listening on (e.g., `50051`)
- **`grpc`**: The global gRPC handle obtained from `grpc_global_handle()`. This manages the underlying libcurl multi-handle for HTTP/2 multiplexing. Default: `grpc_global_handle()`
- **`options...`**: Any of the following keyword arguments:
  - **`secure`**: A `Bool` that controls whether HTTPS/gRPCS (when `true`) or HTTP/gRPC (when `false`) is used for the connection. Default: `false`
  - **`deadline`**: The gRPC deadline in seconds, covering the entire call from submission: time spent queued client-side waiting for one of the handle's `max_streams` slots counts against it, and the transfer (and the `grpc-timeout` header sent to the server) gets only the remaining budget. If the call takes longer than this limit it is cancelled and raises an exception. Pass `Inf` for no deadline: no timeout is enforced client-side and no `grpc-timeout` header is sent, so the call runs until it completes or `grpc_cancel` ends it. Must be non-negative; `0` expires immediately, and a negative, `NaN`, or `-Inf` deadline raises `INVALID_ARGUMENT`. Default: `10`
  - **`keepalive`**: The TCP keepalive interval in seconds. This sets both `CURLOPT_TCP_KEEPINTVL` (interval between keepalive probes) and `CURLOPT_TCP_KEEPIDLE` (time before first keepalive probe) to help detect broken connections. Default: `60`
  - **`max_send_message_length`**: The maximum size in bytes for messages sent to the server. Attempting to send messages larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)
  - **`max_recieve_message_length`**: The maximum size in bytes for messages received from the server. Receiving messages larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)
  - **`token`**: Optional bearer token attached to every request as an `authorization: Bearer <token>` header. 
  - **`metadata`**: A `Dict{String, String}` for adding arbitrary fields to the header. For example, a token can also be attached by setting `metadata = Dict("authorization" => "Bearer <token>")` instead of using the `token` keyword. Setting `token` and an `authorization` metadata entry at the same time raises `INVALID_ARGUMENT`, since the two are the same header and sending both would leave which one applies up to the server; the check is case-insensitive. To override a client-level `token` with per-request metadata, pass `token = nothing` alongside it.

Any of the options mentioned above may also be provided as keyword arguments to `grpc_async_request` or `grpc_async_request`, taking priority over options set for the client.  

### Example

```julia
# Create a client for the TestRPC endpoint
client = TestService_TestRPC_Client(
    "localhost", 50051;
    secure=true,  # Use HTTPS/gRPCS
    deadline=30,  # 30 second timeout
    max_send_message_length=10*1024*1024,  # 10 MiB max send
    max_recieve_message_length=10*1024*1024  # 10 MiB max receive
)
```

```@docs
gRPCClient.gRPCServiceClient
```

## RPC

### Unary

```@docs
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest; options...) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64; options...) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCServiceClient{TRequest,false,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
grpc_sync_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest; options...) where {TRequest<:Any,TResponse<:Any}
```

### Streaming

```@docs
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}; options...) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,true}, request::TRequest,response::Channel{TResponse}; options...) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,true}, request::Channel{TRequest},response::Channel{TResponse}; options...) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any} 
```

### Cancellation

Every request is bounded by its `deadline` even when libcurl stops driving the
transfer. libcurl does not process a handle's timeouts while the handle is
parked waiting for another request's connection to become multiplexable
(`CURLOPT_PIPEWAIT`), so a connection that never becomes ready (for example a
server that accepts TCP but never completes the HTTP/2 handshake) would
otherwise wedge every queued request forever. A client-side watchdog guarantees
each request resolves with `DEADLINE_EXCEEDED` shortly after its deadline.

The deadline also covers time spent queued client-side waiting for one of the
handle's `max_streams` slots, so a request submitted while every slot is held
by a slow or stuck call still fails at its own deadline rather than waiting
indefinitely for a slot.

The exception contract: `grpc_async_request` throws only for conditions it
can detect synchronously at submission (an uninitialized or shut-down handle
as `UNAVAILABLE`, an invalid deadline or a
`token`/`authorization`-metadata conflict as `INVALID_ARGUMENT`, an oversized
message as `RESOURCE_EXHAUSTED`). Every failure that depends on time or
concurrency (deadline exceeded, including expiry while queued, cancellation,
transport errors, server statuses) is raised by `grpc_async_await`.

Shutting a handle down with `grpc_shutdown` fails every request still in
flight with `UNAVAILABLE` from `grpc_async_await`, and a request queued for a
`max_streams` slot with `UNAVAILABLE` from `grpc_async_request`. A shut-down
handle is usually about to be re-initialized, so these calls can be retried,
on this handle once `grpc_init` has run again or elsewhere.

An in-flight request can also be cancelled explicitly at any time:

```@docs
grpc_cancel
```

For a long-lived stream you can combine `deadline = Inf` with `grpc_cancel` to
manage the stream's lifetime yourself: with no deadline the call never times
out (client-side or server-side, since the `grpc-timeout` header is omitted),
and cancellation ends it on demand. After cancelling a client or bidirectional
stream, close your request channel as usual to release its pump task. Note
that with no deadline a request stuck behind a connection that never becomes
ready will wait forever, and until it is cancelled it is never cleaned up and
leaks its resources; `grpc_cancel` (or `grpc_shutdown`) is the only way
out, so prefer a finite deadline unless you have an explicit lifecycle for
the call.

## Raw Encoded Buffers (Partial Decoding)

By default the client encodes a typed message before sending and decodes the
response into a typed message before returning it. You can bypass either step
and work directly with the raw protobuf payload by declaring the relevant
message type parameter as `Vector{UInt8}`. This is useful when you want to
forward bytes you already hold, or partially decode a large response and read
only the fields you care about.

A normal protobuf message type is always a generated struct, so `Vector{UInt8}`
is unambiguous as a "raw buffer" marker for the message type parameter. The raw
buffer is the serialized protobuf message body only; the 5-byte gRPC framing is
still added and stripped by the library, so you never handle it yourself.

Each generated `*_Client` constructor accepts `TRequest` and `TResponse`
keyword arguments that default to the proto message types. Override either (or
both) with `Vector{UInt8}` to make that side raw. The request and response sides
are independent, so you can make either or both raw.

Send a raw request and receive a raw response:

```julia
using ProtoBuf

# Build the request bytes yourself (here, by encoding a typed message)
io = IOBuffer()
encode(ProtoEncoder(io), MyRequest(42, zeros(UInt64, 10)))
raw_request = take!(io)

client = MyService_MyRPC_Client(
    "localhost", 50051;
    TRequest = Vector{UInt8}, TResponse = Vector{UInt8},
)
raw_response = grpc_sync_request(client, raw_request)   # raw_response::Vector{UInt8}

# Partially decode only what you need from the response payload
response = decode(ProtoDecoder(IOBuffer(raw_response)), MyResponse)
```

Mixed combinations work too. To send a typed request but receive the response
as raw bytes, override only `TResponse`:

```julia
client = MyService_MyRPC_Client("localhost", 50051; TResponse = Vector{UInt8})
raw_response = grpc_sync_request(client, MyRequest(42, UInt64[]))
```

Raw buffers apply to streaming as well: override the streaming side's type with
`Vector{UInt8}` and use a `Channel{Vector{UInt8}}`. For example, a
server-streaming call that receives each response as raw bytes:

```julia
client = MyService_MyServerStreamRPC_Client(
    "localhost", 50051;
    TResponse = Vector{UInt8},
)
response_c = Channel{Vector{UInt8}}(16)
req = grpc_async_request(client, raw_request, response_c)
for raw in response_c
    response = decode(ProtoDecoder(IOBuffer(raw)), MyResponse)
    # process response
end
grpc_async_await(req)
```

If you do not have a generated constructor, the same applies by building a
[`gRPCServiceClient`](#Generated-ServiceClient-Constructors) directly with
`Vector{UInt8}` type parameters and the RPC path, for example
`gRPCClient.gRPCServiceClient{Vector{UInt8}, false, Vector{UInt8}, false}("localhost", 50051, "/foo.MyService/MyRPC")`.

## Exceptions

```@docs
gRPCServiceCallException
```
