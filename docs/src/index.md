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

**Note: support for this is currently being upstreamed into [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl/pull/283). Until then, make sure you add the feature branch with gRPC code generation support:**

`pkg> add https://github.com/csvance/ProtoBuf.jl#external-service-support`

gRPCClient.jl integrates with ProtoBuf.jl to automatically generate Julia client stubs for calling gRPC. 

```julia
using ProtoBuf
using gRPCClient

# Register our service codegen with ProtoBuf.jl
grpc_register_service_codegen()

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
╭──────────────────────────────────┬─────────┬────────┬─────────────┬──────────┬────────────┬──────────────┬─────────┬──────┬──────╮
│                        Benchmark │       N │ Memory │ Allocations │ Duration │ Throughput │ Avg duration │ Std-dev │  Min │  Max │
│                                  │   calls │    MiB │             │        s │    calls/s │           μs │      μs │   μs │   μs │
├──────────────────────────────────┼─────────┼────────┼─────────────┼──────────┼────────────┼──────────────┼─────────┼──────┼──────┤
│                    workload_smol │   94000 │   3.74 │       85110 │     5.01 │      18756 │           53 │     4.2 │   47 │   71 │
│        workload_32_224_224_uint8 │    2800 │  63.78 │        9230 │     5.11 │        548 │         1826 │   378.6 │ 1598 │ 2657 │
│       workload_streaming_request │ 2566000 │   0.61 │        6615 │     4.99 │     514001 │            2 │    0.61 │    1 │   16 │
│      workload_streaming_response │  985000 │   13.0 │       27721 │      5.0 │     197101 │            5 │    0.48 │    4 │    7 │
│ workload_streaming_bidirectional │ 2568000 │   1.98 │       25503 │     4.99 │     514539 │            2 │     0.5 │    1 │   12 │
╰──────────────────────────────────┴─────────┴────────┴─────────────┴──────────┴────────────┴──────────────┴─────────┴──────┴──────╯
```

### Stress Workloads

In addition to benchmarks, a number of workloads based on these are available:

- `stress_workload_smol()`
- `stress_workload_32_224_224_uint8()`
- `stress_workload_streaming_request()`
- `stress_workload_streaming_response()`
- `stress_workload_streaming_bidirectional()`

These run forever, and are useful to help identify any stability issues or resource leaks.
