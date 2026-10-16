#!/usr/bin/env bash
# 编译最小注入探针：只证明 dylib 能被加载进微信，不挂任何 hook。
# 产物：build/WXKitProbe.dylib —— 先用它验证 TrollFools 注入链路，再注完整版 WXKit。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT_DIR="$ROOT/build"
mkdir -p "$OUT_DIR"

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -fmodules \
    -O2 \
    -install_name @executable_path/WXKitProbe.dylib \
    -framework Foundation -framework UIKit -framework QuartzCore \
    -o "$OUT_DIR/WXKitProbe.dylib" \
    probe/WXKProbe.m

echo "== 探针产物 =="
ls -lh "$OUT_DIR/WXKitProbe.dylib"
xcrun llvm-objdump --macho --dylibs-used "$OUT_DIR/WXKitProbe.dylib"
echo
echo "下一步：把 WXKitProbe.dylib 注入微信，看到绿色横幅即说明注入链路 OK。"
