const CURL_VERSION_STR = unsafe_string(curl_version())
let m = match(r"^libcurl/(\d+\.\d+\.\d+)\b", CURL_VERSION_STR)
    m !== nothing || error("unexpected CURL_VERSION_STR value")
    curl = m.captures[1]
    julia = "$(VERSION.major).$(VERSION.minor)"
    const global CURL_VERSION = VersionNumber(curl)
    const global USER_AGENT = "curl/$curl julia/$julia"
end

# libcurl 8.4.0 and 8.5.0 stop servicing a transfer's *receive* direction while its *send*
# direction is paused, which wedges any request-streaming call whose caller stops sending
# while responses are still outstanding.
#
# `lib/http2.c drain_stream()` sets `dselect_bits = CURL_CSELECT_IN | CURL_CSELECT_OUT` for
# an HTTP/2 stream whose upload is still open, and this package sends an empty
# `Content-Length:`, so CSELECT_OUT stays set for the life of the call. `Curl_readwrite`
# then consults `select_bits_paused()`, which in those versions ORs the two directions:
#
#     return (((select_bits & CURL_CSELECT_IN)  && (keepon & KEEP_RECV_PAUSE)) ||
#             ((select_bits & CURL_CSELECT_OUT) && (keepon & KEEP_SEND_PAUSE)));
#
# read_callback returns CURL_READFUNC_PAUSE whenever the upload buffer runs dry, setting
# KEEP_SEND_PAUSE, so the second clause reports "paused", Curl_readwrite returns CURLE_OK
# having read nothing, and it deliberately leaves the bits set. Every later
# curl_multi_socket_action re-takes the same early return, response bytes pile up unread in
# the socket receive queue, and the caller blocks until its deadline. Clearing
# KEEP_SEND_PAUSE is the only thing that makes the predicate false, which is why driving the
# multi handle does not help but curl_easy_pause(CURLPAUSE_CONT) does.
#
# The early return arrived in 8.4.0 as the fix for https://github.com/curl/curl/issues/11982
# and over-corrected. Reported at https://curl.se/mail/lib-2024-01/0049.html and fixed in
# 8.6.0 by "transfer: make the select_bits_paused condition check both directions", which
# returns false as soon as any wanted direction is unpaused.
#
# The affected range is therefore closed at both ends: the early return does not exist
# before 8.4.0, so those versions never had the bug. Both bounds are verified against the Go
# test server on Julia 1.10, bidirectional, burst-send then drain, with the workaround
# disabled: libcurl 7.84.0 is 0/30 on the shape that fails 29/30 on 8.4.0. The lower bound
# matters because a Julia built against a system libcurl, as several distributions do, can
# pair a supported Julia with a pre-8.4 library, and that combination needs no workaround.
#
# Julia bundles libcurl as a stdlib, so an affected version cannot simply be upgraded:
# Julia 1.10 and 1.9 ship 8.4.0. On affected versions a request-streaming call re-issues the
# un-pause on a timer for as long as it is in flight, which is what shakes the receive side
# loose. See GRPC_UNPAUSE_INTERVAL and the `unpause` field of gRPCRequest.
const CURL_SEND_PAUSE_BLOCKS_RECV_FROM = v"8.4.0"
const CURL_SEND_PAUSE_BLOCKS_RECV_BELOW = v"8.6.0"

# libcurl 8.6.0 loses a transfer's pending read interest, which strands a streaming call at
# the end of the stream: every response has arrived, but the call never completes.
#
# `lib/http2.c drain_stream()` sets `data->state.select_bits = CURL_CSELECT_IN|CSELECT_OUT`
# to mean "I still hold buffered input, run me and read it". `multi_socket()` then records
# the event the application reports:
#
#     /* 8.6.0, lib/multi.c:3245 */   data->state.select_bits  = (unsigned char)ev_bitmask;
#     /* 8.7.0, lib/multi.c:3170 */   data->state.select_bits |= (unsigned char)ev_bitmask;
#
# By that point libcurl has already drained the socket, so the kernel receive queue is empty
# and the socket is only ever writable. The watcher task therefore reports CURL_CSELECT_OUT
# alone, and on 8.6.0 that plain assignment overwrites the CURL_CSELECT_IN libcurl staked for
# itself. `Curl_readwrite` runs the send half only, the buffered HTTP/2 input is never
# surfaced, and every later writable wake-up overwrites the bit again. The transfer is stuck
# for good, and because a TCP socket with room in its send buffer is always writable, the
# watcher spins on it.
#
# Fixed upstream in 8.7.0 by the `|=` above: "multi: fix multi_sock handling of select_bits",
# https://curl.se/bug/?i=12971. The range is closed at both ends and is 8.6.0 alone: 8.4.0
# and 8.5.0 kept the drain signal in a separate field (`state.dselect_bits`, with the event
# going to `conn->cselect_bits`), so no assignment could clobber it, and 8.6.0 is the release
# that merged the two. Verified against the Go test server on Julia 1.11, on the shape that
# fails 30/30 on 8.6.0: libcurl 7.84.0, 8.4.0, 8.5.0 and 8.7.1 are each 0/30.
#
# Julia 1.11 ships 8.6.0 and bundles libcurl as a stdlib, so it cannot simply be upgraded.
# The workaround is in the watcher task: claim readability when the socket is writable and
# not readable, so the socket action ORs in the bit libcurl wants rather than erasing it.
const CURL_SELECT_BITS_CLOBBERED_FROM = v"8.6.0"
const CURL_SELECT_BITS_CLOBBERED_BELOW = v"8.7.0"

# Resolved in __init__ rather than read off the CURL_VERSION const above, because that const
# is evaluated during precompilation and baked into the cache. Normally the two agree, since
# libcurl is bundled with Julia, but they diverge when a different libcurl is loaded under an
# existing cache, which is exactly how this workaround gets tested.
const NEEDS_UNPAUSE_WORKAROUND = Ref(false)
const NEEDS_SELECT_BITS_WORKAROUND = Ref(false)

function _runtime_curl_version()
    m = match(r"^libcurl/(\d+\.\d+\.\d+)\b", unsafe_string(curl_version()))
    return m === nothing ? CURL_VERSION : VersionNumber(m.captures[1]::SubString{String})
end

struct NoChannel end
const NOCHANNEL = NoChannel()


Base.isopen(req::NoChannel) = false
Base.isempty(req::NoChannel) = true
Base.put!(req::NoChannel, ::IOBuffer) = false
Base.take!(req::NoChannel) = nothing
Base.close(req::NoChannel) = false
Base.iterate(req::NoChannel) =
    Iterators.Stateful(Iterators.flatten(Iterators.repeated(nothing, 0)))

# Backpressure for a streaming response is measured in BYTES of undelivered
# messages, not in message count. The pump's intermediate channel is unbounded
# (a blocking put! in write_callback is the deadlock this design fixes), so
# something else must bound how much can pile up behind a slow consumer, and a
# slot count is the wrong unit: 16 slots bounds memory nicely for large
# messages but trips constantly for tiny ones (16 seven-byte messages is 112
# bytes, so a 1000-message stream of them pauses ~60 times, and each
# pause→resume→re-deliver cycle is expensive — this cost ~10% of bidirectional
# throughput before the byte gate), while 256 slots bounds memory at
# 256 * max_recieve_message_length for large ones. A byte budget bounds memory
# independently of message size and never engages for streams smaller than the
# budget. Measured: a 256 MB stream against a stalled consumer holds ~18 MiB
# resident, flat, where an ungated unbounded channel grew past +119 MiB and was
# still climbing 15 seconds in.
const RECV_BACKPRESSURE_BYTES = 1 * 1024 * 1024

# Should the receive direction pause? Called from handle_streaming_write under
# grpc.lock. The counter is atomic because the pump decrements it without
# holding that lock; a racing read can only see a value mid-decrement, which
# makes the gate trip slightly early, never late.
_response_c_backpressured(req) = req.recv_queued_bytes[] >= RECV_BACKPRESSURE_BYTES

# Has the response pump drained enough buffered bytes to make a resume worth
# it? A resume is expensive: per libcurl it may synchronously re-enter
# write_callback to re-deliver the paused chunk, and it re-grants HTTP/2
# flow-control window. Resuming after *every* drained message therefore pins
# the transfer in a pause→resume→re-deliver→pause ping-pong (measured ~1989
# pauses for a 2000-message bidirectional stream). Resuming only below a
# quarter of the backpressure budget amortizes the cycle. Heuristic read; the
# authoritative recv_paused flag is re-verified under req.lock by the pump
# before it actually resumes.
_response_c_drained(req) = req.recv_queued_bytes[] <= RECV_BACKPRESSURE_BYTES ÷ 4

