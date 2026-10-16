#!/usr/bin/env bash
# 用 Xcode 自带的 clang 直接编译出一个可注入的 dylib（不需要 Theos，不需要越狱）。
# 产物：build/WXKit.dylib —— 用 TrollFools 把它注入微信即可。
#
# 脚本按阶段执行并打印阶段标记：一旦失败，最后几行会明确写出
#   [WXKit] ❌ BUILD FAILED at stage=... line=...
# 这样即使只把日志最后几行发出来，也能定位问题。
set -uo pipefail

STAGE="init"
on_error() {
    local code=$?
    echo ""
    echo "[WXKit] ❌ BUILD FAILED at stage=${STAGE} line=${1} exit=${code}"
    echo "[WXKit] 把上面最后 30 行（或 artifact 里的 build-log.txt）发给维护者即可定位。"
    exit "$code"
}
trap 'on_error $LINENO' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 阶段 1/5：工具链 ----------
STAGE="1/5 工具链"
echo "[WXKit] 阶段 1/5：检查工具链"
command -v xcrun >/dev/null 2>&1 || { echo "[WXKit] 找不到 xcrun（这台机器没有 Xcode 命令行工具）"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "        SDK = ${SDK}"
xcrun --sdk iphoneos clang --version | head -n 3

OUT_DIR="${WXKIT_OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT_DIR"

SOURCES=$(find src -name '*.m' | sort)
SOURCE_COUNT=$(printf '%s\n' "$SOURCES" | grep -c '\.m$' || true)
echo "        源文件 ${SOURCE_COUNT} 个"

# ---------- 阶段 2/5：编译 ----------
STAGE="2/5 编译"
echo "[WXKit] 阶段 2/5：编译 WXKit.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -install_name @executable_path/WXKit.dylib \
    -Isrc -Isrc/Core -Isrc/Features -Isrc/UI \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
    -Wno-unused-variable -Wno-deprecated-declarations \
    -o "$OUT_DIR/WXKit.dylib" \
    $SOURCES
echo "[WXKit] 阶段 2/5：编译完成"

# ---------- 阶段 3/5：产物 ----------
STAGE="3/5 产物检查"
echo "[WXKit] 阶段 3/5：检查产物"
test -f "$OUT_DIR/WXKit.dylib" || { echo "[WXKit] 编译没有产出 dylib"; exit 1; }
ls -lh "$OUT_DIR/WXKit.dylib"
file "$OUT_DIR/WXKit.dylib" || true

# ---------- 阶段 4/5：依赖（信息性，失败不影响构建） ----------
STAGE="4/5 依赖报告"
echo "[WXKit] 阶段 4/5：依赖库（只作参考；这几行失败不算构建失败）"
if command -v otool >/dev/null 2>&1; then
    otool -L "$OUT_DIR/WXKit.dylib" || echo "        （otool 读取失败，忽略）"
else
    echo "        （没有 otool，跳过）"
fi

# ---------- 阶段 5/5：完成 ----------
STAGE="5/5 完成"
echo ""
echo "[WXKit] ✅ BUILD OK：${OUT_DIR}/WXKit.dylib"
echo "[WXKit] 下一步：把 dylib 传到 iPhone，用 TrollFools 注入微信。部署见 docs/TROLLSTORE.md。"
