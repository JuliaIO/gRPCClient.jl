# Streaming RPC

Two APIs are available: the current one drives streaming through the call handle returned by the RPC, the legacy one through user-supplied `Channel`s.

## Current API

Streaming calls return a call handle (`gRPCClientStreamCall`, `gRPCServerStreamCall`, or `gRPCBidirectionalStreamCall`) instead of a response. You send with `put!`, receive with `take!` or iteration, and finish with `fetch` (client streaming) or `close` / `detach`.

### Client streaming, many requests to one response

```julia
rpc = MyService.MyClientStreamRPC(chan)

for i in 1:100
    put!(rpc, MyRequest(i, UInt64[]))
end

response = fetch(rpc)     # ends the request stream and returns the single response
```

`fetch` closes the request stream for you, so an explicit `put!(rpc; done = true)` is only needed to finish sending before you are ready to fetch. `isfull(rpc)` (Julia 1.12 or later) reports whether the next `put!` will block.

### Server streaming, one request to many responses

The request is supplied when opening the call. Then choose a drain pattern (see below), and `close` when done to wait for the server and surface any error.

```julia
rpc = MyService.MyServerStreamRPC(chan, MyRequest(10, UInt64[]))

# Unknown length: iterate
for response in rpc
    handle(response)
end

# Or a known count: each take! blocks until its response arrives
for _ in 1:10
    handle(take!(rpc))
end
close(rpc)
```

### Bidirectional streaming

Requests and responses are independent, so `put!` and `take!` interleave in any order. End the request stream with `done = true`.

```julia
rpc = MyService.MyBidiRPC(chan)

put!(rpc, MyRequest(1, UInt64[]))
response = take!(rpc)
put!(rpc, MyRequest(2, UInt64[]); done = true)   # last request
response = take!(rpc)
close(rpc)
```

Driving both directions from one task deadlocks as soon as the server's flow control makes one side wait on the other. For anything beyond a bounded exchange, run send and receive from separate tasks.

### Draining a response stream safely

Use one of three patterns:

```julia
# 1. Iterate — the race-free default for unknown length
for response in rpc
    handle(response)
end

# 2. Take a known number — each take! blocks until its response arrives
for _ in 1:n
    handle(take!(rpc))
end

# 3. wait then isready — the manual form of iteration
while true
    wait(rpc)               # blocks until a response is ready or the stream ends
    isready(rpc) || break   # nothing ready after wait returned => stream ended
    handle(take!(rpc))
end
```

Do not guard the loop with `isopen(rpc)` or `isready(rpc)`: neither answers "will more responses arrive?", so such a loop drops the tail or stops early.

### take!, fetch, and wait semantics

- **`take!` removes; `fetch` does not.** `fetch` returns the next buffered response without consuming it, so repeated `fetch` returns the same value. Use `take!` to advance.
- **Errors are deferred until the buffer drains.** Responses are buffered, so `take!`/`fetch` keep returning them even after the call has failed. Only once no responses remain does `take!`/`fetch` throw — the call's real error, or a `GRPC_OK` "no more responses are available" if it ended cleanly. So reading past the end always throws; stop when iteration ends or a known count is reached.
- **`wait(rpc)` returns at a clean end and throws on failure.** It blocks until a response is ready or the stream ends, then returns in both cases (a failed call re-raises here). Check `isready(rpc)` after: `true` = a response to `take!`, `false` = the stream ended.
- Add `Vector{UInt8}` to receive undecoded bytes: `take!(rpc, Vector{UInt8})`, `fetch(rpc, Vector{UInt8})`. See `raw-buffers.md`.

### Finishing and cancelling

- **`close(rpc)`** waits for the server to shut the call down and raises any error. It closes the request stream first for a client/bidi call. It can block indefinitely if the server never ends the call — use `detach` then.
- **`detach(rpc; throws = true)`** cancels immediately, frees resources, and by default re-raises any recorded exception (`throws = false` suppresses). The stored exception becomes `CANCELLED`, thrown by later `detach`/`close`.
- **End the request stream** on client/bidi calls, or the server keeps waiting: `put!(rpc; done = true)` (bidi/client), or just `fetch(rpc)` (client streaming closes it for you).

