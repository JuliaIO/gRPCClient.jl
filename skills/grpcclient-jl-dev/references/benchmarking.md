# Benchmarking, stress, and profiling

`utils/gRPCClientUtils.jl` is a separate package, deliberately not a dependency of gRPCClient.jl, holding the measurement tooling. It `include`s `test/gen/test/test_pb.jl` by relative path, so it only works from inside this repository checkout.

```julia
using Pkg
Pkg.add(path = "utils/gRPCClientUtils.jl")
using gRPCClientUtils
```

Every workload runs against the Go test server in `test/go`, so start that first. The port defaults to 8001 and is overridable with `GRPC_BENCH_PORT`.

## Workloads

| Function | Shape |
|---|---|
| `workload_smol(n = 1_000)` | Unary, one-element request and response, async submit then await |
| `workload_32_224_224_uint8(n = 100)` | Unary, a 32x224x224 UInt8-sized payload, buffer preallocated so the measurement excludes caller allocations |
| `workload_streaming_request(n = 1_000)` | Client streaming |
| `workload_streaming_response(n = 1_000)` | Server streaming |
| `workload_streaming_bidirectional(n = 1_000)` | Bidirectional streaming |

Each returns its message count `n`, which is what lets the harness normalize results per message. Keep that contract when adding a workload.

## Benchmark table

```julia
benchmark_table()
```

Runs all five workloads through BenchmarkTools and prints a PrettyTables summary, normalized per message: average memory in KiB, average allocations, throughput in messages per second, and average, standard deviation, minimum, and maximum duration in microseconds. Sample output for shape reference, not as a target:

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

Numbers are only comparable within one machine and one Julia thread count, so record both alongside any result. Allocation counts are the more stable signal when comparing two commits, since throughput moves with machine noise.

## Stress

```julia
stress_workload_smol()
stress_workload_32_224_224_uint8()
stress_workload_streaming_request()
stress_workload_streaming_response()
stress_workload_streaming_bidirectional()
```

Each loops its workload forever, which is how resource leaks and stability problems surface. Watch resident memory, file descriptor count, and thread count over time; a slow climb in descriptors points at watchers or easy handles not being cleaned up, and a climb in tasks points at a pump task that never exits.

## Allocation profiling

```julia
profile_memory_workload_smol()          # and the other four variants
```

Warms up, then runs the workload under `Profile.Allocs` at a 0.1 sample rate and opens a PProf allocation profile. This is the tool for attributing an allocation regression seen in `benchmark_table` to a specific call site.
