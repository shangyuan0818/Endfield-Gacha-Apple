#!/usr/bin/env bash
# 本仓库的回归测试。可以在【没有 Xcode 的机器上】跑 —— 这正是它存在的理由:
# 统计核心与 JSON 定位逻辑是纯 C++, 不需要 Apple SDK 就能验证。
# macOS + Swift 6.2 环境还会验证真实 ObjC → Swift 占位桥接，其余环境明确跳过。
#
# 用法:
#   Tests/run.sh            编译并运行全部测试
#   Tests/run.sh --clean    先清掉 Tests/build 再跑
#
# 覆盖范围与限制见 Tests/README.md。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD="Tests/build"

if [[ "${1:-}" == "--clean" ]]; then rm -rf "$BUILD"; fi
mkdir -p "$BUILD"

CXX="${CXX:-clang++}"
if ! command -v "$CXX" >/dev/null 2>&1; then CXX=g++; fi
if ! command -v "$CXX" >/dev/null 2>&1; then
    echo "找不到 C++ 编译器 (clang++ / g++)" >&2
    exit 1
fi

# Sanitizer 能用就开; 某些精简环境缺 libclang_rt, 缺了就降级为普通构建。
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
if ! echo 'int main(){}' | "$CXX" -x c++ -std=c++20 $SAN -o "$BUILD/.santest" - >/dev/null 2>&1; then
    echo "[run] 当前环境不支持 sanitizer, 降级为普通构建"
    SAN=""
fi
rm -f "$BUILD/.santest"

echo "[run] 抽取 .mm 里的纯 C++ 核心"
python3 Tests/extract_mm_core.py "$BUILD"

FLAGS=(-std=c++20 -Wall -Wextra -g -DFIXTURE_DIR='"Tests/fixtures"')
rc=0
for t in json_scan_tests fetch_session_tests analyzer_tests; do
    echo "[run] 编译 $t"
    # shellcheck disable=SC2086
    "$CXX" "${FLAGS[@]}" $SAN -o "$BUILD/$t" "Tests/$t.cpp"
    echo "[run] 运行 $t"
    if ! "$BUILD/$t"; then rc=1; fi
done

# Swift 部分: 配置迁移逻辑是纯 Foundation 的, 有 swiftc 就一并跑; 没有就跳过。
if command -v swiftc >/dev/null 2>&1; then
    echo "[run] 编译并运行 app_config_tests (Swift)"
    swiftc -O -o "$BUILD/app_config_tests" \
        Endfield-Gacha/Shared/AppConfigMigration.swift Tests/app_config_tests.swift
    if ! "$BUILD/app_config_tests"; then rc=1; fi
else
    echo "[run] 没有 swiftc, 跳过 app_config_tests (在 macOS / 装了 Swift 工具链的机器上会跑)"
fi

# 这一层必须编译 Foundation/ObjC，纯 C++ 抽取测试覆盖不到。
if bash Tests/run_placeholder_bridge_tests.sh; then
    :
else
    bridge_rc=$?
    if [[ $bridge_rc -ne 77 ]]; then rc=1; fi
fi

if [[ $rc -eq 0 ]]; then echo; echo "[run] 已运行的测试全部通过（跳过项见上方输出）"; else echo; echo "[run] 有测试失败"; fi
exit $rc
