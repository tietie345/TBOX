#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH_PATH="$PROJECT_DIR/.build"
MODULE_CACHE="${TMPDIR:-/tmp}/tbox_swiftpm_module_cache"

mkdir -p "$MODULE_CACHE"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build \
  --package-path "$PROJECT_DIR" \
  --scratch-path "$SCRATCH_PATH" \
  --cache-path "$SCRATCH_PATH/cache" \
  --config-path "$SCRATCH_PATH/config" \
  --security-path "$SCRATCH_PATH/security" \
  --disable-sandbox \
  -c debug \
  --product TBOX

BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build \
  --package-path "$PROJECT_DIR" \
  --scratch-path "$SCRATCH_PATH" \
  --cache-path "$SCRATCH_PATH/cache" \
  --config-path "$SCRATCH_PATH/config" \
  --security-path "$SCRATCH_PATH/security" \
  --disable-sandbox \
  -c debug \
  --show-bin-path)"

echo "编译成功: $BIN_PATH/TBOX"
