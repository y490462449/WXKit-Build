#!/usr/bin/env bash
# 用 Xcode 自带的 clang 直接编译出一个可注入的 dylib（不需要 Theos，不需要越狱）。
# 产物：build/WXKit.dylib —— 用 TrollFools 把它注入微信即可。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT_DIR="$ROOT/build"
mkdir -p "$OUT_DIR"

SOURCES=$(find src -name '*.m' | sort)
echo "== 源文件 =="
echo "$SOURCES"

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=14.0 \
    -isysroot "$SDK" \
    -dynamiclib \
    -fobjc-arc \
    -fmodules \
    -O2 \
    -install_name @executable_path/WXKit.dylib \
    -Isrc -Isrc/Core -Isrc/Features -Isrc/UI \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
    -Wno-unused-variable -Wno-deprecated-declarations \
    -o "$OUT_DIR/WXKit.dylib" \
    $SOURCES

echo "== 产物 =="
ls -lh "$OUT_DIR/WXKit.dylib"
echo "== 依赖库（应当只有系统库，不能出现 substrate / ellekit） =="
xcrun llvm-objdump --macho --dylibs-used "$OUT_DIR/WXKit.dylib"
echo
echo "下一步：把 WXKit.dylib 传到 iPhone（AirDrop / 存到「文件」），用 TrollFools 注入微信。"
echo "部署细节见 docs/TROLLSTORE.md。"
