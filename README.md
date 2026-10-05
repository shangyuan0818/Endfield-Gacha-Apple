# Endfield-Gacha-Apple 终末地抽卡工具（macOS &amp; iOS）

Gacha tracker and visualizer for Arknights: Endfield on macOS &amp; iOS. Built with Swift 6 &amp; C++20.

《明日方舟：终末地》寻访(抽卡)数据保存，分析与可视化。使用 Swift 6 与 C++20 构建，提供 macOS 与 iOS 原生高效体验。



## Download / 下载
**App Store / 应用商店**: [寻访数据助理](https://apps.apple.com/us/app/gacha-tracker-for-endfield/id6763351725)


## How to use / 如何使用
### macOS
1. **Fetch Data / 拉取数据**:

   Click the fetch button in the toolbar. Drag your existing UIGF file into the drop zone as the baseline (optional), paste your gacha link and click 「开始」, then choose where to save the result. When the fetch finishes, click 「完成并分析」 to analyze it right away.

   点击工具栏的「拉取数据」按钮。拖入已有的 UIGF 文件作为基底（可选），粘贴抽卡链接并点击「开始」，然后选择保存位置。拉取完成后点击「完成并分析」即可直接分析。

2. **Analyze Data / 分析数据**:

   Drag a UIGF file into the window.

   拖拽 UIGF 文件到窗口。

### iPhone / iPad
1. **Fetch Data / 拉取数据**:

   Open the 「拉取」 tab, paste your gacha link, optionally tap 「选择基底 JSON」 to pick your existing UIGF file, then tap 「开始拉取」. When the fetch finishes, choose where to save the result; it is then analyzed automatically.

   打开「拉取」标签页，粘贴抽卡链接，可选地点击「选择基底 JSON」选取已有的 UIGF 文件，然后点击「开始拉取」。拉取完成后选择保存位置，保存后会自动进行分析。

2. **Analyze Data / 分析数据**:

   On the 「分析」 tab, tap 「导入 UIGF JSON」 and pick a UIGF file.

   在「分析」标签页点击「导入 UIGF JSON」并选取 UIGF 文件。

> [!IMPORTANT]
> The in-game headhunting record only covers **the last 90 days**. Records older than that are dropped
> by the official API and can never be fetched again. Each fetch merges incrementally into the UIGF file
> you supply as the baseline, so fetch regularly and keep that file — it is the only long-term archive
> of your pulls. If anything goes wrong during a fetch, the whole update is cancelled and your file is
> left untouched — just fetch again.
>
> 游戏内【寻访记录】只支持查询**最近 90 天**的记录，更早的记录会被官方接口丢弃且无法再取回。
> 每次拉取都是增量合并到你选定的基底 UIGF 文件，所以请定期拉取并保留该文件 —— 它是你抽卡历史的唯一长期存档。
> 拉取过程中任何一步出错，整次更新都会取消，文件保持原样，重新拉取即可。

> [!NOTE]
> The exported file also carries a non-standard top-level `non_pull_events` key. The official record API mixes
> non-pull events (such as the headhunting testimonial granted every 60 pulls) into the same list; they are kept
> verbatim under that key instead of the UIGF `list`, so `list` stays "one entry = one pull" for every other
> UIGF tool. Other tools can safely ignore the extra key.
>
> The `time` and `timezone` fields are always written in UTC+8, regardless of your device's time zone;
> `gacha_ts` is the exact timestamp.
>
> 导出的文件里还有一个非 UIGF 标准的顶层键 `non_pull_events`。官方记录接口会把非抽卡事件（例如每 60 抽发放的
> 【寻访情报书】）混在同一个列表里返回；这些事件被原样保存在该键下，而不是放进 UIGF 的 `list`，这样 `list` 对
> 所有第三方 UIGF 工具都保持「每一条都是一次抽卡」的语义。其它工具可以直接忽略这个键。
>
> 文件中的 `time` 与 `timezone` 固定按 UTC+8 写出，与设备所在的时区无关；精确时刻以 `gacha_ts` 为准。



## Compatibility / 兼容性
### macOS
- **OS / 系统**: macOS 14.0 or higher (Sonoma+). macOS 14.0或更高。
- **Architecture / 架构**: Universal Binary. 通用二进制。
- **Run Destination**: Any Mac (arm64, x86_64)
- **64-bit Only / 纯64位**: Some features of SwiftUI require at least macOS 14.0. In addition, macOS has dropped support for 32-bit (i386) applications since version 10.15. This tool is 64-bit only. 部分 SwiftUI 功能最低要求 macOS 14.0。此外，由于 macOS 10.15 后不再支持 32 位应用，本工具仅支持 64 位架构。

### iOS
- **OS / 系统**: iOS 18.0 or higher. iOS 18.0或更高。
- **Architecture / 架构**: arm64
- **Run Destination**: Any iOS Device (arm64)

> ### Windows
> Please check the Win32 version here 请查看该Win32版本: [Endfield-Gacha](https://github.com/shangyuan0818/Endfield-Gacha)



## Privacy Policy / 隐私政策

For details regarding data handling and usage, please refer to our [Privacy Policy](privacy-policy.md).

关于数据处理与使用的详细说明，请参阅我们的[隐私政策](privacy-policy.md)。
