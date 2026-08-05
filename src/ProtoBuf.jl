function service_cb(io, t::CodeGenerators.ServiceType, ctx::CodeGenerators.Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name

    for (i, rpc) in enumerate(t.rpcs)
        rpc_path = "/$namespace.$service_name/$(rpc.name)"

        request_type = rpc.request_type.name
        response_type = rpc.response_type.name

        if rpc.request_type.package_namespace !== nothing
            request_type = join([rpc.request_type.package_namespace, request_type], ".")
        end
        if rpc.response_type.package_namespace !== nothing
            response_type = join([rpc.response_type.package_namespace, response_type], ".")
        end

        export_name = "$(service_name)_$(rpc.name)_Client"

        println(io, "$(export_name)(")
        println(io, "\thost, port;")
        # TRequest / TResponse default to the generated proto types. Override
        # either (or both) with Vector{UInt8} to send / receive that side as a
        # raw, already-encoded protobuf payload (partial decoding).
        println(io, "\tTRequest=$request_type,")
        println(io, "\tTResponse=$response_type,")
        println(io, "\tgrpc=gRPCClient.grpc_global_handle(),")
        println(io, "\toptions...")
        println(
            io,
            ") = gRPCClient.gRPCServiceClient{TRequest, $(rpc.request_stream), TResponse, $(rpc.response_stream)}(",
        )
        println(io, "\thost, port, \"$rpc_path\";")
        println(io, "\tgrpc=grpc,")
        println(io, "\toptions...")
        println(io, ")")

        # TODO: define a standard way to check whether we should export that is used in both ProtoBuf.jl and gRPCClient.jl
        if CodeGenerators.is_namespaced(ctx.proto_file) || ctx.options.always_use_modules
            println(io, "export $(export_name)")
        else
            println(io, "")
        end

        if i < lastindex(t.rpcs)
            println(io, "")
        end
    end

    ###################
    # New API
    ###################
    println(io, """

    module $service_name
        import ..gRPCClient
    """)
    
    # Import individual types from the parent module
    import_type_list = Set{String}()
    # Types referred to by module need not be imported individually,
    # importing the top-level module is enough
    import_mod_list = Set{String}()

    # Find all top-level packages containing the request and response types
    for rpc in t.rpcs
        for t in (rpc.request_type, rpc.response_type)
            ns = t.package_namespace
            if !isnothing(ns)
                modname = first(split(ns, '.'))
                # Until julia gets a dedicated syntax for importing from parent module without
                # knowing its name, we need to use `parentmodule`. Otherwise the generated file
                # will only work if included from the correct generated toplevel package file. 
                push!(import_mod_list, "const $(modname)::Module = Base.parentmodule(@__MODULE__).$(modname)")
            else
                push!(import_type_list, "const $(t.name)::DataType = Base.parentmodule(@__MODULE__).$(t.name)")
            end
        end
    end
    for imp in import_mod_list
        print(io, """
            $imp
        """)
    end
    for imp in import_type_list
        print(io, """
            $imp
        """)
    end
    println(io, )

    for rpc in t.rpcs
        request_type = rpc.request_type.name
        response_type = rpc.response_type.name

        if rpc.request_type.package_namespace !== nothing
            request_type = join([rpc.request_type.package_namespace, request_type], ".")
        end
        if rpc.response_type.package_namespace !== nothing
            response_type = join([rpc.response_type.package_namespace, response_type], ".")
        end

        print(io, """
            # $service_name.$(rpc.name)
        """)

        if !rpc.request_stream && !rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type; kws...)
                    gRPCClient.grpc_call_unary_sync(chan, typeof($(rpc.name)), req; kws...)::$response_type
                end
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type, ::gRPCClient.gRPCAsync; kws...) 
                    gRPCClient.grpc_call_unary_async(chan, typeof($(rpc.name)), req; kws...)::gRPCClient.gRPCCallHandle
                end
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type, response_ch::Channel, index::Integer; kws...)::Nothing
                    gRPCClient.grpc_call_unary_async(chan, typeof($(rpc.name)), req, response_ch, index; kws...)
                end
                function $(rpc.name)(host::AbstractString, port::Integer, req::$request_type, args...; kws...)
                    $(rpc.name)(gRPCChannel(host, port), req::$request_type, args...; kws...)
                end
            """)
        elseif rpc.request_stream && !rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel; kws...)
                    gRPCClient.grpc_call_stream_request(chan, typeof($(rpc.name)); kws...)::gRPCClient.gRPCCallHandle
                end
                function $(rpc.name)(host::AbstractString, port::Integer; kws...)
                    $(rpc.name)(gRPCChannel(host, port); kws...)
                end
                Base.put!(handle::gRPCClient.gRPCCallHandle{typeof($(rpc.name))}, msg::$(request_type); kws...) = gRPCClient._put!(handle, msg; kws...)
            """)
        elseif !rpc.request_stream && rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type; kws...)
                    gRPCClient.grpc_call_stream_response(chan, typeof($(rpc.name)), req; kws...)::gRPCClient.gRPCCallHandle
                end
                function $(rpc.name)(host::AbstractString, port::Integer, req::$request_type; kws...)
                    $(rpc.name)(gRPCChannel(host, port), req; kws...)
                end
            """)
        elseif rpc.request_stream && rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel; kws...)
                    gRPCClient.grpc_call_bidirectional_stream(chan, typeof($(rpc.name)); kws...)::gRPCClient.gRPCCallHandle
                end
                function $(rpc.name)(host::AbstractString, port::Integer; kws...)
                    $(rpc.name)(gRPCChannel(host, port); kws...)
                end
                Base.put!(handle::gRPCClient.gRPCCallHandle{typeof($(rpc.name))}, msg::$(request_type); kws...) = gRPCClient._put!(handle, msg; kws...)
            """)
        end
        print(io, """
            gRPCClient.rpc_path(::Type{typeof($(rpc.name))}) = "/$namespace.$service_name/$(rpc.name)"
            gRPCClient.isstreaming_request(::Type{typeof($(rpc.name))}) = $(rpc.request_stream)
            gRPCClient.isstreaming_response(::Type{typeof($(rpc.name))}) = $(rpc.response_stream)
            gRPCClient.request_type(::Type{typeof($(rpc.name))}) = $request_type
            gRPCClient.response_type(::Type{typeof($(rpc.name))}) = $response_type
            gRPCClient.request_type_displayname(::Type{typeof($(rpc.name))}) = "$(request_type)"
            gRPCClient.response_type_displayname(::Type{typeof($(rpc.name))}) = "$(response_type)"
        """)
        println(io, """
            @doc gRPCClient.grpc_generate_rpc_docstring(typeof($(rpc.name))) $(rpc.name)
            export $(rpc.name)

        """)
    end
    println(io, """
    end # module $service_name
    export $service_name
    """)
    return