# Streaming-response body of write_callback.
#
# This path must never block. The original code called put! on req.response_c from
# inside the callback, which runs while the watcher task holds grpc.lock across
# curl_multi_socket_action; once a slow consumer stalled the response pump behind a
# full user channel, req.response_c filled, the put! blocked with the transport lock
# held, and every request on the handle froze. Worse, grpc_cancel and close(grpc)
# need that same lock, so "take one response, then cancel" deadlocked permanently.
#
# Instead, when the undelivered-byte budget (see RECV_BACKPRESSURE_BYTES) is
# exceeded we pause at a frame boundary by returning CURL_WRITEFUNC_PAUSE, which
# unblocks the callback immediately and pauses only this transfer's receive
# direction. With the receive direction paused libcurl stops granting HTTP/2
# window, so the server is throttled by flow control and memory stays bounded
# per stream, which is the gRPC-correct backpressure semantic, the mirror image
# of the send side's CURL_READFUNC_PAUSE design. The response pump resumes the
# transfer with curl_easy_pause(req.easy, CURLPAUSE_CONT) once the byte budget
# has drained below its low watermark.
#
# Re-delivery contract: per curl_easy_pause's documentation, a write callback that
# returns pause "could not take care of any data at all, and that data is then
# delivered again to the callback when the transfer is unpaused". curl therefore
# hands us back the entire paused chunk from its first byte, even bytes we had
# already parsed. chunk_skip records how many bytes of the re-delivered data were
# already handled, so the parser resumes mid-chunk. It is a byte offset into the
# logical re-delivered stream rather than a saved buffer, which keeps it correct
# even if curl re-chunks: a chunk lying entirely inside the consumed prefix is
# consumed whole and the remainder carries forward.
function handle_streaming_write(req, data::Ptr{Cchar}, n::Csize_t)::Csize_t
    buf = unsafe_wrap(Array, convert(Ptr{UInt8}, data), (n,))

    prefix = 0
    if req.chunk_skip > 0
        prefix = min(req.chunk_skip, length(buf))
        req.chunk_skip -= prefix
        # The whole chunk lies inside the already-parsed prefix: nothing new in it
        prefix == length(buf) && return Csize_t(n)
        buf = unsafe_wrap(Array, pointer(buf) + prefix, (length(buf) - prefix,))
    end

    target = length(buf)
    handled = 0
    while !isnothing(buf) && handled < target
        # The gate: hand messages to the pump only at frame boundaries and only
        # while the undelivered-byte budget has room, and pause with ZERO bytes
        # of the remaining chunk consumed. Pausing mid-parse would report "no
        # data consumed" to curl, so the re-delivered chunk would replay bytes
        # handle_write already accepted and duplicate them in the user's stream;
        # chunk_skip exists precisely to re-sync the two views, and gating here
        # is what keeps it exact.
        if _response_c_backpressured(req)
            req.recv_paused = true
            req.chunk_skip = prefix + handled
            return Csize_t(CURL_WRITEFUNC_PAUSE)
        end

        try
            # A zero-byte return with data still left over means handle_write made
            # no progress and looping again would spin forever inside a curl
            # callback, so break and let the byte-count check below report it.
            handled_n_bytes, buf = handle_write(req, buf)
            handled += handled_n_bytes
            handled_n_bytes == 0 && !isnothing(buf) && break
        catch ex
            # Eat InvalidStateException raised on put! to closed channel
            !isa(ex, InvalidStateException) && rethrow(ex)
        end
    end

    !isnothing(req.ex) && return typemax(Csize_t)

    # Check that we handled the correct number of bytes. With no exception in
    # handle_write this only fires on the zero-progress break above: every other
    # exit has consumed the chunk whole (into the current message buffer or into
    # complete messages), and the pause path has already returned.
    if handled != target
        handle_exception(
            req,
            gRPCServiceCallException(
                GRPC_INTERNAL,
                "Recieved $(target) bytes from curl but only handled $(handled)",
            ),
        )

        # Unblock the task waiting on response_c
        close(req.response_c)
        return typemax(Csize_t)
    end

    return Csize_t(prefix + handled)
end

function write_callback(
        data::Ptr{Cchar},
        size::Csize_t,
        count::Csize_t,
        req_p::Ptr{Cvoid},
    )::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest

        !isnothing(req.ex) && return typemax(Csize_t)

        n = size * count

        # Response streaming goes through the backpressure-aware path, which must
        # never block in here. Unary responses are a single message, bounded at
        # length-prefix parse by max_recieve_message_length and drained by
        # grpc_async_await rather than a channel, so the direct path below is
        # unchanged.
        isstreaming_response(req) && return handle_streaming_write(req, data, n)

        buf = unsafe_wrap(Array, convert(Ptr{UInt8}, data), (n,))

        handled_n_bytes_total = 0
        try
            # A zero-byte return with data still left over means handle_write made no
            # progress and looping again would spin forever inside a curl callback,
            # so break and let the byte-count check below report it. Zero bytes with
            # no leftover data is normal (a chunk that only partially fills the
            # current header or message ends the loop through `buf`), and must not
            # be treated as a stall: a zero-length message used to reach here and
            # fail the byte-count check, which is why it is now completed as soon as
            # its length-prefix is parsed. See handle_write.
            while !isnothing(buf) && handled_n_bytes_total < n
                handled_n_bytes, buf = handle_write(req, buf)
                handled_n_bytes_total += handled_n_bytes
                handled_n_bytes == 0 && !isnothing(buf) && break
            end
        catch ex
            # Eat InvalidStateException raised on put! to closed channel
            !isa(ex, InvalidStateException) && rethrow(ex)
        end

        !isnothing(req.ex) && return typemax(Csize_t)

        # Check that we handled the correct number of bytes
        # If there was no exception in handle_write this should always match
        if handled_n_bytes_total != n
            handle_exception(
                req,
                gRPCServiceCallException(
                    GRPC_INTERNAL,
                    "Recieved $(n) bytes from curl but only handled $(handled_n_bytes_total)",
                ),
            )

            # If we are response streaming unblock the task waiting on response_c
            close(req.response_c)
            return typemax(Csize_t)
        end

        return handled_n_bytes_total
    catch err
        @error("write_callback: unexpected error", err = err, maxlog = 1_000)
        return typemax(Csize_t)
    end
end

function read_callback(
        data::Ptr{Cchar},
        size::Csize_t,
        count::Csize_t,
        req_p::Ptr{Cvoid},
    )::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest

        # Curl sometimes calls this again even after we tell it to pause, and it needs no
        # special handling: the request buffer is empty in that state, so the streaming
        # branch below simply pauses again, or ends the request if the stream has since
        # closed. Bailing out early instead used to be actively harmful, because it
        # swallowed the un-pause the request pump issues and left the transfer paused for
        # good. The pump stages the buffer under `req.lock`, which is the lock libcurl
        # invokes this callback under, so a partially written buffer is never visible here.
        buf_p = pointer(req.request.data) + req.request_ptr
        n_left = req.request.size - req.request_ptr

        n = size * count
        n_min = min(n, n_left)

        ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), data, buf_p, n_min)

        req.request_ptr += n_min

        if isstreaming_request(req) && n_min == 0
            # Keep sending until the caller's request stream has ended
            if req.request_eof
                notify(req.curl_done_reading)
                return 0
            end

            seekstart(req.request)
            truncate(req.request, 0)
            req.request_ptr = 0

            # Safe to write more data to the request buffer again
            notify(req.curl_done_reading)

            return CURL_READFUNC_PAUSE
        end

        return n_min
    catch err
        @error("read_callback: unexpected error", err = err, maxlog = 1_000)
        return CURL_READFUNC_ABORT
    end
end

const regex_grpc_status = r"grpc-status: ([0-9]+)"
const regex_grpc_message = Regex("grpc-message: (.*)", "s")


