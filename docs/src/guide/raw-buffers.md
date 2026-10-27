```@meta
CurrentModule = gRPCClient
```

# Raw Encoded Buffers (Partial Decoding)

By default a request message is protobuf-encoded before it is sent and the response is decoded before it is returned. Either side can instead be left as a raw, already-encoded protobuf payload — a `Vector{UInt8}` holding just the message body, with the 5-byte gRPC framing still added and stripped for you. This is useful for forwarding bytes you already hold, or for partially decoding a large response and reading only the fields you need.

On the request side, pass a `Vector{UInt8}` in place of the typed message, whether as the call argument or to [`put!`](@ref):

```julia
using ProtoBuf

chan = gRPCChannel("localhost", 8001)

io = IOBuffer(); encode(ProtoEncoder(io), TestRequest(10, UInt64[]))
raw_request = take!(io)

response = TestService.TestRPC(chan, raw_request)   # typed response
```

On the response side, request raw bytes by passing `Vector{UInt8}` as an extra argument to the call, or to [`fetch`](@ref) / [`take!`](@ref):

```julia
# Unary: receive the response undecoded
raw = TestService.TestRPC(chan, TestRequest(10, UInt64[]), Vector{UInt8})
response = decode(ProtoDecoder(IOBuffer(raw)), TestResponse)

# Server streaming: take each response as raw bytes (this request asks for 10)
rpc = TestService.TestServerStreamRPC(chan, TestRequest(10, UInt64[]))
for _ in 1:10
    raw = take!(rpc, Vector{UInt8})
    # decode(ProtoDecoder(IOBuffer(raw)), TestResponse)
end
```

The two sides are independent, so either or both may be raw. The same mechanism is covered in more depth for the [legacy API](../legacy.md#Raw-Encoded-Buffers-(Partial-Decoding)).
