function stress_workload(f::Function)
    while true
        f()
    end
end

stress_workload_smol() = stress_workload(workload_smol)
stress_workload_32_224_224_uint8() = stress_workload(workload_32_224_224_uint8)
stress_workload_streaming_request() = stress_workload(workload_streaming_request)
stress_workload_streaming_response() = stress_workload(workload_streaming_response)
stress_workload_streaming_bidirectional() =
    stress_workload(workload_streaming_bidirectional)
