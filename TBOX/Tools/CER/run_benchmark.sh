#!/bin/bash
# 录音转写 CER（字错率）回归基准。
#
# 目的：把 docs/TRANSCRIPTION.md 里「版本发布前 CER 不得退化超过 2 个百分点」
# 这条门槛变成可执行脚本，而不是靠人工记忆。
#
# 目录约定（Tools/CER/）：
#   fixtures/<name>.ref.txt   人工校对过的基准文本（UTF-8）
#   fixtures/<name>.<ext>     与基准同名的录音，ext ∈ caf/m4a/wav/mp3
#   baseline.tsv              已记录的基线，每行 `名称<TAB>CER`
#
# 用法：
#   Tools/CER/run_benchmark.sh                  # 比对当前结果与基线，退化 >2pp 报错
#   Tools/CER/run_benchmark.sh --update-baseline # 把当前结果写回基线
#
# 说明：该脚本会真实调用本地模型推理，首次运行需已下载模型；无基准录音时
# 打印提示并成功退出（不阻断其他检查）。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CER_DIR="$PROJECT_DIR/Tools/CER"
FIXTURE_DIR="$CER_DIR/fixtures"
BASELINE="$CER_DIR/baseline.tsv"
REGRESSION_LIMIT="0.02" # 2 个百分点

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

resolve_binary() {
    if [ -n "${TBOX_BIN:-}" ] && [ -x "${TBOX_BIN}" ]; then
        echo "${TBOX_BIN}"
        return 0
    fi
    local candidate
    for candidate in \
        "$PROJECT_DIR/.build/release/TBOX" \
        "$PROJECT_DIR/.build/debug/TBOX" \
        "$PROJECT_DIR/.build/arm64-apple-macosx/release/TBOX" \
        "$PROJECT_DIR/.build/arm64-apple-macosx/debug/TBOX"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if [ ! -d "$FIXTURE_DIR" ] || [ -z "$(ls -A "$FIXTURE_DIR" 2>/dev/null)" ]; then
    echo "跳过 CER 基准：未提供基准录音。"
    echo "  请按 Tools/CER/run_benchmark.sh 头部说明放入 fixtures/<name>.ref.txt 与同名录音。"
    exit 0
fi

if ! BINARY="$(resolve_binary)"; then
    echo "错误：未找到 TBOX 可执行文件。请先执行 ./compile.sh（或 ./build_app.sh）后重试。" >&2
    exit 2
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
MODULE_CACHE="${TMPDIR:-/tmp}/tbox_cer_module_cache"
mkdir -p "$MODULE_CACHE"
CER_BIN="$(mktemp -t tbox_cer)"
trap 'rm -f "$CER_BIN"' EXIT

swiftc -O -module-cache-path "$MODULE_CACHE" -target "$ARCH-apple-macosx14.0" -sdk "$SDK" \
    -o "$CER_BIN" "$CER_DIR/cer.swift"

echo "TBOX 可执行文件：$BINARY"

current_tsv="$(mktemp -t tbox_cer_current)"
trap 'rm -f "$CER_BIN" "$current_tsv"' EXIT

fixture_count=0
for ref in "$FIXTURE_DIR"/*.ref.txt; do
    [ -e "$ref" ] || continue
    name="$(basename "$ref" .ref.txt)"
    audio=""
    for ext in caf m4a wav mp3; do
        if [ -f "$FIXTURE_DIR/$name.$ext" ]; then
            audio="$FIXTURE_DIR/$name.$ext"
            break
        fi
    done
    if [ -z "$audio" ]; then
        echo "警告：基准 '$name' 缺少同名录音，跳过。" >&2
        continue
    fi

    echo "==> 转写 $name …"
    if ! "$BINARY" --transcribe-file "$audio" >/dev/null 2>&1; then
        echo "错误：'$name' 转写失败，无法计算 CER。" >&2
        exit 2
    fi
    transcript="$audio.transcript.json"
    if [ ! -f "$transcript" ]; then
        echo "错误：'$name' 未生成转写缓存 $transcript。" >&2
        exit 2
    fi

    cer="$("$CER_BIN" "$ref" "$transcript")"
    printf '%s\t%s\n' "$name" "$cer" >> "$current_tsv"
    printf '    CER = %s\n' "$cer"
    fixture_count=$((fixture_count + 1))
done

if [ "$fixture_count" -eq 0 ]; then
    echo "跳过 CER 基准：没有可用的 基准文本 + 录音 配对。"
    exit 0
fi

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    sort "$current_tsv" > "$BASELINE"
    echo "已更新基线：$BASELINE"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "未找到基线 $BASELINE。"
    echo "本次结果已作为参考，请执行 Tools/CER/run_benchmark.sh --update-baseline 记录正式基线。"
    exit 0
fi

status=0
while IFS=$'\t' read -r name cer; do
    [ -n "$name" ] || continue
    base="$(awk -F'\t' -v n="$name" '$1==n {print $2}' "$BASELINE" | head -1)"
    if [ -z "$base" ]; then
        echo "提示：'$name' 尚无基线记录（当前 CER=$cer）。"
        continue
    fi
    regression="$(awk -v b="$base" -v c="$cer" -v l="$REGRESSION_LIMIT" \
        'BEGIN { printf "%.6f", (c - b) - l }')"
    over="$(awk -v r="$regression" 'BEGIN { print (r > 0) ? 1 : 0 }')"
    if [ "$over" -eq 1 ]; then
        echo "退化：'$name' 基线 CER=$base，当前 CER=$cer，超出 2 个百分点门槛。" >&2
        status=1
    else
        echo "通过：'$name' 基线=$base 当前=$cer"
    fi
done < "$current_tsv"

exit "$status"
