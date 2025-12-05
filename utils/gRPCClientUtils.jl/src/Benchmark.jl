benchmark_workload_smol() = @benchmark workload_smol(1_000)
benchmark_workload_32_224_224_uint8() = @benchmark workload_32_224_224_uint8(100)
benchmark_workload_streaming_request() = @benchmark workload_streaming_request(1_000)
benchmark_workload_streaming_response() = @benchmark workload_streaming_response(1_000)
benchmark_workload_streaming_bidirectional() =
    @benchmark workload_streaming_bidirectional(1_000)


function perform_benchmark(f, N)
    b = @benchmark $f($N)
    timing = sum(b.times) / 1e9
    timings_us = b.times ./ 1e3
    N_sample = length(b.times) * N
    mem = round(b.memory / (1024*1024), digits = 2)

    return [
        f,
        1000*mem / N, # Avg Memory
        round(b.allocs / N, digits = 1), # Avg Allocs
        round(Int, N_sample/timing), # Throughput
        round(Int, mean(timings_us) / N), # Avg duration
        round(std(timings_us) / N, digits = 2),
        round(Int, minimum(timings_us) / N),
        round(Int, maximum(timings_us) / N),
    ]
end

function benchmark_table()
    grpc_init()

    column_labels = [
        [
            "Benchmark",
            "Avg Memory",
            "Avg Allocs",
            "Throughput",
            "Avg duration",
            "Std-dev",
            "Min",
            "Max",
        ],
        ["", "KiB/message", "allocs/message", "calls/s", "μs", "μs", "μs", "μs"],
    ]
    all_benchmarks = [
        (workload_smol, 1_000),
        (workload_32_224_224_uint8, 100),
        (workload_streaming_request, 1_000),
        (workload_streaming_response, 1_000),
        (workload_streaming_bidirectional, 1_000),
    ]

    all_results = [perform_benchmark(f, N) for (f, N) in ProgressBar(all_benchmarks)]

    pretty_table(
        permutedims(reduce(hcat, all_results));
        column_labels = column_labels,
        style = TextTableStyle(first_line_column_label = crayon"yellow bold"),
        table_format = TextTableFormat(borders = text_table_borders__unicode_rounded),
    )
end