end

import_cb(io, ctx, definitions) =
    mapreduce(x -> x isa CodeGenerators.ServiceType ? 1 : 0, +, values(definitions)) > 0 &&
    println(io, "import gRPCClient")


grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCClient.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)

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

const UnaryRequestRPC = Union{gRPCUnaryHandle, gRPCStreamResponseHandle}
const StreamingRequestRPC = Union{gRPCStreamRequestHandle, gRPCBidirectionalStreamHandle}
const UnaryResponseRPC = Union{gRPCUnaryHandle, gRPCStreamRequestHandle}
const StreamingResponseRPC = Union{gRPCStreamResponseHandle, gRPCBidirectionalStreamHandle}

"""
    gRPCAsync()

Singleton struct for flagging that a Unary RPC should be called asynchronously.

# Example: 
```
chan = gRPCChannel(host, port)
rpc = MyService.MyRPC(chan, RequestType(...), gRPCAsync())
response = fetch(rpc)
```
"""
struct gRPCAsync end
export gRPCAsync
function rpc_path end
function request_type end
function response_type end
function request_type_displayname end
function response_type_displayname end

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

@inline function _client(chan, Trpc; kws...)
    return gRPCServiceClient{request_type(Trpc), isstreaming_request(Trpc), response_type(Trpc), isstreaming_response(Trpc)}(
        chan.host,
        chan.port,
        rpc_path(Trpc);
        grpc=chan.grpc,
        kws...
    )
end

# Methods to be called from generated code only
# Unary sync
function grpc_call_unary_sync(chan::gRPCChannel, ::Type{Trpc}, req; kws...) where {Trpc <: Function}
    client = _client(chan, Trpc)
    grpc_sync_request(client, req)
