using Test
using ProtoBuf
using gRPCClient
using Base.Threads
using Sockets
import REPL # Must be loaded in order to retreive auto-generated docstrings

# Import the timeout header formatting function for testing
import gRPCClient:
    grpc_timeout_header_val,
    GRPC_DEADLINE_EXCEEDED,
    GRPC_UNAUTHENTICATED,
    GRPC_CANCELLED,
    GRPC_INVALID_ARGUMENT,
    GRPC_FAILED_PRECONDITION,
    GRPC_INTERNAL

# The bearer token the test Go server accepts (mirrors expectedBearerToken in
# test/go/server.go). A request carrying an `authorization` header must present
# exactly this value; requests without one are unaffected.
const _TEST_BEARER_TOKEN = "test-secret-token"

# This is primarily used for starting the server when running CI.
# By launching the server asynchronously within julia, we ensure
# that the server is active while testing, which otherwise would require
# scheduling a task on windows CI.
if haskey(ENV, "JULIA_GRPCCLIENT_TEST_START_SERVER")
    if ENV["JULIA_GRPCCLIENT_TEST_START_SERVER"] == "go"
        pipe = Pipe()
        process = run(
            pipeline(`./go/grpc_test_server`; stdout = pipe, stderr = pipe),
            wait = false,
        )
        finalizer(process) do x
            kill(x)
        end

        # Display the prints from the server and
        # wait until it is properly launched before proceeding with requests
        t1 = time()
        println("Starting Go server...")
        while true
            line = readline(pipe) # blocking
            println(line)
            contains(line, "gRPC server started") && break
            contains(lowercase(line), "error") &&
                throw(ErrorException("Failed to start gRPC test server"))
            contains(lowercase(line), "failed") &&
                throw(ErrorException("Failed to start gRPC test server"))
            time() > t1 + 10 &&
                throw(ErrorException("Failed to start gRPC test server due to time-out"))
        end
        sleep(0.01)
    elseif ENV["JULIA_GRPCCLIENT_TEST_START_SERVER"] == "false"
        nothing
    else
        throw(
            ErrorException(
                "Unsupported option for JULIA_GRPCCLIENT_TEST_START_SERVER: $(ENV["JULIA_GRPCCLIENT_TEST_START_SERVER"])",
            ),
        )
    end
end

function _get_test_host()
    return if "GRPC_TEST_SERVER_HOST" in keys(ENV)
        ENV["GRPC_TEST_SERVER_HOST"]
    else
        "localhost"
    end
end