function header_callback(
        data::Ptr{Cchar},
        size::Csize_t,
        count::Csize_t,
        req_p::Ptr{Cvoid},
    )::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest
        n = size * count

        header = unsafe_string(data, n)
        header = strip(header)

        if (m_grpc_status = match(regex_grpc_status, header)) isa RegexMatch
            capture = m_grpc_status.captures[1]
            if capture !== nothing
                req.grpc_status = parse(UInt64, capture)
            end
        elseif (m_grpc_message = match(regex_grpc_message, header)) isa RegexMatch
            capture = m_grpc_message.captures[1]
            if capture !== nothing
                req.grpc_message = capture
            end
        end

        return n
    catch err
        @error("header_callback: unexpected error", err = err, maxlog = 1_000)
        return typemax(Csize_t)
    end
end

# Render a timeout (seconds) as a gRPC `grpc-timeout` header value. Per the gRPC HTTP/2 spec the
# value is a positive integer of AT MOST 8 digits followed by a unit char (H/M/S/m/u/n). Prefer the
# coarsest unit from seconds down to nanoseconds that represents the timeout exactly within 8 digits,
# so common values stay compact ("1S", "500m", "100n"). When no exact representation fits in 8 digits
# (a fractional multi-second timeout, whose exact form needs more than 8 nanosecond digits, e.g.
# 29.999999046 -> "29999999046n" which the peer rejects as malformed), round UP to the finest unit
# that does fit, keeping the header spec-valid and never encoding a shorter timeout than requested.
function grpc_timeout_header_val(timeout::Real)
    # A negative, non-finite, or unrepresentably-large timeout is a caller error: reject it with
    # INVALID_ARGUMENT rather than silently coerce it into a wrong deadline on the wire.
    (isfinite(timeout) && timeout >= 0) || throw(
        gRPCServiceCallException(
            GRPC_INVALID_ARGUMENT,
            "grpc-timeout must be a finite, non-negative number of seconds, got $(timeout)"
        )
    )
    # Convert to Float64 before scaling to nanoseconds. A narrow Real (e.g. Float16, whose max is
    # 65504) would otherwise promote the 1e9 factor into its own type and overflow to Inf, corrupting
    # the conversion; a too-large finite input (e.g. a huge BigFloat) converts to Inf and is caught
    # by the range check below. Nanoseconds is the finest unit, so a value beyond what fits in Int64
    # ns (~292 years) cannot be represented.
    t = Float64(timeout)
    t * 1.0e9 < typemax(Int64) || throw(
        gRPCServiceCallException(
            GRPC_INVALID_ARGUMENT,
            "grpc-timeout $(timeout)s is too large to encode as a grpc-timeout header"
        )
    )
    # Round to the nearest nanosecond (absorbs floating-point representation error, so clean inputs
    # stay exact, e.g. 0.001 -> "1m"). A strictly positive timeout must never collapse to "0S", which
    # would encode an already-expired deadline, so floor it at a single nanosecond.
    ns = round(Int64, t * 1.0e9)
    ns == 0 && t > 0 && (ns = 1)
    # Coarsest-exact preference: seconds, milliseconds, microseconds, nanoseconds.
    # `string(q) * unit` (String * Char) rather than "$(q)$(unit)": interpolating a Char takes a
    # slower path that allocates ~2.5x more, and this runs once per request.
    for (mult, unit) in ((1_000_000_000, 'S'), (1_000_000, 'm'), (1_000, 'u'), (1, 'n'))
        q, r = divrem(ns, mult)
        r == 0 && q <= 99_999_999 && return string(q) * unit
    end
    # No exact unit fits in 8 digits: round up to the finest unit that does (nanoseconds .. hours).
    for (mult, unit) in (
            (1, 'n'), (1_000, 'u'), (1_000_000, 'm'), (1_000_000_000, 'S'),
            (60_000_000_000, 'M'), (3_600_000_000_000, 'H'),
        )
        ticks = cld(ns, mult)
        ticks <= 99_999_999 && return string(ticks) * unit
    end
    # A valid Int64 ns always fits in <=8 hour-digits, so reaching here is a logic error, not input.
    throw(
        gRPCServiceCallException(
            GRPC_INVALID_ARGUMENT,
            "grpc-timeout $(timeout)s could not be encoded within the 8-digit gRPC limit"
        )
    )
end

const _AUTHORIZATION_HEADER = "authorization"

# ASCII case-fold a single byte. Header names are ASCII per the HTTP/2 spec, so folding
# bytes is sufficient and, unlike lowercase(), needs no temporary String.
@inline _ascii_lower(b::UInt8) = ifelse(UInt8('A') <= b <= UInt8('Z'), b | 0x20, b)

# Does `metadata` carry an `authorization` entry under any capitalization? Header names
# are case-insensitive and libcurl lowercases them for HTTP/2, so "Authorization"
# collides with `token` exactly as "authorization" does.
#
# Allocation-free by construction: `keys` on a Dict is a lazy KeySet, and comparing with
# `codeunit` reads bytes in place rather than building a lowercased copy of each key.
function _has_authorization_key(metadata::Dict{String, String})
    n = ncodeunits(_AUTHORIZATION_HEADER)
    for k in keys(metadata)
        ncodeunits(k) == n || continue
        i = 1
        while i <= n && _ascii_lower(codeunit(k, i)) == codeunit(_AUTHORIZATION_HEADER, i)
            i += 1
        end
        i > n && return true
    end
    return false
end

@kwdef struct gRPCConnectionOptions
    secure::Bool = false
    deadline::Float64 = 10
    keepalive::Float64 = 60
    max_send_message_length::Int = 4 * 1024 * 1024
    max_recieve_message_length::Int = 4 * 1024 * 1024
    # Optional bearer token attached to every request as an
    # `authorization: Bearer <token>` header. `nothing` sends no header.
    # Note that this is equivalent to adding "authorization" => "Bearer $token"
    # to metadata
    token::Union{Nothing, String} = nothing
    metadata::Union{Nothing, Dict{String, String}} = nothing

    # `token` and an `authorization` metadata entry are two spellings of the same
    # header, so setting both would append two `authorization` headers and leave which
    # one applies up to the server. Reject that ambiguity at construction rather than
    # silently sending both. Validating here covers every path that builds options: the
    # client constructor and _merge_options, which reaches this via the positional
    # constructor. The check runs once per options object, not once per request, since
    # _merge_options returns the existing object untouched when nothing is overridden.
    #
    # To swap a client-level token for per-request metadata, pass `token = nothing`
    # alongside the metadata override.
    function gRPCConnectionOptions(
            secure,
            deadline,
            keepalive,
            max_send_message_length,
            max_recieve_message_length,
            token,
            metadata,
        )
        if !isnothing(token) &&
                !isnothing(metadata) &&
                _has_authorization_key(metadata)
            throw(
                gRPCServiceCallException(
                    GRPC_INVALID_ARGUMENT,
                    "token and an \"authorization\" metadata entry both set the authorization header; " *
                        "use one or the other (pass token = nothing to override a client-level token with metadata)",
                ),
            )
        end
        new(
            secure,
            deadline,
            keepalive,
            max_send_message_length,
            max_recieve_message_length,
            token,
            metadata,
        )
    end
end

# Creates a new options object (if necessary) where some fields are overridden
# based on overrides
@generated function _merge_options(options::gRPCConnectionOptions, overrides::AbstractDict)::gRPCConnectionOptions
    # if no argument is overriden, just return options.
    # Otherwise, create a new object with some fields overridden
    return quote
        $(Expr(:meta, :inline)) # Equivalent of @inline for generated functions
        isempty(overrides) && return options
        for k in keys(overrides)
            if !(k in fieldnames(gRPCConnectionOptions))
                throw(ArgumentError("Invalid field of gRPCConnectionOptions: $k"))
            end
        end
        gRPCConnectionOptions(
            $(
                [
                    # Generate
                    # get(overrides, :field1, options.field1)
                    # get(overrides, :field2, options.field2)
                    # ...
                    # for each fieldname of gRPCConnectionOptions
                    :(get(overrides, $(QuoteNode(fn)), options.$fn))
                        for fn in fieldnames(gRPCConnectionOptions) if fn != :metadata
                ]...
            ),
            # For metadata, we override on a per-field basis instead
            if :metadata in keys(overrides) && !isnothing(overrides[:metadata])
                if !isnothing(options.metadata)
                    merge(options.metadata, overrides[:metadata])
                else
                    overrides[:metadata]
                end
            else
                options.metadata
            end
        )
    end
end

