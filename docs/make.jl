using Documenter
using gRPCClient

makedocs(
    sitename = "gRPCClient.jl",
    format = Documenter.HTML(),
    modules = [gRPCClient]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/JuliaComputing/gRPCClient.jl.git"
)
