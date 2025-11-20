# gRPCClient.jl

[![License][license-img]][license-url]
[![Documentation][doc-stable-img]][doc-stable-url]
[![Documentation][doc-dev-img]][doc-dev-url]
[![CI](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/csvance/gRPCClient2.jl/graph/badge.svg?token=2SUFGIE336)](https://codecov.io/github/csvance/gRPCClient2.jl)


gRPCClient.jl aims to be a production grade gRPC client emphasizing performance and reliability.

## Documentation

The documentation for gRPCClient.jl can be found [here](https://csvance.github.io/gRPCClient2.jl).

## Benchmarks 

To run the benchmarks, start a Julia terminal and include the `workloads.jl` file:

```julia
include("workloads.jl")
```

All of the benchmarks use the asynchronous channels interface to run multiple requests at the same time. All benchmark tests run against the Test gRPC Server in `test/python`. See the relevant [documentation](https://csvance.github.io/gRPCClient2.jl/dev/#Test-gRPC-Server) for information on how to run this.

### "smol"

Smol benchmarks sending and recieving lots of extremely small protobuffs (~16 bytes each)

```julia
# Note that there are 1_000 RPC calls per sample, so the mean should be divided by 1_000
julia> benchmark_workload_smol()
BenchmarkTools.Trial: 41 samples with 1 evaluation per sample.
 Range (min … max):  108.345 ms … 135.084 ms  ┊ GC (min … max): 0.00% … 7.75%
 Time  (median):     123.482 ms               ┊ GC (median):    0.00%
 Time  (mean ± σ):   122.444 ms ±   6.091 ms  ┊ GC (mean ± σ):  0.33% ± 1.41%

                               █   ▃▃▃█ █  █ ▃                   
  ▇▁▇▁▁▁▁▇▇▁▁▁▇▁▁▁▁▇▇▇▇▇▁▇▁▇▇▁▁█▁▇▁████▁█▇▁█▇█▁▁▁▁▁▇▇▇▁▁▁▁▇▁▁▁▇ ▁
  108 ms           Histogram: frequency by time          135 ms <

 Memory estimate: 4.27 MiB, allocs estimate: 93559.
 ```

 The mean RPC throughput is 8166 request/sec.

 ### (32, 224, 224) UInt8 Batch Inference

 This benchmark simulates sending 224x224 UInt8 images in a batch size of 32 for inference (~1.6 MB each)

```julia
# Note that there are 100 RPC calls per sample, so the mean should be divided by 100
julia> benchmark_workload_32_224_224_uint8()
BenchmarkTools.Trial: 27 samples with 1 evaluation per sample.
 Range (min … max):  151.472 ms … 225.548 ms  ┊ GC (min … max): 1.17% … 10.24%
 Time  (median):     186.578 ms               ┊ GC (median):    1.32%
 Time  (mean ± σ):   187.099 ms ±  17.970 ms  ┊ GC (mean ± σ):  3.72% ±  4.59%

              ▃          ▃    █ ▃                                
  ▇▁▁▁▁▁▇▁▁▁▁▇█▁▇▇▁▁▁▁▁▁▇█▁▁▇▁█▁█▇▁▁▇▁▁▇▇▇▇▁▁▇▇▁▁▇▁▁▁▁▁▁▁▁▇▁▁▁▇ ▁
  151 ms           Histogram: frequency by time          226 ms <

 Memory estimate: 64.00 MiB, allocs estimate: 12943.
```

The mean RPC throughput is ~534 request/sec.

## Stress Testing

To run the stress tests, start a Julia terminal and include the `workloads.jl` file:

```julia
include("workloads.jl")
```

Stress tests are available corresponding to each benchmark listed above:

- `stress_workload_smol()`
- `stress_workload_32_224_224_uint8()`

These run forever, and are useful to help identify any stability issues or resource leaks.

## Acknowledgement

This package is essentially a rewrite of the 0.1 version of gRPCClient.jl together with a gRPC specialized version of [Downloads.jl](https://github.com/JuliaLang/Downloads.jl). Without the above packages to build ontop of this effort would have been a far more signifigant undertaking, so thank you to all of the authors and maintainers who made this possible.

[license-url]: ./LICENSE
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat

[doc-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[doc-dev-url]: https://csvance.github.io/gRPCClient2.jl/dev/

[doc-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[doc-stable-url]: https://csvance.github.io/gRPCClient2.jl/stable/