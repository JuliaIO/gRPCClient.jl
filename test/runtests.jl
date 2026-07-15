using Test
using ProtoBuf
using gRPCClient
using Base.Threads
using Sockets

# Import the timeout header formatting function for testing
import gRPCClient:
    grpc_timeout_header_val, GRPC_DEADLINE_EXCEEDED, GRPC_UNAUTHENTICATED, GRPC_CANCELLED

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
            # Bearer token kwarg is generated (defaults to nothing) and threaded
            # through to the underlying gRPCServiceClient constructor.
            @test contains(generated, "token=nothing,")
            @test contains(generated, "token=token,")
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
    end

    @testset "@async varying request/response" begin
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
    end

    @testset "@async small request/response" begin
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
    end

    @testset "@async big request/response" begin
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
    end

    @testset "Threads.@spawn small request/response" begin
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
    end

    @testset "Threads.@spawn varying request/response" begin
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
    end

    @testset "Async Channels" begin
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
    end

    @static if VERSION >= v"1.12"

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
            for i = 1:N
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

            for i = 1:N
                put!(request_c, TestRequest(1, zeros(UInt64, 1)))
            end

            close(request_c)
            response = grpc_async_await(client, request)

            @test length(response.data) == N
            for i = 1:N
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

            for i = 1:N
                put!(request_c, TestRequest(i, zeros(UInt64, i)))
            end

            for i = 1:N
                response = take_or_diagnose(req, response_c)
                @test length(response.data) == i
                @test last(response.data) == i
            end


            close(request_c)
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
                @test ex.grpc_status == GRPC_DEADLINE_EXCEEDED
            end
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
            for i = 1:N
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
            for i = 1:N
                put!(request_c, TestRequest(1, zeros(UInt64, 32*28*224)))
            end

            close(request_c)
            response = grpc_async_await(client, request)

            @test length(response.data) == N
        end

        @testset "Don't Stick User Tasks" begin
            # This fails on Julia 1.10 but works on Julia 1.12
            client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)

            task = @sync begin
                @spawn begin
                    grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
                end
            end

            @test !task.sticky
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
            for i = 1:3
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
            for _ = 1:3
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

        # NaN and -Inf deadlines are programming errors and throw at submission
        for bad in (NaN, -Inf)
            bad_client = TestService_TestRPC_Client(
                "127.0.0.1",
                silent_port;
                grpc = grpc_handle,
                deadline = bad,
            )
            @test_throws ArgumentError grpc_async_request(
                bad_client,
                TestRequest(1, zeros(UInt64, 1)),
            )
        end

        close(silent_server)
        foreach(close, accepted)
        grpc_shutdown(grpc_handle)
    end

    @testset "grpc-timeout header value formatting" begin
        # Per the gRPC HTTP/2 spec, a grpc-timeout value is a positive integer of at most 8 digits
        # followed by a unit char: H (hour), M (minute), S (second), m (ms), u (us), n (ns).
        _UNIT_NS = Dict('H' => 3_600_000_000_000, 'M' => 60_000_000_000, 'S' => 1_000_000_000,
                        'm' => 1_000_000, 'u' => 1_000, 'n' => 1)
        # Decode a header value back to seconds so we can check it never encodes a shorter timeout.
        decode_s(hv) = parse(Int64, hv[1:end-1]) * _UNIT_NS[hv[end]] / 1e9
        # Assert the value obeys the spec: 1-8 ASCII digits then a known unit char.
        function is_wellformed(hv)
            length(hv) >= 2 || return false
            haskey(_UNIT_NS, hv[end]) || return false
            digits = hv[1:end-1]
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
            @test grpc_timeout_header_val(1e-9) == "1n"
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
            @test grpc_timeout_header_val(1e-10) == "1n"
            @test grpc_timeout_header_val(4e-10) == "1n"
            @test grpc_timeout_header_val(1e-12) == "1n"
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
            @test invalid_arg(() -> grpc_timeout_header_val(-1e-9))       # negative, sub-nanosecond
            @test invalid_arg(() -> grpc_timeout_header_val(Inf))         # non-finite
            @test invalid_arg(() -> grpc_timeout_header_val(NaN))         # non-finite
            @test invalid_arg(() -> grpc_timeout_header_val(1e12))        # beyond Int64 ns (~292y)
        end

        @testset "invariants over a wide sweep" begin
            # For every timeout, the header must be well-formed (<=8 digits + valid unit) and must
            # never encode a SHORTER timeout than requested (rounding is always up).
            vals = Float64[0, 1e-9, 5e-9, 1e-7, 0.0005, 0.05, 0.099999999, 0.1, 0.5, 1, 2.5,
                           9.9999999, 10.0000001, 29.999999046, 60, 90.0001, 123.4567, 3600,
                           99_999.9994, 1e6 + 0.5, 99_999_999]
            for t in vals
                hv = grpc_timeout_header_val(t)
                @test is_wellformed(hv)
                @test decode_s(hv) >= t - 1e-9
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

    @testset "Bearer Authentication" begin
        # A client configured with the correct bearer token sends
        # `authorization: Bearer <token>`, which the test server validates.
        # A successful response proves the header reached the server intact.
        client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = _TEST_BEARER_TOKEN,
        )
        @test client.token == _TEST_BEARER_TOKEN

        response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
        @test length(response.data) == 1
        @test response.data[1] == 1

        # A wrong token is rejected by the server with UNAUTHENTICATED, proving
        # the supplied token value is transmitted faithfully (not dropped).
        bad_client = TestService_TestRPC_Client(
            _TEST_HOST,
            _TEST_PORT;
            token = "wrong-token",
        )
        try
            grpc_sync_request(bad_client, TestRequest(1, zeros(UInt64, 1)))
            @test false  # Should not reach here
        catch ex
            @test isa(ex, gRPCServiceCallException)
            @test ex.grpc_status == GRPC_UNAUTHENTICATED
        end

        # The default client sends no `authorization` header, so the server's
        # auth check is bypassed and the request succeeds as before.
        default_client = TestService_TestRPC_Client(_TEST_HOST, _TEST_PORT)
        @test isnothing(default_client.token)
        response = grpc_sync_request(default_client, TestRequest(1, zeros(UInt64, 1)))
        @test length(response.data) == 1
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

        for i = 1:N
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
            end for _ = 1:N
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

        close(silent_server)
        foreach(close, accepted)
    end

    grpc_shutdown()
end
