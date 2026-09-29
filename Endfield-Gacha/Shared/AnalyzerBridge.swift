//
//  AnalyzerBridge.swift
//  Endfield-Gacha
//
//  调用 ObjC 接口(GachaAnalyzerWrapper / GachaFetcherWrapper),
//  把 GachaAnalysisResult / GachaChartData 转成 Swift 原生类型给 Canvas 用。
//  Swift 侧不直接接触任何 C++ 类型。
//
//  跨平台改造说明:
//    - 原 AnalysisBundleResult.charts 引用了 ContentView.AnalysisBundle,
//      但 ContentView 是 macOS 专属。iOS 端拿不到这个嵌套类型。
//    - 解决方案:把 AnalysisBundle 从 ContentView 内部提到顶层共享位置,
//      macOS 的 ContentView 与 iOS 的 AnalysisView_iOS 都直接用顶层类型。
//    - 改动后,AnalysisBundle 是一个独立的、跨平台的值类型。
//

import Foundation

// 由统计核心同时计算 D 和最大偏差位置，图表不再用另一套口径重算。
struct KSMarkerData: Sendable {
    var d: Double = 0
    var x: Int = 0
    var empirical: Double = 0
    var theory: Double = 0
}

// MARK: - Chart 数据(Swift 原生)
//
// Sendable: 显式声明这是线程安全的值类型, 切断 @MainActor 隔离推断的传染。
// 字段默认值只供非隔离的桥接转换初始化；视图占位统一从后端取得完整理论。
struct ChartData: Sendable {
    // v0.1.2.0: 数组从 150 扩到 260, 容纳辉光池 0..240 的 pity 范围.
    var freq_all:   [Int32]  = Array(repeating: 0,   count: 260)
    var freq_up:    [Int32]  = Array(repeating: 0,   count: 260)
    // ECDF 与 KS 共用后端频数；原始 freq_up 仍用于 MRL。
    var freq_ecdf_up: [Int32] = Array(repeating: 0, count: 260)
    // 理论值及其有效终点均由统计核心提供，零样本也有完整理论数据。
    var theory_cdf_all: [Double] = Array(repeating: 0.0, count: 260)
    var theory_cdf_up: [Double] = Array(repeating: 0.0, count: 260)
    var theory_last_valid_all: Int = 0
    var theory_last_valid_up: Int = 0
    var ecdf_up_step_size: Int = 1
    var theory_tail_mean_excess_up: Double = 0
    var hazard_all: [Double] = Array(repeating: 0.0, count: 260)
    var hazard_up:  [Double] = Array(repeating: 0.0, count: 260)
    var count_all:  Int    = 0
    var count_up:   Int    = 0
    var avg_all:    Double = 0
    var avg_up:     Double = 0
    var avg_win:    Double = -1
    var cv_all:     Double = 0
    var ci_all_err: Double = 0
    var ci_up_err:  Double = 0
    var win_5050:   Int    = 0
    var lose_5050:  Int    = 0
    var win_rate_5050: Double = -1
    var ks_d_all:   Double = 0
    var ks_is_normal:  Bool = true
    var ks_d_up:    Double = 0
    var ks_is_normal_up: Bool = true
    var ks_marker_all = KSMarkerData()
    var ks_marker_up = KSMarkerData()
    // v0.1.4.0: UP 侧样本是否为"两种分布的混合"。只有重构寻访会出现 ——
    // 理论曲线描述的是【系列内第一个 UP】(带 120 抽兜底), 而经验样本记的是每两个 UP
    // 之间的间隔, 第 2 个及以后的 UP 没有兜底。两者不是同一个统计对象, 混合时不判定。
    var ks_up_mixed: Bool = false
    var censored_pity_all: Int = 0
    var censored_pity_up:  Int = 0

    // 零值只供本文件的后端转换暂存，不能作为可绘制的空池。
    // 视图的无数据状态使用 AnalysisBundle.placeholder。
    nonisolated fileprivate init() {}
}

// MARK: - 共享:分析结果打包
//
// 共享类型。提到顶层后,iOS 的 AnalysisView_iOS 与 macOS 的 ContentView
// 都可以直接用。
// v0.1.2.0: 加 statsJoint (辉光庆典池).
// v0.1.4.0: 加 statsRefactor (重构寻访池). 老调用方在拿不到时可以为 nil 容错,
//   但新代码路径应该总是设置 (AnalyzerBridge 保证).
struct AnalysisBundle: Sendable {
    var statsChar:     ChartData
    var statsJoint:    ChartData
    var statsRefactor: ChartData
    var statsWep:      ChartData

    // 首次使用时从后端初始化理论数据，随后复用不可变的值类型缓存。
    // 不依赖导入文件或分析线程；四池均经过与真实结果相同的桥接。
    nonisolated static let placeholder = AnalysisBundle(
        statsChar: toChartData(GachaAnalyzerWrapper.placeholderChartData(for: .character)),
        statsJoint: toChartData(GachaAnalyzerWrapper.placeholderChartData(for: .joint)),
        statsRefactor: toChartData(GachaAnalyzerWrapper.placeholderChartData(for: .refactor)),
        statsWep: toChartData(GachaAnalyzerWrapper.placeholderChartData(for: .weapon))
    )
}

