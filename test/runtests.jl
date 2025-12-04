using Test
using ProtoBuf
using gRPCClient
using Base.Threads

# Import the timeout header formatting function for testing
import gRPCClient: grpc_timeout_header_val, GRPC_DEADLINE_EXCEEDED


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
    for i = 1:1000
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
    for i = 1:1000
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
    for i = 1:100
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

    responses = [TestResponse(Vector{UInt64}()) for _ = 1:1000]

    @sync Threads.@threads for i = 1:1000
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

    responses = [TestResponse(Vector{UInt64}()) for _ = 1:1000]

    @sync Threads.@threads for i = 1:1000
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

    # @testset "Async Channels" begin 
    client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

    channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(1000)
    for i = 1:1000
        grpc_async_request(client, TestRequest(i, zeros(UInt64, 1)), channel, i)
    end

    for i = 1:1000
        r = take!(channel)
        !isnothing(r.ex) && throw(r.ex)
        @test r.index == length(r.response.data)
    end
    # end

    @static if VERSION >= v"1.12"
        # @testset "Response Streaming" begin
        N = 1000

        client = TestService_TestServerStreamRPC_Client(_TEST_HOST, _TEST_PORT)

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        # We should get back N messages that end with their length
        for i = 1:N
            response = take!(response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end

        grpc_async_await(req)
        # end

        # @testset "Request Streaming" begin
        N = 1000
        client = TestService_TestClientStreamRPC_Client(_TEST_HOST, _TEST_PORT)
        request_c = Channel{TestRequest}(N)

        request = grpc_async_request(client, request_c)

        for i = 1:N
            put!(request_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(request_c)
        response = grpc_async_await(client, request)

        @test length(response.data) == N
        for i = 1:N
            @test response.data[i] == i
        end
        # end

        # @testset "Bidirectional Streaming" begin
        N = 1000
        client = TestService_TestBidirectionalStreamRPC_Client(_TEST_HOST, _TEST_PORT)

        request_c = Channel{TestRequest}(N)
        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, request_c, response_c)

        for i = 1:N
            put!(request_c, TestRequest(i, zeros(UInt64, i)))
        end

        for i = 1:N
            response = take!(response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end


        close(request_c)
        grpc_async_await(req)
        # end

        # @testset "Response Streaming - Small Messages" begin
        N = 1000
        client = TestService_TestServerStreamRPC_Client(_TEST_HOST, _TEST_PORT)

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        # We should get back N small messages
        for i = 1:N
            response = take!(response_c)
            @test length(response.data) >= 1
        end

        grpc_async_await(req)
        # end

        # @testset "Request Streaming - Large Payloads" begin
        N = 100
        client = TestService_TestClientStreamRPC_Client(_TEST_HOST, _TEST_PORT)
        request_c = Channel{TestRequest}(N)

        request = grpc_async_request(client, request_c)

        # Send 100 large payloads (similar to unary big test)
        for i = 1:N
            put!(request_c, TestRequest(1, zeros(UInt64, 32*28*224)))
        end

        close(request_c)
        response = grpc_async_await(client, request)

        @test length(response.data) == N
        # end

        # @testset "Don't Stick User Tasks"
        # This fails on Julia 1.10 but works on Julia 1.12
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        task = @sync begin
            @spawn begin
                grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
            end
        end

        @test !task.sticky
        # end

        # @testset "grpc_async_stream_request - gRPCServiceCallException" begin
        # Test that gRPCServiceCallException is properly stored in req.ex
        client = TestService_TestClientStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            max_send_message_length = 100,
        )
        request_c = Channel{TestRequest}(1)

        req = grpc_async_request(client, request_c)

        # Send a request that exceeds max_send_message_length to trigger gRPCServiceCallException
        put!(request_c, TestRequest(1, zeros(UInt64, 1000)))
        close(request_c)

        # Wait and check that the exception is a gRPCServiceCallException
        try
            grpc_async_await(client, req)
            @test false  # Should not reach here
        catch ex
            @test isa(ex, gRPCServiceCallException)
        end
        # end

        # @testset "grpc_async_stream_request - general exception" begin
        # Test the else branch with a non-gRPC exception
        client = TestService_TestClientStreamRPC_Client(_TEST_HOST, _TEST_PORT)
        request_c = Channel{TestRequest}(1)

        req = grpc_async_request(client, request_c)

        # Close the channel and then try to take from it (triggers InvalidStateException)
        close(request_c)

        # Give the async task time to encounter the exception
        sleep(0.2)

        # The InvalidStateException should be handled gracefully
        # and the request should complete (possibly with no error or a different error)
        try
            grpc_async_await(client, req)
        catch ex
            # If there's an exception, it shouldn't be InvalidStateException
            # (that should be handled internally)
            @test !isa(ex, InvalidStateException)
        end
        # end

        # @testset "grpc_async_stream_response - InvalidStateException" begin
        # Test that InvalidStateException is handled when response channel closes early
        client = TestService_TestServerStreamRPC_Client(_TEST_HOST, _TEST_PORT)
        response_c = Channel{TestResponse}(1)

        req = grpc_async_request(client, TestRequest(10, zeros(UInt64, 1)), response_c)

        # Take one response then close the channel to trigger InvalidStateException in put!
        response = take!(response_c)
        @test length(response.data) >= 1
        close(response_c)

        # Give time for the async task to encounter InvalidStateException
        sleep(0.2)

        # InvalidStateException should be handled internally without propagating
        try
            grpc_async_await(req)
        catch ex
            # If there's an exception, it shouldn't be InvalidStateException
            @test !isa(ex, InvalidStateException)
        end
        # end

        # @testset "grpc_async_stream_response - gRPCServiceCallException" begin
        # Test that gRPCServiceCallException is properly handled in response stream
        # Use a client with restrictive max_recieve_message_length
        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            max_recieve_message_length = 1,
        )
        response_c = Channel{TestResponse}(100)

        # Request a response that will exceed the max size
        req = grpc_async_request(client, TestRequest(10, zeros(UInt64, 100)), response_c)

        # Wait for the error to occur
        sleep(0.2)

        # Should get gRPCServiceCallException when awaiting
        try
            for response in response_c
                # Might get some responses before the error
            end
            grpc_async_await(req)
            @test false  # Should not reach here
        catch ex
            @test isa(ex, gRPCServiceCallException)
        end
        # end
    end

    # @testset "Timeout Header Value Formatting" begin
    # Test integer seconds
    @test grpc_timeout_header_val(1) == "1S"

    # Test milliseconds
    @test grpc_timeout_header_val(0.001) == "1m"

    # Test microseconds
    @test grpc_timeout_header_val(0.000001) == "1u"

    # Test nanoseconds
    @test grpc_timeout_header_val(0.0000001) == "100n"

    # end

    # @testset "Deadline - Very short timeout" begin
    # Test with an extremely short deadline that might timeout
    # Note: This test is timing-sensitive and might be flaky
    client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT; deadline = 0.000000001)

    # Try to make a request - it might timeout depending on server response time
    try
        response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
        @test false
    catch ex
        # If it times out, verify it's an exception (CURL timeout or gRPC error)
        @test isa(ex, gRPCServiceCallException)
        @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
    end
    # end

    # @testset "Max Message Size" begin
    # Create a client with much more restictive max message lengths
    client = TestService_TestRPC_Client(
        _TEST_HOST,
        _TEST_PORT;
        max_send_message_length = 1024,
        max_recieve_message_length = 1024,
    )

    # Send too much
    @test_throws gRPCServiceCallException grpc_sync_request(
        client,
        TestRequest(1, zeros(UInt64, 1024)),
    )
    # Receive too much
    @test_throws gRPCServiceCallException grpc_sync_request(
        client,
        TestRequest(1024, zeros(UInt64, 1)),
    )
    # end

    grpc_shutdown()
end
