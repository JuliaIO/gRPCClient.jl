# gRPCClient.jl

[![License][license-img]][license-url]
[![Documentation][doc-stable-img]][doc-stable-url]
[![Documentation][doc-dev-img]][doc-dev-url]
[![CI](https://github.com/JuliaIO/gRPCClient.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaIO/gRPCClient.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/JuliaIO/gRPCClient.jl/graph/badge.svg?token=CJkqtuSbML)](https://codecov.io/github/JuliaIO/gRPCClient.jl)


gRPCClient.jl aims to be a production grade gRPC client emphasizing performance and reliability.

## Documentation

The documentation for gRPCClient.jl can be found [here](https://juliaio.github.io/gRPCClient.jl).

### For LLMs & Agents

This library ships agent skills. In Claude Code:

```
/plugin marketplace add JuliaIO/gRPCClient.jl
/plugin install grpcclient-jl
```

That installs `grpcclient-jl` for calling gRPC services and `grpcclient-jl-dev` for working on the package itself. Both live in [`skills/`](skills) as plain Markdown and are the authoritative reference for how this library behaves.

## Benchmarks

Benchmarking, stress-testing, and profiling utilities live in [`utils/gRPCClientUtils.jl`](utils/gRPCClientUtils.jl). Run `benchmark_table()` against the test server in `test/go` to measure throughput, latency, and allocations per workload on your own hardware.

## Acknowledgement

This package is essentially a rewrite of the 0.1 version of gRPCClient.jl together with a gRPC specialized version of [Downloads.jl](https://github.com/JuliaLang/Downloads.jl). Without the above packages to build ontop of this effort would have been a far more signifigant undertaking, so thank you to all of the authors and maintainers who made this possible.

[license-url]: ./LICENSE
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat

[doc-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[doc-dev-url]: https://juliaio.github.io/gRPCClient.jl/dev/

[doc-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[doc-stable-url]: https://juliaio.github.io/gRPCClient.jl/stable/
