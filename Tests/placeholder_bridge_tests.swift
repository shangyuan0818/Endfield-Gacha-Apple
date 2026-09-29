// macOS 空状态的真实 ObjC++ → ObjC → Swift 路径。
// 与生产 AnalyzerBridge.swift 一起编译；不分析文件、不手动初始化理论表、也不伪造 ChartData。
// runner 使用与 App 相同的 Swift 6 / MainActor 默认隔离设置。

import Foundation

nonisolated private func check(_ condition: Bool, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fatalError(message, file: file, line: line) }
}

nonisolated private func checkCDF(_ cdf: [Double], last: Int, expectedLast: Int,
                                  name: String) {
    check(cdf.count == 260, "\(name): 完整复制 260 个 CDF 值")
    check(last == expectedLast, "\(name): 理论有效终点应为 \(expectedLast)，实际 \(last)")
    check(cdf[0] == 0, "\(name): CDF 起点为零")
    check(cdf.allSatisfy { $0.isFinite && $0 >= -1e-12 && $0 <= 1 + 1e-12 },
          "\(name): CDF 必须是有效概率")
    check(cdf[last] > 0, "\(name): 冷启动时理论表已初始化")
    for x in 1...last {
        check(cdf[x] + 1e-12 >= cdf[x - 1], "\(name): 有效区间 CDF 单调")
    }
    check(cdf[(last + 1)...].allSatisfy { $0 == cdf[last] },
          "\(name): 有效终点之后保持末值")
}

nonisolated private func checkEmptyChart(_ chart: ChartData, name: String,
                                         allEnd: Int, upEnd: Int, step: Int) {
    check(chart.count_all == 0 && chart.count_up == 0, "\(name): 占位没有出金样本")
    for (label, frequencies) in [("综合", chart.freq_all), ("UP 原始", chart.freq_up),
                                 ("UP ECDF", chart.freq_ecdf_up)] {
        check(frequencies.count == 260 && frequencies.allSatisfy { $0 == 0 },
              "\(name) \(label): 频数为空")
    }
    checkCDF(chart.theory_cdf_all, last: chart.theory_last_valid_all,
             expectedLast: allEnd, name: "\(name) 综合")
    checkCDF(chart.theory_cdf_up, last: chart.theory_last_valid_up,
             expectedLast: upEnd, name: "\(name) UP")
    check(chart.ecdf_up_step_size == step, "\(name): ECDF 步长应为 \(step)")
    check(chart.ks_d_all == 0 && chart.ks_d_up == 0, "\(name): 空样本没有 KS 差值")
    check(chart.ks_marker_all.x == 0 && chart.ks_marker_up.x == 0,
          "\(name): 空样本没有 KS 标记位置")
    check(!chart.ks_up_mixed, "\(name): 空样本没有混合分布标志")
}

nonisolated private func checkSameChart(_ a: ChartData, _ b: ChartData, name: String) {
    check(a.freq_all == b.freq_all && a.freq_up == b.freq_up && a.freq_ecdf_up == b.freq_ecdf_up,
          "\(name): 重复读取保留空频数")
    check(a.theory_cdf_all == b.theory_cdf_all && a.theory_cdf_up == b.theory_cdf_up,
          "\(name): 重复读取保留理论 CDF")
    check(a.theory_last_valid_all == b.theory_last_valid_all &&
          a.theory_last_valid_up == b.theory_last_valid_up &&
          a.ecdf_up_step_size == b.ecdf_up_step_size &&
          a.theory_tail_mean_excess_up == b.theory_tail_mean_excess_up,
          "\(name): 重复读取保留理论参数")
}

@main
private struct PlaceholderBridgeTests {
    // 编译本身验证：在 MainActor 默认隔离项目中，后台调用者也能同步取用缓存。
    nonisolated static func main() {
        // 这是本进程第一次接触统计后端；必须由实际占位入口完成冷启动初始化。
        let original = AnalysisBundle.placeholder
        checkEmptyChart(original.statsChar, name: "特许", allEnd: 80, upEnd: 120, step: 1)
        checkEmptyChart(original.statsJoint, name: "辉光", allEnd: 80, upEnd: 240, step: 1)
        checkEmptyChart(original.statsRefactor, name: "重构", allEnd: 80, upEnd: 120, step: 1)
        checkEmptyChart(original.statsWep, name: "武器", allEnd: 40, upEnd: 80, step: 10)

        check(abs(original.statsJoint.theory_tail_mean_excess_up - 84.3666393185) < 1e-9,
              "辉光 UP 的 MRL 长尾参数必须经过真实桥接")
        check(original.statsJoint.theory_cdf_up[240] < 1,
              "辉光 UP 的有效末端仍保留长尾概率")
        for chart in [original.statsChar, original.statsRefactor, original.statsWep] {
            check(chart.theory_tail_mean_excess_up == 0, "非辉光池不携带辉光长尾参数")
        }
        check(original.statsJoint.theory_cdf_all == original.statsChar.theory_cdf_all,
              "辉光综合理论采用角色分布")
        check(original.statsRefactor.theory_cdf_all != original.statsChar.theory_cdf_all &&
              original.statsRefactor.theory_cdf_up != original.statsChar.theory_cdf_up,
              "重构池必须路由到自己的理论表")
        check(original.statsWep.theory_cdf_up[9] == 0 &&
              original.statsWep.theory_cdf_up[10] > 0 &&
              original.statsWep.theory_cdf_up[19] == original.statsWep.theory_cdf_up[10],
              "武器 UP 理论保留十连申领阶梯")

        // 值类型与 Array 的 copy-on-write 必须保护缓存，调用方修改不能污染下次空状态。
        var changed = original
        changed.statsWep.freq_up[1] = 1
        changed.statsWep.freq_ecdf_up[10] = 1
        changed.statsWep.theory_cdf_up[10] = -1
        changed.statsWep.ecdf_up_step_size = 1
        changed.statsJoint.theory_tail_mean_excess_up = -1
        check(changed.statsWep.theory_cdf_up[10] == -1, "确认本地副本确实被修改")

        let cached = AnalysisBundle.placeholder
        checkSameChart(original.statsChar, cached.statsChar, name: "特许")
        checkSameChart(original.statsJoint, cached.statsJoint, name: "辉光")
        checkSameChart(original.statsRefactor, cached.statsRefactor, name: "重构")
        checkSameChart(original.statsWep, cached.statsWep, name: "武器")
        print("[placeholder_bridge] 冷启动、四池理论数据、非隔离访问及缓存值隔离全部通过")
    }
}
