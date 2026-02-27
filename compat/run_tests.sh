#!/bin/bash
# Cross-validation test runner:
# 1. Go generates reference test vectors
# 2. Zig tests run (includes reading Go vectors + writing Zig vectors)
# 3. Go validates Zig-produced vectors
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Step 1: Generate Go test vectors ==="
(cd go && go run ./cmd/generate)

echo ""
echo "=== Step 2: Run Zig compat tests ==="
zig build test

echo ""
echo "=== Step 3: Validate Zig test vectors with Go ==="
(cd go && go run ./cmd/validate)

echo ""
echo "=== All cross-validation tests passed ==="
