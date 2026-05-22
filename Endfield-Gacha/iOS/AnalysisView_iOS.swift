//
//  AnalysisView_iOS.swift
//  Endfield-Gacha (iOS)
//
//  分析 Tab:
//    - 顶部:摘要卡片 (2x2 关键数字, 一眼看到结论)
//    - 中部:可折叠的"详细文本输出"
//    - 下半:4 张图
//        iPhone (compact)  -> 纵向堆叠
//        iPad/横屏 (regular) -> 2x2 网格
//    - 工具栏:导入按钮 (.fileImporter,等价 macOS 的拖拽)
//
//  数据来源:
//    1) 用户点导入,弹文件选择器
//    2) 拉取 Tab 完成后通过 pendingPath 推送过来
//
//  注意:iOS 安全作用域 URL 必须 startAccessingSecurityScopedResource()
//  才能读;这里在分析期间持有,完成后 stop。
//

#if !os(macOS)

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AnalysisView_iOS: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.horizontalSizeClass) private var hSize

    /// 来自拉取 Tab 的待分析路径。消费一次后置 nil。
    @Binding var pendingPath: String?

    @State private var outputText: String = "点击右上角「导入」选择 UIGF JSON 文件,\n或在「拉取」标签页从 URL 抓取数据"
    @State private var analysis: AnalysisBundle? = nil
    @State private var isProcessing: Bool = false
    @State private var showImporter: Bool = false
    @State private var showRawText: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isProcessing {
                        ProgressView("分析中...")
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if let a = analysis {
                        // 摘要卡片 2x2
                        SummaryCardsView(charts: a)
                            .padding(.horizontal)

                        // 折叠详细统计: 三个卡池卡片 (特许 / 辉光 / 武器),
                        // iOS 上结构化排版替代原 PC 风格的等宽对齐文本。
                        // v0.1.2.0: 加辉光庆典卡片.
                        DisclosureGroup(isExpanded: $showRawText) {
                            VStack(spacing: 12) {
                                PoolDetailCard(
                                    poolName: "角色卡池 (特许寻访)",
                                    stats: a.statsChar,
                                    kind: .character
                                )
                                PoolDetailCard(
                                    poolName: "角色卡池 (辉光庆典)",
                                    stats: a.statsJoint,
                                    kind: .joint
                                )
                                PoolDetailCard(
                                    poolName: "武器卡池 (武库申领)",
                                    stats: a.statsWep,
                                    kind: .weapon
                                )
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("详细统计", systemImage: "doc.text")
                                .font(.subheadline)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)

                        // 6 张图布局 (v0.1.2.0, 从 4 张扩到 6 张):
                        //   iPad (regular): 2x3 网格 (3 行 × 2 列, 每行一个池)
                        //   iPhone (compact): 纵向堆叠 6 张
                        let layout: ChartGridLayout =
                            (hSize == .regular) ? .grid2x2Fixed : .vertical
                        ChartGridView(statsChar:  a.statsChar,
                                      statsJoint: a.statsJoint,
                                      statsWep:   a.statsWep,
                                      layout: layout)
                            .padding(.horizontal)
                    } else {
                        // 空态
                        ContentUnavailableView {
                            Label("等待分析数据", systemImage: "chart.bar.doc.horizontal")
                        } description: {
                            Text(outputText)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        } actions: {
                            Button {
                                showImporter = true
                            } label: {
                                Label("导入 UIGF JSON",
                                      systemImage: "tray.and.arrow.down.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(minHeight: 360)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("抽卡分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down.fill")
                    }
                    .disabled(isProcessing)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    runAnalysisWithSecurityScope(url: url)
                case .failure(let err):
                    outputText = "选择文件失败: \(err.localizedDescription)"
                }
            }
            // 接收来自拉取 Tab 的待分析路径
            .onChange(of: pendingPath) { _, newPath in
                guard let p = newPath else { return }
                pendingPath = nil  // 消费一次,避免重入
                let url = URL(fileURLWithPath: p)
                runAnalysisWithSecurityScope(url: url)
            }
        }
    }

    /// 包装:获取安全作用域 → 分析 → 释放
    /// iOS 沙盒外的文件(用户从"文件"App 选的)必须这样访问,否则读不到内容。
    private func runAnalysisWithSecurityScope(url: URL) {
        // 注意:不能在 defer 里 stop,因为分析是异步的。
        // 必须在异步任务完成后再 stop。
        let needsAccess = url.startAccessingSecurityScopedResource()

        isProcessing = true
        analysis = nil
        outputText = "正在分析 \(url.lastPathComponent)..."

        let path = url.path
        let chars = config.chars
        let pool  = config.pool
        let weps  = config.weps

        DispatchQueue.global(qos: .userInitiated).async {
            let bundle = AnalyzerBridge.analyze(
                filePath: path, chars: chars, poolMap: pool, weapons: weps
            )
            DispatchQueue.main.async {
                self.outputText = bundle.outputText
                self.analysis = bundle.charts
                self.isProcessing = false
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }
}

// MARK: - 摘要卡片(2x2)
//
// 把分析结果中最关键的 4 个指标做成卡片,iPhone 上信息密度高且一眼可见。
// 选取标准:用户最关心 + 与 4 张图分别呼应。
private struct SummaryCardsView: View {
    let charts: AnalysisBundle

    var body: some View {
        // 用 Grid 而非 LazyVGrid:
        //   v0.1.2.0: 从 2x2 扩到 3x2, 加辉光庆典池摘要行.
        //   只有 6 张卡片, lazy 加载没有意义。LazyVGrid 在 ScrollView 中
        //   遇到快速滚动/切 Tab 时, 某些 cell 会出现"内容为空但占位还在"的渲染 bug,
        //   尤其是 cell 用了 .regularMaterial 这种需要离屏采样的复杂背景。
        //   Grid 一次性渲染全部 cell,没有卸载/加载的状态切换,从源头消除该 bug。
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                // 1. 特许角色总样本量 + 平均抽数
                StatCard(
                    title: "特许 · 总样本",
                    value: "\(charts.statsChar.count_all)",
                    subtitle: String(format: "平均 %.2f 抽 / 6★",
                                     charts.statsChar.avg_all)
                )
                // 2. 特许角色 50/50 不歪率
                StatCard(
                    title: "特许 · 不歪率",
                    value: rateString(charts.statsChar.win_rate_5050),
                    subtitle: "\(charts.statsChar.win_5050) 中 / \(charts.statsChar.win_5050 + charts.statsChar.lose_5050) 总"
                )
            }
            GridRow {
                // 3. 辉光庆典池总样本 (v0.1.2.0)
                StatCard(
                    title: "辉光 · 总样本",
                    value: "\(charts.statsJoint.count_all)",
                    subtitle: String(format: "平均 %.2f 抽 / 6★",
                                     charts.statsJoint.avg_all)
                )
                // 4. 辉光池非常驻六星率 (每个 6 星独立 50% 出限定, 跟武器池 UP 率同语义)
                StatCard(
                    title: "辉光 · 非常驻率",
                    value: rateString(jointUpRate(charts.statsJoint)),
                    subtitle: "\(charts.statsJoint.win_5050) 限定 / \(charts.statsJoint.win_5050 + charts.statsJoint.lose_5050) 总"
                )
            }
            GridRow {
                // 5. 武器总样本
                StatCard(
                    title: "武器 · 总样本",
                    value: "\(charts.statsWep.count_all)",
                    subtitle: String(format: "平均 %.2f 抽 / 6★",
                                     charts.statsWep.avg_all)
                )
                // 6. 特许角色 UP K-S 正态性 (v0.1.1 起改用 UP):
                //    UP 涉及 50% 歪率 + 各自硬保底, 比综合六星更复杂,
                //    KS 偏离度更能反映"运气是否反常"。
                //    综合六星机制本身简单(纯 hazard 函数), 偏离度本身信息量较少。
                //    若 UP 数据为 0, 降级显示综合 6 星 KS。
                //
                //    标题与其他卡片保持 "主体 · 指标" 命名格式对齐。
                //    标题随数据源动态切换:
                //      有 UP 数据 → "特许 · UP 正态性",副标题 "UP D = 0.xxx"
                //      降级综合 → "特许 · 正态性",  副标题 "综合 D = 0.xxx"
                StatCard(
                    title: ksDisplayTitle(charts.statsChar),
                    value: ksDisplayValue(charts.statsChar),
                    subtitle: ksDisplaySubtitle(charts.statsChar),
                    tint: ksDisplayTint(charts.statsChar)
                )
            }
        }
    }

    /// 辉光池非常驻六星率: count_up / count_all (跟武器池 UP 率同算法).
    /// 没有"歪/不歪"概念, win_5050 直接 = count_up (限定数).
    private func jointUpRate(_ s: ChartData) -> Double {
        guard s.count_all > 0 else { return -1 }
        return Double(s.count_up) / Double(s.count_all)
    }

    /// UP KS 标题: 与其他卡片 "主体 · 指标" 格式对齐。
    /// 有 UP 数据时主体为 "特许 · UP 正态性",降级时为 "特许 · 正态性",
    /// 与下方 ksDisplaySubtitle 的 "UP D" / "综合 D" 始终保持一致。
    private func ksDisplayTitle(_ s: ChartData) -> String {
        s.count_up > 0 ? "特许 · UP 正态性" : "特许 · 正态性"
    }

    /// UP KS 主显示: 优先用 UP, 数据不足降级综合
    private func ksDisplayValue(_ s: ChartData) -> String {
        if s.count_up > 0 { return s.ks_is_normal_up ? "符合" : "偏离" }
        return s.ks_is_normal ? "符合" : "偏离"
    }
    private func ksDisplaySubtitle(_ s: ChartData) -> String {
        if s.count_up > 0 {
            return String(format: "UP D = %.3f", s.ks_d_up)
        }
        return String(format: "综合 D = %.3f", s.ks_d_all)
    }
    private func ksDisplayTint(_ s: ChartData) -> Color {
        let normal = (s.count_up > 0) ? s.ks_is_normal_up : s.ks_is_normal
        return normal ? .primary : .orange
    }

    private func rateString(_ r: Double) -> String {
        r < 0 ? "—" : String(format: "%.1f%%", r * 100)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // 用语义色而非 .regularMaterial:
        //   1) 材质背景需要离屏采样下方像素做模糊, 是渲染最贵的部分,
        //      在快速滚动 + Tab 切换组合下偶发"上下层错位"的渲染 bug;
        //   2) 纯色 secondarySystemBackground 是 iOS 标准卡片背景色
        //      (设置 App 等系统应用都用它), 暗色模式下接近 #1C1C1E,
        //      视觉上与材质几乎一致, 但稳定性高得多。
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - 详细统计:卡池卡片
//
// 把原 C++ 输出的 PC 风格等宽对齐报表,在移动端重排成结构化卡片。
// 完全从 ChartData 直接读取数值,不解析任何文本。
//
// 设计要点:
//   - header: 卡池名 + 总抽数 / UP 数 / 当前垫刀(精简一行)
//   - 数据行: 用左标签 + 右数值的 HStack,可换行,但数字保持等宽对齐
//   - 子注释(理论 / CV / KS / CI 等)用 Text 的 secondary 样式压低视觉权重
//   - 等宽数字用 .monospacedDigit() 而非整体 .monospaced(),
//     中文字符仍走系统字体,避免 monospace 中文的丑陋渲染
private struct PoolDetailCard: View {
    enum Kind {
        case character  // 特许寻访: 显示"真实不歪率"
        case joint      // 辉光庆典: 显示"非常驻六星率" (v0.1.2.0)
        case weapon     // 武库申领: 显示"6 星中 UP 率"
    }

    let poolName: String
    let stats: ChartData
    let kind: Kind

    // 理论值常量(与 C++ 端格式串里的硬编码值一致)
    // 来源: AnalyzerWrapper.mm 中 FormatOutput 格式串
    private var theoryAvgAll: Double {
        switch kind {
        case .character: return 51.81
        case .joint:     return 51.81   // 辉光池综合 6 星与特许寻访同分布
        case .weapon:    return 19.17
        }
    }
    private var theoryAvgUp: Double {
        switch kind {
        case .character: return 74.33
        case .joint:     return 103.62  // 辉光池首限定期望 (E[首6星]/0.5)
        case .weapon:    return 81.66
        }
    }
    private var theoryUpRate: Double {
        switch kind {
        case .character, .joint: return 0.50
        case .weapon:            return 0.25
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ---- Header ----
            HStack(alignment: .firstTextBaseline) {
                Text(poolName)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(stats.count_all) 总 / \(stats.count_up) UP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // 当前垫刀
            HStack(spacing: 12) {
                pityChip(label: "距上次六星", value: stats.censored_pity_all)
                pityChip(label: "距上次 UP",  value: stats.censored_pity_up)
            }
            .padding(.bottom, 2)

            Divider()

            // ---- 数据行 ----
            // 综合六星出货均值: count_all=0 时 avg_all 是未定义的(0 是 sentinel,
            // 不是"均值是 0 抽"). 用 "—" 占位; CV 和 95% CI 同理在零样本下未定义,
            // hint 也精简到只剩理论值.
            DetailRow(
                label: "综合六星出货均值",
                value: stats.count_all > 0
                    ? String(format: "%.2f 抽", stats.avg_all)
                    : "—",
                hint: stats.count_all > 0
                    ? String(format: "理论 %.2f · CV %.1f%% · 95%% CI [%.1f, %.1f]",
                             theoryAvgAll,
                             stats.cv_all * 100,
                             max(0, stats.avg_all - stats.ci_all_err),
                             stats.avg_all + stats.ci_all_err)
                    : String(format: "理论 %.2f", theoryAvgAll)
            )

            // K-S 检验 (综合六星): count_all=0 时 ks_d_all 未定义 (0 是 sentinel,
            // 不是"D 偏离度是 0"). hint 描述 "符合理论模型" 也只在有样本时才有意义,
            // 零样本下既无法计算 D 也无法判断符合/偏离, 全部用占位.
            DetailRow(
                label: "综合六星 K-S 偏离度",
                value: stats.count_all > 0
                    ? String(format: "D = %.3f", stats.ks_d_all)
                    : "—",
                hint: stats.count_all > 0
                    ? (stats.ks_is_normal ? "符合理论模型" : "偏离理论模型")
                    : "样本不足, 无法判断",
                valueTint: stats.count_all > 0
                    ? (stats.ks_is_normal ? .primary : .orange)
                    : .primary
            )

            // 抽到 UP / 限定 平均: 同上, count_up=0 时 avg_up 未定义.
            // 辉光池没有"当期 UP"概念 (4 个 6 星里 2 限定 2 常驻),
            // 文案改成"抽到限定(非常驻)均值"语义更准确.
            DetailRow(
                label: kind == .joint ? "抽到限定(非常驻)均值" : "抽到 UP 综合均值",
                value: stats.count_up > 0
                    ? String(format: "%.2f 抽", stats.avg_up)
                    : "—",
                hint: stats.count_up > 0
                    ? String(format: "理论 %.2f · 95%% CI [%.1f, %.1f]",
                             theoryAvgUp,
                             max(0, stats.avg_up - stats.ci_up_err),
                             stats.avg_up + stats.ci_up_err)
                    : String(format: "理论 %.2f", theoryAvgUp)
            )

            // K-S 检验 (UP / 限定 六星): 与综合六星 KS 行紧邻,
            // 用户能直接对比"机制大盘 vs 当期"是否各自符合理论模型.
            // count_up=0 时 ks_d_up 未定义, 同样用占位.
            DetailRow(
                label: kind == .joint ? "限定六星 K-S 偏离度" : "UP 六星 K-S 偏离度",
                value: stats.count_up > 0
                    ? String(format: "D = %.3f", stats.ks_d_up)
                    : "—",
                hint: stats.count_up > 0
                    ? (stats.ks_is_normal_up ? "符合理论模型" : "偏离理论模型")
                    : "样本不足, 无法判断",
                valueTint: stats.count_up > 0
                    ? (stats.ks_is_normal_up ? .primary : .orange)
                    : .primary
            )

            // 不歪率(角色 特许) / 非常驻率(辉光) / 6 星 UP 率(武器)
            switch kind {
            case .character:
                // 无样本时 win_rate_5050 / avg_win 在 C++ 端为 sentinel -1,
                // 显示占位符 "—" 而非负数, 保持检测项完整可见.
                DetailRow(
                    label: "真实不歪率",
                    value: stats.win_rate_5050 >= 0
                        ? String(format: "%.1f%%", stats.win_rate_5050 * 100)
                        : "—",
                    hint: "理论 \(Int(theoryUpRate * 100))% · \(stats.win_5050) 胜 \(stats.lose_5050) 负"
                )
                DetailRow(
                    label: "赢下小保底均值",
                    value: stats.avg_win > 0
                        ? String(format: "%.2f 抽", stats.avg_win)
                        : "—",
                    hint: nil
                )
            case .joint:
                // 辉光池没有"小保底/大保底"概念, 每个 6 星独立 50% 出限定.
                // 显示"非常驻六星率"(限定 / 总 6 星), 跟武器池 UP 率同语义.
                // 无样本时显示占位符 "—" 而非 0.0%, 与"真实不歪率"对齐.
                let jointUpRate = stats.count_all > 0
                    ? Double(stats.win_5050) / Double(stats.count_all)
                    : 0
                DetailRow(
                    label: "非常驻六星率",
                    value: stats.count_all > 0
                        ? String(format: "%.1f%%", jointUpRate * 100)
                        : "—",
                    hint: "理论 \(Int(theoryUpRate * 100))% · \(stats.win_5050) 限定 / \(stats.lose_5050) 常驻"
                )
            case .weapon:
                // 无样本时显示占位符 "—", 与"真实不歪率" / 辉光"非常驻六星率"对齐.
                let upRate = stats.count_all > 0
                    ? Double(stats.win_5050) / Double(stats.count_all)
                    : 0
                DetailRow(
                    label: "6 星 UP 率",
                    value: stats.count_all > 0
                        ? String(format: "%.1f%%", upRate * 100)
                        : "—",
                    hint: "理论 \(Int(theoryUpRate * 100))% · \(stats.win_5050) UP / \(stats.lose_5050) 非 UP"
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // 垫刀 chip:简短的左右胶囊
    private func pityChip(label: String, value: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.bold())
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(uiColor: .tertiarySystemBackground))
        )
    }
}

// 单行数据展示: 左标签 / 右数值, 数值下方可选 hint
private struct DetailRow: View {
    let label: String
    let value: String
    let hint: String?
    var valueTint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.callout.bold())
                    .foregroundStyle(valueTint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }
}

#endif