### Long-lived streams

Combine `deadline = Inf` with explicit `detach` when the lifetime is yours to manage, since the default 10 second deadline otherwise kills the stream:

```julia
rpc = MyService.MyBidiRPC(gRPCChannel("localhost", 50051; deadline = Inf))
# ... use the stream ...
detach(rpc)          # cancels and frees; there is no watchdog under deadline = Inf
```

An abandoned `Inf` call is not cleaned up by garbage collection — cancelling it is the caller's responsibility. See `deadlines-cancellation.md`.

## Legacy API

Every streaming variant follows the same rhythm: create the channels, start the request, move messages, then await for errors. `grpc_async_request` returns a `gRPCRequest` immediately in all three cases.

### Client streaming, many requests to one response

```julia
client = MyService_MyClientStreamRPC_Client("localhost", 50051)

request_c = Channel{MyRequest}(16)
req = grpc_async_request(client, request_c)

for i in 1:100
    put!(request_c, MyRequest(i, UInt64[]))
end

close(request_c)                            # end of stream; the server replies only after this
response = grpc_async_await(client, req)    # the single response
```

This is the one streaming variant where `grpc_async_await(client, req)` returns data.

### Server streaming, one request to many responses

```julia
client = MyService_MyServerStreamRPC_Client("localhost", 50051)

response_c = Channel{MyResponse}(16)
req = grpc_async_request(client, MyRequest(10, UInt64[]), response_c)

for response in response_c                  # loop ends when the library closes the channel
    handle(response)
end

grpc_async_await(req)                       # raises; returns nothing
```

### Bidirectional streaming

```julia
client = MyService_MyBidiRPC_Client("localhost", 50051)

request_c = Channel{MyRequest}(16)
response_c = Channel{MyResponse}(16)
req = grpc_async_request(client, request_c, response_c)

put!(request_c, MyRequest(1, UInt64[]))
for response in response_c
    handle(response)
    put!(request_c, next_request(response))  # sends and receives interleave freely
end

close(request_c)
grpc_async_await(req)                        # raises; returns nothing
```

Producing into `request_c` and consuming from `response_c` from the same task deadlocks as soon as the server's flow control makes one side wait on the other. For anything beyond a bounded exchange, drive the two directions from separate tasks.

### Channel ownership

- **You close the request channel.** That is the only end-of-stream signal, and a client or bidi call that never sees it waits for the deadline to fire.
- **The library closes the response channel** when the stream ends, which is what terminates a `for response in response_c` loop. Do not close it from the consumer side. Doing so raises an `InvalidStateException` inside the response pump; that case is handled, but it hides the real end of the stream.
- Channel capacity is backpressure only. The request pump batches up to 100 messages or 64 KiB per handoff to libcurl, so a small capacity does not mean one message per network write.

### Await semantics

`grpc_async_await` is the only place stream errors surface, including server statuses and transport failures. Skipping it means a failed stream looks like an empty or truncated one, since the response channel closes either way.

For server streaming and bidirectional streaming, call the single-argument `grpc_async_await(req)`. It returns nothing, and the response data has already flowed through the channel. Only client streaming has a two-argument method returning a response.

### Long-lived streams

Combine `deadline = Inf` with explicit cancellation when the lifetime is yours to manage, since the default 10 second deadline otherwise kills the stream:

```julia
client = MyService_MyBidiRPC_Client("localhost", 50051; deadline = Inf)
request_c = Channel{MyRequest}(16)
response_c = Channel{MyResponse}(16)
req = grpc_async_request(client, request_c, response_c)

# later, from anywhere
grpc_cancel(req)
close(request_c)     # releases the request pump task
```

Cancel first, then close the request channel: cancellation unblocks everything waiting on the request, and closing the channel lets its pump task exit rather than sitting on a `take!` forever. See `deadlines-cancellation.md` for what `deadline = Inf` does and does not protect against.
