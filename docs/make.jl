using Documenter
using DocumenterCodeBlocks
using DocumenterLandingPage
using gRPCClient

makedocs(
    sitename = "gRPCClient.jl",
    format = Documenter.HTML(),
    modules = [gRPCClient],
    plugins = [LandingPage(), CodeBlocks()],
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Guide" => [
            "Setup API" => "guide/setup-api.md",
            "RPC API" => "guide/rpc-api.md",
            "Error Handling" => "guide/errors.md",
            "Raw Buffers" => "guide/raw-buffers.md",
            "Concurrency" => "guide/concurrency.md",
        ],
        "Legacy API" => "legacy.md",
        "gRPCClientUtils.jl" => "utils.md",
        "For LLMs & Agents" => "agents.md",
    ],
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(repo = "github.com/JuliaIO/gRPCClient.jl.git")
