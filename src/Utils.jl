function nullstring(x::Vector{UInt8})
    first_zero_idx = findfirst(==(0), x)
    isnothing(first_zero_idx) && return ""
    String(x[1:(first_zero_idx-1)])
end

# On Windows OS_HANDLE does not like curl_sock_t (Int32)
# Convert it to a pointer instead
CROSS_PLATFORM_OS_HANDLE(sock) = OS_HANDLE(Sys.iswindows() ? Ptr{Cvoid}(Int(sock)) : sock)
