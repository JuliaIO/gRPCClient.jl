# Raw encoded buffers and partial decoding

By default the client protobuf-encodes a typed request and decodes the response into a typed message. Declaring a message type parameter as `Vector{UInt8}` bypasses that step for that side and moves the raw protobuf payload through instead. Two reasons to want it: forwarding bytes already held, for example a proxy or a cache, and reading only a few fields out of a large response.

A generated message type is always a struct, so `Vector{UInt8}` is unambiguous as a raw-buffer marker. The buffer is the serialized protobuf message body only; the 5-byte gRPC frame is still added and stripped by the library. Message size limits still apply and are measured on the payload excluding that frame.

## Choosing the raw side

Every generated constructor takes `TRequest` and `TResponse` keywords defaulting to the proto types. The two sides are independent.

```julia
using ProtoBuf

# Both sides raw
io = IOBuffer()
encode(ProtoEncoder(io), MyRequest(42, UInt64[]))
raw_request = take!(io)

client = MyService_MyRPC_Client("localhost", 50051;
    TRequest = Vector{UInt8}, TResponse = Vector{UInt8})
raw_response = grpc_sync_request(client, raw_request)          # ::Vector{UInt8}
response = decode(ProtoDecoder(IOBuffer(raw_response)), MyResponse)

# Typed request, raw response
client = MyService_MyRPC_Client("localhost", 50051; TResponse = Vector{UInt8})
raw_response = grpc_sync_request(client, MyRequest(42, UInt64[]))
```

With `TRequest = Vector{UInt8}` the argument passed to `grpc_async_request` must be a byte vector; with the default it must be the proto type. The client's type parameter is what dispatch selects on, so a mismatch is a `MethodError` at the call site rather than a runtime decode failure.

## Streaming

Override the streaming side and use a channel of byte vectors:

```julia
client = MyService_MyServerStreamRPC_Client("localhost", 50051; TResponse = Vector{UInt8})
response_c = Channel{Vector{UInt8}}(16)
req = grpc_async_request(client, MyRequest(10, UInt64[]), response_c)
for raw in response_c
    response = decode(ProtoDecoder(IOBuffer(raw)), MyResponse)
end
grpc_async_await(req)
```

Each channel element is one complete message payload, so framing never has to be reassembled by hand.

## Without a generated stub

```julia
gRPCClient.gRPCServiceClient{Vector{UInt8}, false, Vector{UInt8}, false}(
    "localhost", 50051, "/foo.MyService/MyRPC",
)
```

This is the usual approach for calling a service whose `.proto` is unavailable, given the RPC path and a way to build the payload bytes.

## Not to be confused with

A proto `bytes` field also maps to `Vector{UInt8}`, but that is a field inside a normal generated struct and is entirely unaffected by this feature. Raw buffers apply only to the whole-message type parameters `TRequest` and `TResponse`.
