```@meta
CurrentModule = gRPCClient
```

# RPC API

Once the stubs are generated, each service becomes a `baremodule` and each RPC an exported function inside it. A call is made by handing the RPC either a [`gRPCChannel`](@ref) — reusable, and carrying the connection defaults — or a bare `host, port` pair, together with the request message wherever the request side is unary:

```julia
chan = gRPCChannel("localhost", 8001)
response = TestService.TestRPC(chan, TestRequest(...))
```

How the call is driven depends on the RPC's shape:

- **Unary, synchronous** — `TestService.TestRPC(chan, req)` blocks and returns the decoded response, throwing on error. This is the only form that returns the response directly rather than a call handle.
- **Unary, asynchronous** — passing [`gRPCAsync`](@ref)`()` as an extra argument returns a `gRPCUnaryCall` handle immediately, and the response is retrieved later with [`fetch`](@ref). Passing a `Channel{gRPCAsyncChannelResponse}` and an index instead collects many in-flight responses in the order they arrive.
- **Client streaming** — `TestService.TestClientStreamRPC(chan)` returns a `gRPCClientStreamCall`; stream requests with [`put!`](@ref), then [`fetch`](@ref) the single response (which also closes the request stream).
- **Server streaming** — `TestService.TestServerStreamRPC(chan, req)` returns a `gRPCServerStreamCall`; consume responses by iterating the call (`for resp in rpc`) or with [`take!`](@ref), then [`close`](@ref) it (or [`detach`](@ref) to cancel without waiting for the server).
- **Bidirectional** — `TestService.TestBidirectionalStreamRPC(chan)` returns a `gRPCBidirectionalStreamCall`; interleave [`put!`](@ref) and [`take!`](@ref) freely, then [`close`](@ref) or [`detach`](@ref).

