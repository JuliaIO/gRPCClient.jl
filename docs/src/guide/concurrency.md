```@meta
CurrentModule = gRPCClient
```

# Concurrency Model

gRPCClient.jl runs background tasks for socket I/O, streaming request and response pumps, and asynchronous unary fan-out. The `gRPCCURL` handle decides how those tasks are scheduled through its `sticky` property, so a single setting controls the model for every request made through that handle.

Two models are available:

- **Non-sticky** (`sticky = false`, the default) uses `Threads.@spawn`. Tasks are migratable and can run on any thread, so the client scales across threads when Julia is started with more than one (for example `julia -t auto`). This is the right choice when you run multithreaded or have CPU-bound encode and decode work
- **Sticky** (`sticky = true`) uses `@async`. Tasks are pinned to the thread that spawned them and run under cooperative, single-threaded scheduling. This model is incompatible with multithreading: it does not parallelize across threads even when more than one is available. It has lower scheduling overhead and avoids cross-thread data movement, which suits purely I/O-bound workloads and single-threaded deployments

The property is set when the handle is constructed and applies to every client that uses it:

```julia
# Coroutine model, pinned to the calling thread
h = gRPCCURL(sticky = true)
grpc_init(h)

chan = gRPCChannel("localhost", 50051; grpc = h)
response = MyService.MyRPC(chan, MyRequest(...))
```

The global handle returned by `grpc_global_handle()` uses the default `sticky = false`.
