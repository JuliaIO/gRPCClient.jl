const _grpc = gRPCCURL(running = false)

"""
    grpc_global_handle()

Returns the global `gRPCCURL` state which contains a libCURL multi handle. By default all gRPC clients use this multi in order to ensure that HTTP/2 multiplexing happens where possible.
"""
grpc_global_handle() = _grpc

"""
    grpc_init([grpc_curl::gRPCCURL])

Initializes the `gRPCCURL` object. This should be called once before making gRPC calls. There is no harm in calling this more than once (ie by different packages/dependencies). Typical usage looks like this:

```julia
grpc_init()

client = TestService_TestRPC_Client("172.238.177.88", 8001)

# Make some gRPC calls 

# Shut down the global gRPC handle
grpc_shutdown()
```

Unless specifying a `gRPCCURL` the global one provided by `grpc_global_handle()` is used. Each `gRPCCURL` state has its own connection pool and request semaphore, so sometimes you may want to manage your own like shown below:

```julia 
grpc_myapp = gRPCCURL()
grpc_init(grpc_myapp)

client = TestService_TestRPC_Client("172.238.177.88", 8001; grpc=grpc_myapp)

# Make some gRPC calls 

# Only shuts down your gRPC handle
grpc_shutdown(grpc_myapp)
```
"""
grpc_init() = open(grpc_global_handle())
grpc_init(grpc_curl::gRPCCURL) = open(grpc_curl)

"""
    grpc_shutdown([grpc_curl::gRPCCURL])

Shuts down the `gRPCCURL`. This neatly cleans up all active connections and requests. Useful for calling during development with Revise. Unless specifying the `gRPCCURL`, the global one provided by `grpc_global_handle()` is shutdown.
"""
grpc_shutdown() = close(grpc_global_handle())
grpc_shutdown(grpc_curl::gRPCCURL) = close(grpc_curl)


struct gRPCServiceClient{TRequest,SRequest,TResponse,SResponse}
    grpc::gRPCCURL
    host::String
    port::Int64
    path::String
    secure::Bool
    deadline::Float64
    keepalive::Float64
    max_send_message_length::Int64
    max_recieve_message_length::Int64

    function gRPCServiceClient{TRequest,SRequest,TResponse,SResponse}(
        host,
        port,
        path;
        secure = false,
        grpc = grpc_global_handle(),
        deadline = 10,
        keepalive = 60,
        max_send_message_length = 4 * 1024 * 1024,
        max_recieve_message_length = 4 * 1024 * 1024,
    ) where {TRequest<:Any,SRequest,TResponse<:Any,SResponse}
        new(
            grpc,
            host,
            port,
            path,
            secure,
            deadline,
            keepalive,
            max_send_message_length,
            max_recieve_message_length,
        )
    end

end

function url(client::gRPCServiceClient)
    protocol = if client.secure
        "https"
    else
        "http"
    end

    # "$protocol://$(client.host):$(client.port)$(client.path)"
    buffer = IOBuffer()
    write(buffer, protocol, "://", client.host, ":", string(client.port), client.path)
    String(take!(buffer))
end


function grpc_encode_request_iobuffer(
    request,
    req_buf::IOBuffer;
    max_send_message_length = 4 * 1024 * 1024,
)
    start_pos = position(req_buf)

    # Write compressed flag and length prefix
    write(req_buf, UInt8(0))
    write(req_buf, UInt32(0))

    # Serialize the protobuf
    e = ProtoEncoder(req_buf)
    sz = UInt32(encode(e, request))

    end_pos = position(req_buf)

    if req_buf.size - GRPC_HEADER_SIZE > max_send_message_length
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "request message larger than max_send_message_length: $(req_buf.size - GRPC_HEADER_SIZE) > $max_send_message_length",
            ),
        )
    end

    # Seek back to length prefix and update it with size of encoded protobuf
    seek(req_buf, start_pos + 1)
    write(req_buf, hton(sz))

    # Seek back to the end 
    seek(req_buf, end_pos)

    req_buf
end


grpc_encode_request_iobuffer(request; max_send_message_length = 4 * 1024 * 1024) =
    grpc_encode_request_iobuffer(
        request,
        IOBuffer();
        max_send_message_length = max_send_message_length,
    )


function grpc_async_await(req::gRPCRequest)
    # Wait for request to be done
    wait(req)

    # Throw an exception for this request if we have one
    !isnothing(req.ex) && throw(req.ex)

    req.grpc_status != GRPC_OK &&
        throw(gRPCServiceCallException(req.grpc_status, req.grpc_message))

    req.code == CURLE_OPERATION_TIMEDOUT &&
        throw(gRPCServiceCallException(GRPC_DEADLINE_EXCEEDED, "Deadline exceeded."))
    req.code != CURLE_OK &&
        throw(gRPCServiceCallException(GRPC_INTERNAL, nullstring(req.errbuf)))
end


function grpc_async_await(req::gRPCRequest, TResponse)
    grpc_async_await(req)
    return decode(ProtoDecoder(req.response), TResponse)
end
