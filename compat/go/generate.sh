#!/bin/bash
# Generate Go protobuf code from .proto files
# Proto files lack go_package options, so we use -M flags to set the import path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/../proto"
OUT_DIR="$SCRIPT_DIR/pb"

mkdir -p "$OUT_DIR"

# Build -M options for all proto files
M_OPTS=""
for proto in "$PROTO_DIR"/*.proto; do
    base="$(basename "$proto")"
    M_OPTS="$M_OPTS --go_opt=M${base}=compat/pb"
done

protoc \
    --go_out="$OUT_DIR" \
    --go_opt=paths=source_relative \
    $M_OPTS \
    -I "$PROTO_DIR" \
    "$PROTO_DIR"/*.proto

echo "Done. Generated files in $OUT_DIR/"
