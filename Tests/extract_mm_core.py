#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把两个 .mm 里的【纯 C++ 匿名 namespace】抽出来, 让没有 Apple SDK 的机器也能编译测试。

为什么要抽:
  AnalyzerWrapper.mm / FetchSession.mm 是 Objective-C++。统计核心与 JSON 定位逻辑都写在
  文件顶部的匿名 namespace 里, 那一段本身是纯 C++, 但整个文件需要 Foundation 才能编译。
  本脚本只截取 `namespace {` 到第一个 ObjC 相关标记之间的内容, 与真实源文件【逐字一致】——
  测试因此跑的是同一份实现, 而不是抄过来的副本。

限制 (务必知情):
  - 抽出来的只是匿名 namespace, ObjC 方法体 (prepare / ingestResponseData / writeExport)
    不在其中。所以这些测试覆盖的是"定位与判定"逻辑, 不是端到端的网络拉取与文件替换。
  - 真正的端到端验证需要 Xcode 里的 XCTest: 注入"成功第一页 + 损坏第二页", 断言本次失败
    且目标存档逐字节不变。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT  = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent / "build"

# (源文件, 结束标记, 输出名)
TARGETS = [
    ("Endfield-Gacha/ObjC/AnalyzerWrapper.mm", "// ------ 密封数据到 ObjC ------", "analyzer_core.inc"),
    ("Endfield-Gacha/ObjC/FetchSession.mm",    "// NSString <- std::string_view",  "fetch_core.inc"),
]

def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for rel, end_marker, out_name in TARGETS:
        src = (ROOT / rel).read_text(encoding="utf-8")
        try:
            start = src.index("namespace {")
            end = src.index(end_marker)
        except ValueError:
            print(f"[extract] 在 {rel} 里找不到抽取边界 —— 源文件结构变了, 请更新本脚本", file=sys.stderr)
            return 1
        if end <= start:
            print(f"[extract] {rel} 的结束标记出现在起始标记之前", file=sys.stderr)
            return 1
        (OUT / out_name).write_text(src[start:end], encoding="utf-8")
        print(f"[extract] {rel} -> {OUT / out_name}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
