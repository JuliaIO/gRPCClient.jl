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

end

import_cb(io, ctx, definitions) =
    mapreduce(x -> x isa CodeGenerators.ServiceType ? 1 : 0, +, values(definitions)) > 0 &&
    println(io, "import gRPCClient")


grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCClient.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)
