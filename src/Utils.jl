function nullstring(x::Vector{UInt8})
    first_zero_idx = findfirst(==(0), x)
    isnothing(first_zero_idx) && return ""
    String(x[1:(first_zero_idx-1)])
end

# Spawn a task either sticky (pinned to the spawning thread, like `@async`,
# a coroutine model good for IO-bound work and compatible with a single thread)
# or migratable (`Threads.@spawn`, enabling multithreading for CPU-bound work).
# This is the single seam the `gRPCCURL` `sticky` policy flows through. The
# handle- and client-typed methods (defined alongside those types) source
# `sticky` from `grpc.sticky`, so call sites need not reach into the handle.
function _spawn(f; sticky::Bool = false)
    if sticky
        return @async f()
    else
        return Threads.@spawn f()
    end
end

# On Windows x64 OS_HANDLE does not like curl_sock_t (Int32)
function CROSS_PLATFORM_OS_HANDLE(sock::curl_socket_t)
    fd = @static if Sys.iswindows()
        Ptr{Cvoid}(Int(sock))
    else
        sock
    end
    OS_HANDLE(fd)
end
