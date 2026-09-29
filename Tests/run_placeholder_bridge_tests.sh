#!/usr/bin/env bash
# 原生 macOS 桥接测试；不具备 Apple SDK / Swift 默认隔离支持时退出 77（明确跳过）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/Tests/build/placeholder_bridge"

skip() {
    echo "[placeholder_bridge] SKIP: $*"
    exit 77
}

[[ "$(uname -s)" == Darwin ]] || skip "需要 macOS 的 Objective-C runtime 和 Apple SDK"
command -v xcrun >/dev/null 2>&1 || skip "找不到 xcrun，请安装支持 Swift 6.2 的 Xcode 工具链"
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || skip "找不到 macOS SDK"
CLANG="$(xcrun --sdk macosx --find clang++ 2>/dev/null)" || skip "找不到 Apple clang++"
SWIFTC="$(xcrun --sdk macosx --find swiftc 2>/dev/null)" || skip "找不到 Apple swiftc"
SWIFT_HELP="$("$SWIFTC" -help)"
[[ "$SWIFT_HELP" == *"-default-isolation"* ]] || \
    skip "Swift 工具链不支持 -default-isolation；需要 Swift 6.2+ 才能验证项目的 MainActor 默认隔离"

mkdir -p "$BUILD"
TARGET="$(uname -m)-apple-macosx14.0"
echo "[placeholder_bridge] 编译实际 AnalyzerWrapper.mm (ObjC++ / C++23)"
"$CLANG" -std=c++23 -fobjc-arc -isysroot "$SDK" -target "$TARGET" \
    -Wall -Wextra -g -c "$ROOT/Endfield-Gacha/ObjC/AnalyzerWrapper.mm" \
    -o "$BUILD/AnalyzerWrapper.o"

echo "[placeholder_bridge] 编译实际 AnalyzerBridge.swift (Swift 6 / 默认 MainActor)"
"$SWIFTC" -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
    -sdk "$SDK" -target "$TARGET" -parse-as-library -g \
    -module-cache-path "$BUILD/module-cache" \
    -import-objc-header "$ROOT/Endfield-Gacha/ObjC/AnalyzerWrapper.h" \
    "$ROOT/Endfield-Gacha/Shared/AnalyzerBridge.swift" \
    "$ROOT/Tests/placeholder_bridge_tests.swift" "$BUILD/AnalyzerWrapper.o" \
    -lc++ -framework Foundation -o "$BUILD/placeholder_bridge_tests"

echo "[placeholder_bridge] 运行独立进程的冷启动占位测试"
"$BUILD/placeholder_bridge_tests"
