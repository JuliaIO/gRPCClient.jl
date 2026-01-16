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

end
