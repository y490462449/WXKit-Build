# WXKit —— 微信增强插件（开源自用版）
#
# 两种构建方式：
#   1) 只做 TrollStore + TrollFools 注入：用 scripts/build-dylib.sh（纯 clang，不需要 Theos）
#   2) 越狱（Dopamine rootless）安装 .deb：用本 Makefile（需要 Theos）
#
# 说明：本项目不链接 CydiaSubstrate/ElleKit，全部用 Objective-C runtime 交换方法，
#      所以方式 1 产出的 dylib 在不越狱的设备上也能加载。

export THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS ?= arm64
export TARGET ?= iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXKit

WXKit_FILES = $(shell find src -name '*.m')
WXKit_CFLAGS = -fobjc-arc -Isrc -Isrc/Core -Isrc/Features -Isrc/UI -Wno-unused-variable -Wno-deprecated-declarations
WXKit_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore
WXKit_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat 2>/dev/null || true"
