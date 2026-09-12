# 回归测试

**不需要 Xcode。** 统计核心与 JSON 定位逻辑是纯 C++/纯 Foundation, 在任何装了
`clang++`(或 `g++`) 的机器上都能编译运行 —— 这正是这套测试存在的理由: 它覆盖的
恰好是那些「出错了界面上没有任何提示」的地方。

```sh
Tests/run.sh            # 编译并运行全部测试
Tests/run.sh --clean    # 先清掉 Tests/build 再跑
```

有 sanitizer 就自动开 `-fsanitize=address,undefined`(扫描器全是 `string_view`
下标运算, 越界一律当场炸); 环境缺 `libclang_rt` 会自动降级为普通构建。
装了 Swift 工具链还会额外跑配置迁移的测试, 没有就跳过并打印一行提示。

## 测什么

| 程序 | 被测对象 | 关注点 |
|---|---|---|
| `json_scan_tests` | `Endfield-Gacha/ObjC/JsonScan.h` | 扫描器的严格性边界 |
| `fetch_session_tests` | `FetchSession.mm` 的匿名 namespace | 存档定位、分页信封判读、字段读取 |
| `analyzer_tests` | `AnalyzerWrapper.mm` 的匿名 namespace | CDF 期望值、保底/删失、存档读取、配置切分口径 |
| `app_config_tests` | `Shared/AppConfigMigration.swift` | 配置迁移的幂等性与「不覆盖用户输入」 |

几条值得单独点名的不变量:

- **CDF 期望值钉死到小数点后四位**(51.8051 / 79.2914 / 19.1711 / 54.7370 /
  51.3708 / 77.8275 / 84.3666)。概率表改错不会崩溃, 只会让界面上的数字悄悄变成
  另一个游戏的数字。
- **武器池顺序数据与旧算法逐位一致**: 测试里现写了一份旧算法当参照物, 两边
  `freq_all[0..259]` 全等。按池分状态这次改动的前提就是"只修交错, 不动单池行为"。
- **`hasMore` 只按对象本层读, 绝不全文查找**: 根对象成员顺序变化不得影响判读
  (`page_root_flag_first/last.json` 是同一份数据的两种成员顺序)。
- **配置切分口径两侧对齐**: `analyzer_tests` 第九节与 `app_config_tests` 的
  `testPoolEntries` 是同一组用例 —— 全角逗号/冒号不是分隔符、只切第一个冒号、
  重复键先到先得、trim 只认 ASCII 空白。口径分叉会让迁移写出来的键在分析时查不到。
- **迁移幂等**: 每个用例都跑两遍, 第二遍必须一个字都不改。

## `Tests/fixtures/`

来自外部审查的反例, 逐份保留原文而不是在测试里内联字符串 —— 反例的价值在于
「当初真的能触发」, 改写过就不算数了。`*.invalid.json` 是故意不合法的。
`raw_nul_whitespace.invalid.json` 里含一个真正的 `NUL` 字节 (字符串外), 用来钉住
「裸 NUL 不算空白、不得当作合法文档尾」这一条 —— 不要用编辑器"顺手清理"它。

## `extract_mm_core.py`

两个 `.mm` 文件的纯 C++ 部分都在匿名 namespace 里, 而文件本身 `#import` 了
Foundation, 在 Linux 上编不过。这个脚本把匿名 namespace 的**原文**抽到
`Tests/build/*.inc`, 测试再 `#include` 它 —— 测的始终是仓库里那一份实现, 不是副本。
抽取失败(找不到起止标记)会直接报错退出, 不会静默测一份空文件。

同样的理由: `AppConfigMigration.swift` 之所以从 `AppConfig.swift` 里拆出来, 就是为了
让它只依赖 Foundation, `run.sh` 可以把**它本体**和测试一起 `swiftc` 编译。
`AppConfig.swift` 只剩 UserDefaults 读写与平台开关。

## 这套测试【不】覆盖的部分

诚实地列出来, 免得绿灯被当成"可以发版"的证据:

- **Swift/SwiftUI 与 Objective-C 的真实编译**。本仓库的 CI 环境没有 Xcode, 上面这些
  程序只编译两个 `.mm` 里的纯 C++ 片段和一个纯 Foundation 的 `.swift`。
  桥接头、`@Observable`、视图层的改动必须在 macOS 上用 Xcode 构建才算验证过。
- **网络与真实接口**。分页信封的判读是拿构造出来的 JSON 测的; 接口真实返回的形状
  变化只有联网跑一次才知道。
- **文件落盘**(`fsync` / `F_FULLFSYNC`)、UserDefaults 的真实读写、UI 行为。
- **端到端**: 从拉取到出图的整条链路没有测试, 需要在设备上手测。
