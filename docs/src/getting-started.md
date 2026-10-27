```@meta
CurrentModule = gRPCClient
```

# Getting Started

## Test gRPC Server

All examples in the documentation are run against a test server written in Go. You can run it by doing the following:

```bash
cd test/go

# Build
go build -o grpc_test_server

# Run
./grpc_test_server
```

## Code Generation

gRPCClient.jl integrates with ProtoBuf.jl to automatically generate Julia client stubs for calling gRPC. 

```julia
using ProtoBuf

# Loading gRPCClient before calling protojl is required — it registers the service stub generator that adds client constructors to the output.
using gRPCClient

# Creates Julia bindings for the messages and RPC defined in test.proto
protojl("test/proto/test.proto", ".", "test/gen")
```

This will currently generate code both for an older and an updated API. If backwards compatibility with older versions of `gRPCClient.jl` (before 1.2.0) is not required, running `grpc_register_service_codegen(legacy = false)` is recommended as it will reduce amount of generated code and enable better IDE integration. 

## Next steps

See [Lifecycles](guide/rpc-api.md#Lifecycles) for examples covering every kind of unary and streaming call.
