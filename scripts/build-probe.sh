#!/usr/bin/env bash
# 编译最小注入探针：只证明 dylib 能被加载进微信，不挂任何 hook。
# 产物：build/WXKitProbe.dylib
set -uo pipefail

STAGE="init"
on_error() {
    local code=$?
    echo ""
    echo "[WXKitProbe] ❌ BUILD FAILED at stage=${STAGE} line=${1} exit=${code}"
    exit "$code"
}
trap 'on_error $LINENO' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAGE="1/3 工具链"
echo "[WXKitProbe] 阶段 1/3：检查工具链"
command -v xcrun >/dev/null 2>&1 || { echo "找不到 xcrun"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT_DIR="${WXKIT_OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT_DIR"

STAGE="2/3 编译"
echo "[WXKitProbe] 阶段 2/3：编译 WXKitProbe.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -install_name @executable_path/WXKitProbe.dylib \
    -framework Foundation -framework UIKit -framework QuartzCore \
    -o "$OUT_DIR/WXKitProbe.dylib" \
    probe/WXKProbe.m

STAGE="3/3 完成"
test -f "$OUT_DIR/WXKitProbe.dylib" || { echo "没有产出探针 dylib"; exit 1; }
ls -lh "$OUT_DIR/WXKitProbe.dylib"
echo "[WXKitProbe] ✅ BUILD OK：${OUT_DIR}/WXKitProbe.dylib"
echo "[WXKitProbe] 下一步：先注它，微信里出现绿色横幅即说明注入链路 OK。"