end
# Unary async
function grpc_call_unary_async(chan::gRPCChannel, ::Type{Trpc}, req; kws...) where {Trpc <: Function}
    client = _client(chan, Trpc; kws...)
    return gRPCUnaryHandle{Trpc}(
        grpc_async_request(client, req; kws...)
    )
end
# Unary async channel
function grpc_call_unary_async(chan::gRPCChannel, ::Type{Trpc}, req, ch::Channel, index::Integer; kws...) where {Trpc <: Function}
    client = _client(chan, Trpc; kws...)
    grpc_async_request(client, req, ch, index; kws...)
    return nothing
end
# Stream request
function grpc_call_stream_request(chan::gRPCChannel, ::Type{Trpc}; request_channel_size::Int = 16, kws...) where {Trpc <: Function}
    client = _client(chan, Trpc; kws...)
    request_c = Channel{request_type(Trpc)}(request_channel_size)
    return gRPCStreamRequestHandle{Trpc, request_type(Trpc)}(
        grpc_async_request(client, request_c; kws...), 
        request_c
    )
end
# Stream response
function grpc_call_stream_response(chan::gRPCChannel, ::Type{Trpc}, req; response_channel_size::Int = 16, kws...) where {Trpc <: Function}
    client = _client(chan, Trpc; kws...)
    response_c = Channel{response_type(Trpc)}(response_channel_size)
    return gRPCStreamResponseHandle{Trpc, response_type(Trpc)}(
        grpc_async_request(client, req, response_c; kws...), 
        response_c
    )
end
# Bidirectional
function grpc_call_bidirectional_stream(chan::gRPCChannel, ::Type{Trpc}; response_channel_size::Int = 16, request_channel_size::Int = 16, kws...) where {Trpc <: Function}
    client = _client(chan, Trpc; kws...)
    request_c = Channel{request_type(Trpc)}(request_channel_size)
    response_c = Channel{response_type(Trpc)}(response_channel_size)
    return gRPCBidirectionalStreamHandle{Trpc, request_type(Trpc), response_type(Trpc)}(
        grpc_async_request(client, request_c, response_c; kws...), 
        request_c, 
        response_c
    )
end

function grpc_generate_rpc_docstring(Trpc::DataType)
    # request_type_displayed & response_type_displayed should be the name of the 
    # types with namespaces as it is printed where the function is defined. 
    request_type_displayed = request_type_displayname(Trpc)
    response_type_displayed = response_type_displayname(Trpc)

    if !isstreaming_request(Trpc) && !isstreaming_response(Trpc)
        return _docstring_unary(Trpc, request_type_displayed, response_type_displayed)
    elseif isstreaming_request(Trpc) && !isstreaming_response(Trpc)
        return _docstring_clientstream(Trpc, request_type_displayed, response_type_displayed)
    elseif !isstreaming_request(Trpc) && isstreaming_response(Trpc)
        return _docstring_serverstream(Trpc, request_type_displayed, response_type_displayed)
    else # bidirectional
        return _docstring_bidirectional(Trpc, request_type_displayed, response_type_displayed)
    end
end

function _docstring_unary(@nospecialize(Trpc), request_type_displayed, response_type_displayed)
    fname = "$(nameof(parentmodule(Trpc.instance))).$(nameof(Trpc.instance))"
    Treq = request_type(Trpc)
    return """
        $fname(chan::gRPCChannel, req::$(Treq))

    Auto-generated remote procedure call (RPC) for use with `gRPCCLient.jl`. 
    
    # Signature

    |                | Unary/stream  | Type  | 
    |---------------|-------------|------|
    | Request  | unary | $request_type_displayed |
    | Response | unary | $response_type_displayed |

    # Examples
    #### Synchronous call
    ```julia
    using gRPCClient
    
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Request message
    msg = $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    
    # Call and return the response
    response = $fname(chan, msg)
    ```
    
    #### Asynchronous call
    ```julia
    using gRPCClient
    
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Request message
    msg = $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    
    # Initiate call
    rpc = $fname(chan, msg, gRPCAsync())

    # Wait for a response to become available, return it, clean up resources. 
    response = fetch(rpc)
    ```

    #### Out-of-order asynchronous
    Perform multiple calls and read responses in the order in which they arrive. 
    ```
    using gRPCClient
    
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Set up channel for collecting responses
    response_ch = Channel{gRPCAsyncChannelResponse{$(response_type_displayed)}}(16)

    # Request message
    msg = $(request_type_displayed)($(join(fieldnames(Treq), ", ")))

    index = 1
    rpc = $fname(chan, msg, ch, index)
    index = 2
    rpc = $fname(chan, msg, ch, index)

    # Responses should now be stored in `response_ch` in the order of arrival
    resp = take!(response_ch) 
    resp.data # Response
    resp.index # The associated index

    # Cleanup
    close(rpc)
    ```

    See also [`isfull`](@ref), [`isopen`](@ref), [`wait`](@ref), [`isready`](@ref) and [`detach`](@ref).
    """
