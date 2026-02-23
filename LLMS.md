# gRPCClient.jl

gRPCClient.jl aims to be a production grade gRPC client emphasizing performance and reliability.

## Features

- Unary+Streaming RPC
- HTTP/2 connection multiplexing
- Synchronous and asynchronous interfaces
- Thread safe
- SSL/TLS

The client is missing a few features which will be added over time if there is sufficient interest:

- OAuth2
- Compression

## Getting Started

### Test gRPC Server

All examples in the documentation are run against a test server written in Go. You can run it by doing the following:

```bash
cd test/go

# Build
go build -o grpc_test_server

# Run
./grpc_test_server
```

### Code Generation

gRPCClient.jl integrates with ProtoBuf.jl to automatically generate Julia client stubs for calling gRPC.

```julia
using ProtoBuf
using gRPCClient

# Creates Julia bindings for the messages and RPC defined in test.proto
protojl("test/proto/test.proto", ".", "test/gen")
```

## Example Usage

See [here](build/index.md#RPC) for examples covering all provided interfaces for both unary and streaming gRPC calls.

## API

### Package Initialization / Shutdown

```
gRPCClient.grpc_init — Method.
```

```julia
grpc_init([grpc_curl::gRPCCURL])
```

Initializes the `gRPCCURL` object. The global handle is initialized automatically when the package is loaded. There is
no harm in calling this more than once (ie by different packages/dependencies).

Unless specifying a `gRPCCURL` the global one provided by `grpc_global_handle()` is used. Each `gRPCCURL` state has its
own connection pool and request semaphore, so sometimes you may want to manage your own like shown below:

```julia
grpc_myapp = gRPCCURL()
grpc_init(grpc_myapp)

client = TestService_TestRPC_Client("172.238.177.88", 8001; grpc=grpc_myapp)

# Make some gRPC calls

# Only shuts down your gRPC handle
grpc_shutdown(grpc_myapp)
```

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/gRPC.jl#L10-L28)

```
gRPCClient.grpc_shutdown — Method.
```

```julia
grpc_shutdown([grpc_curl::gRPCCURL])
```

Shuts down the `gRPCCURL`. This neatly cleans up all active connections and requests. Useful for calling during
development with Revise. Unless specifying the `gRPCCURL`, the global one provided by `grpc_global_handle()` is
shutdown.

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/gRPC.jl#L32-L36)

```
gRPCClient.grpc_global_handle — Method.
```

```julia
grpc_global_handle()
```

Returns the global `gRPCCURL` state which contains a libCURL multi handle. By default all gRPC clients use this multi in
order to ensure that HTTP/2 multiplexing happens where possible.

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/gRPC.jl#L3-L7)

### Generated ServiceClient Constructors

When you generate service stubs using ProtoBuf.jl, a constructor method is automatically created for each RPC endpoint.
These constructors create `gRPCServiceClient` instances that are used to make RPC calls.

#### Constructor Signature

For a service method named `TestRPC` in service `TestService`, the generated constructor will have the form:

```julia
TestService_TestRPC_Client(
    host, port;
    secure=false,
    grpc=grpc_global_handle(),
    deadline=10,
    keepalive=60,
    max_send_message_length = 4*1024*1024,
    max_recieve_message_length = 4*1024*1024,
)
```

#### Parameters

- **`host`**: The hostname or IP address of the gRPC server (e.g., `"localhost"`, `"api.example.com"`)
- **`port`**: The port number the gRPC server is listening on (e.g., `50051`)
- **`secure`**: A `Bool` that controls whether HTTPS/gRPCS (when `true`) or HTTP/gRPC (when `false`) is used for the
  connection. Default: `false`
- **`grpc`**: The global gRPC handle obtained from `grpc_global_handle()`. This manages the underlying libcurl
  multi-handle for HTTP/2 multiplexing. Default: `grpc_global_handle()`
- **`deadline`**: The gRPC deadline in seconds. If a request takes longer than this time limit, it will be cancelled and
  raise an exception. Default: `10`
- **`keepalive`**: The TCP keepalive interval in seconds. This sets both `CURLOPT_TCP_KEEPINTVL` (interval between
  keepalive probes) and `CURLOPT_TCP_KEEPIDLE` (time before first keepalive probe) to help detect broken connections.
  Default: `60`
- **`max_send_message_length`**: The maximum size in bytes for messages sent to the server. Attempting to send messages
  larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)
- **`max_recieve_message_length`**: The maximum size in bytes for messages received from the server. Receiving messages
  larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)

#### Example

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

### RPC

#### Unary

```
gRPCClient.grpc_async_request — Method.
```

```julia
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
```

