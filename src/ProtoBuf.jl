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
            # methods with `async` keyword should be inlined to guarantee type stability
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type; kws...)
                    gRPCClient.grpc_call_unary_sync(chan, typeof($(rpc.name)), req; kws...)::$response_type
                end
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type, ::gRPCClient.gRPCAsync; kws...) 
                    gRPCClient.grpc_call_unary_async(chan, typeof($(rpc.name)), req; kws...)::gRPCClient.gRPCUnaryHandle{typeof($(rpc.name))}
                end
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type, response_ch::Channel{gRPCClient.gRPCAsyncChannelResponse{$response_type}}, index::Integer; kws...)::Nothing
                    gRPCClient.grpc_call_unary_async(chan, typeof($(rpc.name)), req, response_ch, index; kws...)
                end
                function $(rpc.name)(host::AbstractString, port::Integer, req::$request_type, args...; kws...)
                    $(rpc.name)(gRPCChannel(host, port), req::$request_type, args...; kws...)
                end
            """)
        elseif rpc.request_stream && !rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel; kws...)
                    gRPCClient.grpc_call_stream_request(chan, typeof($(rpc.name)); kws...)::gRPCClient.gRPCStreamRequestHandle{typeof($(rpc.name)), $request_type}
                end
                function $(rpc.name)(host::AbstractString, port::Integer; kws...)
                    $(rpc.name)(gRPCChannel(host, port); kws...)
                end
            """)
        elseif !rpc.request_stream && rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel, req::$request_type; kws...)
                    gRPCClient.grpc_call_stream_response(chan, typeof($(rpc.name)), req; kws...)::gRPCClient.gRPCStreamResponseHandle{typeof($(rpc.name)), $response_type}
                end
                function $(rpc.name)(host::AbstractString, port::Integer, req::$request_type; kws...)
                    $(rpc.name)(gRPCChannel(host, port), req; kws...)
                end
            """)
        elseif rpc.request_stream && rpc.response_stream
            print(io, """
                function $(rpc.name)(chan::gRPCClient.gRPCChannel; kws...)
                    gRPCClient.grpc_call_bidirectional_stream(chan, typeof($(rpc.name)); kws...)::gRPCClient.gRPCBidirectionalStreamHandle{typeof($(rpc.name)), $request_type, $response_type}
                end
                function $(rpc.name)(host::AbstractString, port::Integer; kws...)
                    $(rpc.name)(gRPCChannel(host, port); kws...)
                end
            """)
        end
        println(io, """
            @doc gRPCClient.grpc_generate_rpc_docstring($(rpc.name)) $(rpc.name)
            gRPCClient.rpc_path(::Type{typeof($(rpc.name))}) = "/$namespace.$service_name/$(rpc.name)"
            gRPCClient.isstreaming_request(::Type{typeof($(rpc.name))}) = $(rpc.request_stream)
            gRPCClient.isstreaming_response(::Type{typeof($(rpc.name))}) = $(rpc.response_stream)
            gRPCClient.request_type(::Type{typeof($(rpc.name))}) = $request_type
            gRPCClient.response_type(::Type{typeof($(rpc.name))}) = $response_type
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

struct gRPCChannel
    host::String
    port::Int
    grpc::gRPCCURL
    function gRPCChannel(host::AbstractString, port::Integer; grpc = grpc_global_handle())
        new(host, port, grpc)
    end
end

abstract type gRPCCallHandle{Trpc} end
isstreaming_request(::gRPCCallHandle{Trpc}) where Trpc = isstreaming_request(Trpc)
isstreaming_response(::gRPCCallHandle{Trpc}) where Trpc = isstreaming_response(Trpc)
request_type(::gRPCCallHandle{Trpc}) where Trpc = request_type(Trpc)
response_type(::gRPCCallHandle{Trpc}) where Trpc = response_type(Trpc)

struct gRPCUnaryHandle{Trpc} <: gRPCCallHandle{Trpc}
    call::gRPCRequest
end
struct gRPCStreamRequestHandle{Trpc, TRequest} <: gRPCCallHandle{Trpc}
    call::gRPCRequest
    request_stream::Channel{TRequest}
end
struct gRPCStreamResponseHandle{Trpc, TResponse} <: gRPCCallHandle{Trpc}
    call::gRPCRequest
    response_stream::Channel{TResponse}
end
struct gRPCBidirectionalStreamHandle{Trpc, TRequest, TResponse} <: gRPCCallHandle{Trpc}
    call::gRPCRequest
    request_stream::Channel{TRequest}
    response_stream::Channel{TResponse}
end

"""
Throws any error found during the call. Returns the result for 
RPCs with unary responses. 
"""
function Base.close(h::gRPCCallHandle)
    if isstreaming_request(h)
        close(h.request_stream)
    end
    if isstreaming_response(h)
        grpc_async_await(h.call)
    else
        grpc_async_await(h.call, response_type(h))
    end
end
Base.kill(h::gRPCCallHandle) = grpc_cancel(h.call)# TODO: also close channels

# Streaming request
Base.put!(h::gRPCStreamRequestHandle, msg) = put!(h.request_stream, msg)
Base.isfull(h::gRPCStreamRequestHandle) = isfull(h.request_stream)

# Streaming response: 
Base.take!(h::gRPCStreamResponseHandle) = take!(h.response_stream)
Base.wait(h::gRPCStreamResponseHandle) = wait(h.response_stream)
Base.fetch(h::gRPCStreamResponseHandle) = fetch(h.response_stream)
Base.isready(h::gRPCStreamResponseHandle) = isready(h.response_stream)
Base.iterate(h::gRPCStreamResponseHandle) = iterate(h.response_stream)
Base.iterate(h::gRPCStreamResponseHandle, state) = iterate(h.response_stream, state)
IteratorSize(::Type{<:gRPCStreamResponseHandle}) = SizeUnknown()

# Bidirectional stream (put! and isfull operate on request, the rest on response)
Base.put!(h::gRPCBidirectionalStreamHandle, msg) = put!(h.request_stream, msg)
Base.isfull(h::gRPCBidirectionalStreamHandle) = isfull(h.request_stream)
Base.take!(h::gRPCBidirectionalStreamHandle) = take!(h.response_stream)
Base.wait(h::gRPCBidirectionalStreamHandle) = wait(h.response_stream)
Base.fetch(h::gRPCBidirectionalStreamHandle) = fetch(h.response_stream)
Base.isready(h::gRPCBidirectionalStreamHandle) = isready(h.response_stream)
Base.iterate(h::gRPCBidirectionalStreamHandle) = iterate(h.response_stream)
Base.iterate(h::gRPCBidirectionalStreamHandle, state) = iterate(h.response_stream, state)
IteratorSize(::Type{<:gRPCBidirectionalStreamHandle}) = SizeUnknown()

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

struct gRPCAsync end
export gRPCAsync
function rpc_path end
function request_type end
function response_type end
@inline rpc_path(f::Function) = rpc_path(typeof(f))
@inline isstreaming_request(f::Function) = isstreaming_request(typeof(f))
@inline isstreaming_response(f::Function) = isstreaming_response(typeof(f))
@inline request_type(f::Function) = request_type(typeof(f))
@inline response_type(f::Function) = response_type(typeof(f))

function grpc_generate_rpc_docstring(rpc::Function)
    return "This is the docstring for $(nameof(rpc))"
end