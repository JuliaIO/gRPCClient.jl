function profile_memory_fn(f, N)
    grpc_init()

    # Warmup
    _ = f(N)

    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.1 f(N)
    PProf.Allocs.pprof()
end

profile_memory_workload_smol() = profile_memory_fn(workload_smol, workload_smol_N)
profile_memory_workload_32_224_224_uint8() =
    profile_memory_fn(workload_32_224_224_uint8, workload_32_224_224_uint8_N)
profile_memory_workload_streaming_request() =
    profile_memory_fn(workload_streaming_request, workload_streaming_request_N)
profile_memory_workload_streaming_response() =
    profile_memory_fn(workload_streaming_response, workload_streaming_response_N)
profile_memory_workload_streaming_bidirectional() =
    profile_memory_fn(workload_streaming_bidirectional, workload_streaming_bidirectional_N)
