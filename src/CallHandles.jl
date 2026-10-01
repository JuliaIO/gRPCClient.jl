"""
    gRPCChannel(host::AbstractString, port::Integer[; grpc::gRPCCURL = grpc_global_handle(), options...])

A lightweight description of the connection to a gRPC server. 

The port and hostname are required. By default, a `gRPCChannel` will handle
all communication to the server through its `gRPCCURL` instance, which defaults
to the global default instance. Additional options for the connection may be provided
as keyword arguments. Note that these settings only set the defaults when using a 
`gRPCChannel`, but may be overridden in each call. 

# Options

$(_options_docstring)

# Example

In the example below, the setting `secure` will be overriden in the RPC call. 
```
chan = gRPCChannel("127.0.0.1", 12345, secure = true)

response = MyService.MyUnaryRPC(chan, MyMessage(), secure = false)
```
"""
struct gRPCChannel
    host::String
    port::Int
    grpc::gRPCCURL
    options::gRPCConnectionOptions
    function gRPCChannel(host::AbstractString, port::Integer; grpc::gRPCCURL = grpc_global_handle(), options...)
        return new(host, port, grpc, gRPCConnectionOptions(; options...))
    end
end

abstract type AbstractgRPCCall{Trpc} end
isstreaming_request(::AbstractgRPCCall{Trpc}) where {Trpc} = isstreaming_request(Trpc)
isstreaming_response(::AbstractgRPCCall{Trpc}) where {Trpc} = isstreaming_response(Trpc)
request_type(::AbstractgRPCCall{Trpc}) where {Trpc} = request_type(Trpc)
response_type(::AbstractgRPCCall{Trpc}) where {Trpc} = response_type(Trpc)

struct gRPCUnaryCall{Trpc} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
end
struct gRPCClientStreamCall{Trpc, TRequest} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
end
struct gRPCServerStreamCall{Trpc} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    response_channel::Channel{IOBuffer}
end
struct gRPCBidirectionalStreamCall{Trpc, TRequest} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
    response_channel::Channel{IOBuffer}
end

# Helpers for dispatching based on request or response types
const UnaryRequestRPC = Union{gRPCUnaryCall, gRPCServerStreamCall}
const StreamingRequestRPC = Union{gRPCClientStreamCall, gRPCBidirectionalStreamCall}
const UnaryResponseRPC = Union{gRPCUnaryCall, gRPCClientStreamCall}
const StreamingResponseRPC = Union{gRPCServerStreamCall, gRPCBidirectionalStreamCall}

function Base.show(io::IO, rpc::AbstractgRPCCall)
    f = typeof(rpc).parameters[1].instance
    # If typeinfo is set, we know the rpc is shown as part of some container.
    return if get(io, :compact, false) || haskey(io, :typeinfo)
        print(io, "$(typeof(rpc))(...)")
    else
        print(
            io,
            """
            $(typeof(rpc))(...) with properties:
              RPC           : $(parentmodule(f)).$(nameof(f))
              Request type  : $(isstreaming_request(rpc) ? "stream " : "unary ")$(request_type(rpc))
              Response type : $(isstreaming_response(rpc) ? "stream " : "unary ")$(response_type(rpc))
              Status        : $(GRPC_CODE_TABLE[rpc.req.grpc_status])
              Completed     : $(!isopen(rpc))"""
        )
    end
end

function handle_channel_exception(ex, rpc, newex)
    if isa(ex, InvalidStateException) && ex.state === :closed
        # The channel may have been closed before the shutdown procedure
        # was complete. Obtain the lock for a correct diagnosis.
        grpc = rpc.req.grpc::gRPCCURL
        lock(grpc.lock) do
            if !isopen(rpc.req)
                if !isnothing(rpc.req.ex)
                    throw(rpc.req.ex)
                end
                throw(newex)
            end
        end
    end
    rethrow()
end

"""
    close(rpc::AbstractgRPCCall)

Waits for `rpc` to be closed by the server and throw any exception caught. 

Note that `close(rpc)` may block forever, as it depends on 
the call being shut down by the server logic. In such cases, 
[`detach(rpc)`](@ref) may be a better option. 
"""
@inline function Base.close(rpc::AbstractgRPCCall)
    isstreaming_request(rpc) && close(rpc.request_channel)
    return try
        grpc_async_await(rpc.req)
    finally
        # this will be closed by a task anyway, but
        # its better to ensure it is closed before this
        # function returns.
        isstreaming_response(rpc) && close(rpc.response_channel)
    end
end

