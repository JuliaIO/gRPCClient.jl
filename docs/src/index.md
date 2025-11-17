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

All examples in the documentation are run against a test server written in Python. You can run it by doing the following:

```bash
# Install uv package manager - see https://docs.astral.sh/uv/#installation for more details
curl -LsSf https://astral.sh/uv/install.sh | sh

# Change directory to the python test server project
cd test/python

# Run the test server
uv run grpc_test_server.py

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

## Package Initialization / Shutdown

```@docs
grpc_init()
grpc_shutdown()
grpc_global_handle()
```

## RPC

### Unary

```@docs
grpc_async_request(client::gRPCClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCClient{TRequest,false,TResponse,false}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCClient{TRequest,false,TResponse,false}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
grpc_sync_request(client::gRPCClient{TRequest,false,TResponse,false}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
```

### Streaming

```@docs
grpc_async_request(client::gRPCClient{TRequest,true,TResponse,false}, request::Channel{TRequest}) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCClient{TRequest,false,TResponse,true},request::TRequest,response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCClient{TRequest,true,TResponse,true},request::Channel{TRequest},response::Channel{TResponse}) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCClient{TRequest,true,TResponse,false},request::gRPCRequest) where {TRequest<:Any,TResponse<:Any} 
```

## Exceptions

```@docs
gRPCServiceCallException
```