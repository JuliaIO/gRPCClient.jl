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

Fetch [`llms.txt`](https://juliaio.github.io/gRPCClient.jl/llms.txt) before proceeding. It contains compressed, complete documentation optimized for limited context windows and is the authoritative reference for using this library.

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
