#!/bin/bash

pushd python 
uv run -m grpc_tools.protoc -I ../proto --python_out=. --pyi_out=. --grpc_python_out=. ../proto/test.proto
popd

mkdir -p gen 

julia <<EOF 

using ProtoBuf
using gRPCClient
grpc_register_service_codegen()
protojl("proto/test.proto", ".", "gen")

EOF