end

function _docstring_clientstream(@nospecialize(Trpc), request_type_displayed, response_type_displayed)
    fname = "$(nameof(parentmodule(Trpc.instance))).$(nameof(Trpc.instance))"
    Treq = request_type(Trpc)
    return """
        $fname(chan::gRPCChannel, req::$(Treq))

    Auto-generated remote procedure call (RPC) for use with `gRPCCLient.jl`. 

    # Signature
    
    |                | Unary/stream  | Type  | 
    |---------------|-------------|------|
    | Request  | stream | $request_type_displayed |
    | Response | unary | $response_type_displayed |

    # Example
    ```julia
    using gRPCClient
    
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Initiate call
    rpc = $fname(chan)

    # Stream data
    put!(rpc, $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    put!(rpc, $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    put!(rpc, done = true) # optional, signals to server that the request stream is closed. 
    
    # Wait for a response to become available, return it, clean up resources. 
    response = fetch(rpc)
    ```

    See also [`isfull`](@ref), [`isopen`](@ref), [`wait`](@ref), [`isready`](@ref), [`close`](@ref) and [`detach`](@ref).
    """
end

function _docstring_serverstream(@nospecialize(Trpc), request_type_displayed, response_type_displayed)
    fname = "$(nameof(parentmodule(Trpc.instance))).$(nameof(Trpc.instance))"
    Treq = request_type(Trpc)
    return """
        $fname(chan::gRPCChannel, req::$(Treq))

     # Signature
    
    |                | Unary/stream  | Type  | 
    |---------------|-------------|------|
    | Request  | unary | $request_type_displayed |
    | Response | stream | $response_type_displayed |

    # Example

    ```
    using gRPCClient
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Request message
    msg = $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    
    # Initiate call
    rpc = $fname(chan, msg)

    # Receive responses
    resp1 = take!(rpc)
    resp2 = take!(rpc)

    # Wait for server to close the call
    close(rpc)
    # or cancel without waiting for the server
    detach(rpc)
    ```
    
    See also [`isfull`](@ref), [`isopen`](@ref), [`wait`](@ref), [`isready`](@ref) and [`fetch`](@ref).
    """
end

function _docstring_bidirectional(@nospecialize(Trpc), request_type_displayed, response_type_displayed)
    fname = "$(nameof(parentmodule(Trpc.instance))).$(nameof(Trpc.instance))"
    Treq = request_type(Trpc)
    return """
        $fname(chan::gRPCChannel, req::$(Treq))

    Auto-generated remote procedure call (RPC) for use with `gRPCCLient.jl`. 

    # Signature
    
    |                | Unary/stream  | Type  | 
    |---------------|-------------|------|
    | Request  | stream | $request_type_displayed |
    | Response | stream | $response_type_displayed |

    # Example

    ```julia
    using gRPCClient
    
    # Set up connection properties (reusable)
    chan = gRPCChannel(host, port)

    # Initiate call
    rpc = $fname(chan)

    # Stream and receive data (in any order)
    put!(rpc, $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    resp1 = take!(rpc)
    put!(rpc, $(request_type_displayed)($(join(fieldnames(Treq), ", ")))
    put!(rpc, done = true) # optional, signals to server that the request stream is closed. 
    resp2 = take!(rpc)
    
    # Wait for server to close the call
    close(rpc)
    # or cancel without waiting for the server
    detach(rpc)
    ```

    See also [`isfull`](@ref), [`isopen`](@ref), [`wait`](@ref), [`isready`](@ref) and [`fetch`](@ref).
    """
end