using Test 
using ProtoBuf 
using gRPCClient
using Base.Threads


function _get_test_host()
    if "GRPC_TEST_SERVER_HOST" in keys(ENV)
        ENV["GRPC_TEST_SERVER_HOST"]
    else
        "localhost"
    end
end

function _get_test_port()
    if "GRPC_TEST_SERVER_PORT" in keys(ENV)
        parse(UInt16, ENV["GRPC_TEST_SERVER_PORT"])
    else
        8001
    end
end

const _TEST_HOST = _get_test_host()
const _TEST_PORT = _get_test_port()

# protobuf and service definitions for our tests
include("gen/test/test_pb.jl")

@testset "gRPCClient.jl" begin

    # Initialize the global gRPCCURL structure
    grpc_init()

    # @testset "@async varying request/response" begin
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_async_request(client, TestRequest(i, zeros(UInt64, i)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == i

            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    # end

    # @testset "@async small request/response" begin 
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == 1
            @test response.data[1] == 1
        end
    # end 

    # @testset "@async big request/response" begin 
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        requests = Vector{gRPCRequest}()
        for i in 1:100
            # 28*224*sizeof(UInt64) == sending batch of 32 224*224 UInt8 image
            request = grpc_async_request(client, TestRequest(64, zeros(UInt64, 32*28*224)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == 64
        end
    # end 

    # @testset "Threads.@spawn small request/response" begin
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        responses = [TestResponse(Vector{UInt64}()) for _ in 1:1000]

        @sync Threads.@threads for i in 1:1000
            response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
            responses[i] = response
        end 

        for (i, response) in enumerate(responses)
            @test length(response.data) == 1
            @test response.data[1] == 1
        end
    # end

    # @testset "Threads.@spawn varying request/response" begin
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        responses = [TestResponse(Vector{UInt64}()) for _ in 1:1000]

        @sync Threads.@threads for i in 1:1000
            response = grpc_sync_request(client, TestRequest(i, zeros(UInt64, i)))
            responses[i] = response
        end 

        for (i, response) in enumerate(responses)
            @test length(response.data) == i
            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    # end

    # @testset "Max Message Size" begin 
        # Create a client with much more restictive max message lengths
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT; max_send_message_length=1024, max_recieve_message_length=1024)

        # Send too much 
        @test_throws gRPCServiceCallException grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1024)))
        # Receive too much
        @test_throws gRPCServiceCallException grpc_sync_request(client, TestRequest(1024, zeros(UInt64, 1)))
    # end

    # @testset "Async Channels" begin 
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(1000)
        for i in 1:1000
            grpc_async_request(client, TestRequest(i, zeros(UInt64, 1)), channel, i)
        end

        for i in 1:1000
            r = take!(channel)
            !isnothing(r.ex) && throw(r.ex)
            @test r.index == length(r.response.data)
        end
    # end
    
    # @testset "Response Streaming" begin 
        N = 16

        client = TestService_TestServerStreamRPC_Client(_TEST_HOST, _TEST_PORT)

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(16, zeros(UInt64, 1)), response_c)

        # We should get back 16 messages that end with their length
        for i in 1:N 
            response = take!(response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end

        grpc_async_await(req)
    # end

    # @testset "Request Streaming" begin 
        N = 16
        client = TestService_TestClientStreamRPC_Client(_TEST_HOST, _TEST_PORT)
        request_c = Channel{TestRequest}(N)

        request = grpc_async_request(client, request_c)

        for i in 1:N
            put!(request_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(request_c)
        response = grpc_async_await(client, request)
        
        @test length(response.data) == N
        for i in 1:N
            @test response.data[i] == i
        end
    # end

    # @testset "Bidirectional Streaming" begin 
        N = 16
        client = TestService_TestBidirectionalStreamRPC_Client(_TEST_HOST, _TEST_PORT)

        request_c = Channel{TestRequest}(N)
        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, request_c, response_c)

        for i in 1:N
            put!(request_c, TestRequest(i, zeros(UInt64, i)))
        end

        for i in 1:N
            response = take!(response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end

        close(request_c)
        grpc_async_await(req)
    # end

    # @testset "Don't Stick User Tasks" 
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        task = @sync begin 
            @spawn begin 
                grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
            end
        end 

        @test !task.sticky
    # end


    grpc_shutdown()
end