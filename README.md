# gRPCClient.jl

[![License][license-img]][license-url]
[![Documentation][doc-stable-img]][doc-stable-url]
[![Documentation][doc-dev-img]][doc-dev-url]
[![CI](https://github.com/JuliaIO/gRPCClient.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaIO/gRPCClient.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/JuliaIO/gRPCClient.jl/graph/badge.svg?token=CJkqtuSbML)](https://codecov.io/github/JuliaIO/gRPCClient.jl)


gRPCClient.jl aims to be a production grade gRPC client emphasizing performance and reliability.

## Documentation

The documentation for gRPCClient.jl can be found [here](https://juliaio.github.io/gRPCClient.jl).

## Benchmarks

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

## Acknowledgement

This package is essentially a rewrite of the 0.1 version of gRPCClient.jl together with a gRPC specialized version of [Downloads.jl](https://github.com/JuliaLang/Downloads.jl). Without the above packages to build ontop of this effort would have been a far more signifigant undertaking, so thank you to all of the authors and maintainers who made this possible.

[license-url]: ./LICENSE
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat

[doc-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[doc-dev-url]: https://juliaio.github.io/gRPCClient.jl/dev/

[doc-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[doc-stable-url]: https://juliaio.github.io/gRPCClient.jl/stable/
