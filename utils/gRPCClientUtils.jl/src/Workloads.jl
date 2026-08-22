# Port of the TestService benchmark server. Override with GRPC_BENCH_PORT.
_bench_port() = parse(Int, get(ENV, "GRPC_BENCH_PORT", "8001"))

function workload_32_224_224_uint8(n = 100)
    client = TestService_TestRPC_Client("localhost", _bench_port())

    reqs = Vector{gRPCRequest}()

    send_sz = 32 * 224 * 224 ÷ sizeof(UInt64)
    # Pre-allocate this so we are measuring gRPC client performance without external allocations
    test_buf = zeros(UInt64, send_sz)

    for i in 1:n
        req = grpc_async_request(client, TestRequest(32, test_buf))
        push!(reqs, req)
    end
    for req in reqs
        grpc_async_await(req)
    end

    return n
end

function workload_32_224_224_uint8_simple_api(n = 100)
    chan = gRPCClient.gRPCChannel("localhost", _bench_port(), grpc = grpc_global_handle())
    rpcs = Vector{gRPCClient.gRPCUnaryCall{typeof(gRPCClientUtils.TestService.TestRPC)}}()

    send_sz = 32 * 224 * 224 ÷ sizeof(UInt64)
    # Pre-allocate this so we are measuring gRPC client performance without external allocations
    test_buf = zeros(UInt64, send_sz)

    for i in 1:n
        rpc = TestService.TestRPC(chan, TestRequest(32, test_buf), gRPCClient.gRPCAsync())
        push!(rpcs, rpc)
    end
    for rpc in rpcs
        close(rpc)
    end

    return n
end

function workload_smol(n = 1_000)
    client = TestService_TestRPC_Client("localhost", _bench_port())

    # Since requests are lightweight, use async / await pattern to avoid creating an extra task per request
    reqs = Vector{gRPCRequest}()
    for i in 1:n
        req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        push!(reqs, req)
    end

    for req in reqs
        grpc_async_await(req)
    end

    return n
end

function workload_smol_simple_api(n = 1_000)
    chan = gRPCClient.gRPCChannel("localhost", _bench_port(), grpc = grpc_global_handle())
    rpcs = Vector{gRPCClient.gRPCUnaryCall{typeof(gRPCClientUtils.TestService.TestRPC)}}()

    for i = 1:n
        rpc = TestService.TestRPC(chan, TestRequest(1, zeros(UInt64, 1)), gRPCClient.gRPCAsync())
        push!(rpcs, rpc)
    end

    for rpc in rpcs
        close(rpc)
    end

    return n
end

function workload_streaming_request(n = 1_000)
    client = TestService_TestClientStreamRPC_Client("localhost", _bench_port())
    requests_c = Channel{TestRequest}(16)

    @sync begin
        req = grpc_async_request(client, requests_c)

        for i in 1:n
            put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(requests_c)

        response = grpc_async_await(req)
    end

    return n
end

function workload_streaming_request_simple_api(n = 1_000)
    chan = gRPCClient.gRPCChannel("localhost", _bench_port(), grpc = grpc_global_handle())

    @sync begin
        rpc = TestService.TestClientStreamRPC(chan)

        for i in 1:n
            put!(rpc, TestRequest(1, zeros(UInt64, 1)))
        end
        put!(rpc, done = true)

        response = fetch(rpc)
    end

    return n
end

function workload_streaming_response(n = 1_000)
    client = TestService_TestServerStreamRPC_Client("localhost", _bench_port())
    response_c = Channel{TestResponse}(16)

    req = grpc_async_request(client, TestRequest(n, zeros(UInt64, 1)), response_c)

    for i in 1:n
        take!(response_c)
    end
    close(response_c)

    return n
end


function workload_streaming_response_simple_api(n = 1_000)
    chan = gRPCClient.gRPCChannel("localhost", _bench_port(), grpc = grpc_global_handle())

    rpc = TestService.TestServerStreamRPC(chan, TestRequest(n, zeros(UInt64, 1)))

    for i in 1:n
        take!(rpc)
    end
    close(rpc)

    return n
end

function workload_streaming_bidirectional(n = 1_000)
    client = TestService_TestBidirectionalStreamRPC_Client("localhost", _bench_port())
    requests_c = Channel{TestRequest}(16)
    response_c = Channel{TestResponse}(16)

    @sync begin
        req = grpc_async_request(client, requests_c, response_c)

        task_request = Threads.@spawn begin
            for i in 1:n
                put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
            end
            close(requests_c)
        end
        errormonitor(task_request)

        task_response = Threads.@spawn begin
            for i in 1:n
                take!(response_c)
            end
            close(response_c)
        end
        errormonitor(task_response)

        nothing
    end

    return n
end

function workload_streaming_bidirectional_simple_api(n = 1_000)
    chan = gRPCClient.gRPCChannel("localhost", _bench_port(), grpc = grpc_global_handle())

    @sync begin
        rpc = TestService.TestBidirectionalStreamRPC(chan)

        task_request = Threads.@spawn begin
            for i in 1:n
                put!(rpc, TestRequest(1, zeros(UInt64, 1)))
            end
            put!(rpc, done = true)
        end
        errormonitor(task_request)

        task_response = Threads.@spawn begin
            for i in 1:n
                io = take!(rpc)
            end
            close(rpc)
        end
        errormonitor(task_response)

        nothing
    end

    return n
end
