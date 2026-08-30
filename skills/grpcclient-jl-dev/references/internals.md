# Transport internals

Everything here lives in `src/Curl.jl` unless stated otherwise.

## gRPCCURL

Wraps one libcurl multi handle plus the machinery around it: `lock` (a `ReentrantLock` guarding the multi, any attached easy handle, and the struct itself), `timer` (libcurl's requested timeout), `watchers` and `watchers_lock` (socket watchers, split out to cut contention), `running`, `requests`, `max_streams` (16 by default), `sem_cond` and `sem_free` (the concurrency semaphore), and `sticky`.

Locking rule: **all** operations on the multi handle, on any easy handle added to it, or on the struct must hold `grpc.lock`. Watchers use `watchers_lock` and the semaphore uses `sem_cond`, so a change touching more than one of these needs a consistent acquisition order.

`open` allocates the multi handle, resets watchers, fills `sem_free` with one `Event` per slot, and calls `preserve_handle`, so an open handle is never collected. `close` cancels every live request, cleans up the multi, stops the pending timer, closes watchers, wakes every semaphore waiter so they observe the shutdown, and calls `unpreserve_handle`.

Two subtleties that were bug fixes and should not be undone:

- `close` must call `stoptimer!`. A leftover libcurl timeout `Timer` keeps a libuv handle alive after shutdown, which hangs precompilation of any package whose workload issues a gRPC call.
- The `gRPCCURL` finalizer must not close the handle inline, since finalizers may not block on locks or yield. It spawns a task instead, and returns immediately when the handle was already closed.

## Semaphore

`max_reqs_dec(grpc, expiry)` takes a slot or blocks on `sem_cond` until one frees, giving up at `expiry` with `DEADLINE_EXCEEDED`. `max_reqs_inc` returns it. `sem_free` holds recycled `curl_done_reading` `Event`s rather than allocating one per request, which cut allocations by about 7 percent.

It is a `Condition` rather than a `Channel` on purpose: waiters must be wakeable to re-check their own deadline or a shutdown, not only when a slot frees.

## Request lifecycle

`gRPCRequest`'s constructor performs, in order:

1. Merge per-call option overrides into the client options
2. Reject a non-running handle with `FAILED_PRECONDITION`
3. Validate the deadline, rejecting negative, `NaN`, and `-Inf` with `INVALID_ARGUMENT`. This must stay ahead of the watchdog `Timer`, which would otherwise raise a bare `ArgumentError` on a negative interval
4. Compute `expiry = time() + deadline`, which is why queue time counts against the deadline
5. Arm the watchdog, before the queue wait, so a request can never block past its deadline
6. Take a `max_streams` slot, or return a pre-failed request when the deadline expires while queued
7. Configure and add the easy handle to the multi under `grpc.lock`

There is a second `gRPCRequest` constructor for the dead-on-arrival case: a request whose deadline expired while queued holds no slot, is never added to `grpc.requests`, and is already marked completed, so `grpc_async_await` raises its stored exception and nothing needs cleanup.

`cleanup_request` removes the easy handle from the multi, which is libcurl's documented way to abort a transfer, returns the slot, notifies `ready` and `curl_done_reading`, and sets `completed`. It runs under `grpc.lock`, which is what makes completion, cancellation, and shutdown mutually idempotent. Hardening in place: the easy handle is set to `C_NULL` after being closed, so a late use cannot touch freed memory.

## Deadline watchdog

One `Timer` per request, armed at `deadline + GRPC_DEADLINE_GRACE` (0.25 s), covers both phases of the call. While the request is still queued, firing wakes the semaphore waiters so an expired one can bail out; once in flight, it cancels the transfer with `DEADLINE_EXCEEDED`.

It exists because libcurl only enforces `CURLOPT_TIMEOUT_MS` and `CURLOPT_CONNECTTIMEOUT_MS` for handles it is actively driving. A handle parked waiting for another handle's connection to become multiplexable under `CURLOPT_PIPEWAIT` never re-enters libcurl's state machine until that connection progresses, so a server that accepts TCP but never completes the HTTP/2 handshake would wedge the request forever and leak its slot. The grace period keeps libcurl's more specific errors primary whenever libcurl is behaving.

Taking `sem_cond` inside the timer callback also fences the read of `req` against its assignment in the constructor, since the timer can fire before the constructor finishes.

## Event loop integration

libcurl drives itself through two callbacks. `socket_callback` creates, updates, and destroys a `CURLWatcher` per socket, each watching the file descriptor through FileWatching and calling back into the multi on readiness. `timer_callback` maintains `grpc.timer` for libcurl's requested timeout. `check_multi_info` drains completion messages and finishes requests. There is no polling loop, so nothing in the client burns CPU while idle.

## Framing and callbacks

`grpc_encode_request_iobuffer` writes the 5-byte gRPC frame, meaning a compression flag byte and a big-endian `UInt32` length, then the payload, then seeks back to patch the length. The size limit is checked on the payload excluding the frame. `_encode_body` has two methods, one encoding a typed message through ProtoBuf and one writing an already-encoded `AbstractVector{UInt8}` verbatim, which is the whole implementation of raw requests. `_decode_message` mirrors it on the response side.

`write_callback` accumulates response bytes and tracks frame parsing state across chunks (`response_read_header`, `response_compressed`, `response_length`), since a gRPC message can arrive split across arbitrary write callbacks. For a response-streaming request it delegates to `handle_streaming_write`, which must never block — the callback runs under `grpc.lock`, and blocking there wedges the whole handle. The pump's intermediate channel is therefore unbounded, and backpressure is applied in bytes: each handed-off message is charged to `recv_queued_bytes`, and past `RECV_BACKPRESSURE_BYTES` (1 MiB) the callback pauses the transfer at a frame boundary via `CURL_WRITEFUNC_PAUSE`, letting HTTP/2 flow control throttle the server. On resume curl re-delivers the whole paused chunk, so `chunk_skip` skips the already-parsed prefix. Unary responses keep the direct path: one bounded message, no channel. `read_callback` uploads from `request` and coordinates with the streaming request pump through `curl_done_reading` and `curl_easy_pause`. `header_callback` scrapes `grpc-status` and `grpc-message` with `regex_grpc_status` and `regex_grpc_message`.

`grpc_timeout_header_val` formats the `grpc-timeout` header, picking the coarsest unit that represents the value exactly and staying within the spec's 8-digit limit, rounding up to the finest fitting unit on overflow. It has extensive tests of its own, including invariants over a wide sweep.

## Streaming pumps

`src/Streaming.jl` runs one task per streaming direction, spawned with the handle's `sticky` model and wrapped in `errormonitor`.

`grpc_async_stream_request` blocks on `take!` for the first request, then opportunistically drains more, stopping at 100 messages or 64 KiB, to cut per-handoff overhead with libcurl. It waits on `curl_done_reading` before writing into the upload buffer, then resets the event and calls `curl_easy_pause(CURLPAUSE_CONT)` to tell libcurl there is more to send. `InvalidStateException` from the user closing the request channel is the normal end of stream, and triggers a final pause-continue so `read_callback` can return 0.

Both pumps must re-check `req.completed` under `req.lock` before touching the easy handle. Once a request has completed, cancelled, or timed out, the easy handle is gone and libcurl will never signal `curl_done_reading` again; `cleanup_request` notifies it so a racing `wait` still wakes, and the re-check keeps `curl_easy_pause` off a freed handle. This is the sharpest hazard in the file.

`grpc_async_stream_response` decodes each buffered message into the user's channel, credits its bytes back to the backpressure budget as it takes them, and resumes a paused transfer with `curl_easy_pause(CURLPAUSE_CONT)` once the budget drains below its low watermark. It closes both its own channel and `req.response_c` on exit, which is what ends a consumer's `for` loop. On an abnormal end (`req.ex` set, or handle shutdown) `cleanup_request` also closes the caller's channel (`response_user_c`) to unblock a pump stalled on a caller who stopped draining; a normal completion leaves it open until the pump has delivered everything it buffered.