"""
    detach(rpc::AbstractgRPCCall[; throws::Bool = true])

Gracefully cancel an in-flight request `rpc` and frees all associated resources. 

If `throws`, any exception caught during the lifetime of `rpc` will be thrown. 
The stored exception is replaced with  CANCELLED, which will be thrown on 
future calls to `detach` or `close`. 
"""
@inline function Base.detach(rpc::AbstractgRPCCall; throws::Bool = true)
    grpc = rpc.req.grpc::gRPCCURL
    prev_ex = @lock grpc.lock rpc.req.ex

    grpc_cancel(rpc.req)

    # this will be closed by a task anyway, but
    # its better to ensure it is closed before this
    # function returns.
    isstreaming_request(rpc) && close(rpc.request_channel)
    isstreaming_response(rpc) && close(rpc.response_channel)

    # If the call got cancelled by this call to `detach`, we
    # also want to throw any exception that already existed.
    if throws && !isnothing(prev_ex)
        throw(prev_ex)
    end
    return nothing
end

"""
    isopen(rpc::AbstractgRPCCall)

Tells whether the underlying call is still active.

Use it for liveness, or to decide whether another `put!` is still worthwhile. Do not
use it to tell whether more responses remain: responses may still be buffered or in
transit after it returns `false`, so drain a stream by consuming responses to
completion rather than guarding on this.
"""
@inline Base.isopen(rpc::AbstractgRPCCall) = isopen(rpc.req)

# Overload of Base.put! should be in generated code to
# enable IDE suggestions of msg type.
@inline function _put!(rpc::StreamingRequestRPC, msg; done::Bool = false)
    try
        put!(rpc.request_channel, msg)
    catch ex
        handle_channel_exception(ex, rpc, gRPCServiceCallException(GRPC_OK, "Call has already been completed."))
    end
    done && close(rpc.request_channel)
    return nothing
end

"""
    put!(rpc::gRPCBidirectionalStreamCall, msg[; done::Bool = false])    
    put!(rpc::gRPCClientStreamCall, msg[; done::Bool = false])
    put!(rpc::gRPCBidirectionalStreamCall; done::Bool)
    put!(rpc::gRPCClientStreamCall; done::Bool)

Sends a request message `msg` (if provided) over a client-streaming RPC. 

If `done = true`, the server will be notified that the client is done
sending more messages. Future calls to `put!` will result in an exception. 
"""
@inline function Base.put!(rpc::StreamingRequestRPC; done::Bool)
    done && close(rpc.request_channel)
    return nothing
end

@static if @isdefined(isfull) # Not available in 1.10
    """
        isfull(rpc::gRPCClientStreamCall)
        isfull(rpc::gRPCBidirectionalStreamCall)

    Tells whether the request channel of `rpc` is full. 

    If `true`, a subsequent call to `put!` will likely be blocking.
    If `false`, a subsequent call to `put!` will not be blocking. 
    """
    @inline Base.isfull(rpc::StreamingRequestRPC) = isfull(rpc.request_channel)
end # @static if @isdefined(isfull)

"""
    fetch(rpc::gRPCUnaryCall)
    fetch(rpc::gRPCClientStreamCall)
    fetch(..., Vector{UInt8})

Reads the response of `rpc`, cleanup resources and throw any exception caught. 

If the `rpc` has streaming requests, the request stream will be closed.

If `Vector{UInt8}` is provided as the second argument, the response 
will be returned without decoding the proto format. 

If the response of `rpc` is not of interest, `close` may be used to avoid decoding. 
"""
@inline function Base.fetch(rpc::UnaryResponseRPC)
    if isstreaming_request(rpc)
        put!(rpc, done = true)
    end
    io = grpc_async_await(rpc.req, IOBuffer)
    return decode(ProtoDecoder(seekstart(io)), response_type(rpc))
end

@inline function Base.fetch(rpc::UnaryResponseRPC, ::Type{Vector{UInt8}})
    if isstreaming_request(rpc)
        put!(rpc, done = true)
    end
    io = grpc_async_await(rpc.req, IOBuffer)
    return read(seekstart(io))
end

"""
    wait(rpc::gRPCUnaryCall)
    wait(rpc::gRPCClientStreamCall)

Waits for an RPC with unary response to be ready to return its response. 
"""
@inline function Base.wait(rpc::UnaryResponseRPC)
    wait(rpc.req)
    !isnothing(rpc.req.ex) && throw(rpc.req.ex)
    return nothing
end

"""
    isready(rpc::gRPCUnaryCall)
    isready(rpc::gRPCClientStreamCall)

Tells whether `fetch(rpc)` would return the response immediately, without blocking.

Use it to poll for the response. It is `false` both while the call runs and if it
failed; use `isopen(rpc)` to test for completion, then `fetch` (which returns the
response or throws the error).
"""
@inline function Base.isready(rpc::UnaryResponseRPC)
    return !isopen(rpc) && isnothing(rpc.req.ex)
end

"""
    wait(rpc::gRPCServerStreamCall)
    wait(rpc::gRPCBidirectionalStreamCall)

Block until a response is available or the stream has ended, returning in both cases; a
failed call throws its exception here.

You will usually want to check [`isready`](@ref) afterwards: `true` means a response is
available to [`take!`](@ref), `false` means the stream has ended.
"""
@inline function Base.wait(rpc::StreamingResponseRPC)
    try
        wait(rpc.response_channel)
    catch ex
        (ex isa InvalidStateException && ex.state === :closed) || rethrow()
        # The response channel is closed: a failed call re-raises its exception here,
        # while a clean end of stream returns normally.
        grpc = rpc.req.grpc::gRPCCURL
        lock(grpc.lock) do
            if !isopen(rpc.req)
                isnothing(rpc.req.ex) || throw(rpc.req.ex)
            end
        end
    end
    return nothing
