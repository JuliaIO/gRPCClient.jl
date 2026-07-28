---
name: grpcclient-jl-dev
description: Work on the gRPCClient.jl package itself. Covers running the Go test server, running and extending the test suite, regenerating test stubs with protoc.sh, building the docs, benchmarking and stress testing with gRPCClientUtils, and navigating the libcurl transport in src/Curl.jl. Use when editing files in this repository (src/Curl.jl, src/gRPC.jl, src/Unary.jl, src/Streaming.jl, src/ProtoBuf.jl, test/runtests.jl) or debugging the client's transport, deadline watchdog, or streaming pumps. For calling a gRPC service as a user of the package, use the grpcclient-jl skill instead.
---

# Developing gRPCClient.jl

## Repository map

| Path | Contents |
|---|---|
| `src/gRPCClient.jl` | Module entry: exception types, `GRPC_*` status constants, includes, exports, `__init__` |
| `src/Curl.jl` | The libcurl transport: `gRPCCURL`, `gRPCRequest`, callbacks, socket watchers, concurrency semaphore, deadline watchdog, `grpc_cancel` |
| `src/gRPC.jl` | Public handle lifecycle, `gRPCServiceClient`, request framing, the generic `grpc_async_await` |
| `src/Unary.jl` | Unary methods and `gRPCAsyncChannelResponse` |
| `src/Streaming.jl` | Streaming methods and the request and response pump tasks; included only on Julia 1.12 and newer |
| `src/ProtoBuf.jl` | The ProtoBuf.jl codegen hook that emits `*_Client` constructors |
| `test/proto/test.proto` | One service with all four RPC variants |
| `test/gen/` | Checked-in generated stubs used by the suite |
| `test/go/` | The Go reference server every test and benchmark runs against |
| `test/python/` | Generated Python stubs, regenerated alongside the Julia ones |
| `utils/gRPCClientUtils.jl` | Separate package for benchmarks, stress workloads, and memory profiling |

Streaming is conditionally compiled: `src/Streaming.jl` is included only under `@static if VERSION >= v"1.12"`, so anything added there needs a matching version guard in the tests.

## Test server

```bash
cd test/go
go build -o grpc_test_server
./grpc_test_server              # listens on :8001
```

The server accepts the bearer token `test-secret-token`, mirrored by `_TEST_BEARER_TOKEN` in `test/runtests.jl`. Requests carrying an `authorization` header must present exactly that value; requests without one are unaffected.

## Running tests

```bash
# Server already running on localhost:8001
julia --project test/runtests.jl

# Let the suite start and stop the Go server itself, which is what CI does
JULIA_GRPCCLIENT_TEST_START_SERVER=go julia --project test/runtests.jl

# Point at a server elsewhere
GRPC_TEST_SERVER_HOST=myhost GRPC_TEST_SERVER_PORT=9000 julia --project test/runtests.jl
```

`JULIA_GRPCCLIENT_TEST_START_SERVER` accepts `go` or `false`; any other value is an error. With `go`, the suite runs `./go/grpc_test_server` from the `test` directory, so build it first, and reads its output until the startup line appears, giving up after 10 seconds. Host and port default to `localhost` and `8001`.

CI covers Julia 1.10, 1.12, and nightly across Linux, Windows, macOS 15 x64, and macOS aarch64, with a 5 minute timeout on the test job. The workflow only triggers on changes under `src/`, `test/`, `Project.toml`, or the workflow file, so documentation and utils changes skip the matrix.

## Regenerating stubs

```bash
cd test
bash protoc.sh
```

This regenerates the Python stubs in `test/python/` with `grpc_tools.protoc` through `uv`, then regenerates `test/gen/` by running `protojl("proto/test.proto", ".", "gen")` in a fresh Julia process. Changes to `src/ProtoBuf.jl` are only visible in the checked-in stubs after running it, and the `Code Generation` testset asserts on the generated text, including the `# gRPCClient.jl BEGIN` and `# gRPCClient.jl END` markers, the four constructor names, the `TRequest=`/`TResponse=` keywords, and the streaming type parameters for each variant.

## Docs

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

`docs/src/index.md` uses `@docs` blocks that name method signatures explicitly, so renaming or re-signing a public method breaks the docs build. Documenter is strict about docstrings it cannot resolve, which is the usual cause of a red docs job after an API change.

## Test suite conventions

The suite is one top-level `@testset "gRPCClient.jl"` with nested sets per area. Points worth matching when adding tests:

- Concurrency is covered twice over, under `@async` and under `Threads.@spawn`, because the two exercise different `sticky` paths
- Failure paths are exercised directly, including deadline expiry, cancellation of a never-ready connection, oversized messages, shutdown during concurrent requests, and exceptions raised inside the streaming pumps
- Internal names used by tests are imported explicitly at the top of `test/runtests.jl`, for example `grpc_timeout_header_val` and the `GRPC_*` constants, since the constants are not exported
- Tests that need a connection which never becomes ready open a listening socket that accepts TCP without completing the HTTP/2 handshake, which is the scenario the deadline watchdog exists for

## Reference files

| File | Read it when |
|---|---|
| `references/internals.md` | Touching the transport, the request lifecycle, locking, the semaphore, the watchdog, or the streaming pumps |
| `references/benchmarking.md` | Measuring throughput, allocations, or latency, or running stress and profiling workloads |