function _get_test_port()
    return if "GRPC_TEST_SERVER_PORT" in keys(ENV)
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
    gRPCClient.grpc_init()
    @testset "Code Generation" begin
        mktempdir() do tmpdir
            @test isnothing(protojl("proto/test.proto", @__DIR__, tmpdir))
            generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)
            # gRPCClient import injected after ProtoBuf imports
            @test contains(generated, "import gRPCClient")
            # BEGIN/END markers wrapping the service block
            @test contains(generated, "# gRPCClient.jl BEGIN")
            @test contains(generated, "# gRPCClient.jl END")
            # All four service client constructors are present
            @test contains(generated, "TestService_TestRPC_Client(")
            @test contains(generated, "TestService_TestServerStreamRPC_Client(")
            @test contains(generated, "TestService_TestClientStreamRPC_Client(")
            @test contains(generated, "TestService_TestBidirectionalStreamRPC_Client(")
            # Message types default via overridable TRequest/TResponse kwargs,
            # so the construction uses the type-parameter names (raw-buffer support).
            @test contains(generated, "TRequest=TestRequest,")
            @test contains(generated, "TResponse=TestResponse,")
            # Correct streaming type parameters for each RPC variant
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, false, TResponse, false}",
            )
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, false, TResponse, true}",
            )
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, true, TResponse, false}",
            )
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, true, TResponse, true}",
            )
            # Correct fully-qualified RPC paths
            @test contains(generated, "/test.TestService/TestRPC")
            @test contains(generated, "/test.TestService/TestServerStreamRPC")
            @test contains(generated, "/test.TestService/TestClientStreamRPC")
            @test contains(generated, "/test.TestService/TestBidirectionalStreamRPC")
            # Client constructors are exported (proto has a package namespace)
            @test contains(generated, "export TestService_TestRPC_Client")
            @test contains(generated, "export TestService_TestServerStreamRPC_Client")
            @test contains(generated, "export TestService_TestClientStreamRPC_Client")
            @test contains(
                generated,
                "export TestService_TestBidirectionalStreamRPC_Client",
            )
        end

        # Test that request/response type package_namespace is correctly applied when types
        # come from a different proto package. Previously this was broken because the code
        # checked rpc.package_namespace instead of rpc.request_type.package_namespace and
        # rpc.response_type.package_namespace.
        mktempdir() do tmpdir
            @test isnothing(
                protojl("ext_service.proto", joinpath(@__DIR__, "proto"), tmpdir),
            )
            generated = read(joinpath(tmpdir, "ext_service", "ext_service_pb.jl"), String)
            # Request type from ext_types package must be prefixed with package namespace
            @test contains(generated, "TRequest=ext_types.ExtRequest,")
            # Response type from ext_types package must be prefixed with package namespace
            @test contains(generated, "TResponse=ext_types.ExtResponse,")
            # Streaming flags differ per RPC; message types come through the kwargs above
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, false, TResponse, false}",
            )
            @test contains(
                generated,
                "gRPCClient.gRPCServiceClient{TRequest, false, TResponse, true}",
            )
            # Service client constructors are present
            @test contains(generated, "ExtService_ExtRPC_Client(")
            @test contains(generated, "ExtService_ExtStreamRPC_Client(")
        end

        @testset "Codegen: New API" begin
            @testset "compatguard" begin
                mktempdir() do tmpdir
                    grpc_register_service_codegen(legacy = true, servicemodule = true)
                    @test isnothing(protojl("proto/test.proto", @__DIR__, tmpdir))
                    generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)
                    @test contains(generated, "Base.@static if Base.:!(Base.isless(Base.pkgversion(gRPCClient), Base.VersionNumber(\"1.2.0-rc1\")))")
                    @test contains(generated, "This file contains code generated with `gRPCClient.jl`")
                    @test contains(generated, "baremodule TestService")
                    # More tests are done only with legacy = false
                end

                mktempdir() do tmpdir
                    grpc_register_service_codegen(legacy = false, servicemodule = true)
                    @test isnothing(protojl("proto/test.proto", @__DIR__, tmpdir))
                    generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)
                    @test !contains(generated, "Base.@static if Base.:!(Base.isless(Base.pkgversion(gRPCClient), Base.VersionNumber(\"1.2.0-rc1\")))")
                    @test !contains(generated, "This file contains code generated with `gRPCClient.jl`")
                    @test contains(generated, "const TestResponse::DataType = Base.parentmodule(TestService).TestResponse")
                    @test contains(generated, "const TestRequest::DataType = Base.parentmodule(TestService).TestRequest") 
                    # Count number of methods defined for each RPC
                    @test count("function TestRPC", generated) == 3
                    @test count("function TestClientStreamRPC", generated) == 2
                    @test count("function TestServerStreamRPC", generated) == 3
                    @test count("function TestBidirectionalStreamRPC", generated) == 2
                end

                mktempdir() do tmpdir
                    grpc_register_service_codegen(legacy = true, servicemodule = false)
                    @test isnothing(protojl("proto/test.proto", @__DIR__, tmpdir))
                    generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)
                    @test !contains(generated, "Base.@static if Base.:!(Base.isless(Base.pkgversion(gRPCClient), Base.VersionNumber(\"1.2.0-rc1\")))")
                    @test !contains(generated, "This file contains code generated with `gRPCClient.jl`")
                end
            end

            @testset "Traits" begin
                @test gRPCClient.isstreaming_request(typeof(TestService.TestRPC)) == false
                @test gRPCClient.isstreaming_request(typeof(TestService.TestClientStreamRPC)) == true
                @test gRPCClient.isstreaming_request(typeof(TestService.TestServerStreamRPC)) == false
                @test gRPCClient.isstreaming_request(typeof(TestService.TestBidirectionalStreamRPC)) == true

                @test gRPCClient.isstreaming_response(typeof(TestService.TestRPC)) == false
                @test gRPCClient.isstreaming_response(typeof(TestService.TestClientStreamRPC)) == false
                @test gRPCClient.isstreaming_response(typeof(TestService.TestServerStreamRPC)) == true
                @test gRPCClient.isstreaming_response(typeof(TestService.TestBidirectionalStreamRPC)) == true
                
                @test gRPCClient.request_type(typeof(TestService.TestRPC)) == TestRequest
                @test gRPCClient.request_type(typeof(TestService.TestClientStreamRPC)) == TestRequest
                @test gRPCClient.request_type(typeof(TestService.TestServerStreamRPC)) == TestRequest
                @test gRPCClient.request_type(typeof(TestService.TestBidirectionalStreamRPC)) == TestRequest 

                @test gRPCClient.response_type(typeof(TestService.TestRPC)) == TestResponse
                @test gRPCClient.response_type(typeof(TestService.TestClientStreamRPC)) == TestResponse
                @test gRPCClient.response_type(typeof(TestService.TestServerStreamRPC)) == TestResponse
                @test gRPCClient.response_type(typeof(TestService.TestBidirectionalStreamRPC)) == TestResponse

                @test gRPCClient.request_type_displayname(typeof(TestService.TestRPC)) == "TestRequest"
                @test gRPCClient.request_type_displayname(typeof(TestService.TestClientStreamRPC)) == "TestRequest"
                @test gRPCClient.request_type_displayname(typeof(TestService.TestServerStreamRPC)) == "TestRequest"
                @test gRPCClient.request_type_displayname(typeof(TestService.TestBidirectionalStreamRPC)) == "TestRequest"

                @test gRPCClient.response_type_displayname(typeof(TestService.TestRPC)) == "TestResponse"
                @test gRPCClient.response_type_displayname(typeof(TestService.TestClientStreamRPC)) == "TestResponse"
                @test gRPCClient.response_type_displayname(typeof(TestService.TestServerStreamRPC)) == "TestResponse"
                @test gRPCClient.response_type_displayname(typeof(TestService.TestBidirectionalStreamRPC)) == "TestResponse"

                @test gRPCClient.rpc_path(typeof(TestService.TestRPC)) == "/test.TestService/TestRPC"
                @test gRPCClient.rpc_path(typeof(TestService.TestClientStreamRPC)) == "/test.TestService/TestClientStreamRPC"
                @test gRPCClient.rpc_path(typeof(TestService.TestServerStreamRPC)) == "/test.TestService/TestServerStreamRPC"
                @test gRPCClient.rpc_path(typeof(TestService.TestBidirectionalStreamRPC)) == "/test.TestService/TestBidirectionalStreamRPC"
            end

            @testset "docstrings" begin
                @test contains(string(@doc TestService.TestRPC), "Request |        unary |  TestRequest |\n| Response |        unary | TestResponse |\n")
                @test contains(string(@doc TestService.TestClientStreamRPC), "Request |       stream |  TestRequest |\n| Response |        unary | TestResponse |\n")
                @test contains(string(@doc TestService.TestServerStreamRPC), "Request |        unary |  TestRequest |\n| Response |       stream | TestResponse |\n")
                @test contains(string(@doc TestService.TestBidirectionalStreamRPC), "Request |       stream |  TestRequest |\n| Response |       stream | TestResponse |\n")
            end
        end
    end

    @testset "@async varying request/response" begin
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
    end

    @testset "@async small request/response" begin
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
    end

    @testset "@async big request/response" begin
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        requests = Vector{gRPCRequest}()
        for i in 1:100
            # 28*224*sizeof(UInt64) == sending batch of 32 224*224 UInt8 image
            request = grpc_async_request(client, TestRequest(64, zeros(UInt64, 32 * 28 * 224)))
            push!(requests, request)
        end

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == 64
        end
    end

    @testset "Threads.@spawn small request/response" begin
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
    end

    @testset "Threads.@spawn varying request/response" begin
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
    end

    @testset "Async Channels" begin
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
    end

    @testset "Simple API: Unary, sync" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)
        
        @testset "sync" begin
            resp = TestService.TestRPC(chan, TestRequest(1, [1]))
            @test resp.data == [1]
        end

        @testset "Partially encoded" begin
            io = IOBuffer()
            encode(ProtoEncoder(io), TestRequest(1, [1]))
            seekstart(io)

            raw_resp = TestService.TestRPC(chan, read(io), Vector{UInt8})

            io = IOBuffer(raw_resp)
            response = decode(ProtoDecoder(io), TestResponse)
            @test response.data == [1]
        end
    end

    @testset "Simple API: Unary, async" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)

        @testset "async" begin
            rpc = TestService.TestRPC(chan, TestRequest(1, [1]), gRPCClient.gRPCAsync())
            @test !isready(rpc)
            @test :ok == timedwait(() -> isready(rpc), 0.1, pollint = 0.001)
            resp = fetch(rpc)
            @test resp.data == [1]
        end

        @testset "Detaching" begin
            rpc = TestService.TestRPC(chan, TestRequest(1, [1]), gRPCClient.gRPCAsync())
            @test !rpc.req.completed
            detach(rpc)
            @test_throws gRPCException fetch(rpc)
            @test rpc.req.completed
            @test_throws "Request was cancelled by the client." detach(rpc)
            @test_throws "Request was cancelled by the client." detach(rpc)
            detach(rpc, throws = false) # does not throw
            @test_throws "Request was cancelled by the client." close(rpc)
        end

        @testset "Connection options" begin
            chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT, max_send_message_length = 1024)
            rpc = TestService.TestRPC(chan, TestRequest(1, [1]), gRPCClient.gRPCAsync())
            @test rpc.req.max_send_message_length == 1024
            rpc = TestService.TestRPC(chan, TestRequest(1, [1]), gRPCClient.gRPCAsync(), max_send_message_length = 2048)
            @test rpc.req.max_send_message_length == 2048
        end

        @testset "Partially encoded" begin
            io = IOBuffer()
            encode(ProtoEncoder(io), TestRequest(1, [1]))
            seekstart(io)
            rpc = TestService.TestRPC(chan, read(io), gRPCAsync())

            io = IOBuffer(fetch(rpc, Vector{UInt8}))
            response = decode(ProtoDecoder(io), TestResponse)
            @test response.data == [1]
        end
    end

    @testset "Simple API: Unary, multiplexing" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)
        
        @testset "store response in channel" begin
            responses = Channel{gRPCAsyncChannelResponse{TestResponse}}(Inf)
            TestService.TestRPC(chan, TestRequest(2, []), responses, 1)
            TestService.TestRPC(chan, TestRequest(3, []), responses, 2)

            rs = Any[nothing, nothing]
            r = take!(responses)
            rs[r.index] = r.response.data
            r = take!(responses)
            rs[r.index] = r.response.data
            @test rs == [[1, 2], [1, 2, 3]]
        end        

        @testset "Partially encoded" begin
            responses = Channel{gRPCAsyncChannelResponse{Vector{UInt8}}}(Inf)
            
            io = IOBuffer()
            encode(ProtoEncoder(io), TestRequest(1, [1]))
            seekstart(io)
            TestService.TestRPC(chan, read(io), responses, 1)

            r = take!(responses)
            @test r.index == 1
            io = IOBuffer(r.response)
            response = decode(ProtoDecoder(io), TestResponse)
            @test response.data == [1]
        end
    end

    @testset "Simple API: Streaming request" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)
        @testset "basic call" begin
            
            rpc = TestService.TestClientStreamRPC(chan)
            for i = 1:4
                put!(rpc, TestRequest(1, [1]))
            end
            response = fetch(rpc)
            @test response.data == 1:4
        end

        @testset "detaching" begin
            rpc = TestService.TestClientStreamRPC(chan)
            @test isopen(rpc)
            detach(rpc)
            timedwait(() -> !isopen(rpc), 0.1, pollint = 0.001)
            @test !isopen(rpc)
            @test rpc.req.ex.grpc_status == GRPC_CANCELLED
            @test_throws "Request was cancelled by the client" put!(rpc, TestRequest(1, [1])) 
        end

        @testset "Ending request stream" begin
            rpc = TestService.TestClientStreamRPC(chan)
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, TestRequest(1, [1]), done = true)
            @test :ok == timedwait(() -> isopen(rpc), 0.1, pollint = 0.001)
        
            rpc = TestService.TestClientStreamRPC(chan)
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, done = true)
            @test :ok == timedwait(() -> isopen(rpc), 0.1, pollint = 0.001)
        end

        @testset "Connection options" begin
            chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT, max_send_message_length = 1024)
            rpc = TestService.TestClientStreamRPC(chan)
            @test rpc.req.max_send_message_length == 1024
            close(rpc)
            rpc = TestService.TestClientStreamRPC(chan, max_send_message_length = 2048)
            @test rpc.req.max_send_message_length == 2048
            close(rpc)
        end

        @testset "Partially encoded" begin
            rpc = TestService.TestClientStreamRPC(chan)
            
            for i = 1:4
                io = IOBuffer()
                encode(ProtoEncoder(io), TestRequest(1, [1]))
                seekstart(io)
                put!(rpc, read(io))
            end
            response = fetch(rpc)
            @test response.data == 1:4

            io = IOBuffer(fetch(rpc, Vector{UInt8}))
            response = decode(ProtoDecoder(io), TestResponse)
            @test response.data == 1:4
        end
    end

    
    @testset "Simple API: Streaming response" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)
        @testset "Streaming response" begin
            rpc = TestService.TestServerStreamRPC(chan, TestRequest(4, [1]))
            @test isopen(rpc)
            # Server should send 4 responses pretty immediately
            for i = 1:4
                resp = take!(rpc)
                @test length(resp.data) == i
            end
            @test :ok == timedwait(() -> !isopen(rpc), 0.1, pollint = 0.001)
            close(rpc)
        end

        @testset "fetch and take!" begin
            rpc = TestService.TestServerStreamRPC(chan, TestRequest(1, [1]))
            waittask = Threads.@spawn wait(rpc) # Allows us to check if wait(rpc) is done
            @test !istaskdone(waittask)
            @test !isready(rpc) # If this runs immediately after put!, it should be true
            # wait, but with a time limit to ensure CI ends quickly
            @test :ok == timedwait(() -> istaskdone(waittask), 0.1, pollint = 0.001)
            @test isready(rpc) # response stream should be ready
            resp1 = fetch(rpc) # Get data without removing
            resp2 = take!(rpc) # Get data again, also remove
            @test resp1.data == resp2.data == [1]
            # The server should have shut down after sending us 1 response
            @test !isopen(rpc)
            @test_throws "Call has already been completed" take!(rpc)
        end

        @testset "Connection options" begin
            chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT, max_send_message_length = 1024)
            rpc = TestService.TestServerStreamRPC(chan, TestRequest(4, [1]))
            @test rpc.req.max_send_message_length == 1024
            detach(rpc)
            rpc = TestService.TestServerStreamRPC(chan, TestRequest(4, [1]), max_send_message_length = 2048)
            @test rpc.req.max_send_message_length == 2048
            detach(rpc)
        end

         @testset "Partially encoded" begin
            io = IOBuffer()
            encode(ProtoEncoder(io), TestRequest(4, [1]))
            seekstart(io)
            rpc = TestService.TestServerStreamRPC(chan, read(io))
            
            # Server should send 4 responses pretty immediately
            for i = 1:4
                io = IOBuffer(take!(rpc, Vector{UInt8}))
                resp = decode(ProtoDecoder(io), TestResponse)
                @test length(resp.data) == i
            end
        end
    end

    @testset "Simple API: Bidirectional" begin
        chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT)

        @testset "Minimal example" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan)
            put!(rpc, TestRequest(1, [1]))
            resp = take!(rpc)
            @test resp.data == [1]
            close(rpc)
            @test rpc.req.completed # Stream should be done
            @test !isopen(rpc.response_channel) 
            # Check that we get information about _why_ stream was closed
            @test_throws "Call has already been completed" take!(rpc)
        end

        @testset "detaching" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan)
            @test isopen(rpc)
            detach(rpc)
            timedwait(() -> !isopen(rpc.response_channel), 0.1, pollint = 0.001)
            @test !isopen(rpc)
            @test rpc.req.ex.grpc_status == GRPC_CANCELLED
            @test_throws "Request was cancelled by the client" take!(rpc)
        end
        
        @testset "Testing isfull" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan, request_channel_size = 1)
            @isdefined(isfull) && @test !isfull(rpc)
            put!(rpc, TestRequest(1, [1]))
            @test isfull(rpc) # If this runs immediately after put!, it should be true
            @test :ok == timedwait(() -> !isfull(rpc), 0.1, pollint = 0.001) # Sooner or later, the request should have been handled
            close(rpc)
        end

        @testset "Ending request stream" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan)
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, TestRequest(1, [1]), done = true)
            @test :ok == timedwait(() -> !isopen(rpc), 0.1, pollint = 0.001)
            @test_throws "Call has already been completed." put!(rpc, TestRequest(1, [1]))

            rpc = TestService.TestBidirectionalStreamRPC(chan)
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, TestRequest(1, [1]))
            put!(rpc, done = true)
            @test :ok == timedwait(() -> !isopen(rpc), 0.1, pollint = 0.001)
            @test_throws "Call has already been completed." put!(rpc, TestRequest(1, [1]))
        end

        @testset "Testing fetch and take!" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan, request_channel_size = 1)
            waittask = Threads.@spawn wait(rpc) # Allows us to check if wait(rpc) is done
            @test !istaskdone(waittask)
            put!(rpc, TestRequest(1, [1]))
            @test !isready(rpc) # If this runs immediately after put!, it should be true
            # wait, but with a time limit to ensure CI ends quickly
            @test :ok == timedwait(() -> istaskdone(waittask), 0.1, pollint = 0.001)
            @test isready(rpc) # response stream should be ready
            resp1 = fetch(rpc) # Get data without removing
            resp2 = take!(rpc) # Get data again, also remove
            @test resp1.data == resp2.data == [1]
            @test !rpc.req.completed # The rpc should still be active and ready for new requests
        end

        @testset "Connection options" begin
            chan = gRPCClient.gRPCChannel(_TEST_HOST, _TEST_PORT, max_send_message_length = 1024)
            rpc = TestService.TestBidirectionalStreamRPC(chan)
            @test rpc.req.max_send_message_length == 1024
            detach(rpc)
            rpc = TestService.TestBidirectionalStreamRPC(chan, max_send_message_length = 2048)
            @test rpc.req.max_send_message_length == 2048
            detach(rpc)
        end

        @testset "Partially encoded" begin
            rpc = TestService.TestBidirectionalStreamRPC(chan)

            io = IOBuffer()
            encode(ProtoEncoder(io), TestRequest(1, [1]))
            seekstart(io)
            put!(rpc, read(io))

            io = IOBuffer(take!(rpc, Vector{UInt8}))
            resp = decode(ProtoDecoder(io), TestResponse)
            @test resp.data == [1]
            close(rpc)
        end
    end

    # The streaming stress tests move ~1000 messages (or ~160MB) through a single
    # call. On a slow CI runner that can take longer than the default 10s deadline,
    # and the call's own DEADLINE_EXCEEDED then closes the stream mid-test, so give
    # them a deadline generous enough to only trip when something is truly wedged.
    stream_test_deadline = 300.0

    # take! that, when the stream has died and closed the channel, surfaces the
    # request's real failure (DEADLINE_EXCEEDED, a server error, ...) through
    # grpc_async_await instead of erroring with a bare InvalidStateException.
    take_or_diagnose = (req, channel) -> try
        take!(channel)
    catch
        grpc_async_await(req)
        rethrow()
    end

    @testset "Response Streaming" begin
        N = 1000

        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        # We should get back N messages that end with their length
        for i in 1:N
            response = take_or_diagnose(req, response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end

        grpc_async_await(req)
    end

    @testset "Request Streaming" begin
        N = 1000
        client = TestService_TestClientStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )
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
    end

    @testset "Bidirectional Streaming" begin
        N = 1000
        client = TestService_TestBidirectionalStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        request_c = Channel{TestRequest}(N)
        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, request_c, response_c)

        for i in 1:N
            put!(request_c, TestRequest(i, zeros(UInt64, i)))
        end

        for i in 1:N
            response = take_or_diagnose(req, response_c)
            @test length(response.data) == i
            @test last(response.data) == i
        end


        close(request_c)
        grpc_async_await(req)
    end

    # An all-default protobuf encodes to zero bytes, so its 5-byte length-prefix
    # is the entire frame. Such a message used to fail the response parser: it
    # completed without consuming any of the current chunk, which the write
    # callback read as a stall and reported as INTERNAL "only handled N bytes",
    # and a zero-length message whose prefix was the last thing on the wire was
    # dropped instead of delivered. Interleaving empty and non-empty responses
    # covers both, ending on an empty one.
    @testset "Response Streaming zero-length messages" begin
        N = 200

        client = TestService_TestBidirectionalStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        request_c = Channel{TestRequest}(N)
        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, request_c, response_c)

        # Every other response is empty, including the last one
        sizes = [iseven(i) ? 0 : i for i in 1:N]
        for sz in sizes
            put!(request_c, TestRequest(sz, UInt64[]))
        end
        close(request_c)

        for sz in sizes
            response = take_or_diagnose(req, response_c)
            @test length(response.data) == sz
        end

        grpc_async_await(req)
    end

    @testset "Response Streaming hang after END_STREAM" begin
        N = 10

        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        i = 1
        try
            while i <= N + 1
                response = take!(response_c)
                i += 1
            end
            @test false
        catch ex
            @test isa(ex, InvalidStateException)
            @test i == N + 1
        end
        grpc_async_await(req)
    end

    @testset "Response Streaming backpressure: stalled consumer" begin
        # Regression test for the write_callback blocking deadlock: the streaming
        # write path must never block inside the curl callback. A consumer that
        # stops draining used to wedge write_callback in put! while it held the
        # transport lock, which froze every request on the handle and deadlocked
        # grpc_cancel / grpc_shutdown (they need that same lock). Now the receive
        # direction pauses at a frame boundary (CURL_WRITEFUNC_PAUSE) and the
        # response pump resumes it with curl_easy_pause once a slot frees.
        # N is large enough that the response stream exceeds
        # RECV_BACKPRESSURE_BYTES (message i encodes to ~3i bytes of protobuf —
        # one tag plus one-or-two varint bytes per uint64 — so N=1500 ≈ 3.4 MB),
        # so with the consumer stalled the receive direction is paused in flight
        # and the request is still open when the cancel lands: the exact state
        # that used to deadlock
        N = 1500

        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        # Capacity 1, and we take exactly one message before stopping: the
        # "I have what I need, now cancel" pattern that used to hang forever
        response_c = Channel{TestResponse}(1)
        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)
        response = take!(response_c)
        @test length(response.data) == 1
        sleep(1)   # let the pipe back up behind the stalled consumer

        # grpc_cancel must return promptly instead of waiting on the transport
        # lock, and an unrelated request on the same handle must proceed
        cancel_task = @async grpc_cancel(req)
        other_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )
        other_response = grpc_sync_request(
            other_client,
            TestRequest(1, zeros(UInt64, 1)),
        )
        @test length(other_response.data) == 1
        sleep(2)
        @test istaskdone(cancel_task)
        @test fetch(cancel_task)

        # await reports the cancellation, and the consumer's channel closes
        @test_throws gRPCServiceCallException grpc_async_await(req, TestResponse)
        @test !isopen(response_c)
    end

    @testset "Response Streaming backpressure: slow consumer, in-order delivery" begin
        # A consumer slower than the producer forces repeated pause / re-delivery
        # cycles, including mid-chunk re-delivery (chunk_skip). Every message must
        # still arrive exactly once, in order, byte-exact.
        N = 50

        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        response_c = Channel{TestResponse}(1)
        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        i = 0
        for response in response_c
            i += 1
            @test length(response.data) == i
            @test response.data == UInt64.(1:i)
            i % 7 == 0 && sleep(0.01)   # vary the drain rate
        end
        @test i == N
        grpc_async_await(req)
    end

    @testset "Response Streaming backpressure: shutdown with stalled consumer" begin
        # grpc_shutdown must complete even while a streaming response is wedged
        # behind a consumer that never drains: cleanup closes the channels, which
        # ends the pump, and the callback is not blocking on any of them. N is
        # large enough (~3.4 MB, see the stalled-consumer testset) to exceed
        # RECV_BACKPRESSURE_BYTES so the transfer is paused in flight when the
        # shutdown lands.
        N = 1500

        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        response_c = Channel{TestResponse}(1)
        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)
        response = take!(response_c)
        @test length(response.data) == 1
        sleep(1)   # let the pipe back up behind the stalled consumer

        shutdown_task = @async grpc_shutdown()
        sleep(2)
        @test istaskdone(shutdown_task)
        fetch(shutdown_task)

        # cleanup_request on shutdown does not set req.ex (grpc_cancel does), so
        # await must simply return rather than block forever on req.ready
        grpc_async_await(req, TestResponse)
        @test !isopen(response_c)

        # The global handle must be usable again after re-init
        grpc_init()
        revived_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )
        revived_response = grpc_sync_request(
            revived_client,
            TestRequest(1, zeros(UInt64, 1)),
        )
        @test length(revived_response.data) == 1
    end

    @testset "Deadline Exceeded" begin
        client = TestService_TestClientStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = 0.001,
        )
        request_c = Channel{TestRequest}(1)

        # Even with a 1ms deadline submission never throws; the failure is
        # raised by the await
        request = grpc_async_request(client, request_c)
        sleep(1.0)

        try
            grpc_async_await(request)
            @test false
        catch ex
            # Verify the deadline was exceeded
            @test isa(ex, gRPCServiceCallException)
            # A mismatch here has historically only reproduced on CI, where the
            # status number alone says nothing about which transport error the
            # platform reported, so log the message before asserting
            ex.grpc_status == GRPC_DEADLINE_EXCEEDED || @error(
                "expected DEADLINE_EXCEEDED",
                status = ex.grpc_status,
                message = ex.grpc_message,
            )
            @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
        end
    end

    @testset "Deadline Exceeded - non-timeout transport error" begin
        # Tearing a transfer down at CURLOPT_TIMEOUT_MS does not always surface as
        # CURLE_OPERATION_TIMEDOUT: on Windows the socket error from the teardown can
        # arrive first. Whichever curl reports, a call whose deadline has passed must
        # fail with DEADLINE_EXCEEDED rather than INTERNAL. The platform-specific race
        # cannot be provoked here, so drive a real request to completion and then
        # rewrite the three fields await reads.
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)
        req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        grpc_async_await(client, req)

        req.code = gRPCClient.CURLE_SEND_ERROR

        awaited_status = function (expiry)
            req.expiry = expiry
            return try
                grpc_async_await(req)
                nothing
            catch ex
                @test isa(ex, gRPCServiceCallException)
                ex.grpc_status
            end
        end

        @test awaited_status(time() - 1) == GRPC_DEADLINE_EXCEEDED

        # The same error before the deadline, or on a request with no deadline at
        # all, stays an INTERNAL transport failure
        @test awaited_status(time() + 60) == GRPC_INTERNAL
        @test awaited_status(Inf) == GRPC_INTERNAL
    end

    @testset "Response Streaming - Small Messages" begin
        N = 1000
        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )

        response_c = Channel{TestResponse}(N)

        req = grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)

        # We should get back N small messages
        for i in 1:N
            response = take_or_diagnose(req, response_c)
            @test length(response.data) >= 1
        end

        grpc_async_await(req)
    end

    @testset "Request Streaming - Large Payloads" begin
        N = 100
        client = TestService_TestClientStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = stream_test_deadline,
        )
        request_c = Channel{TestRequest}(N)

        request = grpc_async_request(client, request_c)

        # Send 100 large payloads (similar to unary big test)
        for i in 1:N
            put!(request_c, TestRequest(1, zeros(UInt64, 32 * 28 * 224)))
        end

        close(request_c)
        response = grpc_async_await(client, request)

        @test length(response.data) == N
    end

    @testset "Don't Stick User Tasks" begin
        # A unary test that only ever sat inside the streaming version guard. It is broken
        # below 1.12, and not for anything this package can fix: arming the deadline
        # watchdog with `Timer(cb, delay)` runs its callback loop in an `@async`, and on
        # those versions scheduling a sticky task marks the scheduling task sticky too
        # (JuliaLang/julia#41324, fixed by the 1.12 scheduler).
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

        task = @sync begin
            @spawn begin
                grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
            end
        end

        @test !task.sticky broken = VERSION < v"1.12"
    end

    @testset "grpc_async_stream_request - gRPCServiceCallException" begin
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
    end

    @testset "grpc_async_stream_request - general exception" begin
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
    end

    @testset "grpc_async_stream_response - InvalidStateException" begin
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
    end

    @testset "grpc_async_stream_response - gRPCServiceCallException" begin
        # Test that gRPCServiceCallException is properly handled in response stream
        # Use a client with restrictive max_recieve_message_length
        client = TestService_TestServerStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            max_recieve_message_length = 1,
        )
        response_c = Channel{TestResponse}(100)

        # Request a response that will exceed the max size
        req =
            grpc_async_request(client, TestRequest(10, zeros(UInt64, 100)), response_c)

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
    end

    @testset "No deadline (Inf) ended by grpc_cancel" begin
        # A bidirectional stream with no deadline stays open indefinitely and is
        # ended by explicit cancellation
        client = TestService_TestBidirectionalStreamRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            deadline = Inf,
        )
        request_c = Channel{TestRequest}(16)
        response_c = Channel{TestResponse}(16)
        req = grpc_async_request(client, request_c, response_c)

        # Stream is live: request/response round trips work
        for i in 1:3
            put!(request_c, TestRequest(i, zeros(UInt64, i)))
            r = take!(response_c)
            @test length(r.data) == i
        end

        @test grpc_cancel(req)
        # Response iteration ends promptly after cancellation
        for _ in response_c
        end
        @test !isopen(response_c)
        try
            grpc_async_await(req)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_CANCELLED
        end
        # Cancel does not close the caller's request channel; that stays the
        # caller's job
        @test isopen(request_c)
        close(request_c)

        # Regression for the recycled curl_done_reading Event: the slot freed by
        # the cancelled stream (LIFO freelist, so the next request reuses it) must
        # be clean. Run follow-up streams and unary requests on the same handle.
        for _ in 1:3
            cs_client = TestService_TestClientStreamRPC_Client(_TEST_HOST, _TEST_PORT)
            cs_c = Channel{TestRequest}(4)
            cs_req = grpc_async_request(cs_client, cs_c)
            put!(cs_c, TestRequest(1, zeros(UInt64, 1)))
            put!(cs_c, TestRequest(1, zeros(UInt64, 1)))
            close(cs_c)
            r = grpc_async_await(cs_client, cs_req)
            @test length(r.data) == 2
        end
        u_client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)
        @test length(grpc_sync_request(u_client, TestRequest(4, zeros(UInt64, 1))).data) == 4
    end

    @testset "No deadline (Inf) on a never-ready connection" begin
        # With no deadline there is no watchdog: a request parked behind a connection
        # that never becomes ready waits indefinitely, and grpc_cancel is the way out
        grpc_handle = gRPCCURL()

        silent_server = listen(Sockets.localhost, 0)
        silent_port = Int(getsockname(silent_server)[2])
        accepted = Sockets.TCPSocket[]
        @async while true
            try
                push!(accepted, accept(silent_server))
            catch
                break
            end
        end

        client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = Inf,
        )
        req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        sleep(1.0)
        # Still in flight: nothing timed it out
        @test !req.completed
        @test isnothing(req.ex)

        t0 = time()
        @test grpc_cancel(req)
        try
            grpc_async_await(client, req)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_CANCELLED
        end
        @test time() - t0 < 1.0

        # NaN, -Inf, and negative deadlines are programming errors and throw
        # INVALID_ARGUMENT at submission (part of the submission exception contract).
        # Negative values are rejected before the watchdog Timer is armed, which would
        # otherwise surface a bare ArgumentError on a negative interval.
        for bad in (NaN, -Inf, -1.0, -0.001)
            bad_client = TestService_TestRPC_Client(
                "127.0.0.1",
                silent_port;
                grpc = grpc_handle,
                deadline = bad,
            )
            try
                grpc_async_request(bad_client, TestRequest(1, zeros(UInt64, 1)))
                @test false
            catch ex
                @test isa(ex, gRPCServiceCallException)
                @test ex.grpc_status == GRPC_INVALID_ARGUMENT
            end

            # Also rejected when supplied as a per-request override on a good client
            ok_client = TestService_TestRPC_Client(
                "127.0.0.1",
                silent_port;
                grpc = grpc_handle,
            )
            try
                grpc_async_request(
                    ok_client,
                    TestRequest(1, zeros(UInt64, 1));
                    deadline = bad,
                )
                @test false
            catch ex
                @test isa(ex, gRPCServiceCallException)
                @test ex.grpc_status == GRPC_INVALID_ARGUMENT
            end
        end

        # A deadline of exactly 0 is legal: it expires immediately, so the failure is
        # DEADLINE_EXCEEDED raised from await rather than INVALID_ARGUMENT at submission
        zero_client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = 0,
        )
        req = grpc_async_request(zero_client, TestRequest(1, zeros(UInt64, 1)))
        try
            grpc_async_await(req, TestResponse)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
        end

        close(silent_server)
        foreach(close, accepted)
        grpc_shutdown(grpc_handle)
    end

    @testset "grpc-timeout header value formatting" begin
        # Per the gRPC HTTP/2 spec, a grpc-timeout value is a positive integer of at most 8 digits
        # followed by a unit char: H (hour), M (minute), S (second), m (ms), u (us), n (ns).
        _UNIT_NS = Dict(
            'H' => 3_600_000_000_000, 'M' => 60_000_000_000, 'S' => 1_000_000_000,
            'm' => 1_000_000, 'u' => 1_000, 'n' => 1
        )
        # Decode a header value back to seconds so we can check it never encodes a shorter timeout.
        decode_s(hv) = parse(Int64, hv[1:(end - 1)]) * _UNIT_NS[hv[end]] / 1.0e9
        # Assert the value obeys the spec: 1-8 ASCII digits then a known unit char.
        function is_wellformed(hv)
            length(hv) >= 2 || return false
            haskey(_UNIT_NS, hv[end]) || return false
            digits = hv[1:(end - 1)]
            1 <= length(digits) <= 8 && all(isdigit, digits)
        end

        @testset "exact whole units" begin
            # Whole seconds render as S.
            @test grpc_timeout_header_val(1) == "1S"
            @test grpc_timeout_header_val(5) == "5S"
            @test grpc_timeout_header_val(60) == "60S"      # S is preferred over M
            @test grpc_timeout_header_val(3600) == "3600S"  # S is preferred over H
            # Whole milliseconds render as m.
            @test grpc_timeout_header_val(0.001) == "1m"
            @test grpc_timeout_header_val(0.1) == "100m"
            # Whole microseconds render as u.
            @test grpc_timeout_header_val(0.000001) == "1u"
            @test grpc_timeout_header_val(0.0005) == "500u"
            # Whole nanoseconds render as n.
            @test grpc_timeout_header_val(0.0000001) == "100n"
            @test grpc_timeout_header_val(1.0e-9) == "1n"
        end

        @testset "coarsest exact unit is preferred" begin
            # A value expressible in several units picks the coarsest (fewest ticks), not the finest.
            @test grpc_timeout_header_val(1) == "1S"       # not "1000m"
            @test grpc_timeout_header_val(0.5) == "500m"   # not "500000u"
            @test grpc_timeout_header_val(2.5) == "2500m"  # not "2500000u"
        end

        @testset "8-digit boundary is exact" begin
            # The largest value representable in each unit within 8 digits stays in that unit.
            @test grpc_timeout_header_val(99_999_999) == "99999999S"        # 99999999 whole seconds
            @test grpc_timeout_header_val(0.099999999) == "99999999n"       # 99999999 ns
        end

        @testset "overflow rounds up to the finest fitting unit" begin
            # A fractional multi-second timeout's exact form needs >8 nanosecond digits, which the
            # peer rejects as malformed. It must round UP to the finest unit that fits in 8 digits.
            @test grpc_timeout_header_val(29.999999046) == "30000000u"  # was the 11-digit "29999999046n" bug
            @test grpc_timeout_header_val(10.0000001) == "10000001u"
            @test grpc_timeout_header_val(123.4567) == "123457m"
            # Absurdly large whole-second value overflows S and steps up to minutes.
            @test grpc_timeout_header_val(100_000_000) == "1666667M"
        end

        @testset "edge cases" begin
            @test grpc_timeout_header_val(0) == "0S"     # zero is valid: immediate deadline
            # A strictly positive timeout must never round DOWN to "0S" (already-expired). Values
            # below half a nanosecond floor at one nanosecond instead of collapsing to zero.
            @test grpc_timeout_header_val(1.0e-10) == "1n"
            @test grpc_timeout_header_val(4.0e-10) == "1n"
            @test grpc_timeout_header_val(1.0e-12) == "1n"
        end

        @testset "narrow and exotic Real types" begin
            # The `::Real` signature must handle any numeric type. In particular a narrow float must
            # not overflow the ns scale factor to Inf and crash with InexactError.
            @test grpc_timeout_header_val(Float16(1.0)) == "1S"
            @test grpc_timeout_header_val(Float16(0.0)) == "0S"
            @test grpc_timeout_header_val(Float32(2.5)) == "2500m"
            @test grpc_timeout_header_val(1) == "1S"            # Int
            @test grpc_timeout_header_val(true) == "1S"         # Bool
            @test grpc_timeout_header_val(big(5)) == "5S"       # BigInt
            @test grpc_timeout_header_val(1 // 2) == "500m"     # Rational
            # Well-formed (not necessarily exact) for irrationals and big floats.
            @test is_wellformed(grpc_timeout_header_val(float(pi)))
            @test is_wellformed(grpc_timeout_header_val(big"1.5"))
        end

        @testset "invalid input throws INVALID_ARGUMENT" begin
            # A bad timeout is a caller error and must surface as a gRPC INVALID_ARGUMENT exception,
            # never be silently coerced into a wrong (clamped) deadline on the wire.
            invalid_arg(f) = try
                f(); nothing
            catch e
                e isa gRPCServiceCallException && e.grpc_status == gRPCClient.GRPC_INVALID_ARGUMENT
            end
            @test invalid_arg(() -> grpc_timeout_header_val(-1))          # negative
            @test invalid_arg(() -> grpc_timeout_header_val(-1.0e-9))       # negative, sub-nanosecond
            @test invalid_arg(() -> grpc_timeout_header_val(Inf))         # non-finite
            @test invalid_arg(() -> grpc_timeout_header_val(NaN))         # non-finite
            @test invalid_arg(() -> grpc_timeout_header_val(1.0e12))        # beyond Int64 ns (~292y)
        end

        @testset "invariants over a wide sweep" begin
            # For every timeout, the header must be well-formed (<=8 digits + valid unit) and must
            # never encode a SHORTER timeout than requested (rounding is always up).
            vals = Float64[
                0, 1.0e-9, 5.0e-9, 1.0e-7, 0.0005, 0.05, 0.099999999, 0.1, 0.5, 1, 2.5,
                9.9999999, 10.0000001, 29.999999046, 60, 90.0001, 123.4567, 3600,
                99_999.9994, 1.0e6 + 0.5, 99_999_999,
            ]
            for t in vals
                hv = grpc_timeout_header_val(t)
                @test is_wellformed(hv)
                @test decode_s(hv) >= t - 1.0e-9
            end
        end
    end

    @testset "Max Message Size" begin
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
    end

    function client_authorizes(client; kws...)
        # A client configured with the correct bearer token sends
        # `authorization: Bearer <token>`, which the test server validates.
        # A successful response proves the header reached the server intact.
        response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)); kws...)
        return (length(response.data) == 1) && (response.data[1] == 1)
    end

    function client_fails_authorization(client; kws...)
        try
            grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)); kws...)
            return false
        catch ex
            # A wrong token is rejected by the server with UNAUTHENTICATED, proving
            # the supplied token value is transmitted faithfully (not dropped).
            return isa(ex, gRPCServiceCallException) && (ex.grpc_status == GRPC_UNAUTHENTICATED)
        end
    end

    @testset "Bearer Authentication" begin
        client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = _TEST_BEARER_TOKEN,
        )
        @test client.options.token == _TEST_BEARER_TOKEN
        @test client_authorizes(client)

        bad_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = "wrong-token",
        )
        @test client_fails_authorization(bad_client)

        # The default client sends no `authorization` header, so the server's
        # auth check is bypassed and the request succeeds as before.
        default_client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)
        @test isnothing(default_client.options.token)
        response = grpc_sync_request(default_client, TestRequest(1, zeros(UInt64, 1)))
        @test length(response.data) == 1
    end

    @testset "Metadata" begin
        # The token can also be implemented through metadata, so we use the
        # same server capabilities as in the token test to verify metadata
        md = Dict("authorization" => "Bearer $(_TEST_BEARER_TOKEN)")
        client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            metadata = md
        )
        @assert isnothing(client.options.token)
        @test client.options.metadata == md
        @test client_authorizes(client)

        bad_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            metadata = Dict("authorization" => "wrong_auth"),
        )
        @test client_fails_authorization(bad_client)
    end

    @testset "_merge_options" begin
        # Most options should be plainly overridden
        options = gRPCClient.gRPCConnectionOptions()
        options = gRPCClient._merge_options(options, Dict(:token => "123"))
        @test options.token == "123"

        # metadata Dicts are merged
        options = gRPCClient.gRPCConnectionOptions(metadata = Dict("A" => "foo"))
        options = gRPCClient._merge_options(options, Dict(:metadata => Dict("B" => "bar")))
        @test options.metadata["A"] == "foo"
        @test options.metadata["B"] == "bar"

        # if two metadata dicts contain the same key, override
        options = gRPCClient.gRPCConnectionOptions(metadata = Dict("A" => "foo"))
        options = gRPCClient._merge_options(options, Dict(:metadata => Dict("A" => "bar")))
        @test options.metadata["A"] == "bar"

        # set metadata = nothing in gRPCConnectionOptions
        opts = gRPCClient.gRPCConnectionOptions(metadata = nothing)
        gRPCClient._merge_options(opts, Dict{Symbol, Any}(:metadata => Dict("x" => "1")))

        # Check rejection of invalid arguments
        opts = gRPCClient.gRPCConnectionOptions(metadata = nothing)
        @test_throws ArgumentError gRPCClient._merge_options(opts, Dict{Symbol, Any}(:not_a_key => Dict("x" => "1")))
    end

    @testset "token and authorization metadata conflict" begin
        # `token` and an `authorization` metadata entry are two spellings of the same
        # header. Setting both would put two `authorization` headers on the wire and
        # leave the choice to the server, so it is rejected as INVALID_ARGUMENT rather
        # than silently sending both.
        function conflicts(; kws...)
            try
                gRPCClient.gRPCConnectionOptions(; kws...)
                return false
            catch ex
                return isa(ex, gRPCServiceCallException) &&
                    ex.grpc_status == GRPC_INVALID_ARGUMENT
            end
        end

        @test conflicts(token = "t", metadata = Dict("authorization" => "Bearer x"))
        # Header names are case-insensitive and libcurl lowercases them for HTTP/2, so
        # any capitalization collides with `token`.
        @test conflicts(token = "t", metadata = Dict("Authorization" => "Bearer x"))
        @test conflicts(token = "t", metadata = Dict("AUTHORIZATION" => "Bearer x"))
        @test conflicts(
            token = "t",
            metadata = Dict("x-req-id" => "1", "authoriZATION" => "Bearer x"),
        )

        # Either mechanism alone is fine, as is metadata that merely looks similar.
        @test !conflicts(token = "t")
        @test !conflicts(metadata = Dict("authorization" => "Bearer x"))
        @test !conflicts(token = "t", metadata = Dict("x-api-key" => "k"))
        @test !conflicts(token = "t", metadata = Dict("authorizatio" => "x"))
        @test !conflicts(token = "t", metadata = Dict("authorizationx" => "x"))
        @test !conflicts(token = "t", metadata = Dict("x-authorization" => "x"))

        # The conflict is also caught when a per-request override introduces it, in
        # either direction.
        with_token = gRPCClient.gRPCConnectionOptions(token = "t")
        @test_throws gRPCServiceCallException gRPCClient._merge_options(
            with_token,
            Dict(:metadata => Dict("authorization" => "Bearer x")),
        )
        with_md = gRPCClient.gRPCConnectionOptions(
            metadata = Dict("authorization" => "Bearer x"),
        )
        @test_throws gRPCServiceCallException gRPCClient._merge_options(
            with_md,
            Dict(:token => "t"),
        )

        # Passing `token = nothing` is the documented way to hand a client-level token
        # over to per-request metadata.
        swapped = gRPCClient._merge_options(
            with_token,
            Dict(:token => nothing, :metadata => Dict("authorization" => "Bearer x")),
        )
        @test isnothing(swapped.token)
        @test swapped.metadata["authorization"] == "Bearer x"

        # The conflict check must not allocate: it runs whenever options are built.
        md = Dict("x-req-id" => "1", "authorization" => "Bearer x")
        gRPCClient._has_authorization_key(md)  # warm up
        @test (@allocated gRPCClient._has_authorization_key(md)) == 0
        md_miss = Dict("x-req-id" => "1", "x-trace" => "abc")
        gRPCClient._has_authorization_key(md_miss)
        @test (@allocated gRPCClient._has_authorization_key(md_miss)) == 0

        # A client rejects the conflicting pair end to end.
        @test_throws gRPCServiceCallException TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = _TEST_BEARER_TOKEN,
            metadata = Dict("authorization" => "Bearer $(_TEST_BEARER_TOKEN)"),
        )
    end

    @testset "Connection options priority" begin
        # Tests _merge_options in action

        # We test options priority by declaring tokens both
        # at client creation and as keyword arguments to grpc_sync_request.
        # The latter should take priority

        # Client has good token
        good_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = _TEST_BEARER_TOKEN,
        )
        # Bad token provided to grpc_sync_request should override
        @test client_fails_authorization(good_client; token = "bad token")

        # Client has bad token
        bad_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = "bad token",
        )
        # Good token provided to grpc_sync_request should override
        @test client_authorizes(bad_client; token = _TEST_BEARER_TOKEN)
    end

    @testset "Graceful shutdown during concurrent requests" begin
        # Create a separate gRPCCURL handle for this test to avoid interfering with other tests
        grpc_handle = gRPCCURL()
        grpc_init(grpc_handle)
        # Create client using the custom handle
        client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT; grpc = grpc_handle)

        # Start multiple concurrent requests
        N = 100
        tasks = Vector{Task}(undef, N)

        for i in 1:N
            tasks[i] = @spawn begin
                try
                    # Make requests with varying sizes
                    request = grpc_async_request(client, TestRequest(i, zeros(UInt64, i)))
                    grpc_async_await(client, request)
                catch ex
                    # It's acceptable to get exceptions during shutdown
                    # Just verify they are the expected types
                    @test isa(ex, gRPCServiceCallException)
                end
            end
        end

        # Allow the scheduler to schedule the requests
        yield()

        # Close the handle while requests are in flight
        grpc_shutdown(grpc_handle)

        # Wait for all tasks to complete - they should finish gracefully
        # even though the handle was closed
        for task in tasks
            wait(task)
        end

        # Verify the handle is properly closed
        @test grpc_handle.multi == Ptr{Cvoid}(0)
        @test !grpc_handle.running
        @test isempty(grpc_handle.requests)
        @test isempty(grpc_handle.watchers)
    end

    @testset "Deadline watchdog and grpc_cancel on a never-ready connection" begin
        # A server that accepts TCP but never completes the HTTP/2 handshake. libcurl
        # parks every handle after the first behind CURLOPT_PIPEWAIT waiting for the
        # connection to become multiplexable, and parked handles never have their
        # CURLOPT_TIMEOUT_MS processed, so without the client-side deadline watchdog
        # these requests wedge forever and leak all max_streams slots.
        grpc_handle = gRPCCURL()
        grpc_init(grpc_handle)

        silent_server = listen(Sockets.localhost, 0)
        silent_port = Int(getsockname(silent_server)[2])
        accepted = Sockets.TCPSocket[]
        accept_task = @async while true
            try
                push!(accepted, accept(silent_server))
            catch
                break
            end
        end

        deadline = 1.0
        client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = deadline,
        )

        # Exceed max_streams so later requests also exercise semaphore hand-off
        N = gRPCClient.GRPC_MAX_STREAMS + 4

        t0 = time()
        tasks = [
            @spawn begin
                try
                    request = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
                    grpc_async_await(client, request)
                    nothing
                catch ex
                    ex
                end
            end for _ in 1:N
        ]
        results = fetch.(tasks)
        elapsed = time() - t0

        # Every request resolved (no wedge) with DEADLINE_EXCEEDED at ~deadline per batch
        @test all(
            ex ->
            isa(ex, gRPCServiceCallException) &&
                ex.grpc_status == GRPC_DEADLINE_EXCEEDED,
            results,
        )
        # Two semaphore batches, each bounded by deadline + watchdog grace; generous margin
        @test elapsed < 6 * deadline

        # Explicit cancellation of an in-flight (parked) request
        request = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        @test grpc_cancel(request)
        try
            grpc_async_await(client, request)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_CANCELLED
        end
        # Cancelling an already-completed request is a no-op
        @test !grpc_cancel(request)

        close(silent_server)
        foreach(close, accepted)
        grpc_shutdown(grpc_handle)
        @test isempty(grpc_handle.requests)
    end

    @testset "Deadline covers the max_streams queue wait" begin
        # One slot, held by a request against a never-ready connection. A second request
        # with a shorter deadline never gets the slot and must fail at ITS deadline,
        # not once the occupier finally releases the slot.
        grpc_handle = gRPCCURL(max_streams = 1)

        silent_server = listen(Sockets.localhost, 0)
        silent_port = Int(getsockname(silent_server)[2])
        accepted = Sockets.TCPSocket[]
        @async while true
            try
                push!(accepted, accept(silent_server))
            catch
                break
            end
        end

        occupier_client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = 3.0,
        )
        occupier = grpc_async_request(occupier_client, TestRequest(1, zeros(UInt64, 1)))

        queued_client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = 0.5,
        )
        t0 = time()
        # Submission never throws, even for a request that expires while queued; the
        # failure is raised by the await
        queued = grpc_async_request(queued_client, TestRequest(1, zeros(UInt64, 1)))
        try
            grpc_async_await(queued_client, queued)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
        end
        # Resolved around its own deadline (plus watchdog grace), well before the
        # occupier frees the slot at ~3s
        @test time() - t0 < 2.0

        # The occupier still resolves at its own deadline
        try
            grpc_async_await(occupier_client, occupier)
            @test false
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
        end

        close(silent_server)
        foreach(close, accepted)
        grpc_shutdown(grpc_handle)
    end

    @testset "Shutdown unblocks queued requests" begin
        grpc_handle = gRPCCURL(max_streams = 1)

        silent_server = listen(Sockets.localhost, 0)
        silent_port = Int(getsockname(silent_server)[2])
        accepted = Sockets.TCPSocket[]
        @async while true
            try
                push!(accepted, accept(silent_server))
            catch
                break
            end
        end

        client = TestService_TestRPC_Client(
            "127.0.0.1",
            silent_port;
            grpc = grpc_handle,
            deadline = 10.0,
        )
        # Hold the only slot, then queue a second request behind it
        grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        queued = @spawn try
            # A shutdown while queued propagates FAILED_PRECONDITION from submission
            # (the caller is still blocked inside grpc_async_request at that point)
            req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
            grpc_async_await(client, req)
            nothing
        catch ex
            ex
        end
        sleep(0.5)
        @test !istaskdone(queued)

        t0 = time()
        grpc_shutdown(grpc_handle)
        ex = fetch(queued)
        # The queued request was unblocked by the shutdown, well before its deadline
        @test time() - t0 < 2.0
        @test isa(ex, gRPCServiceCallException)
        @test ex.grpc_status == GRPC_FAILED_PRECONDITION

        close(silent_server)
        foreach(close, accepted)
    end

    grpc_shutdown()
end