Every form except the synchronous unary call returns an `AbstractgRPCCall` handle. The operations these handles support, and which handle types accept them, are listed under [Call initialization](#Call-initialization). Connection [options](setup-api.md#gRPCChannel) such as `deadline`, `secure`, and `token` may be set once on the channel and overridden on any individual call.

## Auto-generated RPC docstrings

Every generated RPC method carries its own docstring, produced by the code generator, documenting the method's exact call signatures, its request and response types, the connection options, and copy-pasteable examples tailored to that RPC's shape (unary, client-streaming, server-streaming, or bidirectional). View it at the REPL with `?`, for example `?TestService.TestRPC`, once the stubs are loaded. These per-RPC docstrings are the most direct reference for the exact call syntax of a given service, complementing the generic handle operations documented below.

## Call initialization

The table below lists the operations available on a call handle and which of the four call shapes each one applies to. "Async unary" is a unary call started with [`gRPCAsync`](@ref)`()`; a synchronous unary call returns its response directly and exposes none of these handle operations.

| Description                                | Name                                 | Throws         | Async unary | Client stream   | Server stream   | Bidirectional         |
| ------------------------------------------ | ------------------------------------ | ------------------------------------ |:-----------:|:---------------:|:---------------:|:---------------------:|
| Create a call                              | `<service.rpc>`                      | On submission (sync unary: also on failure) |     ✓       |       ✓         |       ✓         |          ✓            |
| Check if ready for a request               | `Base.isfull` (Julia 1.12 or later)  | Never                                |             |       ✓         |                 |          ✓            |
| Send request                               | `put!(rpc, msg)`                     | If the call has ended                |             |       ✓         |                 |          ✓            |
| Signal done with requests                  | `Base.put!(rpc[, msg], done = true)` | Only when sending `msg`              |             |       ✓         |                 |          ✓            |
| Check if response is available             | `Base.isready`                       | Never                                |     ✓       |       ✓         |       ✓         |          ✓            |
| Wait for response or end of stream         | `Base.wait`                          | On failure                           |     ✓       |       ✓         |       ✓         |          ✓            |
| Take response                              | `Base.take!`                         | When ended and drained               |             |                 |       ✓         |          ✓            |
| Read response without removing it          | `Base.fetch`                         | On failure (streaming: when ended and drained) |     ✓       |       ✓         |       ✓         |          ✓            |
| Iterate responses                          | `for x in rpc`                       | On failure                           |             |                 |       ✓         |          ✓            |
| Check if rpc is still active               | `Base.isopen`                        | Never                                |     ✓       |       ✓         |       ✓         |          ✓            |
| Wait for server shutdown and report errors | `Base.close`                         | On failure                           |     ✓       |       ✓         |       ✓         |          ✓            |
| Gracefully cancel                          | `Base.detach`                        | On failure                           |     ✓       |       ✓         |       ✓         |          ✓            |

For unary responses (async unary and client streaming) `fetch` retrieves the single response and cleans up; for streaming responses (server streaming and bidirectional) `take!` removes the next response and `fetch` returns it without removing it. Streaming responses are buffered, so any responses still queued are delivered first — the call's error, or a normal end of stream, is only raised once no responses remain.

```@docs
Base.isopen(rpc::AbstractgRPCCall)
Base.put!(rpc::StreamingRequestRPC; done::Bool)
Base.fetch(rpc::UnaryResponseRPC)
Base.wait(rpc::UnaryResponseRPC)
Base.wait(rpc::StreamingResponseRPC)
Base.isready(rpc::UnaryResponseRPC)
Base.isready(rpc::StreamingResponseRPC)
Base.take!(rpc::StreamingResponseRPC)
Base.fetch(rpc::StreamingResponseRPC)
Base.iterate(rpc::StreamingResponseRPC)
Base.close(rpc::AbstractgRPCCall)
Base.detach(rpc::AbstractgRPCCall; throws::Bool = true)
gRPCAsync
```
## Lifecycles
### Unary

A synchronous unary call blocks and returns the decoded response directly, raising on error:

```julia
chan = gRPCChannel("localhost", 8001)

response = TestService.TestRPC(chan, TestRequest(1, [1]))
```

Passing [`gRPCAsync`](@ref)`()` instead starts the call without blocking and returns a handle; [`fetch`](@ref) waits for the response (raising on error) and releases the call's resources:

```julia
rpc = TestService.TestRPC(chan, TestRequest(1, [1]), gRPCAsync())
# ... do other work while the call is in flight ...
response = fetch(rpc)
```

### Client streaming

The call is opened without a request message. Stream request messages with [`put!`](@ref), then [`fetch`](@ref) the single response; `fetch` closes the request stream for you, so an explicit `put!(rpc; done = true)` is only needed if you want to finish sending before fetching:

```julia
chan = gRPCChannel("localhost", 8001)

rpc = TestService.TestClientStreamRPC(chan)
for i in 1:4
    put!(rpc, TestRequest(1, [i]))
end
response = fetch(rpc)
```

### Server streaming

The request message is supplied when opening the call. Pull responses with [`take!`](@ref) as they arrive, then [`close`](@ref) the call to wait for the server to finish and surface any error ([`detach`](@ref) instead cancels without waiting). This example's server sends one response per requested element:

```julia
chan = gRPCChannel("localhost", 8001)

rpc = TestService.TestServerStreamRPC(chan, TestRequest(4, [1]))
for _ in 1:4
    response = take!(rpc)
end
close(rpc)
```

Taking a known number of responses is a safe pattern: [`take!`](@ref) blocks until each one arrives, so every response is received and the call never reads past the end.

When the number of responses is not known ahead of time, use iteration:

```julia
rpc = TestService.TestServerStreamRPC(chan, TestRequest(4, [1]))
for response in rpc
    # process response
end
```

Alternatively, use a combination of [`wait`](@ref) and [`isready`](@ref):

```julia
while true
    wait(rpc)
    isready(rpc) || break
    raw = take!(rpc)
    # handle raw
end
```

### Bidirectional streaming

Requests and responses are independent, so [`put!`](@ref) and [`take!`](@ref) may be interleaved in any order. Signal the end of the request stream with `done = true` (or a bare `put!(rpc; done = true)`), and [`close`](@ref) the call when finished:

```julia
chan = gRPCChannel("localhost", 8001)

rpc = TestService.TestBidirectionalStreamRPC(chan)
put!(rpc, TestRequest(1, [1]))
response = take!(rpc)
put!(rpc, TestRequest(1, [2]); done = true)
response = take!(rpc)
close(rpc)
```
