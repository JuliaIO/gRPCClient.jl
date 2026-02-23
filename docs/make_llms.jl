using Documenter
using gRPCClient

makedocs(
    sitename = "gRPCClient.jl",
    # NOTE: This is not implemented in upstream Documenter.jl
    # I maintain my own fork that I use in order to produce Markdown output
    # https://github.com/csvance/Documenter.jl/tree/markdown-output
    format = Documenter.MarkdownDoc(),
    modules = [gRPCClient]
)