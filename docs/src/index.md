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

# Loading gRPCClient before calling protojl is required — it registers the service stub generator that adds client constructors to the output.
using gRPCClient

# Creates Julia bindings for the messages and RPC defined in test.proto
protojl("test/proto/test.proto", ".", "test/gen")
```

## Example Usage

See [here](#RPC) for examples covering all provided interfaces for both unary and streaming gRPC calls. 

## API

### Package Initialization / Shutdown

```@docs
grpc_init()
grpc_shutdown()
grpc_global_handle()
```

### Generated ServiceClient Constructors

When you generate service stubs using ProtoBuf.jl, a constructor method is automatically created for each RPC endpoint. These constructors create `gRPCServiceClient` instances that are used to make RPC calls.

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
- **`secure`**: A `Bool` that controls whether HTTPS/gRPCS (when `true`) or HTTP/gRPC (when `false`) is used for the connection. Default: `false`
- **`grpc`**: The global gRPC handle obtained from `grpc_global_handle()`. This manages the underlying libcurl multi-handle for HTTP/2 multiplexing. Default: `grpc_global_handle()`
- **`deadline`**: The gRPC deadline in seconds. If a request takes longer than this time limit, it will be cancelled and raise an exception. Default: `10`
- **`keepalive`**: The TCP keepalive interval in seconds. This sets both `CURLOPT_TCP_KEEPINTVL` (interval between keepalive probes) and `CURLOPT_TCP_KEEPIDLE` (time before first keepalive probe) to help detect broken connections. Default: `60`
- **`max_send_message_length`**: The maximum size in bytes for messages sent to the server. Attempting to send messages larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)
- **`max_recieve_message_length`**: The maximum size in bytes for messages received from the server. Receiving messages larger than this will raise an exception. Default: `4*1024*1024` (4 MiB)

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

```@docs
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
grpc_sync_request(client::gRPCServiceClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
```

#### Streaming

```@docs
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,false}, request::Channel{TRequest}) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,false,TResponse,true},request::TRequest,response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCServiceClient{TRequest,true,TResponse,true},request::Channel{TRequest},response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCServiceClient{TRequest,true,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any} 
```

### Raw Encoded Buffers (Partial Decoding)

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

The generated `*_Client` constructors always use the concrete proto types, so
for raw calls construct a [`gRPCServiceClient`](#Generated-ServiceClient-Constructors)
directly, passing the RPC path. The request and response sides are independent,
so you can make either or both raw.

Send a raw request and receive a raw response:

```julia
using ProtoBuf

# Build the request bytes yourself (here, by encoding a typed message)
io = IOBuffer()
encode(ProtoEncoder(io), MyRequest(42, zeros(UInt64, 10)))
raw_request = take!(io)

client = gRPCClient.gRPCServiceClient{Vector{UInt8}, false, Vector{UInt8}, false}(
    "localhost", 50051, "/foo.MyService/MyRPC",
)
raw_response = grpc_sync_request(client, raw_request)   # raw_response::Vector{UInt8}

# Partially decode only what you need from the response payload
response = decode(ProtoDecoder(IOBuffer(raw_response)), MyResponse)
```

Mixed combinations work too. To send a typed request but receive the response
as raw bytes, make only the response type raw:

```julia
client = gRPCClient.gRPCServiceClient{MyRequest, false, Vector{UInt8}, false}(
    "localhost", 50051, "/foo.MyService/MyRPC",
)
raw_response = grpc_sync_request(client, MyRequest(42, UInt64[]))
```

Raw buffers apply to streaming as well: declare the streaming side's message
type as `Vector{UInt8}` and use a `Channel{Vector{UInt8}}`. For example, a
server-streaming call that receives each response as raw bytes:

```julia
client = gRPCClient.gRPCServiceClient{Vector{UInt8}, false, Vector{UInt8}, true}(
    "localhost", 50051, "/foo.MyService/MyServerStreamRPC",
)
response_c = Channel{Vector{UInt8}}(16)
req = grpc_async_request(client, raw_request, response_c)
for raw in response_c
    response = decode(ProtoDecoder(IOBuffer(raw)), MyResponse)
    # process response
end
grpc_async_await(req)
```

### Exceptions

```@docs
gRPCServiceCallException
```

## gRPCClientUtils.jl

A module for benchmarking and stress testing has been included in `utils/gRPCClientUtils.jl`. In order to add it to your test environment:

```julia
using Pkg
Pkg.add(path="utils/gRPCClientUtils.jl")
```

### Benchmarks

All benchmarks run against the Test gRPC Server in `test/go`. See the relevant [documentation](#Test-gRPC-Server) for information on how to run this.

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

## For LLMs & Agents

This library provides an [`llms.txt`](llms.txt) file designed to bootstrap your context with everything needed to use it effectively.

The file is a compressed, curated snapshot of the library's essential knowledge — trimmed of noise and optimized for limited context windows. Rather than crawling docs, parsing source files, or relying on potentially stale training data, agents should load `llms.txt` first as their authoritative reference.

**It contains:**
- API surface and usage patterns
- Key concepts and terminology
- Common workflows and examples

If you are an LLM or agent operating on this codebase, fetch `llms.txt` before proceeding. It is the single source of truth for how this library works and is purpose-built for programmatic consumption.