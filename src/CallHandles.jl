

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
        new(host, port, grpc, gRPCConnectionOptions(; options...))
    end
end

abstract type AbstractgRPCCall{Trpc} end
isstreaming_request(::AbstractgRPCCall{Trpc}) where Trpc = isstreaming_request(Trpc)
isstreaming_response(::AbstractgRPCCall{Trpc}) where Trpc = isstreaming_response(Trpc)
request_type(::AbstractgRPCCall{Trpc}) where Trpc = request_type(Trpc)
response_type(::AbstractgRPCCall{Trpc}) where Trpc = response_type(Trpc)

struct gRPCUnaryCall{Trpc} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
end
struct gRPCClientStreamCall{Trpc, TRequest} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
end
struct gRPCServerStreamCall{Trpc, TResponse} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    response_channel::Channel{TResponse}
end
struct gRPCBidirectionalStreamCall{Trpc, TRequest, TResponse} <: AbstractgRPCCall{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
    response_channel::Channel{TResponse}
end

# Helpers for dispatching based on request or response types
const UnaryRequestRPC = Union{gRPCUnaryCall, gRPCServerStreamCall}
const StreamingRequestRPC = Union{gRPCClientStreamCall, gRPCBidirectionalStreamCall}
const UnaryResponseRPC = Union{gRPCUnaryCall, gRPCClientStreamCall}
const StreamingResponseRPC = Union{gRPCServerStreamCall, gRPCBidirectionalStreamCall}

function Base.show(io::IO, rpc::AbstractgRPCCall) 
    f = typeof(rpc).parameters[1].instance
    if get(IOContext(io), :compact, false)
        print(io, "$(typeof(rpc))(...)")
    else
        print(io, """
        $(typeof(rpc))(...) with properties:
          RPC           : $(parentmodule(f)).$(nameof(f))
          Request type  : $(isstreaming_request(rpc) ? "stream " : "unary ")$(request_type(rpc))
          Response type : $(isstreaming_response(rpc) ? "stream " : "unary ")$(response_type(rpc))
          Status        : $(GRPC_CODE_TABLE[rpc.req.grpc_status])
          Completed     : $(!isopen(rpc))""")
    end
end

"""
    close(rpc::AbstractgRPCCall)

Waits for `rpc` to be closed by the server and throw any exception caught. 

Note that `close(rpc)` may block forever, as it depends on 
the call being shut down by the server logic. In such cases, 
[`detach(rpc)`](@ref) may be a better option. 
"""
function Base.close(rpc::AbstractgRPCCall)
    isstreaming_request(rpc) && close(rpc.request_channel)
    try
        grpc_async_await(rpc.req)
    finally
        # this will be closed by a task anyway, but
        # its better to ensure it is closed before this 
        # function returns.
        isstreaming_response(rpc) && close(rpc.response_channel)
    end
end

"""
    detach(rpc::AbstractgRPCCall[; throws::Bool = false])

Gracefully cancel an in-flight request `rpc` and frees all associated resources. 

If `throws`, any exception caught during the lifetime of `rpc` will be thrown. 
The stored exception is replaced with  CANCELLED, which will be thrown on 
future calls to `detach` or `close`. 
"""
function Base.detach(rpc::AbstractgRPCCall; throws::Bool = true)
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

Tells whether `rpc` is still open.

If false, either all responses have been received or an error has occured.
"""
Base.isopen(rpc::AbstractgRPCCall) = isopen(rpc.req)

# Overload of Base.put! should be in generated code to  
# enable IDE suggestions of msg type. 
function _put!(rpc::StreamingRequestRPC, msg; done::Bool = false) 
    try
        put!(rpc.request_channel, msg)
    catch ex
        if isa(ex, InvalidStateException) && ex.state === :closed
            # The channel may have been closed before the shutdown procedure
            # was complete. Obtain the lock for a correct diagnosis. 
            grpc = rpc.req.grpc::gRPCCURL
            lock(grpc.lock) do 
                if !isopen(rpc.req) 
                    if !isnothing(rpc.req.ex)
                        throw(rpc.req.ex)
                    end
                    throw(gRPCServiceCallException(GRPC_OK, "Call has already been completed."))
                end
            end
        end
    end 
    done && close(rpc.request_channel)
    return nothing
end

"""
    put!(rpc::gRPCBidirectionalStreamCall, msg[; done::Bool = false])
    put!(rpc::gRPCBidirectionalStreamCall; done::Bool)
    put!(rpc::gRPCClientStreamCall, msg[; done::Bool = false])
    put!(rpc::gRPCClientStreamCall; done::Bool)

Sends a request message `msg` (if provided) over a client-streaming RPC. 

If `done = true`, the server will be notified that the client is done
sending more messages. Future calls to `put!` will result in an exception. 
"""
function Base.put!(rpc::StreamingRequestRPC; done::Bool)
    done && close(rpc.request_channel)
    return nothing
end

"""
    isfull(rpc::gRPCClientStreamCall)
    isfull(rpc::gRPCBidirectionalStreamCall)

Tells whether the request channel of `rpc` is full. 

If `true`, a subsequent call to `put!` will likely be blocking.
If `false`, a subsequent call to `put!` will not be blocking. 
""" 
@static if @isdefined(isfull) # Not available in 1.10
    Base.isfull(rpc::StreamingRequestRPC) = isfull(rpc.request_channel)
end

"""
    fetch(rpc::gRPCUnaryCall)
    fetch(rpc::gRPCClientStreamCall)

Reads the response of `rpc`, cleanup resources and throw any exception caught. 

If the `rpc` has streaming requests, the request stream will be closed.

If the response of `rpc` is not of interest, `close` may be used to avoid decoding. 
"""
function Base.fetch(rpc::UnaryResponseRPC)
    if isstreaming_request(rpc)
        put!(rpc, done = true)
    end
    return grpc_async_await(rpc.req, response_type(rpc))
end

"""
    wait(rpc::gRPCUnaryCall)
    wait(rpc::gRPCClientStreamCall)

Waits for an RPC with unary response to be ready to return its response. 
"""
function Base.wait(rpc::UnaryResponseRPC)
    wait(rpc.req)
    !isnothing(rpc.req.ex) && throw(rpc.req.ex)
    return nothing
end

"""
    isready(rpc::gRPCUnaryCall)
    isready(rpc::gRPCClientStreamCall)

Check whether `fetch(rpc)` or `take!` is ready to return a response (or throw an exception) once called. 
"""
function Base.isready(rpc::UnaryResponseRPC)
    return !isopen(rpc) && isnothing(rpc.req.ex)
end

for f in (:take!, :wait, :fetch, :isready)
    eval(quote
        function Base.$f(rpc::StreamingResponseRPC)
            try
                $(f)(rpc.response_channel)
            catch ex
                if isa(ex, InvalidStateException) && ex.state === :closed
                    # The channel may have been closed before the shutdown procedure
                    # was complete. Obtain the lock for a correct diagnosis. 
                    grpc = rpc.req.grpc::gRPCCURL
                    lock(grpc.lock) do 
                        if !isopen(rpc.req) 
                            if !isnothing(rpc.req.ex)
                                throw(rpc.req.ex)
                            end
                            throw(gRPCServiceCallException(GRPC_OK, "Call has already been completed and no more responses are available. "))
                        end
                    end
                end
                rethrow()
            end 
        end
    end)
end

@doc """
    take!(rpc::gRPCServerStreamCall)
    take!(rpc::gRPCBidirectionalStreamCall)

Remove and return a recevied response from a stream. Blocks unless a response is already available. 
""" Base.take!

@doc """
    fetch(rpc::gRPCServerStreamCall)
    fetch(rpc::gRPCBidirectionalStreamCall)

Return a recevied response from a response stream. Blocks unless a response is already available. 

Note that `fetch` does not remove the response, so repeated calls will return the same
value. In most scenarios, [`take!`](@ref) is the preferred option for response streams. 
""" Base.fetch

@doc """
    wait(rpc::gRPCServerStreamCall)
    wait(rpc::gRPCBidirectionalStreamCall)

Wait until a response becomes available. 
""" Base.wait

@doc """
    isready(rpc::gRPCServerStreamCall)
    isready(rpc::gRPCBidirectionalStreamCall)

Tells whether the response stream has a message available which has not yet been removed by `take!`.
""" Base.isready