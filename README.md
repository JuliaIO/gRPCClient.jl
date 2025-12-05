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


### Naive Baseline: `julia`

By default Julia 1.12 starts with just one thread. The closer to `@async` we get, the better performance is for most cases. 
However, it is unlikely Julia will be used this way in the real world.

```
╭──────────────────────────────────┬─────────────┬────────────────┬────────────┬──────────────┬─────────┬──────┬──────╮
│                        Benchmark │  Avg Memory │     Avg Allocs │ Throughput │ Avg duration │ Std-dev │  Min │  Max │
│                                  │ KiB/message │ allocs/message │    calls/s │           μs │      μs │   μs │   μs │
├──────────────────────────────────┼─────────────┼────────────────┼────────────┼──────────────┼─────────┼──────┼──────┤
│                    workload_smol │        2.95 │           72.5 │      18424 │           54 │    3.54 │   48 │   66 │
│        workload_32_224_224_uint8 │       637.0 │           79.1 │        548 │         1826 │  405.48 │ 1602 │ 2730 │
│       workload_streaming_request │        0.61 │            6.6 │     508983 │            2 │    0.67 │    1 │   15 │
│      workload_streaming_response │       12.99 │           27.6 │     194689 │            5 │    0.52 │    4 │    9 │
│ workload_streaming_bidirectional │        1.98 │           25.5 │     490718 │            2 │    0.59 │    1 │   13 │
╰──────────────────────────────────┴─────────────┴────────────────┴────────────┴──────────────┴─────────┴──────┴──────╯
```

### Real World: `julia -t auto`

Using more threads isn't great for async IO, but this is likely how most people will be using `gRPCClient.jl`.

```
╭──────────────────────────────────┬─────────────┬────────────────┬────────────┬──────────────┬─────────┬──────┬──────╮
│                        Benchmark │  Avg Memory │     Avg Allocs │ Throughput │ Avg duration │ Std-dev │  Min │  Max │
│                                  │ KiB/message │ allocs/message │    calls/s │           μs │      μs │   μs │   μs │
├──────────────────────────────────┼─────────────┼────────────────┼────────────┼──────────────┼─────────┼──────┼──────┤
│                    workload_smol │        2.95 │           72.5 │      18014 │           56 │    3.08 │   50 │   64 │
│        workload_32_224_224_uint8 │       637.0 │           79.7 │        567 │         1762 │   99.07 │ 1628 │ 1911 │
│       workload_streaming_request │        0.86 │            6.5 │     341851 │            3 │    1.68 │    2 │   30 │
│      workload_streaming_response │        13.0 │           27.7 │      64515 │           16 │    5.12 │    6 │   33 │
│ workload_streaming_bidirectional │        1.41 │           25.6 │     102072 │           10 │    6.23 │    4 │   52 │
╰──────────────────────────────────┴─────────────┴────────────────┴────────────┴──────────────┴─────────┴──────┴──────╯
```

## Acknowledgement

This package is essentially a rewrite of the 0.1 version of gRPCClient.jl together with a gRPC specialized version of [Downloads.jl](https://github.com/JuliaLang/Downloads.jl). Without the above packages to build ontop of this effort would have been a far more signifigant undertaking, so thank you to all of the authors and maintainers who made this possible.

[license-url]: ./LICENSE
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat

[doc-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[doc-dev-url]: https://juliaio.github.io/gRPCClient.jl/dev/

[doc-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[doc-stable-url]: https://juliaio.github.io/gRPCClient.jl/stable/