end

"""
    isready(rpc::gRPCServerStreamCall)
    isready(rpc::gRPCBidirectionalStreamCall)

Tells whether a response is buffered, so `take!(rpc)` would return one without blocking.

Use it to consume responses without blocking (for example polling, or fan-in across
several calls). Do not use it as a loop guard to drain a stream: a `false` does not mean
the stream has ended — more responses may be in transit or arrive later — and pairing it
with `isopen` still races. Iterate `rpc` (or take a known number of responses) instead.
"""
@inline function Base.isready(rpc::StreamingResponseRPC)
    return isready(rpc.response_channel)
end

"""
    take!(rpc::gRPCServerStreamCall)
    take!(rpc::gRPCBidirectionalStreamCall)
    take!(..., Vector{UInt8})

Remove and return a recevied response from a stream. Blocks unless a response is already available. 

If `Vector{UInt8}` is provided as the second argument, the response 
will be returned without decoding the proto format. 
"""
@inline function Base.take!(rpc::StreamingResponseRPC)
    return try
        io = take!(rpc.response_channel)
        seekstart(io)
        decode(ProtoDecoder(io), response_type(rpc))
    catch ex
        handle_channel_exception(ex, rpc, gRPCServiceCallException(GRPC_OK, "Call has already been completed and no more responses are available. "))
    end
end

@inline function Base.take!(rpc::StreamingResponseRPC, ::Type{Vector{UInt8}})
    return try
        io = take!(rpc.response_channel)
        seekstart(io)
        read(io)::Vector{UInt8}
    catch ex
        handle_channel_exception(ex, rpc, gRPCServiceCallException(GRPC_OK, "Call has already been completed and no more responses are available. "))
    end
end

"""
    fetch(rpc::gRPCServerStreamCall)
    fetch(rpc::gRPCBidirectionalStreamCall)
    fetch(..., Vector{UInt8})

Return a recevied response from a response stream. Blocks unless a response is already available. 

If `Vector{UInt8}` is provided as the second argument, the response 
will be returned without decoding the proto format. 

Note that `fetch` does not remove the response, so repeated calls will return the same
value. In most scenarios, [`take!`](@ref) is the preferred option for response streams. 
"""
@inline function Base.fetch(rpc::StreamingResponseRPC)
    return try
        io = fetch(rpc.response_channel)
        seekstart(io)
        decode(ProtoDecoder(io), response_type(rpc))
    catch ex
        handle_channel_exception(ex, rpc, gRPCServiceCallException(GRPC_OK, "Call has already been completed and no more responses are available. "))
    end
end

@inline function Base.fetch(rpc::StreamingResponseRPC, ::Type{Vector{UInt8}})
    return try
        io = fetch(rpc.response_channel)
        seekstart(io)
        read(io)::Vector{UInt8}
    catch ex
        handle_channel_exception(ex, rpc, gRPCServiceCallException(GRPC_OK, "Call has already been completed and no more responses are available. "))
    end
end

"""
    iterate(rpc::gRPCServerStreamCall)
    iterate(rpc::gRPCBidirectionalStreamCall)

Iterate the responses of `rpc`, so a response stream can be drained with a `for` loop:

```julia
for response in rpc
    # handle response
end
```

This is the race-free way to consume a stream of unknown length: each response is returned
in turn and the loop ends cleanly once the server closes the stream. A failed call still
throws from within the loop. Prefer this over guarding a `take!` loop with
[`isopen`](@ref)/[`isready`](@ref), which cannot do both safely.

Iteration can also be implemented manually with the following equivalent:

```julia
while true
    wait(rpc)
    isready(rpc) || break
    response = take!(rpc)
    # handle response
end
```
"""
@inline function Base.iterate(rpc::StreamingResponseRPC, state = nothing)
    # Equivalent to the wait/isready/take! procedure above, but done in a single atomic
    # take!: a clean end of stream surfaces as the GRPC_OK "already completed" exception,
    # which stops iteration; any other status is a real failure and propagates.
    return try
        (take!(rpc), nothing)
    catch ex
        if ex isa gRPCServiceCallException && ex.grpc_status == GRPC_OK
            nothing
        else
            rethrow()
        end
    end
end

Base.IteratorSize(::Type{<:StreamingResponseRPC}) = Base.SizeUnknown()
Base.eltype(::Type{<:AbstractgRPCCall{Trpc}}) where {Trpc} = response_type(Trpc)

# Implement stateful iteration protocol; prevent `isempty` from removing responses.
@inline function Base.isdone(rpc::StreamingResponseRPC, state...)
    c = rpc.response_channel
    return !isopen(c) && !isready(c)
end
