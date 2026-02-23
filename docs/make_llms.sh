#!/bin/bash

julia --project=docs << EOF
using Pkg
Pkg.add(url="https://github.com/csvance/Documenter.jl", rev="markdown-output")
Pkg.develop(path=".")
EOF

julia --project=docs docs/make_llms.jl

julia --project=docs << EOF
using Pkg
Pkg.add("Documenter")
Pkg.rm("gRPCClient")
EOF