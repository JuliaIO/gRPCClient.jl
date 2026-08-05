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