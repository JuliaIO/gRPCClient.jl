```@raw html
---
layout: home

hero:
  name: gRPCClient.jl
  text: A production grade gRPC client for Julia
  tagline: Built on libcurl, emphasizing performance and reliability.
  actions:
    - theme: brand
      text: Get started
      link: /getting-started/
    - theme: alt
      text: Guide
      link: /guide/setup-api/
    - theme: alt
      text: View on GitHub
      link: https://github.com/JuliaIO/gRPCClient.jl

features:
  - icon: 🔁
    title: Unary and streaming RPCs
    details: Unary, client streaming, server streaming and bidirectional streaming, each callable synchronously or asynchronously.
    link: /guide/rpc-api/
  - icon: 🧩
    title: Generated service modules
    details: "`protojl` turns every `service` into a module of RPC functions with typed signatures and docstrings."
    link: "/guide/setup-api/#Code-generation"
  - icon: ✅
    title: Julia 1.10 and newer
    details: Tested on Linux, Windows and macOS, with workarounds for the libcurl bugs in the versions bundled with Julia 1.10 and 1.11.
  - icon: 🧵
    title: Thread safe
    details: Start and drive calls from any task or thread.
    link: /guide/concurrency/
  - icon: ⚡
    title: Built for throughput
    details: Profiled, benchmarked and optimized to minimize allocations and maximize throughput.
    link: /utils/
  - icon: 📦
    title: Partial decoding
    details: Send and receive raw encoded buffers when you only need part of a message.
    link: /guide/raw-buffers/
---
```

```@meta
CurrentModule = gRPCClient
```

## Planned features

The client is missing a few features which will be added over time if there is sufficient interest:

- OAuth2
- Compression
