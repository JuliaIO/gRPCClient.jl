function workload_32_224_224_uint8(n)
    client = TestService_TestRPC_Client("localhost", 8001)

    reqs = Vector{gRPCRequest}()

    send_sz = 32*224*224÷sizeof(UInt64)
    # Pre-allocate this so we are measuring gRPC client performance without external allocations
    test_buf = zeros(UInt64, send_sz)

    for i in 1:n
        req = grpc_async_request(client, TestRequest(32, test_buf))
        push!(reqs, req)
    end
    for req in reqs
        grpc_async_await(req)
    end
end

function workload_smol(n)
    client = TestService_TestRPC_Client("localhost", 8001)

    # Since requests are lightweight, use async / await pattern to avoid creating an extra task per request
    reqs = Vector{gRPCRequest}()
    for i in 1:n
        req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        push!(reqs, req)
    end

    for req in reqs
        grpc_async_await(req)
    end
end 

function workload_streaming_request(n)
    client = TestService_TestClientStreamRPC_Client("localhost", 8001)
    requests_c = Channel{TestRequest}(16)

    @sync begin 
        req = grpc_async_request(client, requests_c)

        for i in 1:n 
            put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(requests_c)

        response = grpc_async_await(req)
    end    

    nothing
end

function workload_streaming_response(n)
    client = TestService_TestServerStreamRPC_Client("localhost", 8001)
    response_c = Channel{TestResponse}(16)

    req = grpc_async_request(client, TestRequest(n, zeros(UInt64, 1)), response_c)

    for i in 1:n 
        take!(response_c)
    end
    close(response_c)

    nothing
end


function workload_streaming_bidirectional(n)
    client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)
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
end
