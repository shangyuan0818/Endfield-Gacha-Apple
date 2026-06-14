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

// MARK: - Chart 数据(Swift 原生)
//
// Sendable: 显式声明这是线程安全的值类型, 切断 @MainActor 隔离推断的传染。
// 字段默认值: 用 memberwise init 而非 static property, 避免静态属性被推断为
// @MainActor 隔离 (因为 ContentView.AnalysisBundle 引用链会污染整个类型上下文)。
struct ChartData: Sendable {
    // v0.1.2.0: 数组从 150 扩到 260, 容纳辉光池 0..240 的 pity 范围.
    var freq_all:   [Int32]  = Array(repeating: 0,   count: 260)
    var freq_up:    [Int32]  = Array(repeating: 0,   count: 260)
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
    var censored_pity_all: Int = 0
    var censored_pity_up:  Int = 0
}

// MARK: - 共享:分析结果打包
//
// 共享类型。提到顶层后,iOS 的 AnalysisView_iOS 与 macOS 的 ContentView
// 都可以直接用。
// v0.1.2.0: 加 statsJoint (辉光庆典池). 老调用方在拿不到时可以为 nil 容错,
//   但新代码路径应该总是设置 (AnalyzerBridge 保证).
struct AnalysisBundle: Sendable {
    var statsChar:  ChartData
    var statsJoint: ChartData
    var statsWep:   ChartData
}

struct AnalysisBundleResult {
    var outputText: String
    var charts: AnalysisBundle?
}

// MARK: - ObjC → Swift 转换 (4 次批量 memcpy 替代 600 次 msgSend)
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
    c.hazard_all.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyHazardAll(into: base) }
    }
    c.hazard_up.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress { d.copyHazardUp(into: base) }
    }

    // 映射标量数值属性
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
              let sw = result.statsWep else {
            let msg = result.textOutput ?? "分析失败"
            return AnalysisBundleResult(outputText: msg, charts: nil)
        }

        let chartChar  = toChartData(sc)
        let chartJoint = toChartData(sj)
        let chartWep   = toChartData(sw)

        return AnalysisBundleResult(
            outputText: result.textOutput ?? "",
            charts: AnalysisBundle(statsChar:  chartChar,
                                   statsJoint: chartJoint,
                                   statsWep:   chartWep)
        )
    }
}

// MARK: - FetcherBridge (已废弃)
//
// 旧的同步 completion-handler 桥 (GachaFetcherWrapper.fetchAllPools) 已移除。
// 拉取改用 AsyncFetch-Design v5 的 GachaFetchCoordinator (Swift async):
// View 在 Task 里直接 `try await coordinator.run(...)`, 见 FetcherView / FetcherView_iOS。
