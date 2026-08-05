

"""
    gRPCChannel(host::AbstractString, port::Integer[; grpc = gRPCCURL()])

TODO
"""
struct gRPCChannel
    host::String
    port::Int
    grpc::gRPCCURL
    function gRPCChannel(host::AbstractString, port::Integer; grpc = gRPCCURL())
        new(host, port, grpc)
    end
end

"""
Supertype for all call handles (stream/unary)

TODO
""" 
abstract type gRPCCallHandle{Trpc} end
isstreaming_request(::gRPCCallHandle{Trpc}) where Trpc = isstreaming_request(Trpc)
isstreaming_response(::gRPCCallHandle{Trpc}) where Trpc = isstreaming_response(Trpc)
request_type(::gRPCCallHandle{Trpc}) where Trpc = request_type(Trpc)
response_type(::gRPCCallHandle{Trpc}) where Trpc = response_type(Trpc)

struct gRPCUnaryHandle{Trpc} <: gRPCCallHandle{Trpc}
    req::gRPCRequest
end
struct gRPCStreamRequestHandle{Trpc, TRequest} <: gRPCCallHandle{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
end
struct gRPCStreamResponseHandle{Trpc, TResponse} <: gRPCCallHandle{Trpc}
    req::gRPCRequest
    response_channel::Channel{TResponse}
end
struct gRPCBidirectionalStreamHandle{Trpc, TRequest, TResponse} <: gRPCCallHandle{Trpc}
    req::gRPCRequest
    request_channel::Channel{TRequest}
    response_channel::Channel{TResponse}
end

const UnaryRequestRPC = Union{gRPCUnaryHandle, gRPCStreamResponseHandle}
const StreamingRequestRPC = Union{gRPCStreamRequestHandle, gRPCBidirectionalStreamHandle}
const UnaryResponseRPC = Union{gRPCUnaryHandle, gRPCStreamRequestHandle}
const StreamingResponseRPC = Union{gRPCStreamResponseHandle, gRPCBidirectionalStreamHandle}

function Base.show(io::IO, rpc::gRPCCallHandle) 
    f = typeof(rpc).parameters[1].instance
    if get(IOContext(io), :compact, false)
        print(io, "$(typeof(rpc))(...)")
    else
        print(io, """
        $(typeof(rpc))(...) with:
         RPC           : $(parentmodule(f)).$(nameof(f))
         Request type  : $(isstreaming_request(rpc) ? "stream " : "unary ")$(request_type(rpc))
         Response type : $(isstreaming_response(rpc) ? "stream " : "unary ")$(response_type(rpc))
         Status        : $(GRPC_CODE_TABLE[rpc.req.grpc_status])
         Completed     : $(!isopen(rpc))""")
    end
end

"""
    close(rpc::gRPCCallHandle)

Waits for `rpc` to be closed by the server and throw any exception caught. 

Note that `close(rpc)` may block forever, as it depends on 
the call being shut down by the server logic. In such cases, 
[`detach(rpc)`](@ref) may be a better option. 
"""
function Base.close(rpc::gRPCCallHandle)
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
    detach(rpc::gRPCCallHandle[; throws::Bool = false])

Gracefully cancel an in-flight request `rpc` and frees all associated resources. 

If `throws`, any exception caught during the lifetime of `rpc` will be thrown. 
The stored exception is replaced with  CANCELLED, which will be thrown on 
future calls to `detach` or `close`. 
"""
function Base.detach(rpc::gRPCCallHandle; throws::Bool = true)
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
    isopen(rpc::gRPCCallHandle)

Tells whether `rpc` is still open.

If false, either all responses have been received or an error has occured.
"""
Base.isopen(rpc::gRPCCallHandle) = isopen(rpc.req)

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
    put!(rpc::gRPCBidirectionalStreamHandle, msg[; done::Bool = false])
    put!(rpc::gRPCStreamRequestHandle      , msg[; done::Bool = false])
    put!(rpc::gRPCBidirectionalStreamHandle[; done::Bool = false])
    put!(rpc::gRPCStreamRequestHandle      [; done::Bool = false])

Sends a request message `msg` (if provided) over a client-streaming RPC. 

If `done = true`, the server will be notified that the client is done
sending more messages. Future calls to `put!` will result in an exception. 
"""
function Base.put!(rpc::StreamingRequestRPC; done::Bool = false)
    done && close(rpc.request_channel)
    return nothing
end

"""
    isfull(rpc::gRPCStreamRequestHandle)
    isfull(rpc::gRPCBidirectionalStreamHandle)

Tells whether the request channel of `rpc` is full. 

If `true`, a subsequent call to `put!` will likely be blocking.
If `false`, a subsequent call to `put!` will not be blocking. 
""" 
@static if @isdefined(isfull) # Not available in 1.10
    Base.isfull(rpc::StreamingRequestRPC) = isfull(rpc.request_channel)
end

"""
    fetch(rpc::gRPCUnaryHandle)
    fetch(rpc::gRPCStreamRequestHandle)

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
    wait(rpc::gRPCUnaryHandle)
    wait(rpc::gRPCStreamRequestHandle)

Waits for an RPC with unary response to be ready to return its response. 
"""
function Base.wait(rpc::UnaryResponseRPC)
    wait(rpc.req)
    !isnothing(rpc.req.ex) && throw(rpc.req.ex)
    return nothing
end

"""
    isready(rpc::gRPCUnaryHandle)
    isready(rpc::gRPCStreamRequestHandle)

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
    take!(rpc::gRPCStreamResponseHandle)
    take!(rpc::gRPCBidirectionalStreamHandle)

Remove and return a recevied response from a stream. Blocks unless a response is already available. 
""" Base.take!

@doc """
    fetch(rpc::gRPCStreamResponseHandle)
    fetch(rpc::gRPCBidirectionalStreamHandle)

Return a recevied response from a response stream. Blocks unless a response is already available. 

Note that `fetch` does not remove the response, so repeated calls will return the same
value. In most scenarios, [`take!`](@ref) is the preferred option for response streams. 
""" Base.fetch

@doc """
    wait(rpc::gRPCStreamResponseHandle)
    wait(rpc::gRPCBidirectionalStreamHandle)

Wait until a response becomes available. 
""" Base.wait

@doc """
    isready(rpc::gRPCStreamResponseHandle)
    isready(rpc::gRPCBidirectionalStreamHandle)

Tells whether the response stream has a message available which has not yet been removed by `take!`.
""" Base.isready