struct AnalysisBundleResult {
    var outputText: String
    var charts: AnalysisBundle?
}

// MARK: - ObjC → Swift 转换 (批量复制频数、理论 CDF 和风险函数)
//
// 关键: 必须标记 nonisolated。
// 因为以前 AnalysisBundleResult.charts 引用了 ContentView.AnalysisBundle (SwiftUI View),
// 在 Swift 6 strict concurrency 下,SwiftUI 的 @MainActor 隔离会通过类型推断
// 传染到本文件,导致 withUnsafeMutableBufferPointer 的闭包被标为 @MainActor,
// 在后台线程 (DispatchQueue.global) 调用时触发 _swift_task_checkIsolatedSwift
// → dispatch_assert_queue_fail → EXC_BREAKPOINT 崩溃。
// 即使现在 AnalysisBundle 已经独立,仍保留 nonisolated 作为防御。
nonisolated private func toChartData(_ d: GachaChartData) -> ChartData {
    var c = ChartData()

    // 直接把 Swift Array 的内存暴露给 ObjC 做 memcpy。
    // withUnsafeMutableBufferPointer 提供原始指针,等同于 C 的 int*/double*。
    c.freq_all.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyFreqAll(into: base) }
    }
    c.freq_up.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyFreqUp(into: base) }
    }
    c.freq_ecdf_up.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyECDFUp(into: base) }
    }
    c.theory_cdf_all.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyTheoryCDFAll(into: base) }
    }
    c.theory_cdf_up.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyTheoryCDFUp(into: base) }
    }
    c.hazard_all.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyHazardAll(into: base) }
    }
    c.hazard_up.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyHazardUp(into: base) }
    }

    // 映射标量数值属性
    c.theory_last_valid_all = d.theoryLastValidAll
    c.theory_last_valid_up = d.theoryLastValidUp
    c.ecdf_up_step_size = d.ecdfUpStepSize
    c.theory_tail_mean_excess_up = d.theoryTailMeanExcessUp
    c.count_all         = d.countAll
    c.count_up          = d.countUp
    c.avg_all           = d.avgAll
    c.avg_up            = d.avgUp
    c.avg_win           = d.avgWin
    c.cv_all            = d.cvAll
    c.ci_all_err        = d.ciAllErr
    c.ci_up_err         = d.ciUpErr
    c.win_5050          = d.win5050
    c.lose_5050         = d.lose5050
    c.win_rate_5050     = d.winRate5050
    c.ks_d_all          = d.ksDAll
    c.ks_is_normal      = d.ksIsNormal
    c.ks_d_up           = d.ksDUp
    c.ks_is_normal_up   = d.ksIsNormalUp
    c.ks_marker_all = KSMarkerData(d: d.ksDAll, x: d.ksXAll,
                                  empirical: d.ksEmpiricalAll, theory: d.ksTheoryAll)
    c.ks_marker_up = KSMarkerData(d: d.ksDUp, x: d.ksXUp,
                                 empirical: d.ksEmpiricalUp, theory: d.ksTheoryUp)
    c.ks_up_mixed       = d.ksUpMixed
    c.censored_pity_all = d.censoredPityAll
    c.censored_pity_up  = d.censoredPityUp

    return c
}

// MARK: - AnalyzerBridge
enum AnalyzerBridge {
    // nonisolated: analyze 在后台 worker (DispatchQueue.global) 上被调用,
    // 不应继承调用方的 actor 隔离。
    nonisolated static func analyze(filePath: String, chars: String, poolMap: String, weapons: String) -> AnalysisBundleResult {
        let result = GachaAnalyzerWrapper.analyzeFile(
            filePath,
            chars:   chars,
            poolMap: poolMap,
            weapons: weapons
        )

        guard result.ok,
              let sc = result.statsChar,
              let sj = result.statsJoint,
              let sr = result.statsRefactor,
              let sw = result.statsWep else {
            let msg = result.textOutput ?? "分析失败"
            return AnalysisBundleResult(outputText: msg, charts: nil)
        }

        let chartChar  = toChartData(sc)
        let chartJoint = toChartData(sj)
        let chartRefac = toChartData(sr)
        let chartWep   = toChartData(sw)

        return AnalysisBundleResult(
            outputText: result.textOutput ?? "",
            charts: AnalysisBundle(statsChar:     chartChar,
                                   statsJoint:    chartJoint,
                                   statsRefactor: chartRefac,
                                   statsWep:      chartWep)
        )
    }
}

// MARK: - FetcherBridge (已废弃)
//
// 旧的同步 completion-handler 桥 (GachaFetcherWrapper.fetchAllPools) 已移除。
// 拉取改用 AsyncFetch-Design v5 的 GachaFetchCoordinator (Swift async):
// View 在 Task 里直接 `try await coordinator.run(...)`, 见 FetcherView / FetcherView_iOS。
