# For LLMs & Agents

This library ships agent skills rather than an `llms.txt` file. Install them in Claude Code with:

```
/plugin marketplace add JuliaIO/gRPCClient.jl
/plugin install grpcclient-jl
```

Two skills are included, and each loads only what the task at hand needs:

- **`grpcclient-jl`** for calling gRPC services: code generation with `protojl`, unary and streaming RPC, deadlines and cancellation, authentication metadata, raw protobuf buffers, and the exception contract
- **`grpcclient-jl-dev`** for working on the package itself: the Go test server, the test suite, stub regeneration, the libcurl transport internals, and the benchmarking utilities

The skills live in [`skills/`](https://github.com/JuliaIO/gRPCClient.jl/tree/main/skills) as plain Markdown, so they can also be read directly or copied into another agent's context. They are the authoritative reference for how this library behaves, maintained alongside the source.
