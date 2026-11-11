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

A raw response shares the received message's memory rather than copying it (on Julia 1.11 and later). `fetch` does not consume the response, so an asynchronous call can be fetched again, raw or decoded, and every raw fetch returns the same bytes. Modifying them therefore changes what later fetches of the call return; `copy` them first if you need to change them and fetch again. On a response stream, `take!(rpc, Vector{UInt8})` removes the response and hands its buffer over.

## Sending a raw request without a copy

A raw request is normally copied into the call's upload buffer behind the 5-byte gRPC frame. For a unary call, `borrow_request = true` sends it from your vector instead, without a copy, which matters when the messages are large, for example in a proxy that forwards raw messages:

```julia
response = TestService.TestRPC(chan, raw_request; borrow_request = true)

rpc = TestService.TestRPC(chan, raw_request, gRPCAsync(); borrow_request = true)
response = fetch(rpc)   # the borrow ends here
```

The vector is borrowed from the request call until the call completes, that is until `fetch`, `wait` or `grpc_async_await` on it has returned. Until then it must not be written, resized or emptied. Reading it, and sending it in other borrowed calls at the same time, are fine. A caller that never awaits the call must treat the vector as lent indefinitely. A synchronous call returns only once it has completed, so it always satisfies this.

Borrowing is opt-in because it is a loan, not a transfer: the response side can hand a buffer over because nothing else holds it, but a request vector belongs to the caller, and a caller that reuses its buffer after an asynchronous submit would otherwise send corrupted messages without any error. `borrow_request` is accepted only by a unary call with a raw `Vector{UInt8}` request, synchronous or with `gRPCAsync()`; a typed request, a streaming call, and the form that delivers the response to a `Channel` reject it with an `ArgumentError`.

The two sides are independent, so either or both may be raw. The same mechanism is covered in more depth for the [legacy API](../legacy.md#Raw-Encoded-Buffers-(Partial-Decoding)).