Initiate an asynchronous gRPC request: send the request to the server and then immediately return a `gRPCRequest` object
without waiting for the response. In order to wait on / retrieve the result once its ready, call `grpc_async_await`.
This is ideal when you need to send many requests in parallel and waiting on each response before sending the next
request would things down.

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Unary.jl#L3-L31)

```
gRPCClient.grpc_async_request — Method.
```

```julia
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}
```

Initiate an asynchronous gRPC request: send the request to the server and then immediately return. When the request is
complete a background task will put the response in the provided channel. This has the advantage over the request /
await patern in that you can handle responses immediately after they are recieved in any order.

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Unary.jl#L70-L101)

```
gRPCClient.grpc_async_await — Method.
```

```julia
grpc_async_await(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
```

Wait for the request to complete and return the response when it is ready. Throws any exceptions that were encountered
during handling of the request.

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Unary.jl#L145-L149)

```
gRPCClient.grpc_sync_request — Method.
```

```julia
grpc_sync_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
```

Do a synchronous gRPC request: send the request and wait for the response before returning it. Under the hood this just
calls `grpc_async_request` and `grpc_async_await`. Use this when you want the simplest possible interface for a single
request.

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Unary.jl#L156-L176)

#### Streaming

```
gRPCClient.grpc_async_request — Method.
```

```julia
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}) where {TRequest<:Any,TResponse<:Any}
```

Start a client streaming gRPC request (multiple requests, single response).

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Streaming.jl#L110-L138)

```
gRPCClient.grpc_async_request — Method.
```

```julia
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,true},request::TRequest,response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
```

Start a server streaming gRPC request (single request, multiple responses).

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Streaming.jl#L167-L195)

```
gRPCClient.grpc_async_request — Method.
```

```julia
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,true},request::Channel{TRequest},response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
```

Start a bidirectional streaming gRPC request (multiple requests, multiple responses).

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

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Streaming.jl#L231-L265)

```
gRPCClient.grpc_async_await — Method.
```

```julia
grpc_async_await(client::gRPCServiceClient{TRequest,true,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
```

Raise any exceptions encountered during the streaming request.

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/Streaming.jl#L299-L303)

### Exceptions

```
gRPCClient.gRPCServiceCallException — Type.
```

Exception type that is thrown when something goes wrong while calling an RPC. This can either be triggered by the
servers response code or by the client when something fails.

This exception type has two fields:

1. `grpc_status::Int` - See [here](https://grpc.io/docs/guides/status-codes/) for an indepth explanation of each status.
2. `message::String`

[source](https://github.com/JuliaIO/gRPCClient.jl/blob/7cfad6b790b5b90f82dead69c9d44bd9d55fda33/src/gRPCClient.jl#L21-L29)

## gRPCClientUtils.jl

A module for benchmarking and stress testing has been included in `utils/gRPCClientUtils.jl`. In order to add it to your
test environment:

```julia
using Pkg
Pkg.add(path="utils/gRPCClientUtils.jl")
```

### Benchmarks

All benchmarks run against the Test gRPC Server in `test/go`. See the
relevant [documentation](build/index.md#Test-gRPC-Server) for information on how to run this.

#### All Benchmarks w/ PrettyTables.jl

```julia
using gRPCClientUtils

benchmark_table()
```

```
╭──────────────────────────────────┬─────────────┬────────────────┬────────────┬──────────────┬─────────┬──────┬──────╮
│                        Benchmark │  Avg Memory │     Avg Allocs │ Throughput │ Avg duration │ Std-dev │  Min │  Max │
│                                  │ KiB/message │ allocs/message │ messages/s │           μs │      μs │   μs │   μs │
├──────────────────────────────────┼─────────────┼────────────────┼────────────┼──────────────┼─────────┼──────┼──────┤
│                    workload_smol │        2.78 │           67.5 │      17744 │           56 │     3.3 │   51 │   66 │
│        workload_32_224_224_uint8 │       636.8 │           74.1 │        578 │         1731 │   99.33 │ 1583 │ 1899 │
│       workload_streaming_request │        0.87 │            6.5 │     339916 │            3 │    1.61 │    2 │   20 │
│      workload_streaming_response │        13.0 │           27.7 │      65732 │           15 │    4.94 │    6 │   50 │
│ workload_streaming_bidirectional │        1.45 │           25.6 │     105133 │           10 │    6.06 │    4 │   55 │
╰──────────────────────────────────┴─────────────┴────────────────┴────────────┴──────────────┴─────────┴──────┴──────╯
```

### Stress Workloads

In addition to benchmarks, a number of workloads based on these are available:

- `stress_workload_smol()`
- `stress_workload_32_224_224_uint8()`
- `stress_workload_streaming_request()`
- `stress_workload_streaming_response()`
- `stress_workload_streaming_bidirectional()`

These run forever, and are useful to help identify any stability issues or resource leaks.