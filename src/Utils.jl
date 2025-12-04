function nullstring(x::Vector{UInt8})
    first_zero_idx = findfirst(==(0), x)
    isnothing(first_zero_idx) && return ""
    String(x[1:(first_zero_idx-1)])
end
