module gRPCClientUtils

using gRPCClient
using BenchmarkTools
using PrettyTables
using ProgressBars
using ProtoBuf

include("../../../test/gen/test/test_pb.jl")
include("Workloads.jl")
include("Benchmark.jl")
include("Stress.jl")

export benchmark_table

export workload_smol
export workload_32_224_224_uint8
export workload_streaming_request
export workload_streaming_response
export workload_streaming_bidirectional

export stress_workload_smol
export stress_workload_32_224_224_uint8
export stress_workload_streaming_request
export stress_workload_streaming_response
export stress_workload_streaming_bidirectional


end # module gRPCClientUtils
