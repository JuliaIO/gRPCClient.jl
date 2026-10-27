```@meta
CurrentModule = gRPCClient
```

# gRPCClientUtils.jl

A module for benchmarking and stress testing has been included in `utils/gRPCClientUtils.jl`. In order to add it to your test environment:

```julia
using Pkg
Pkg.add(path="utils/gRPCClientUtils.jl")
```

## Benchmarks

All benchmarks run against the Test gRPC Server in `test/go`. See the relevant [documentation](getting-started.md#Test-gRPC-Server) for information on how to run this.

### All Benchmarks w/ PrettyTables.jl

```julia
using gRPCClientUtils

benchmark_table()
```

```
╭──────────────────────────────────┬─────────────┬────────────────┬────────────┬──────────────┬─────────┬──────┬──────╮
│                        Benchmark │  Avg Memory │     Avg Allocs │ Throughput │ Avg duration │ Std-dev │  Min │  Max │
│                                  │ KiB/message │ allocs/message │ messages/s │           μs │      μs │   μs │   μs │
├──────────────────────────────────┼─────────────┼────────────────┼────────────┼──────────────┼─────────┼──────┼──────┤
│                    workload_smol │        2.78 │           67.5 │      17744 │           56 │     3.3 │   51 │   66 │
│        workload_32_224_224_uint8 │       636.8 │           74.1 │        578 │         1731 │   99.33 │ 1583 │ 1899 │
│       workload_streaming_request │        0.87 │            6.5 │     339916 │            3 │    1.61 │    2 │   20 │
│      workload_streaming_response │        13.0 │           27.7 │      65732 │           15 │    4.94 │    6 │   50 │
│ workload_streaming_bidirectional │        1.45 │           25.6 │     105133 │           10 │    6.06 │    4 │   55 │
╰──────────────────────────────────┴─────────────┴────────────────┴────────────┴──────────────┴─────────┴──────┴──────╯
```

## Stress Workloads

In addition to benchmarks, a number of workloads based on these are available:

- `stress_workload_smol()`
- `stress_workload_32_224_224_uint8()`
- `stress_workload_streaming_request()`
- `stress_workload_streaming_response()`
- `stress_workload_streaming_bidirectional()`

These run forever, and are useful to help identify any stability issues or resource leaks.
