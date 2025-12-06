function profile_memory_fn(f::Function)
    grpc_init()

    # Warmup
    _ = f()

    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.1 f()
    PProf.Allocs.pprof()
end

profile_memory_workload_smol() = profile_memory_fn(workload_smol)
profile_memory_workload_32_224_224_uint8() = profile_memory_fn(workload_32_224_224_uint8)
profile_memory_workload_streaming_request() = profile_memory_fn(workload_streaming_request)
profile_memory_workload_streaming_response() =
    profile_memory_fn(workload_streaming_response)
profile_memory_workload_streaming_bidirectional() =
    profile_memory_fn(workload_streaming_bidirectional)
