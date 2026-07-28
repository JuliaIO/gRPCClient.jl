# Handles, concurrency, and thread safety

## The handle

A `gRPCCURL` wraps one libcurl multi handle. Everything hanging off it, meaning the connection pool, the HTTP/2 multiplexing, the socket watchers, the concurrency semaphore, and the scheduling model, is per handle. The package initializes a global one on load:

```julia
grpc_global_handle()   # the shared handle every client uses by default
grpc_init()            # already called by __init__; idempotent, safe from several packages
grpc_shutdown()        # closes connections, cancels in-flight requests, releases the timer
```

Create a private handle when a subsystem needs its own connection pool and its own concurrency limit, so that a burst in one part of an application cannot starve another:

```julia
h = gRPCCURL()                 # or gRPCCURL(max_streams = 64, sticky = false)
grpc_init(h)

client = MyService_MyRPC_Client("host", 50051; grpc = h)
# ...
grpc_shutdown(h)               # shuts down only this handle
```

`grpc_init` on an already-open handle is a no-op, and `grpc_shutdown` is safe to call twice. Calling into a shut-down handle raises `FAILED_PRECONDITION` at submission.

## max_streams

`max_streams` defaults to 16 and caps concurrent in-flight requests on the handle. Submitting past the cap does not fail; the request queues for a slot, and the wait counts against its own deadline. That combination is the usual explanation for `DEADLINE_EXCEEDED` from a server that is demonstrably healthy: 200 requests submitted at once against a 16-slot handle with the default 10 second deadline means the tail requests spend their whole budget queued.

Options when that happens: raise `max_streams` on a private handle, raise the deadline to cover the queue, or throttle submission so the number in flight stays near the cap. Note that HTTP/2 servers also enforce their own maximum concurrent streams per connection, so raising `max_streams` far past what the server permits moves the queue rather than removing it.

## The sticky scheduling model

The `sticky` field, fixed at handle construction, selects how every task the handle spawns is scheduled: socket I/O, the streaming request and response pumps, and the async unary fan-out that feeds `gRPCAsyncChannelResponse` channels.

```julia
h = gRPCCURL(sticky = true)    # default is false
```

- `sticky = false`, the default, uses `Threads.@spawn`. Tasks are migratable and run on any thread, so the client scales with `julia -t auto`. Correct choice when the application is multithreaded or when protobuf encode and decode is a measurable cost.
- `sticky = true` uses `@async`. Tasks are pinned to the spawning thread under cooperative scheduling. It has lower scheduling overhead and avoids cross-thread data movement, which suits purely I/O-bound or single-threaded deployments, but it does not parallelize across threads even when threads are available.

The global handle uses `sticky = false`. The setting is per handle, not per client or per call, so mixing models means using more than one handle.

Library tasks never adopt the caller's stickiness, so calling from inside an `@async` block does not pin the client's internals, and the reverse is also true.

## Thread safety

Clients, handles, and requests are safe to share across tasks and threads. All operations on the multi handle and on any easy handle attached to it are serialized under the handle's lock. `grpc_cancel` is explicitly safe to call at any time from any task.

The concurrency-relevant consequences for calling code:

- A single client can serve any number of concurrent calls; there is no need for one client per task.
- `grpc_sync_request` blocks only the calling task, not the thread's other tasks.
- User-supplied channels are ordinary Julia channels, so ordinary channel discipline applies. Responses arriving through a `gRPCAsyncChannelResponse` channel are unordered, which is what the `index` field is for.
