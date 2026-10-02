using Documenter
using DocumenterLandingPage
using gRPCClient

pages = [
    "Home" => "index.md",
]

function flatten_pages(entries, prefix = "")
    flat = Pair{String,String}[]
    for (name, value) in entries
        if value isa AbstractString
            push!(flat, (isempty(prefix) ? name : prefix * " > " * name) => value)
        else
            append!(flat, flatten_pages(value, isempty(prefix) ? name : prefix * " > " * name))
        end
    end
    return flat
end

flat_pages = flatten_pages(pages)

open(joinpath(@__DIR__, "src", "llms.txt"), "w") do io
    println(io, "# gRPCClient.jl")
    println(io, "> A production grade gRPC client emphasizing performance and reliability.")
    println(io, "")
    println(io, "## Documentation Sections")
    for (name, path) in flat_pages
        println(io, "- [", name, "](", replace(path, ".md" => ".html"), ")")
    end
end

open(joinpath(@__DIR__, "src", "llms-full.txt"), "w") do io
    println(io, "# gRPCClient.jl Full Documentation")
    println(io, "> This file contains the complete documentation source for gRPCClient.jl.")
    println(io, "")
    for (name, path) in flat_pages
        src_path = joinpath(@__DIR__, "src", path)
        if isfile(src_path)
            println(io, "## Section: ", name)
            println(io, "<!-- Source: ", path, " -->")
            println(io, "")
            println(io, read(src_path, String))
            println(io, "\n---\n")
        end
    end
end

makedocs(
    sitename = "gRPCClient.jl",
    format = Documenter.HTML(;
        canonical = "https://JuliaIO.github.io/gRPCClient.jl",
        assets = String[],
    ),
    pages = pages,
    modules = [gRPCClient],
    plugins = [LandingPage()],
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(repo = "github.com/JuliaIO/gRPCClient.jl.git")
