#!/bin/bash
# TBOX 统一构建入口。实际构建、固定证书签名和单实例重启由 build_app.sh 完成。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$PROJECT_DIR/build_app.sh"
