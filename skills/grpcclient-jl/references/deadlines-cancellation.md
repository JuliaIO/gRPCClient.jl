# Deadlines, cancellation, and the exception contract

## What the deadline covers

`deadline` is in seconds and spans the entire call from submission, not just the network transfer. Time spent queued client-side waiting for one of the handle's `max_streams` slots counts against it, and only the remaining budget is given to the transfer and encoded into the `grpc-timeout` header sent to the server. A request submitted while every slot is held by slow calls therefore fails at its own deadline rather than waiting indefinitely for a slot.

Validation: the value must be non-negative. `0` expires immediately, while negative, `NaN`, and `-Inf` raise `INVALID_ARGUMENT` at submission. `Inf` means no deadline.

## The client-side watchdog

libcurl does not process a handle's timeouts while that handle is parked waiting for another request's connection to become multiplexable, which is what `CURLOPT_PIPEWAIT` does. A server that accepts TCP but never completes the HTTP/2 handshake would consequently wedge every queued request forever, leaking their concurrency slots. A client-side watchdog closes that gap and resolves each request with `DEADLINE_EXCEEDED` shortly after its deadline, roughly a quarter second of grace past it. The grace period exists so that libcurl's own more specific error wins whenever libcurl is actually driving the handle.

The practical guarantee: a request with a finite deadline always resolves, whatever the transport does.

## deadline = Inf

With `deadline = Inf` no client-side timeout is enforced and no `grpc-timeout` header is sent, so the server does not impose one either. The call runs until it completes or until `grpc_cancel` ends it. That is the intended tool for a long-lived stream whose lifetime the application manages, and it is also a way to hang forever: a request stuck behind a connection that never becomes ready will wait indefinitely, because the watchdog has no deadline to enforce. `grpc_cancel` and `grpc_shutdown` are the only exits. Prefer a finite deadline unless the call has an explicit lifecycle.

An abandoned `Inf` request is not cleaned up by garbage collection. Cancelling it is the caller's responsibility.

## grpc_cancel

```julia
grpc_cancel(req)                  # awaiters throw CANCELLED
grpc_cancel(req, ex)              # awaiters throw ex instead
```

It removes the easy handle from the libcurl multi, which is libcurl's documented way to abort a transfer, then unblocks everything waiting on the request, including streaming channels. Safe to call at any time from any task.

The return value is meaningful: `true` when this call performed the cancellation, and `false` when the request had already completed or the handle was already shut down, in which case nothing changed. Use it to distinguish "I stopped it" from "it had already finished" without racing.

After cancelling a client or bidirectional stream, close the request channel so its pump task can exit.

## The exception contract

`grpc_async_request` throws only for programming errors it can detect synchronously at submission:

| Condition | Status |
|---|---|
| Handle uninitialized or shut down | `FAILED_PRECONDITION` |
| Invalid deadline (negative, `NaN`, `-Inf`) | `INVALID_ARGUMENT` |
| Message larger than `max_send_message_length` | `RESOURCE_EXHAUSTED` |
| `token` plus an `authorization` metadata entry | `INVALID_ARGUMENT` |
| Unknown option keyword | `ArgumentError`, not a gRPC exception |

Everything whose outcome depends on time or concurrency is raised by `grpc_async_await`: deadline expiry, including expiry while queued for a slot, cancellation, transport errors, and non-OK server statuses. `grpc_sync_request` does both in sequence and so raises either class.

The split matters when writing error handling. Wrapping only the submission catches configuration mistakes and nothing else, and for streaming calls, omitting `grpc_async_await` entirely means a failed stream is indistinguishable from a short one.

In the channel-based unary form, submission-time errors still throw from `grpc_async_request`, while everything else arrives as the `ex` field of a `gRPCAsyncChannelResponse`.

## Statuses worth special handling

`gRPCServiceCallException` carries `grpc_status` and `message`. The constants are not exported, so qualify them as `gRPCClient.GRPC_DEADLINE_EXCEEDED` or import them explicitly.

| Status | Typical cause on this client |
|---|---|
| `GRPC_DEADLINE_EXCEEDED` | Deadline elapsed, whether queued, in transfer, or enforced by the watchdog |
| `GRPC_CANCELLED` | `grpc_cancel`, or `grpc_shutdown` while the call was in flight |
| `GRPC_RESOURCE_EXHAUSTED` | Message exceeded `max_send_message_length` or `max_recieve_message_length` |
| `GRPC_FAILED_PRECONDITION` | Call attempted on a shut-down or uninitialized handle |
| `GRPC_INTERNAL` | Underlying libcurl error; `message` carries the libcurl text |
| `GRPC_UNAUTHENTICATED` | Server rejected or required the bearer token |
