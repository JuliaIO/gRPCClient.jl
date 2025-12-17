module gRPCClient

using PrecompileTools: @setup_workload, @compile_workload

using LibCURL
using Base.Threads
using ProtoBuf
using FileWatching
using Base: Semaphore, acquire, release
using Base.Threads
using Base: OS_HANDLE, preserve_handle, unpreserve_handle


import Base.wait,
    Base.reset, Base.notify, Base.isreadable, Base.iswritable, Base.close, Base.open
import ProtoBuf.CodeGenerators


abstract type gRPCException <: Exception end

"""
Exception type that is thrown when something goes wrong while calling an RPC. This can either be triggered by the servers response code or by the client when something fails.

This exception type has two fields:

1. `grpc_status::Int` - See [here](https://grpc.io/docs/guides/status-codes/) for an indepth explanation of each status.
2. `message::String`

"""
struct gRPCServiceCallException <: gRPCException
    grpc_status::Int
    message::String
end

const GRPC_HEADER_SIZE = 5
const GRPC_MAX_STREAMS = 16

const GRPC_OK = 0
const GRPC_CANCELLED = 1
const GRPC_UNKNOWN = 2
const GRPC_INVALID_ARGUMENT = 3
const GRPC_DEADLINE_EXCEEDED = 4
const GRPC_NOT_FOUND = 5
const GRPC_ALREADY_EXISTS = 6
const GRPC_PERMISSION_DENIED = 7
const GRPC_RESOURCE_EXHAUSTED = 8
const GRPC_FAILED_PRECONDITION = 9
const GRPC_ABORTED = 10
const GRPC_OUT_OF_RANGE = 11
const GRPC_UNIMPLEMENTED = 12
const GRPC_INTERNAL = 13
const GRPC_UNAVAILABLE = 14
const GRPC_DATA_LOSS = 15
const GRPC_UNAUTHENTICATED = 16

const GRPC_CODE_TABLE = Dict{Int64,String}(
    0 => "OK",
    1 => "CANCELLED",
    2 => "UNKNOWN",
    3 => "INVALID_ARGUMENT",
    4 => "DEADLINE_EXCEEDED",
    5 => "NOT_FOUND",
    6 => "ALREADY_EXISTS",
    7 => "PERMISSION_DENIED",
    8 => "RESOURCE_EXHAUSTED",
    9 => "FAILED_PRECONDITION",
    10 => "ABORTED",
    11 => "OUT_OF_RANGE",
    12 => "UNIMPLEMENTED",
    13 => "INTERNAL",
    14 => "UNAVAILABLE",
    15 => "DATA_LOSS",
    16 => "UNAUTHENTICATED",
)

function Base.showerror(io::IO, e::gRPCServiceCallException)
    print(
        io,
        "gRPCServiceCallException(grpc_status=$(GRPC_CODE_TABLE[e.grpc_status])($(e.grpc_status)), message=\"$(e.message)\")",
    )
end

include("Utils.jl")
include("Curl.jl")
include("gRPC.jl")
include("Unary.jl")

# Streaming only supported on >= 1.12
@static if VERSION >= v"1.12"
    include("Streaming.jl")
else
    @warn "Julia $(VERSION) <= 1.12, streaming support is disabled: https://github.com/JuliaIO/gRPCClient.jl/issues/68"
end

include("ProtoBuf.jl")

export grpc_init
export grpc_shutdown
export grpc_global_handle
export grpc_register_service_codegen

export grpc_async_request
export grpc_async_await
export grpc_sync_request

export gRPCCURL
export gRPCRequest
export gRPCServiceClient
export gRPCAsyncChannelResponse

export gRPCException
export gRPCServiceCallException


@setup_workload begin
    function _get_precompile_host()
        if "GRPC_PRECOMPILE_SERVER_HOST" in keys(ENV)
            ENV["GRPC_PRECOMPILE_SERVER_HOST"]
        else
            # We don't have a Julia gRPC server so call my Linode's public gRPC endpoint
            "172.238.177.88"
        end
    end

    function _get_precompile_port()
        if "GRPC_PRECOMPILE_SERVER_PORT" in keys(ENV)
            parse(UInt16, ENV["GRPC_PRECOMPILE_SERVER_PORT"])
        else
            8001
        end
    end

    TEST_HOST = _get_precompile_host()
    TEST_PORT = _get_precompile_port()

    @compile_workload begin
        "GRPC_PRECOMPILE_DISABLE" in keys(ENV) && return

        include("../test/gen/test/test_pb.jl")

        # Initialize the gRPC package - grpc_shutdown() does the opposite for use with Revise.
        grpc_init()

        # Unary 
        client_unary = TestService_TestRPC_Client(TEST_HOST, TEST_PORT)

        try
            # Sync API
            test_response =
                grpc_sync_request(client_unary, TestRequest(1, Vector{UInt64}()))

            # Async API
            request = grpc_async_request(client_unary, TestRequest(1, Vector{UInt64}()))
            test_response = grpc_async_await(client_unary, request)

            # Streaming 
            @static if VERSION >= v"1.12"

                # Request 
                client_request =
                    TestService_TestClientStreamRPC_Client(TEST_HOST, TEST_PORT)
                request_c = Channel{TestRequest}(16)
                put!(request_c, TestRequest(1, zeros(UInt64, 1)))
                close(request_c)
                test_response = grpc_async_await(
                    client_request,
                    grpc_async_request(client_request, request_c),
                )

                # Response 
                client_response =
                    TestService_TestServerStreamRPC_Client(TEST_HOST, TEST_PORT)
                response_c = Channel{TestResponse}(16)
                req = grpc_async_request(
                    client_response,
                    TestRequest(1, zeros(UInt64, 1)),
                    response_c,
                )
                test_response = take!(response_c)
                grpc_async_await(req)

                # Bidirectional 
                client_bidirectional = TestService_TestBidirectionalStreamRPC_Client(
                    TEST_HOST,
                    TEST_PORT;
                    deadline = PRECOMPILE_DEADLINE,
                )
                request_c = Channel{TestRequest}(16)
                response_c = Channel{TestResponse}(16)
                put!(request_c, TestRequest(1, zeros(UInt64, 1)))
                req = grpc_async_request(client_bidirectional, request_c, response_c)
                test_response = take!(response_c)
                close(request_c)
                grpc_async_await(req)
            end
        catch ex
            !isa(ex, gRPCServiceCallException) &&
                ex.code == DEADLINE_EXCEEDED &&
                rethrow(ex)

            @warn """
            DEADLINE_EXCEEDED during gRPCClient.jl precompile

            A dedicated server for allowing this package to precompile is provided to the public but is not accessible from this network.
            If you care about this you can consider the following options:
            - Request that your network administrator allow connections to this address on TCP: $(TEST_HOST):$(TEST_PORT)
            - Add a precompile block to your own package which calls an accessible gRPC server
            - Run your own instance of the Go gRPC test server in public mode `./grpc_test_server -public` and set GRPC_PRECOMPILE_SERVER_HOST and GRPC_PRECOMPILE_SERVER_PORT environment variables to point to it
            - Set the GRPC_PRECOMPILE_DISABLE environment variable to disable gRPCClient.jl precompiliation and this message
            """
        end

        grpc_shutdown()
    end
end



end
