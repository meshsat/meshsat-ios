#!/usr/bin/env bash
# Regenerate the Swift protobuf sources from Vendor/protos into
# Packages/MeshSatKit/Sources/MeshSatProto/Generated. The generated files are
# committed, so neither CI nor a contributor needs protoc.
#
# Needs: protoc, and protoc-gen-swift from apple/swift-protobuf at the version
# pinned in Packages/MeshSatKit/Package.swift (the runtime and the plugin must
# match). On a Mac: brew install protobuf swift-protobuf.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Packages/MeshSatKit/Sources/MeshSatProto/Generated
rm -rf "$OUT"; mkdir -p "$OUT/meshtastic" "$OUT/takproto"
protoc -I Vendor/protos --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
  --swift_out="$OUT/meshtastic" Vendor/protos/meshtastic/*.proto
protoc -I Vendor/protos --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
  --swift_out="$OUT/takproto" Vendor/protos/takproto/*.proto
echo "generated:"; find "$OUT" -name '*.pb.swift' | sort
