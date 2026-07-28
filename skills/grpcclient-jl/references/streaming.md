# Streaming RPC

Requires Julia 1.12 or newer. On older versions `src/Streaming.jl` is not included at all, a warning is emitted at load time, and the streaming `grpc_async_request` methods simply do not exist, so the failure looks like a `MethodError` rather than a version check.

Every streaming variant follows the same rhythm: create the channels, start the request, move messages, then await for errors. `grpc_async_request` returns a `gRPCRequest` immediately in all three cases.

## Client streaming, many requests to one response

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

## Server streaming, one request to many responses

```julia
client = MyService_MyServerStreamRPC_Client("localhost", 50051)

response_c = Channel{MyResponse}(16)
req = grpc_async_request(client, MyRequest(10, UInt64[]), response_c)

for response in response_c                  # loop ends when the library closes the channel
    handle(response)
end

grpc_async_await(req)                       # raises; returns nothing
```

## Bidirectional streaming

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

## Channel ownership

- **You close the request channel.** That is the only end-of-stream signal, and a client or bidi call that never sees it waits for the deadline to fire.
- **The library closes the response channel** when the stream ends, which is what terminates a `for response in response_c` loop. Do not close it from the consumer side. Doing so raises an `InvalidStateException` inside the response pump; that case is handled, but it hides the real end of the stream.
- Channel capacity is backpressure only. The request pump batches up to 100 messages or 64 KiB per handoff to libcurl, so a small capacity does not mean one message per network write.

## Await semantics

`grpc_async_await` is the only place stream errors surface, including server statuses and transport failures. Skipping it means a failed stream looks like an empty or truncated one, since the response channel closes either way.

For server streaming and bidirectional streaming, call the single-argument `grpc_async_await(req)`. It returns nothing, and the response data has already flowed through the channel. Only client streaming has a two-argument method returning a response.

## Long-lived streams

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
