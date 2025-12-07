function service_cb(io, t::CodeGenerators.ServiceType, ctx::CodeGenerators.Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name


    for (i, rpc) in enumerate(t.rpcs)
        rpc_path = "/$namespace.$service_name/$(rpc.name)"

        request_type = rpc.request_type.name
        response_type = rpc.response_type.name

        if rpc.request_type.package_namespace !== nothing
            request_type = join([rpc.package_namespace, request_type], ".")
        end
        if rpc.response_type.package_namespace !== nothing
            response_type = join([rpc.package_namespace, response_type], ".")
        end

        println(io, "$(service_name)_$(rpc.name)_Client(")
        println(io, "\thost, port;")
        println(io, "\tsecure=false,")
        println(io, "\tgrpc=gRPCClient.grpc_global_handle(),")
        println(io, "\tdeadline=10,")
        println(io, "\tkeepalive=60,")
        println(io, "\tmax_send_message_length = 4*1024*1024,")
        println(io, "\tmax_recieve_message_length = 4*1024*1024,")
        println(
            io,
            ") = gRPCClient.gRPCServiceClient{$request_type, $(rpc.request_stream), $response_type, $(rpc.response_stream)}(",
        )
        println(io, "\thost, port, \"$rpc_path\";")
        println(io, "\tsecure=secure,")
        println(io, "\tgrpc=grpc,")
        println(io, "\tdeadline=deadline,")
        println(io, "\tkeepalive=keepalive,")
        println(io, "\tmax_send_message_length=max_send_message_length,")
        println(io, "\tmax_recieve_message_length=max_recieve_message_length,")
        println(io, i < length(t.rpcs) ? ")\n" : ")")
    end
end

import_cb(io, ctx) = println(io, "import gRPCClient")

grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCClient.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)
