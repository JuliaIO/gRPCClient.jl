```@meta
CurrentModule = gRPCClient
```

# Error Handling

Errors surface as a [`gRPCServiceCallException`](@ref), whose `grpc_status` field carries the gRPC status code and whose `message` holds the server- or client-supplied detail.

!!! warning "Status codes other than `OK` are not yet stable"
    Do not rely on the specific non-`OK` status code reported for a given failure. Some of the codes the client assigns, particularly for client-side and transport errors, may be reworked to align more closely with the gRPC reference implementations. Such corrections are considered bug fixes rather than breaking changes, so they will not require a new major version. They may ship in any minor release, but status codes will not change within patch releases. Treat any non-`OK` status as a failure, and review code that branches on a particular status when upgrading to a new minor version.

Where the exception is raised depends on how the call is driven:

- A **synchronous unary** call raises from the call itself, so wrap `TestService.TestRPC(chan, req)` in a `try`/`catch`.
- For every **asynchronous or streaming** call, starting the call only reports the errors it can detect immediately, such as an uninitialized or shut-down handle (`UNAVAILABLE`), an invalid arguments, or an oversized message. Every failure that depends on timeouts, cancellation, transport errors, and server errors is raised later during the lifecycle, but at the latest when calling [`close`](@ref) or [`detach`](@ref) (also [`fetch`](@ref) for unary-response calls).
- Streaming a request with [`put!`](@ref) raises once the call is no longer accepting requests — because it has completed, was cancelled, or failed. If the call ended because of an error, that error is what will be raised. Note that `put!` only *enqueues* a message for the background sender; a message it accepts can still go untransmitted.

!!! note "End every asynchronous or streaming call"
    To ensure all errors are surfaced, always end a unary-response call (async unary, client streaming) with [`fetch`](@ref), [`close`](@ref), or [`detach`](@ref), and a streaming-response call (server, bidirectional) with [`close`](@ref) or [`detach`](@ref). 

A call can be ended early at any time with [`detach`](@ref), which cancels the request and frees its resources; by default it re-raises any exception already recorded for the call, which you can suppress with `throws = false`. Combining `deadline = Inf` with `detach` lets you manage a long-lived stream's lifetime yourself. The client-side deadline watchdog that bounds a call even when the underlying connection never becomes ready is described under [Cancellation](../legacy.md#Cancellation) in the legacy API.

!!! warning "A `deadline = Inf` call *must* be ended explicitly"
    `deadline = Inf` disables the client-side deadline watchdog, so a call that never completes on its own is never cleaned up: it leaks its resources, including its `max_streams` concurrency slot, and garbage collection will not reclaim it. Always end such a call with [`close`](@ref) or [`detach`](@ref).
