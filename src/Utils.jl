function nullstring(x::Vector{UInt8})
    first_zero_idx = findfirst(==(0), x)
    isnothing(first_zero_idx) && return ""
    String(x[1:(first_zero_idx-1)])
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