# How long (seconds) past the request deadline the client-side watchdog waits before
# cancelling a request libcurl has failed to complete. The grace period keeps libcurl's own
# (more specific) timeout errors primary when it is driving the handle properly; the
# watchdog only wins when libcurl has wedged (see the watchdog comment in gRPCRequest).
const GRPC_DEADLINE_GRACE = 0.25

# How often (seconds) an in-flight request-streaming call re-issues
# curl_easy_pause(CURLPAUSE_CONT) on a libcurl that needs the workaround described at the
# top of this file. Only the un-pause clears the block, so this bounds how long a wedged
# call stalls. curl_easy_pause on a transfer that is not paused is cheap, and an un-pause
# with an empty request buffer draws one read_callback that pauses straight back, so a
# healthy call pays only for the call itself.
const GRPC_UNPAUSE_INTERVAL = 0.05

mutable struct gRPCRequest
    # CURL multi lock for exclusive access to the easy handle after its added to the multi
    lock::ReentrantLock

    # CURL easy handle
    easy::Ptr{Cvoid}
    # CURL multi handle
    multi::Ptr{Cvoid}
    # CURL headers list
    headers::Ptr{Cvoid}

    # The full request URL
    url::String

    # Contains the request data which will be uploaded in read_callback
    request::IOBuffer

    # Tracks the current location inside request for the read_callback
    request_ptr::Int64

    # Holds the current response in the response stream
    response::IOBuffer

    # These are only used when the request or response is streaming
    request_c::Union{Channel{IOBuffer}, NoChannel}
    response_c::Union{Channel{IOBuffer}, NoChannel}

    # The task making the request can block on this until the request is complete
    ready::Event

    # CURL status code and error message
    code::CURLcode
    errbuf::Vector{UInt8}

    # Used to enforce maximum send / recv message sizes
    max_send_message_length::Int64
    max_recieve_message_length::Int64

    # Contains the first exception if any encountered during the request
    ex::Union{Nothing, Exception}

    # Keeps track of the response stream parsing state
    response_read_header::Bool
    response_compressed::Bool

    # Set once the caller's request stream has ended, so no further request data will ever
    # be staged and read_callback should end the upload by returning 0. Only meaningful for
    # a request-streaming call.
    #
    # This used to be read off `request_c` (closed and empty), but nothing is ever put into
    # that channel: it is a lifecycle handle and a flag, not a queue. A plain field can be
    # written inside the critical section below, where `close(::Channel)` cannot go, because
    # close acquires the channel's own lock and this section runs while holding the one lock
    # that serializes every transfer on the handle. It also keeps read_callback, which runs
    # inside libcurl, from taking a Channel's lock at all.
    #
    # Sits with the other Bools deliberately: `response_length` needs 4-byte alignment, so
    # there are padding bytes here that this field occupies for free. Placed after
    # `curl_done_reading` instead it would cost a whole 8-byte slot per request.
    request_eof::Bool

    response_length::UInt32

    # Set by handle_streaming_write when it returned CURL_WRITEFUNC_PAUSE because
    # the undelivered-byte budget was exceeded; cleared by the pump when the
    # budget drains below its low watermark and it resumes the receive direction
    # with curl_easy_pause. See the comment on handle_streaming_write for the
    # full protocol. Occupies padding next to the other Bools, like request_eof.
    recv_paused::Bool

    # Bytes at the front of the next re-delivered chunk that were already parsed
    # before the last CURL_WRITEFUNC_PAUSE. curl re-delivers the entire paused
    # chunk from its first byte, so this offset is how the parser resumes
    # mid-chunk. Only meaningful between a pause and the re-delivery it produced.
    chunk_skip::Int64

    # Total bytes of completed-but-undelivered response messages currently
    # queued for the pump. Atomic because its two writers hold different locks:
    # complete_streaming_message! increments under grpc.lock (write_callback
    # always runs under it), while the pump decrements without it. When this
    # exceeds RECV_BACKPRESSURE_BYTES the receive direction pauses, which bounds
    # client memory under a stalled consumer regardless of message size or
    # stream length.
    recv_queued_bytes::Base.Threads.Atomic{Int64}

    # Set by read_callback once curl has taken every byte of the request upload buffer, so
    # the request pump knows the buffer is free and it may stage the next batch. Flow
    # control only: what keeps the pump's write from racing a read_callback is `lock`
    curl_done_reading::Event

    # Response headers
    grpc_status::Int64
    grpc_message::String

    # The gRPCCURL handle this request was made on, needed by grpc_cancel and the deadline
    # watchdog. Typed Any because gRPCCURL is defined later in this file.
    grpc::Any

    # Set (under grpc.lock) once cleanup_request has run, making completion, cancellation,
    # and shutdown mutually idempotent
    completed::Bool

    # Client-side deadline watchdog, see the comment in the constructor
    timer::Union{Nothing, Timer}

    # Repeating un-pause for a request-streaming call on a libcurl whose send pause also
    # blocks the receive direction, `nothing` everywhere else (every other kind of call, and
    # every libcurl from 8.6.0 on). See CURL_SEND_PAUSE_BLOCKS_RECV_BELOW.
    unpause::Union{Nothing, Timer}

    # Absolute `time()` at which this request's deadline expires, Inf when there is no
    # deadline. grpc_async_await uses it to attribute a transport error that landed after
    # the deadline to DEADLINE_EXCEEDED rather than INTERNAL: when libcurl tears a
    # transfer down at CURLOPT_TIMEOUT_MS it usually reports CURLE_OPERATION_TIMEDOUT,
    # but on some platforms the socket error from the teardown surfaces first instead.
    expiry::Float64

    # The caller's response channel, set by grpc_async_request right after
    # construction for the variants that spawn a response pump, NOCHANNEL
    # everywhere else. Typed Any rather than a Union to keep it out of the
    # positional constructors above: only cleanup_request reads it.
    #
    # Exists so an abnormal end (cancellation, deadline, handle shutdown) can
    # unblock a response pump that is stuck in put! to a channel the caller
    # stopped draining — grpc_cancel's documented "all tasks waiting on the
    # request (including streaming channels) are unblocked". Closing the user
    # channel wakes that put! with InvalidStateException, which the pump treats
    # as its normal exit. A normal completion must NOT close it from here: the
    # pump still has to deliver everything it buffered, and only then closes
    # the channel itself in its finally block.
    response_user_c::Any

    function gRPCRequest(
            grpc,
            url::String,
            request::IOBuffer,
            response::IOBuffer,
            request_c::Union{Channel{IOBuffer}, NoChannel},
            response_c::Union{Channel{IOBuffer}, NoChannel},
            options::gRPCConnectionOptions;
            kws...
        )

        options = _merge_options(options, kws)

        # Exception contract: grpc_async_request throws only for programming errors it
        # can detect synchronously at submission (an uninitialized or shut-down handle
        # as FAILED_PRECONDITION, an invalid deadline as INVALID_ARGUMENT, an oversized
        # message as RESOURCE_EXHAUSTED at encode). Failures that depend on time or
        # concurrency (deadline exceeded, cancellation, transport errors, server
        # statuses) are raised by grpc_async_await instead, keeping each exception type
        # in the location callers have always handled it.
        !grpc.running && throw(
            gRPCServiceCallException(
                GRPC_FAILED_PRECONDITION,
                "gRPCCURL backend is not running, did you forget to call grpc_init()?",
            ),
        )

        deadline = options.deadline

        # A deadline of Inf means no deadline: no watchdog, no curl timeouts, and no
        # grpc-timeout header (per the gRPC spec an absent header means no deadline).
        # Such a request runs until it completes, grpc_cancel is called, or the handle
        # is shut down. NaN, -Inf, and any negative deadline are programming errors, so
        # they throw here rather than in await. Negative values must be rejected before
        # the watchdog Timer below, which would otherwise raise a bare ArgumentError on
        # a negative interval instead of the INVALID_ARGUMENT the contract promises. A
        # deadline of exactly 0 is legal and expires immediately, surfacing as
        # DEADLINE_EXCEEDED from await like any other expiry.
        deadline == Inf || (isfinite(deadline) && deadline >= 0) || throw(
            gRPCServiceCallException(
                GRPC_INVALID_ARGUMENT,
                "deadline must be a non-negative finite number of seconds or Inf, got $(deadline)",
            ),
        )

        # The deadline covers the entire call starting now: time spent queued waiting for
        # one of the max_streams slots counts against it, and the transfer only gets
        # whatever budget remains after the wait.
        expiry = time() + deadline

        # One watchdog covers both phases of the call, and is armed before the queue wait
        # so a request can never block past its deadline. While the request is queued
        # (req not yet assigned below) firing wakes the semaphore waiters so an expired
        # waiter can give up; once the request is in flight it cancels the transfer.
        #
        # The in-flight case is the important one: libcurl only enforces
        # CURLOPT_TIMEOUT_MS / CURLOPT_CONNECTTIMEOUT_MS for handles it is actively
        # driving. A handle parked while waiting for another handle's connection to
        # become multiplexable (CURLOPT_PIPEWAIT) does not re-enter libcurl's state
        # machine until that connection makes progress, so if the connection never
        # becomes ready (server accepts TCP but never completes the HTTP/2 handshake,
        # stalled connect, etc.) the parked handle's timeout never fires, the request
        # wedges forever, and its max_streams slot leaks. This watchdog is the
        # client-side backstop for that: if libcurl has not completed the request
        # shortly after the deadline, cancel it with DEADLINE_EXCEEDED.
        local req = nothing
        watchdog = if deadline == Inf
            nothing
        else
            Timer(deadline + GRPC_DEADLINE_GRACE) do _
                try
                    # Wake all queue waiters so any expired one can bail out. Cheap: this
                    # only runs when a request actually times out, and waiters that are
                    # not expired just go back to sleep. Taking the condition lock also
                    # fences the read of `req` below against its assignment in the
                    # constructor.
                    lock(grpc.sem_cond) do
                        notify(grpc.sem_cond; all = true)
                    end

                    r = req
                    r isa gRPCRequest && grpc_cancel(
                        r,
                        gRPCServiceCallException(
                            GRPC_DEADLINE_EXCEEDED,
                            "Deadline exceeded.",
                        ),
                    )
                catch err
                    @error("deadline watchdog: unexpected error", err, maxlog = 1_000)
                end
            end
        end

        # Take one of the max_streams slots or block until one frees up, giving up at the
        # deadline. The slot carries a recycled curl_done_reading Event, which avoids
        # allocating one per request (a 7% reduction in allocations overall).
        curl_done_reading = try
            max_reqs_dec(grpc, expiry)
        catch ex
            isnothing(watchdog) || close(watchdog)
            # Only a deadline expiry while queued becomes an await-raised dead request;
            # a shutdown while queued propagates as FAILED_PRECONDITION from submission,
            # matching the contract above
            (ex isa gRPCServiceCallException && ex.grpc_status == GRPC_DEADLINE_EXCEEDED) ||
                rethrow()
            return gRPCRequest(
                grpc,
                url,
                request,
                response,
                request_c,
                response_c,
                ex,
                options,
                expiry,
            )
        end

        # The transfer gets the budget the queue wait did not use. max_reqs_dec only
        # checks expiry while the queue is non-empty, so re-check here.
        remaining = expiry - time()
        if remaining <= 0
            isnothing(watchdog) || close(watchdog)
            max_reqs_inc(grpc, curl_done_reading)
            return gRPCRequest(
                grpc,
                url,
                request,
                response,
                request_c,
                response_c,
                gRPCServiceCallException(
                    GRPC_DEADLINE_EXCEEDED,
                    "Deadline exceeded while queued waiting for an available stream.",
                ),
                options,
                expiry,
            )
        end

        easy_handle = curl_easy_init()

        # Set the GRPC_CURL_VERBOSE environment variable to get libcurl debug output
        haskey(ENV, "GRPC_CURL_VERBOSE") &&
            curl_easy_setopt(easy_handle, CURLOPT_VERBOSE, UInt32(1))

        curl_easy_setopt(easy_handle, CURLOPT_URL, url)
        # With no deadline (remaining == Inf) pass 0: for CURLOPT_TIMEOUT_MS that
        # disables curl's overall timeout, and for CURLOPT_CONNECTTIMEOUT_MS it falls
        # back to curl's default connect timeout (300s), a sane floor to keep even for
        # a request with no deadline
        timeout_ms = isfinite(remaining) ? Clong(ceil(1000 * remaining)) : Clong(0)
        curl_easy_setopt(easy_handle, CURLOPT_TIMEOUT_MS, timeout_ms)
        curl_easy_setopt(easy_handle, CURLOPT_CONNECTTIMEOUT_MS, timeout_ms)
        curl_easy_setopt(easy_handle, CURLOPT_PIPEWAIT, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_POST, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_CUSTOMREQUEST, "POST")

        if startswith(url, "http://")
            curl_easy_setopt(
                easy_handle,
                CURLOPT_HTTP_VERSION,
                CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE,
            )
        elseif startswith(url, "https://")
            curl_easy_setopt(easy_handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS)
        end

        headers = C_NULL
        headers = curl_slist_append(headers, "User-Agent: $(USER_AGENT)")
        headers = curl_slist_append(headers, "Content-Type: application/grpc+proto")
        headers = curl_slist_append(headers, "Content-Length:")
        headers = curl_slist_append(headers, "te: trailers")
        # The server is told the remaining budget, not the original deadline: any time
        # this request already spent queued client-side is gone. With no deadline the
        # header is omitted entirely, which the gRPC spec defines as "no deadline".
        if isfinite(remaining)
            headers = curl_slist_append(
                headers,
                "grpc-timeout: $(grpc_timeout_header_val(remaining))",
            )
        end
        if !isnothing(options.token)
            headers = curl_slist_append(headers, "authorization: Bearer $(options.token)")
        end
        if !isnothing(options.metadata)
            for k in (collect(keys(options.metadata)))
                headers = curl_slist_append(headers, "$k: $(options.metadata[k])")
            end
        end
        curl_easy_setopt(easy_handle, CURLOPT_HTTPHEADER, headers)

        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPALIVE, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPINTVL, options.keepalive)
        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPIDLE, options.keepalive)

        req = new(
            grpc.lock,
            easy_handle,
            grpc.multi,
            headers,
            url,
            request,
            0,
            response,
            request_c,
            response_c,
            Event(),
            UInt32(0),
            zeros(UInt8, CURL_ERROR_SIZE),
            options.max_send_message_length,
            options.max_recieve_message_length,
            nothing,
            false,
            false,
            false,
            0,
            false,
            0,
            Base.Threads.Atomic{Int64}(0),
            curl_done_reading,
            GRPC_OK,
            "",
            grpc,
            false,
            watchdog,
            nothing,
            expiry,
            NOCHANNEL,
        )
        preserve_handle(req)

        # Arm the repeating un-pause once `req` exists. Only a request-streaming call ever
        # pauses the send direction, and only an affected libcurl needs shaking loose.
        if NEEDS_UNPAUSE_WORKAROUND[] && isstreaming_request(req)
            req.unpause = Timer(
                GRPC_UNPAUSE_INTERVAL;
                interval = GRPC_UNPAUSE_INTERVAL,
            ) do _
                try
                    lock(grpc.lock) do
                        # cleanup_request runs under this lock and frees the easy handle,
                        # so re-check both before touching it
                        (req.completed || !grpc.running) && return
                        curl_easy_pause(req.easy, CURLPAUSE_CONT)
                    end
                catch err
                    @error("streaming un-pause: unexpected error", err, maxlog = 1_000)
                end
            end
        end

        req_p = pointer_from_objref(req)
        curl_easy_setopt(easy_handle, CURLOPT_PRIVATE, req_p)

        errbuf_p = pointer(req.errbuf)
        curl_easy_setopt(easy_handle, CURLOPT_ERRORBUFFER, errbuf_p)

        write_cb =
            @cfunction(write_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
        curl_easy_setopt(easy_handle, CURLOPT_WRITEFUNCTION, write_cb)
        curl_easy_setopt(easy_handle, CURLOPT_WRITEDATA, req_p)

        read_cb =
            @cfunction(read_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
        curl_easy_setopt(easy_handle, CURLOPT_READFUNCTION, read_cb)
        curl_easy_setopt(easy_handle, CURLOPT_READDATA, req_p)

        # set header callback
        header_cb =
            @cfunction(header_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))

        curl_easy_setopt(easy_handle, CURLOPT_HEADERFUNCTION, header_cb)
        curl_easy_setopt(easy_handle, CURLOPT_HEADERDATA, req_p)
        curl_easy_setopt(easy_handle, CURLOPT_UPLOAD, true)

        lock(grpc.lock) do
            if !grpc.running
                # We did all that work for nothing, and now we have to cleanup. A
                # shut-down handle is a submission-time FAILED_PRECONDITION per the
                # contract at the top of this constructor.
                isnothing(watchdog) || close(watchdog)
                isnothing(req.unpause) || close(req.unpause)
                curl_easy_cleanup(easy_handle)
                curl_slist_free_all(headers)
                unpreserve_handle(req)
                # *MUST* increment the sem or we could deadlock
                max_reqs_inc(grpc, req)

                throw(
                    gRPCServiceCallException(
                        GRPC_FAILED_PRECONDITION,
                        "Tried to make a request when the provided grpc handle is shutdown",
                    ),
                )
            end

            push!(grpc.requests, req)
            curl_multi_add_handle(grpc.multi, easy_handle)

            # If the watchdog fired in the window between the queue wait and this
            # registration it saw `req` unset and cancelled nothing; a fired one-shot
            # Timer is no longer open, so catch that case here (grpc_cancel is a
            # no-op if it raced a concurrent completion)
            if !isnothing(watchdog) && !isopen(watchdog)
                grpc_cancel(
                    req,
                    gRPCServiceCallException(GRPC_DEADLINE_EXCEEDED, "Deadline exceeded."),
                )
            end
        end

        return req
    end

    # Build an already-completed request that only carries an exception. Used when the
    # deadline expires while queued for a max_streams slot, before the request ever
    # reaches libcurl: submission still returns a gRPCRequest and DEADLINE_EXCEEDED is
    # raised from grpc_async_await, where callers have always handled it (see the
    # exception contract in the primary constructor). Holds no easy handle and no
    # max_streams slot, is never added to grpc.requests, and is already marked
    # completed so cleanup_request and grpc_cancel are no-ops on it.
    function gRPCRequest(
            grpc,
            url::String,
            request::IOBuffer,
            response::IOBuffer,
            request_c::Union{Channel{IOBuffer}, NoChannel},
            response_c::Union{Channel{IOBuffer}, NoChannel},
            ex::Exception,
            options::gRPCConnectionOptions,
            expiry::Float64,
        )
        req = new(
            grpc.lock,
            Ptr{Cvoid}(0),
            grpc.multi,
            C_NULL,
            url,
            request,
            0,
            response,
            request_c,
            response_c,
            Event(),
            UInt32(0),
            UInt8[],
            options.max_send_message_length,
            options.max_recieve_message_length,
            ex,
            false,
            false,
            true,
            0,
            false,
            0,
            Base.Threads.Atomic{Int64}(0),
            Event(),
            GRPC_OK,
            "",
            grpc,
            true,
            nothing,
            nothing,
            expiry,
            NOCHANNEL,
        )

        # Unblock stream pumps and anything already waiting on the request. The pumps
        # check req.ex before touching the easy handle, so they exit without side effects.
        close(req.response_c)
        close(req.request_c)
        notify(req.ready)

        return req
    end
end

function handle_exception(req::gRPCRequest, ex; notify_ready = false)
    # We want to record the *first* exception a request encounters
    # This helps identify the root cause of why something failed
    return if isnothing(req.ex)
        req.ex = ex
        notify_ready && notify(req.ready)
    end
end


isstreaming_request(req::gRPCRequest) = !isa(req.request_c, NoChannel)
isstreaming_response(req::gRPCRequest) = !isa(req.response_c, NoChannel)


Base.wait(req::gRPCRequest) = wait(req.ready)

# Hand a fully received response message off to the `grpc_async_stream_response` task
# and reset the parser for the next one. Only valid for a response-streaming request:
# a unary response is left in `req.response` for `grpc_async_await` to decode.
function complete_streaming_message!(req::gRPCRequest)
    # Charge the message against the byte-based backpressure budget as it is
    # handed off; handle_streaming_write consults the budget between frames to
    # decide whether to pause the receive direction
    atomic_add!(req.recv_queued_bytes, Int64(req.response.size))
    # Put the completed response protobuf buffer in the channel so it can be processed
    # by the `grpc_async_stream_response` task
    seekstart(req.response)
    put!(req.response_c, req.response)

    # There might be another response after this one so reset the parser state
    req.response = IOBuffer()
    req.response_read_header = false
    req.response_compressed = false
    req.response_length = 0

    return nothing
end

function handle_write(
        req::gRPCRequest,
        buf::Vector{UInt8},
    )::Tuple{Int64, Union{Nothing, Vector{UInt8}}}
    if !req.response_read_header
        header_bytes_left = GRPC_HEADER_SIZE - req.response.size

        if length(buf) < header_bytes_left
            # Not enough data yet to read the entire header
            return write(req.response, buf), nothing
        else
            buf_header = buf[1:header_bytes_left]
            n = write(req.response, buf_header)

            # Read the header
            seekstart(req.response)
            req.response_compressed = read(req.response, UInt8) > 0
            req.response_length = ntoh(read(req.response, UInt32))

            if req.response_compressed
                handle_exception(
                    req,
                    gRPCServiceCallException(
                        GRPC_UNIMPLEMENTED,
                        "Response was compressed but compression is not currently supported.",
                    ),
                )

                # If we are response streaming unblock the task waiting on response_c
                close(req.response_c)
                notify(req.ready)
                return n, nothing
            elseif req.response_length > req.max_recieve_message_length
                handle_exception(
                    req,
                    gRPCServiceCallException(
                        GRPC_RESOURCE_EXHAUSTED,
                        "length-prefix longer than max_recieve_message_length: $(req.response_length) > $(req.max_recieve_message_length)",
                    ),
                )
                # If we are response streaming unblock the task waiting on response_c
                close(req.response_c)
                notify(req.ready)
                return n, nothing
            end

            req.response_read_header = true
            seekstart(req.response)
            truncate(req.response, 0)

            # A zero-length message is complete the moment its length-prefix is
            # parsed: an all-default protobuf (`google.protobuf.Empty`, a message
            # whose every field holds its default) encodes to no bytes at all, so
            # there is no body to wait for. Emit it here instead of letting it fall
            # through to the message path below, which would have to complete a
            # message without consuming any of this chunk. That keeps handle_write
            # always consuming at least one byte per call, and delivers the message
            # even when its prefix is the last thing that arrives on the wire.
            req.response_length == 0 &&
                isstreaming_response(req) &&
                complete_streaming_message!(req)

            buf_leftover = nothing

            if (leftover_bytes = length(buf) - header_bytes_left) > 0
                # Handle the remaining data
                buf_leftover = unsafe_wrap(Array, pointer(buf) + n, (leftover_bytes,))
            end

            return n, buf_leftover
        end
    end

    # Already read the header
    message_bytes_left = req.response_length - req.response.size

    # Not enough bytes to complete the message
    length(buf) < message_bytes_left && return write(req.response, buf), nothing

    if isstreaming_response(req)
        # Write just enough to complete the message
        buf_complete = unsafe_wrap(Array, pointer(buf), (message_bytes_left,))
        n = write(req.response, buf_complete)

        complete_streaming_message!(req)

        # Handle the remaining data
        leftover_bytes = length(buf) - n

        buf_leftover = nothing
        if leftover_bytes > 0
            buf_leftover = unsafe_wrap(Array, pointer(buf) + n, (leftover_bytes,))
        end

        return n, buf_leftover
    else
        # We only expect a single response for non-streaming RPC
        if length(buf) > message_bytes_left
            handle_exception(
                req,
                gRPCServiceCallException(
                    GRPC_RESOURCE_EXHAUSTED,
                    "Response was longer than declared in length-prefix.",
                ),
            )
            notify(req.ready)
            return 0, nothing
        end

        n = write(req.response, buf)
        seekstart(req.response)

        return n, nothing
    end

end


function timer_callback(multi_h::Ptr{Cvoid}, timeout_ms::Clong, grpc_p::Ptr{Cvoid})::Cint
    try
        grpc = unsafe_pointer_to_objref(grpc_p)::gRPCCURL
        @assert multi_h == grpc.multi

        stoptimer!(grpc)

        if timeout_ms >= 0
            grpc.timer = Timer(timeout_ms / 1000) do timer
                lock(grpc.lock) do
                    if grpc.running
                        curl_multi_socket_action(
                            grpc.multi,
                            CURL_SOCKET_TIMEOUT,
                            0,
                            Ref{Cint}(),
                        )
                        check_multi_info(grpc)
                    end
                end
            end
        end

        return 0
    catch err
        @error("timer_callback: unexpected error", err = err, maxlog = 1_000)
        return -1
    end
end


mutable struct CURLWatcher
    sock::curl_socket_t
    fdw::FDWatcher
    ready::Event
    running::Bool


    function CURLWatcher(sock, fdw)
        event = Event()
        notify(event)
        return new(sock, fdw, event, true)
    end
end

Base.isreadable(w::CURLWatcher) = w.fdw.readable
Base.iswritable(w::CURLWatcher) = w.fdw.writable
function Base.close(w::CURLWatcher)
    w.running = false
    notify(w.ready)
    return close(w.fdw)
end


function socket_callback(
        easy_h::Ptr{Cvoid},
        sock::curl_socket_t,
        action::Cint,
        grpc_p::Ptr{Cvoid},
        socket_p::Ptr{Cvoid},
    )::Cint
    try
        if action ∉ (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT, CURL_POLL_REMOVE)
            @error("socket_callback: unexpected action", action, maxlog = 1_000)
            return -1
        end

        grpc = unsafe_pointer_to_objref(grpc_p)::gRPCCURL

        # If we shut down the multi, tell curl
        !grpc.running && return -1

        if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
            readable = action in (CURL_POLL_IN, CURL_POLL_INOUT)
            writable = action in (CURL_POLL_OUT, CURL_POLL_INOUT)

            watcher = lock(grpc.watchers_lock) do
                if grpc.running
                    if sock in keys(grpc.watchers)

                        # We already have a watcher for this sock
                        watcher = grpc.watchers[sock]

                        # Reset the ready event and trigger an EOFError
                        reset(watcher.ready)
                        close(watcher.fdw)

                        # Update the FDWatcher with the new flags
                        watcher.fdw = FDWatcher(
                            CROSS_PLATFORM_OS_HANDLE(sock),
                            readable,
                            writable,
                        )

                        # Start waiting on the socket with the new flags
                        notify(watcher.ready)

                        nothing
                    else
                        # Don't have a watcher, create one and start a task
                        watcher = CURLWatcher(
                            sock,
                            FDWatcher(CROSS_PLATFORM_OS_HANDLE(sock), readable, writable),
                        )
                        grpc.watchers[sock] = watcher

                        watcher
                    end
                end
            end

            isnothing(watcher) && return 0

            task = _spawn(grpc) do
                while watcher.running && grpc.running
                    # Watcher configuration might be changed, wait until its safe to wait on the watcher
                    wait(watcher.ready)

                    events = try
                        wait(watcher.fdw)
                    catch err
                        err isa EOFError && continue
                        err isa Base.IOError || rethrow()
                        FileWatching.FDEvent()
                    end

                    readable = isreadable(events)
                    writable = iswritable(events)

                    # On a libcurl that clobbers its own select bits, a socket action
                    # carrying only CURL_CSELECT_OUT throws away the CURL_CSELECT_IN that
                    # libcurl staked for input it has already buffered internally, and the
                    # transfer never surfaces it. Claim readability in exactly that case, so
                    # the action ORs in the bit libcurl is waiting for instead of erasing it.
                    # See CURL_SELECT_BITS_CLOBBERED_FROM. Costs one extra recv attempt on an
                    # affected libcurl, which returns EAGAIN when there is genuinely nothing
                    # to read, the same as any spurious wake-up.
                    if NEEDS_SELECT_BITS_WORKAROUND[] && writable && !readable
                        readable = true
                    end

                    flags =
                        CURL_CSELECT_IN * readable +
                        CURL_CSELECT_OUT * writable +
                        CURL_CSELECT_ERR * (events.disconnect || events.timedout)

                    lock(grpc.lock) do
                        # Be careful to not do anything with the grpc handle if its already been shutdown
                        if grpc.running
                            status = curl_multi_socket_action(
                                grpc.multi,
                                sock,
                                flags,
                                Ref{Cint}(),
                            )
                            @assert status == CURLM_OK "curl_multi_socket_action returned a status other than CURLM_OK(0): $status"
                            check_multi_info(grpc)
                        end
                    end
                end

                # If the multi handle was shutdown, return without doing any operations on it
                !grpc.running && return

                # When we shut down the watcher do the check_multi_info in this task to avoid creating a new one
                lock(grpc.lock) do
                    # Be careful to not do anything with the grpc handle if its already been shutdown
                    grpc.running && check_multi_info(grpc)
                end
            end
            @isdefined(errormonitor) && errormonitor(task)
        else
            lock(grpc.watchers_lock) do
                # Its possible this was already cleaned up if close() was called on the gRPCCURL, check to avoid race condition
                if sock ∈ keys(grpc.watchers)
                    # Shut down and cleanup the watcher for this socket
                    watcher = grpc.watchers[sock]
                    close(watcher)
                    delete!(grpc.watchers, sock)
                end
            end
        end

        return 0
    catch err
        @error("socket_callback: unexpected error", err = err, maxlog = 1_000)
        return -1
    end
end


function grpc_multi_init(grpc)
    grpc.multi = curl_multi_init()

    grpc_p = pointer_from_objref(grpc)

    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    curl_multi_setopt(grpc.multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    curl_multi_setopt(grpc.multi, CURLMOPT_TIMERDATA, grpc_p)

    socket_cb = @cfunction(
        socket_callback,
        Cint,
        (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid})
    )
    curl_multi_setopt(grpc.multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    return curl_multi_setopt(grpc.multi, CURLMOPT_SOCKETDATA, grpc_p)
end


mutable struct gRPCCURL
    # libcurl multi handle
    multi::Ptr{Cvoid}
    # *ALL* operations on the multi handle, any easy handles added to the multi, or this struct must acquire this lock.
    lock::ReentrantLock
    timer::Union{Nothing, Timer}
    watchers::Dict{curl_socket_t, CURLWatcher}
    # Reduce lock contention by giving watchers their own lock
    watchers_lock::ReentrantLock
    running::Bool
    requests::Vector{gRPCRequest}
    # The maximum number of concurrent gRPC requests/streams
    max_streams::Int64
    # Semaphore limiting concurrency to max_streams. sem_free holds one recycled
    # curl_done_reading Event per free slot; sem_cond guards it and queues waiters.
    # A plain Condition (rather than a Channel) so waiters can be woken to re-check
    # their own deadline or a shutdown, not only when a slot frees up.
    sem_cond::Threads.Condition
    sem_free::Vector{Event}
    # Selects the concurrency model for tasks spawned by this handle. When true,
    # tasks are sticky (`@async`, a coroutine model incompatible with
    # multithreading). When false (the default), tasks are migratable
    # (`Threads.@spawn`, a multithreading model).
    sticky::Bool

    function gRPCCURL(;
            max_streams::Int = GRPC_MAX_STREAMS,
            running = true,
            sticky::Bool = false,
        )
        grpc = new(
            Ptr{Cvoid}(0),
            ReentrantLock(),
            nothing,
            Dict{curl_socket_t, CURLWatcher}(),
            ReentrantLock(),
            running,
            Vector{gRPCRequest}(),
            max_streams,
            Threads.Condition(),
            Event[],
            sticky,
        )

        # Finalizers may not block on locks or yield, and close(x) does both (grpc.lock,
        # watchers_lock, sem_cond, closing channels and timers), so delegate the close
        # to a freshly spawned task per the Julia manual's finalizer guidance. In
        # practice this backstop only ever runs for handles that were already closed or
        # never opened: open(grpc) calls preserve_handle(grpc), so an open handle is
        # never garbage collected. An unreferenced handle cannot be reopened, so the
        # already-closed check needs no lock, and it avoids spawning a task from the
        # finalizer of every already-shutdown handle.
        finalizer(grpc) do x
            x.multi == Ptr{Cvoid}(0) && return
            t = _spawn(() -> close(x); sticky = x.sticky)
            @isdefined(errormonitor) && errormonitor(t)
            nothing
        end

        # This is used for the global const gRPCCURL handle
        # grpc_init() is called automatically via __init__() when the package is loaded
        !running && return grpc

        open(grpc)

        return grpc
    end
end

# Spawn a task using the concurrency model configured on the handle. Supports
# do-block syntax: `_spawn(grpc) do ... end`.
_spawn(f, grpc::gRPCCURL) = _spawn(f; sticky = grpc.sticky)

function Base.close(grpc::gRPCCURL)
    grpc.running = false

    ret = lock(grpc.lock) do
        # Already closed
        if grpc.multi == Ptr{Cvoid}(0)
            true
        else
            while length(grpc.requests) > 0
                request = pop!(grpc.requests)
                cleanup_request(grpc, request)
            end

            curl_multi_cleanup(grpc.multi)
            grpc.multi = Ptr{Cvoid}(0)

            # Close any pending libcurl timeout Timer. Without this the last scheduled Timer stays
            # open after shutdown, which leaks a libuv handle: `grpc.running` and the multi handle
            # are gone, but the Timer keeps the event loop alive. That makes precompilation of any
            # package that issues a gRPC call in its workload hang ("waiting for IO to finish").
            # Done under grpc.lock, matching how timer_callback assigns grpc.timer.
            stoptimer!(grpc)

            false
        end
    end

    ret && return

    lock(grpc.watchers_lock) do
        # Cleanup watchers
        while length(grpc.watchers) > 0
            _, watcher = pop!(grpc.watchers)
            close(watcher)
        end
    end

    # Wake anything queued on the semaphore so it can observe the shutdown
    lock(grpc.sem_cond) do
        notify(grpc.sem_cond; all = true)
    end

    unpreserve_handle(grpc)

    return nothing
end

function Base.open(grpc::gRPCCURL)
    return lock(grpc.lock) do
        if grpc.multi == Ptr{Cvoid}(0)
            lock(grpc.watchers_lock) do
                # Guarantee that we start with a clean slate
                grpc.watchers = Dict{curl_socket_t, CURLWatcher}()
            end

            lock(grpc.sem_cond) do
                grpc.sem_free = Event[Event() for _ in 1:grpc.max_streams]
            end

            grpc.requests = Vector{gRPCRequest}()
            grpc.timer = nothing

            grpc.running = true
            grpc_multi_init(grpc)
            preserve_handle(grpc)
        end
    end
end


# Take a slot (an Event from the freelist) or block until one frees up, giving up with
# DEADLINE_EXCEEDED once `expiry` (an absolute time() value) passes. Waiters are woken by
# max_reqs_inc when a slot frees, by any request's deadline watchdog firing, and by
# close(grpc), and re-check their own condition on every wake.
function max_reqs_dec(grpc::gRPCCURL, expiry::Float64)
    return lock(grpc.sem_cond) do
        while isempty(grpc.sem_free)
            grpc.running || throw(
                gRPCServiceCallException(
                    GRPC_FAILED_PRECONDITION,
                    "The grpc handle was shutdown while the request was queued",
                ),
            )
            time() >= expiry && throw(
                gRPCServiceCallException(
                    GRPC_DEADLINE_EXCEEDED,
                    "Deadline exceeded while queued waiting for an available stream.",
                ),
            )
            wait(grpc.sem_cond)
        end
        return pop!(grpc.sem_free)
    end
end

function max_reqs_inc(grpc::gRPCCURL, event::Event)
    lock(grpc.sem_cond) do
        push!(grpc.sem_free, event)
        # Hand the slot to one waiter. If that waiter's deadline expired in the meantime
        # it takes the slot, notices, and returns it here, passing the wake-up on.
        notify(grpc.sem_cond; all = false)
    end
    return nothing
end

function max_reqs_inc(grpc::gRPCCURL, req::gRPCRequest)
    return if isstreaming_request(req)
        # The request-stream pump may still be waiting on (or about to wait on) this
        # request's curl_done_reading Event. Notify it so the pump wakes and observes
        # req.completed, and hand the freelist a fresh Event so a lingering pump can
        # never interfere with the next request that takes this slot.
        notify(req.curl_done_reading)
        max_reqs_inc(grpc, Event())
    else
        # Reset before we recycle
        reset(req.curl_done_reading)
        max_reqs_inc(grpc, req.curl_done_reading)
    end
end

function cleanup_request(grpc::gRPCCURL, req::gRPCRequest)
    # Idempotent under grpc.lock: normal completion (check_multi_info), the deadline
    # watchdog / grpc_cancel, and close(grpc) can all race to clean up the same request
    req.completed && return
    req.completed = true
    # Stop the deadline watchdog
    isnothing(req.timer) || close(req.timer)
    # Stop the repeating un-pause. It is a *repeating* Timer, so leaving it open would keep
    # the libuv event loop alive for the rest of the process.
    isnothing(req.unpause) || close(req.unpause)
    # First remove from the multi
    curl_multi_remove_handle(grpc.multi, req.easy)
    # Cleanup the easy handle
    curl_easy_cleanup(req.easy)
    # Defense in depth on top of the completed flag: if any future path reaches the
    # easy handle after cleanup, libcurl rejects C_NULL with an error code instead of
    # touching freed memory
    req.easy = C_NULL
    # Free the request headers
    curl_slist_free_all(req.headers)
    # Allow this to be GC now that there is no risk of use in C callback
    unpreserve_handle(req)
    # Close streaming channels
    close(req.response_c)
    close(req.request_c)
    # An abnormal end (cancellation, deadline expiry, handle shutdown) must also
    # unblock a response pump stalled in put! to a caller channel nobody is
    # draining: closing it wakes the pump, which exits through its InvalidStateException
    # path and closes the channel itself in its finally. A normal completion leaves the
    # caller's channel alone so the pump can deliver everything it buffered first.
    # grpc.running is already false by the time close(grpc) reaches here.
    (!isnothing(req.ex) || !grpc.running) && close(req.response_user_c)
    # Increment the request semaphore to allow more requests through
    max_reqs_inc(grpc, req)
    # Unblock anything waiting on the request
    return notify(req.ready)
end

"""
    grpc_cancel(req::gRPCRequest[, ex::Exception])

Gracefully cancel an in-flight request. The easy handle is removed from the libcurl multi,
aborting the transfer, all tasks waiting on the request (including streaming channels) are
unblocked, and `grpc_async_await` will throw `ex`, a CANCELLED `gRPCServiceCallException`
by default.

Safe to call at any time from any task. Returns `true` when this call performed the
cancellation and `false` when the request had already completed (or the handle was already
shut down), in which case nothing changes.
"""
function grpc_cancel(
        req::gRPCRequest,
        ex::Exception = gRPCServiceCallException(
            GRPC_CANCELLED,
            "Request was cancelled by the client.",
        ),
    )
    grpc = req.grpc::gRPCCURL
    return lock(grpc.lock) do
        # Already completed, or the whole handle was shut down: nothing to cancel
        (req.completed || !grpc.running) && return false

        handle_exception(req, ex)

        # cleanup_request removes the easy handle from the multi, which is libcurl's
        # documented way to abort an in-flight transfer, then unblocks all waiters
        cleanup_request(grpc, req)

        idx = findfirst(x -> x === req, grpc.requests)
        !isnothing(idx) && deleteat!(grpc.requests, idx)

        return true
    end
end

struct CURLMsg
    msg::CURLMSG
    easy::Ptr{Cvoid}
    code::CURLcode
end

function check_multi_info(grpc::gRPCCURL)
    while true
        p = curl_multi_info_read(grpc.multi, Ref{Cint}())
        p == C_NULL && return
        message = unsafe_load(convert(Ptr{CURLMsg}, p))
        if message.msg == CURLMSG_DONE
            # When requests go according to plan, we clean up after them and notify any tasks waiting on them here
            easy_handle = message.easy
            req_p_ref = Ref{Ptr{Cvoid}}()
            curl_easy_getinfo(easy_handle, CURLINFO_PRIVATE, req_p_ref)
            req = unsafe_pointer_to_objref(req_p_ref[])::gRPCRequest
            @assert easy_handle == req.easy
            req.code = message.code

            # The actual cleanup/notification happens here
            cleanup_request(grpc, req)

            # Remove from the list of requests associated (in-place, no allocation)
            idx = findfirst(x -> x === req, grpc.requests)
            !isnothing(idx) && deleteat!(grpc.requests, idx)
        else
            @error("curl_multi_info_read: unknown message", message, maxlog = 1_000)
        end
    end
    return
end


function stoptimer!(grpc::gRPCCURL)
    t = grpc.timer
    if t !== nothing
        grpc.timer = nothing
        close(t)
    end
    return nothing
end
