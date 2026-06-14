//
//  ChartGridView.swift
//  Endfield-Gacha
//
//  4 宫格图表(SwiftUI Canvas, 等价 Windows GDI+ DrawECDF/DrawMRL)
//  布局与 Windows gui.cpp 对齐。
//
//  设计:
//    - 左栏 ECDF (经验累积分布函数): 离散阶梯线 + 理论 CDF 虚线 + KS 偏离标记
//    - 右栏 MRL (Mean Residual Life "剩余抽数期望"): 经验+理论双线 + 当前位置标注
//    抽卡数据是离散整数 pity, 样本量小(n~10), 这两个图都是离散友好的非参数显示,
//    不需要带宽选择, 物理意义直观, 与 KS 检验直接对应。
//
//  跨平台说明:
//    - 原 macOS 版用了 NSColor.tertiaryLabelColor / separatorColor /
//      windowBackgroundColor,这些在 iOS 不存在。
//      统一改用 SwiftUI 语义颜色 (.secondary / .separator) +
//      Color(PlatformColor.systemBackground) 桥接。
//    - 新增 ChartGridLayout 枚举:
//      .grid2x2       → macOS,2x2 自适应填满父容器
//      .grid2x2Fixed  → iPad,2x2 但每行固定 360pt(ScrollView 容器需要)
//      .vertical     → iPhone,纵向堆叠 4 张,每张 280pt
//
//  v0.1.1: UP 理论 CDF / MRL (charPoolUP, wepPoolUP)。
//  v0.1.2: ECDF 双 KS 标记 (蓝色综合标签左上 / 红色 UP 标签右下)。
//

import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

// MARK: - 跨平台颜色桥接
private extension Color {
    /// 用于白色描边的"窗口背景色"。
    /// macOS = windowBackgroundColor, iOS = systemBackground。
    static var chartBackground: Color {
        #if canImport(UIKit)
        return Color(PlatformColor.systemBackground)
        #else
        return Color(PlatformColor.windowBackgroundColor)
        #endif
    }

    static let chartBlue = Color(red: 65/255.0,  green: 140/255.0, blue: 240/255.0)
    static let chartRed  = Color(red: 240/255.0, green: 80/255.0,  blue: 80/255.0)
}

// MARK: - 布局枚举
enum ChartGridLayout {
    case grid2x2          // macOS:2x2 自适应填满父容器
    case grid2x2Fixed     // iPad:2x2 但每行固定 360pt(ScrollView 容器需要)
    case vertical         // iPhone:纵向堆叠,每张 280pt
}

// MARK: - 理论 CDF (与 Windows / Analyzer InitCDFTables 完全对齐)
//
// charPool / wepPool: 综合 6★ 的 CDF (任意 6★)
// charPoolUP / wepPoolUP: 当期 UP 的 CDF (考虑歪率 + 各自硬保底)
private struct TheoryCDF {
    // ===== 角色综合 6★ =====
    static let charPool: [Double] = {
        var cdf = [Double](repeating: 0, count: 82)
        var surv = 1.0
        for i in 1...80 {
            let p: Double
            if i == 30      { p = 1.0 - pow(1.0 - 0.008, 11) }   // 第30抽合并11次判定
            else if i <= 65 { p = 0.008 }
            else if i <= 79 { p = 0.058 + Double(i - 66) * 0.05 }
            else            { p = 1.0 }
            let pp = min(p, 1.0)
            cdf[i] = cdf[i-1] + surv * pp
            surv *= (1.0 - pp)
        }
        cdf[81] = 1.0
        return cdf
    }()

    // ===== 武器综合 6★ (单抽近似版) =====
    static let wepPool: [Double] = {
        var cdf = [Double](repeating: 0, count: 41)
        var surv = 1.0
        let bh = 0.04, bm = 0.96
        for k in 1...30 {
            cdf[k] = cdf[k-1] + surv * bh
            surv *= bm
        }
        let norm = 1.0 - pow(bm, 10)
        var ls = 1.0
        for k in 31...40 {
            cdf[k] = cdf[k-1] + surv * (ls * bh / norm)
            ls *= bm
        }
        cdf[40] = 1.0
        return cdf
    }()

    // ===== 角色当期 UP =====
    // 修正 (与 C++ AnalyzerWrapper.mm 的角色 UP CDF 完全一致, 消除图表理论曲线与文本统计/
    //   K-S 检验的分布漂移): 终末地特许寻访【没有原神/米池式大保底】—— 小保底歪了之后,
    //   下一次出六星仍是独立 50/50, 可以连续歪多次。唯一兜底是【第 120 抽硬保底】(本期累计
    //   120 抽必出 UP), 每期独立、不继承。
    //   => 状态退化为单维 D[s] (与武器/辉光池同构), n=120 强制所有"尚未出 UP"的存活者毕业。
    //   D[s]: 水位 s ∈ [0,80), 概率质量 = "尚未出 UP"的人群。
    //   每抽: 不出货 → D[s]×(1-ph) 推进到 s+1; 出货(独立 50/50) → 50% 毕业(出 UP),
    //         50% 歪(水位归 0, 仍未出 UP)。n=30: 1 本体抽(推进水位) + 10 免费抽(水位停)。
    //
    // 历史: 旧版 v0.1.1.1 误用"歪→下次必中"双状态 D[h][s], E[首UP] ≈ 74.16, 与社区 74.33
    //   看似吻合 —— 实则 74.33 是【净成本】(扣前 5 抽免费), 原始抽真值 = 74.33 + 5 ≈ 79.29;
    //   74.16 只是数值巧合, 掩盖了"终末地根本没有该大保底"这个 bug。本版改回单维 + 120 硬保底,
    //   E[首UP] = 79.29 原始抽 (CDF@80 ≈ 57.59%, @100 ≈ 62.80%, @119 ≈ 67.24%)。
    static let charPoolUP: [Double] = {
        let hardCap = 120
        let maxSoftPity = 80
        var cdf = [Double](repeating: 0, count: hardCap + 2)

        func h(_ k: Int) -> Double {
            if k <= 65       { return 0.008 }
            else if k <= 79  { return 0.058 + Double(k - 66) * 0.05 }
            else             { return 1.0 }
        }

        // 单维状态: D[s] = 水位 s 且"尚未出 UP"的概率 (无大保底标志, 每次出货独立 50/50)
        var D = [Double](repeating: 0, count: maxSoftPity)
        D[0] = 1.0
        var cum = 0.0

        for n in 1...hardCap {
            if n == hardCap {
                // 120 硬保底: 所有"尚未出 UP"的存活者强制毕业
                let alive = D.reduce(0, +)
                cum += alive
                cdf[n] = min(1.0, cum)
                for k in (n + 1)...(hardCap + 1) { cdf[k] = 1.0 }
                break
            }

            if n == 30 {
                // 1 本体抽 (推进水位) + 10 免费抽 (水位停)
                var stateA = [Double](repeating: 0, count: maxSoftPity)
                var pFinish = 0.0
                for s in 0..<maxSoftPity where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoftPity { stateA[s + 1] += D[s] * (1 - ph) }
                    pFinish   += D[s] * ph * 0.5   // 毕业 (出 UP)
                    stateA[0] += D[s] * ph * 0.5   // 歪, 水位归 0 (本体抽)
                }
                for _ in 0..<10 {
                    var stateB = [Double](repeating: 0, count: maxSoftPity)
                    for s in 0..<maxSoftPity where stateA[s] > 0 {
                        let ph = h(s + 1)
                        stateB[s] += stateA[s] * (1 - ph)   // 不出货, 水位停
                        pFinish   += stateA[s] * ph * 0.5   // 毕业 (出 UP)
                        stateB[s] += stateA[s] * ph * 0.5   // 歪, 水位停 (免费抽)
                    }
                    stateA = stateB
                }
                cum += pFinish
                cdf[n] = min(1.0, cum)
                D = stateA
            } else {
                var newD = [Double](repeating: 0, count: maxSoftPity)
                var pFinish = 0.0
                for s in 0..<maxSoftPity where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoftPity { newD[s + 1] += D[s] * (1 - ph) }
                    pFinish += D[s] * ph * 0.5   // 毕业 (出 UP)
                    newD[0] += D[s] * ph * 0.5   // 歪, 水位归 0
                }
                cum += pFinish
                cdf[n] = min(1.0, cum)
                D = newD
            }
        }
        return cdf
    }()

    // ===== 武器当期 UP =====
    // 4×8 状态机: ns ∈ [0,3] 已连续多少 10-pull 没出 6★;
    //             nf ∈ [0,7] 已连续多少 10-pull 没出 featured。
    // 40 抽 6★ pity + 80 抽 featured pity. CDF 只在 10 倍数边界跳变。
    static let wepPoolUP: [Double] = {
        let s = 1.0 - pow(0.99, 10.0)
        let u = pow(0.99, 10.0) - pow(0.96, 10.0)
        let v = pow(0.96, 10.0)
        let sPity = 1.0 - 0.75 * pow(0.99, 9.0)

        var state = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
        state[0][0] = 1.0
        var finishPer10: [Double] = []

        for _ in 0..<8 {
            var newState = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
            var pFeat = 0.0
            for ns in 0..<4 {
                for nf in 0..<8 {
                    let prob = state[ns][nf]
                    if prob == 0 { continue }
                    if nf == 7 {
                        pFeat += prob
                        continue
                    }
                    if ns == 3 {
                        pFeat += prob * sPity
                        newState[0][nf + 1] += prob * (1 - sPity)
                    } else {
                        pFeat += prob * s
                        newState[0][nf + 1]      += prob * u
                        newState[ns + 1][nf + 1] += prob * v
                    }
                }
            }
            finishPer10.append(pFeat)
            state = newState
        }

        var cdf = [Double](repeating: 0, count: 81)
        var cum = 0.0
        for k in 0..<8 {
            cum += finishPer10[k]
            let pullEnd = (k + 1) * 10
            cdf[pullEnd] = min(1.0, cum)
        }
        for i in 1...80 {
            if i % 10 != 0 {
                cdf[i] = cdf[(i / 10) * 10]
            }
        }
        return cdf
    }()

    // ===== 辉光庆典 UP (v0.1.2.4) =====
    //
    // 与 Special 池机制差异:
    //   (1) 4 个 6 星均匀分布: 2 限定 + 2 常驻, P(限定|六星) = 50%
    //   (2) 没有"大保底"——歪了下一次不保证是限定
    //   (3) 没有 120 抽 UP 硬保底
    //   (4) n=30 处赠送 10 次免费十连 (水位停)
    //
    // 等价模型: 重复独立"出 6 星"周期, 每周期 50% 出限定 (即停止).
    // 完整理论期望: E[首限定] ≈ 104.68 抽.
    //
    // CDF 截到 X=240 (与图表 X 轴一致, 数组 [0..240]).
    // CDF[240] ≈ 0.93, 长尾 ~7% 用 jointTailMeanExcess 单点近似补回 MRL.
    static let jointPoolUP: [Double] = {
        let maxSoft = 80
        let maxN    = 240
        func h(_ k: Int) -> Double {
            if k <= 65       { return 0.008 }
            else if k <= 79  { return 0.058 + Double(k - 66) * 0.05 }
            else             { return 1.0 }
        }
        var cdf = [Double](repeating: 0, count: maxN + 2)
        var D = [Double](repeating: 0, count: maxSoft)
        D[0] = 1.0
        var cum = 0.0

        for n in 1...maxN {
            var newD = [Double](repeating: 0, count: maxSoft)
            var pHitGrad = 0.0

            if n == 30 {
                // 1 本体抽 + 10 免费十连 (水位停)
                var stateA = [Double](repeating: 0, count: maxSoft)
                for s in 0..<maxSoft where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoft { stateA[s + 1] += D[s] * (1 - ph) }
                    pHitGrad   += D[s] * ph * 0.5
                    stateA[0]  += D[s] * ph * 0.5
                }
                for _ in 0..<10 {
                    var newStateA = [Double](repeating: 0, count: maxSoft)
                    for s in 0..<maxSoft where stateA[s] > 0 {
                        let ph = h(s + 1)
                        newStateA[s] += stateA[s] * (1 - ph)
                        pHitGrad     += stateA[s] * ph * 0.5
                        newStateA[s] += stateA[s] * ph * 0.5
                    }
                    stateA = newStateA
                }
                newD = stateA
            } else {
                for s in 0..<maxSoft where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoft { newD[s + 1] += D[s] * (1 - ph) }
                    pHitGrad += D[s] * ph * 0.5
                    newD[0]  += D[s] * ph * 0.5
                }
            }
            cum += pHitGrad
            cdf[n] = min(1.0, cum)
            D = newD
        }
        return cdf
    }()

    // jointTailMeanExcess = E[首限定 | 首限定 > 240] - 240 ≈ 84.37
    //
    // 数学动机: 辉光池 CDF[240] ≈ 0.93, 截断丢掉 ~7% 长尾质量, 直接算 MRL[0]
    // 会从真值 ~104.68 跌到 ~82. 用单点近似 (位置 240+84.37, 质量 1-cdf[240])
    // 补回 MRL[t] += (240 + tail_mean_excess - t) × (1 - cdf[240]).
    //
    // 与 Windows / ObjC 端 v0.1.2.4 实现完全一致: 临时跑 simulate 到 n=2000
    // 累加尾部 Σ k·pdf[k] / Σ pdf[k]. 动态计算保证未来机制改动自动跟上.
    static let jointTailMeanExcess: Double = {
        let maxSoft = 80
        let maxN    = 240
        let tailSimN = 2000
        func h(_ k: Int) -> Double {
            if k <= 65       { return 0.008 }
            else if k <= 79  { return 0.058 + Double(k - 66) * 0.05 }
            else             { return 1.0 }
        }
        var D = [Double](repeating: 0, count: maxSoft)
        D[0] = 1.0
        var tailSumKPdf = 0.0
        var tailMass    = 0.0

        for n in 1...tailSimN {
            var newD = [Double](repeating: 0, count: maxSoft)
            var pHitGrad = 0.0

            if n == 30 {
                var stateA = [Double](repeating: 0, count: maxSoft)
                for s in 0..<maxSoft where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoft { stateA[s + 1] += D[s] * (1 - ph) }
                    pHitGrad  += D[s] * ph * 0.5
                    stateA[0] += D[s] * ph * 0.5
                }
                for _ in 0..<10 {
                    var newStateA = [Double](repeating: 0, count: maxSoft)
                    for s in 0..<maxSoft where stateA[s] > 0 {
                        let ph = h(s + 1)
                        newStateA[s] += stateA[s] * (1 - ph)
                        pHitGrad     += stateA[s] * ph * 0.5
                        newStateA[s] += stateA[s] * ph * 0.5
                    }
                    stateA = newStateA
                }
                newD = stateA
            } else {
                for s in 0..<maxSoft where D[s] > 0 {
                    let ph = h(s + 1)
                    if s + 1 < maxSoft { newD[s + 1] += D[s] * (1 - ph) }
                    pHitGrad += D[s] * ph * 0.5
                    newD[0]  += D[s] * ph * 0.5
                }
            }

            let pdfN = pHitGrad
            if n > maxN {
                tailSumKPdf += Double(n) * pdfN
                tailMass    += pdfN
            }
            D = newD
        }
        guard tailMass > 1e-12 else { return 0.0 }
        return tailSumKPdf / tailMass - Double(maxN)
    }()
}

struct ChartGridView: View {
    let statsChar:  ChartData
    let statsJoint: ChartData   // v0.1.2.0: 辉光庆典池
    let statsWep:   ChartData
    var layout: ChartGridLayout = .grid2x2

    var body: some View {
        switch layout {
        case .grid2x2:
            gridLayout(useFixedHeight: false)
        case .grid2x2Fixed:
            gridLayout(useFixedHeight: true)
        case .vertical:
            verticalLayout
        }
    }

    // macOS / iPad: 2x3 网格 (3 行 × 2 列, 每行一个池子: 特许/辉光/武器)
    //
    // 高度策略:
    //   - macOS: 外层 ZStack 撑满窗口,内容自适应。
    //   - iPad: 走 ScrollView 容器,需要固定高度。
    private func gridLayout(useFixedHeight: Bool) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                charECDF
                charMRL
            }
            .frame(height: useFixedHeight ? 280 : nil)
            HStack(spacing: 12) {
                jointECDF
                jointMRL
            }
            .frame(height: useFixedHeight ? 280 : nil)
            HStack(spacing: 12) {
                wepECDF
                wepMRL
            }
            .frame(height: useFixedHeight ? 280 : nil)
        }
    }

    // iPhone: 纵向 6 张依次堆叠 (3 个池 × 2 图), 每张固定高度
    private var verticalLayout: some View {
        VStack(spacing: 12) {
            charECDF.frame(height: 260)
            charMRL.frame(height: 260)
            jointECDF.frame(height: 260)
            jointMRL.frame(height: 260)
            wepECDF.frame(height: 260)
            wepMRL.frame(height: 260)
        }
    }

    // MARK: 6 张图的具体配置(只写一次,两种布局共用)
    private var charECDF: some View {
        ECDFCanvas(title: "角色 (特许寻访) 累积分布 (ECDF)",
                   freq_all: statsChar.freq_all, freq_up: statsChar.freq_up,
                   count_all: statsChar.count_all, count_up: statsChar.count_up,
                   censored_all: statsChar.censored_pity_all,
                   censored_up:  statsChar.censored_pity_up,
                   theoryCDF: TheoryCDF.charPool,
                   theoryCDFUp: TheoryCDF.charPoolUP,
                   limitBase: 120,
                   ecdfUpStepSize: 1)
    }
    private var charMRL: some View {
        MRLCanvas(title: "角色 (特许寻访) 剩余抽数期望 (MRL)",
                  freq_all: statsChar.freq_all, freq_up: statsChar.freq_up,
                  count_all: statsChar.count_all, count_up: statsChar.count_up,
                  censored_all: statsChar.censored_pity_all,
                  censored_up:  statsChar.censored_pity_up,
                  theoryCDF: TheoryCDF.charPool,
                  theoryCDFUp: TheoryCDF.charPoolUP,
                  limitBase: 120,
                  theoryAllCap: 80, theoryUpCap: 120)
    }
    // v0.1.2.0/4: 辉光庆典池图表. ECDF 红线只画到 X=240 (CDF 在此处 ~0.93,
    // 长尾质量通过 tailMeanExcessUp 在 MRL 计算中补回).
    private var jointECDF: some View {
        ECDFCanvas(title: "角色 (辉光庆典) 累积分布 (ECDF)",
                   freq_all: statsJoint.freq_all, freq_up: statsJoint.freq_up,
                   count_all: statsJoint.count_all, count_up: statsJoint.count_up,
                   censored_all: statsJoint.censored_pity_all,
                   censored_up:  statsJoint.censored_pity_up,
                   theoryCDF: TheoryCDF.charPool,
                   theoryCDFUp: TheoryCDF.jointPoolUP,
                   limitBase: 240,
                   ecdfUpStepSize: 1)
    }
    private var jointMRL: some View {
        MRLCanvas(title: "角色 (辉光庆典) 剩余抽数期望 (MRL)",
                  freq_all: statsJoint.freq_all, freq_up: statsJoint.freq_up,
                  count_all: statsJoint.count_all, count_up: statsJoint.count_up,
                  censored_all: statsJoint.censored_pity_all,
                  censored_up:  statsJoint.censored_pity_up,
                  theoryCDF: TheoryCDF.charPool,
                  theoryCDFUp: TheoryCDF.jointPoolUP,
                  limitBase: 240,
                  theoryAllCap: 80, theoryUpCap: 240,
                  tailMeanExcessUp: TheoryCDF.jointTailMeanExcess)
    }
    private var wepECDF: some View {
        ECDFCanvas(title: "武器累积分布 (ECDF)",
                   freq_all: statsWep.freq_all, freq_up: statsWep.freq_up,
                   count_all: statsWep.count_all, count_up: statsWep.count_up,
                   censored_all: statsWep.censored_pity_all,
                   censored_up:  statsWep.censored_pity_up,
                   theoryCDF: TheoryCDF.wepPool,
                   theoryCDFUp: TheoryCDF.wepPoolUP,
                   limitBase: 80,
                   ecdfUpStepSize: 10)
    }
    private var wepMRL: some View {
        MRLCanvas(title: "武器剩余抽数期望 (MRL)",
                  freq_all: statsWep.freq_all, freq_up: statsWep.freq_up,
                  count_all: statsWep.count_all, count_up: statsWep.count_up,
                  censored_all: statsWep.censored_pity_all,
                  censored_up:  statsWep.censored_pity_up,
                  theoryCDF: TheoryCDF.wepPool,
                  theoryCDFUp: TheoryCDF.wepPoolUP,
                  limitBase: 80,
                  theoryAllCap: 40, theoryUpCap: 80)
    }
}

// MARK: - KS 标签锚点
//
// 蓝色 (综合): leftTop 锚点 → 标签贴在 KS 虚线左上方
// 红色 (UP):   rightBottom 锚点 → 标签贴在 KS 虚线右下方
// 两个标签天然不会撞在一起, 颜色与对应 ECDF 实线一致。
private enum KSLabelAnchor {
    case leftTop      // 标签的右下角对齐到虚线中点的 (左上偏移)
    case rightBottom  // 标签的左上角对齐到虚线中点的 (右下偏移)
}

// MARK: - ECDF
struct ECDFCanvas: View {
    let title: String
    let freq_all: [Int32]
    let freq_up:  [Int32]
    let count_all: Int
    let count_up:  Int
    let censored_all: Int
    let censored_up:  Int
    let theoryCDF: [Double]
    let theoryCDFUp: [Double]
    let limitBase: Int
    /// UP CDF 的有效采样步长 (角色=1 / 武器=10)
    /// 影响 ECDF 理论虚线的画法: 角色折线连相邻整数点, 武器画真实阶梯。
    var ecdfUpStepSize: Int = 1

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let compact = (hSize == .compact)
        let topInset: CGFloat = compact ? 52 : 32

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.background)
            Canvas { ctx, size in draw(ctx: &ctx, size: size) }
                .padding(.top, topInset)

            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 12) {
                        Text("━━ 综合六星").font(.system(size: 10)).foregroundStyle(Color.chartBlue)
                        Text("━━ 当期 UP").font(.system(size: 10)).foregroundStyle(Color.chartRed)
                        Text("- - 理论").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 14)
                .padding(.trailing, 14)
            } else {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 10).padding(.leading, 14)
                HStack(spacing: 14) {
                    Text("━━ 综合六星 ECDF").font(.system(size: 10)).foregroundStyle(Color.chartBlue)
                    Text("━━ 当期限定 UP").font(.system(size: 10)).foregroundStyle(Color.chartRed)
                    Text("- - 理论 CDF").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.top, 11).padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    private func drawText(_ ctx: inout GraphicsContext, _ text: Text, at point: CGPoint,
                          anchor: UnitPoint = .center) {
        ctx.draw(ctx.resolve(text), at: point, anchor: anchor)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        guard freq_all.count >= 260, freq_up.count >= 260 else { return }
        let hasData = (count_all > 0) || (count_up > 0)
        // v0.1.2.1: 无数据时不直接 return, 继续画坐标轴 + 理论 CDF,
        // 末尾叠加灰色提示. 让用户在导入 UIGF JSON 但还没出金时也能
        // 看到理论参考曲线, 而不是一片空白.

        var maxX = limitBase
        for i in 1..<260 {
            if (freq_all[i] > 0 || freq_up[i] > 0) && i > maxX { maxX = i }
        }
        maxX = ((maxX / 10) + 1) * 10
        if maxX > 259 { maxX = 259 }

        let plotX: CGFloat = 50
        let plotY: CGFloat = 16
        let plotW = size.width  - plotX - 20
        let plotH = size.height - plotY - 30
        guard plotW > 10, plotH > 10 else { return }

        func pt(_ x: Int, _ y: Double) -> CGPoint {
            let yClamped = max(0, min(1, y))
            return CGPoint(x: plotX + CGFloat(x) / CGFloat(maxX) * plotW,
                           y: plotY + plotH - CGFloat(yClamped) * plotH)
        }

        let axisColor = Color.secondary.opacity(0.6)
        let gridColor = Color.secondary.opacity(0.25)

        for i in 0...4 {
            let py = plotY + plotH - CGFloat(i) / 4.0 * plotH
            if i > 0 {
                var grid = Path()
                grid.move(to: CGPoint(x: plotX, y: py))
                grid.addLine(to: CGPoint(x: plotX + plotW, y: py))
                ctx.stroke(grid, with: .color(gridColor), lineWidth: 0.5)
            }
            let label = Text("\(i * 25)%").font(.system(size: 10)).foregroundStyle(.secondary)
            drawText(&ctx, label, at: CGPoint(x: plotX - 22, y: py))
        }

        var axisPath = Path()
        axisPath.move(to: CGPoint(x: plotX, y: plotY))
        axisPath.addLine(to: CGPoint(x: plotX, y: plotY + plotH))
        axisPath.addLine(to: CGPoint(x: plotX + plotW, y: plotY + plotH))
        ctx.stroke(axisPath, with: .color(axisColor), lineWidth: 1)

        let step = maxX > 140 ? 20 : 10
        for x in stride(from: 0, through: maxX, by: step) {
            let px = plotX + CGFloat(x) / CGFloat(maxX) * plotW
            let tick = Text("\(x)").font(.system(size: 10)).foregroundStyle(.secondary)
            drawText(&ctx, tick, at: CGPoint(x: px, y: plotY + plotH + 10))
        }

        // ===== 理论 CDF (虚线) =====
        // 角色: 单抽粒度, 折线连相邻整数点 (无微小 90° 角点, dash 平滑展开)。
        // 武器: 10 抽一组的真实阶梯, 水平段 + 垂直段。
        // 共用: 单连续 path + lineJoin=.round + dash[4,3]。
        // dash 沿整条 path 累计长度展开, 跨拐角不重启, 短段不会糊成实线。
        //
        // 自动跳跃检测 (v0.1.1):
        // 在 stepSize=1 的折线模式下用状态机:
        //   - 折线模式: Δ_k / Δ_{k-1} > JUMP_THRESHOLD (=5) → 进入阶梯模式
        //   - 阶梯模式: Δ 持续上升 (Δ_k > Δ_{k-1}) → 保持阶梯; 否则退出折线
        // 这样能正确表达"软保底响应到峰值"这一持续陡升过程, 而不只是把
        // 触发跳跃的那一个点画成阶梯。例如角色 UP CDF 在 k=66 hazard 跳跃,
        // 但 CDF 增量峰值出现在 k=69 (因为 D[s] 迭代积分需要几抽反应):
        //   k=66 (Δ=0.018, 进入阶梯) → k=67 (0.031) → k=68 (0.040) → k=69 (0.045) →
        //   k=70 (0.045 ≤ 0.045 退出阶梯) → 后续平滑衰减
        // 自动覆盖以下场景, 不需要硬编码具体 k:
        //   - 角色综合 k=30 (单点跳跃: 30 抽合并 11 次判定)
        //   - 角色综合 k=66~69 (软保底响应)
        //   - 角色 UP   k=66~69 (软保底响应)
        //   - 角色 UP   k=120 (硬保底)
        // 武器综合 k=31 比值仅 2.86, 不触发, 保持平滑折线 (软保底渐进展开是真实形态)。
        func drawTheoryCDF(_ cdf: [Double], stepSize: Int, color: Color) {
            let upper = min(cdf.count - 1, maxX)
            guard upper >= 1 else { return }
            // v0.1.2.2: 与 Windows gui.cpp drawTheoryCDF 同款 upper_eff 截断, 截掉两类"伪末端":
            //   1) 已饱和段: 找到第一个 cdf[k] >= 1-eps 的 k_sat, 之后所有 cdf 都等于 1.0
            //      (硬保底之后的延伸 + char_up 122 个槽里 cdf[120]=cdf[121]=1 的哨兵区);
            //      画到 k_sat 就停, 否则末端会冒出一段 1→1 水平虚线 (即"垂直阶梯顶端向右
            //      拐弯"的视觉 bug).
            //   2) 未填充哨兵段: 辉光庆典 jointPoolUP[241]=0 (cdf 数组容量 242 但只填到 240),
            //      画上去会从 0.93 跳到 0, 产生"红色理论虚线末端笔直掉下来"的视觉 bug.
            //      检测到 cdf[k] < cdf[k-1] (单调性破坏) 也立即停.
            let EPS_SAT = 1e-6
            var upperEff = upper
            for k in 1...upper {
                if cdf[k] >= 1.0 - EPS_SAT { upperEff = k; break }
                if cdf[k] + EPS_SAT < cdf[k - 1] { upperEff = k - 1; break }
            }
            guard upperEff >= 1 else { return }
            var path = Path()
            path.move(to: pt(0, cdf[0]))
            if stepSize == 1 {
                let JUMP_THRESHOLD = 5.0
                let MIN_PREV_DELTA = 1e-6
                var inStepMode = false
                for k in 1...upperEff {
                    let curDelta  = cdf[k] - cdf[k-1]
                    let prevDelta = (k >= 2) ? cdf[k-1] - cdf[k-2] : 0.0
                    var drawAsStep: Bool
                    if inStepMode {
                        // 阶梯模式: Δ 持续上升就保持, 否则退出
                        if curDelta > prevDelta && prevDelta > MIN_PREV_DELTA {
                            drawAsStep = true
                        } else {
                            inStepMode = false
                            drawAsStep = false
                        }
                    } else {
                        // 折线模式: 检测进入条件
                        if prevDelta > MIN_PREV_DELTA
                            && curDelta / prevDelta > JUMP_THRESHOLD {
                            inStepMode = true
                            drawAsStep = true
                        } else {
                            drawAsStep = false
                        }
                    }
                    if drawAsStep {
                        // 阶梯: 水平到 (k, cdf[k-1]), 垂直到 (k, cdf[k])
                        path.addLine(to: pt(k, cdf[k - 1]))
                        path.addLine(to: pt(k, cdf[k]))
                    } else {
                        path.addLine(to: pt(k, cdf[k]))
                    }
                }
            } else {
                var k = stepSize
                while k <= upperEff {
                    path.addLine(to: pt(k, cdf[k - stepSize]))
                    path.addLine(to: pt(k, cdf[k]))
                    k += stepSize
                }
                if k - stepSize < upperEff {
                    path.addLine(to: pt(upperEff, cdf[k - stepSize]))
                }
            }
            ctx.stroke(path, with: .color(color.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.4,
                                          lineJoin: .round,
                                          dash: [4, 3]))
        }
        drawTheoryCDF(theoryCDF,   stepSize: 1,             color: .chartBlue)
        drawTheoryCDF(theoryCDFUp, stepSize: ecdfUpStepSize, color: .chartRed)

        // ===== 经验 ECDF =====
        // 注: 删失观测不画在 ECDF 上 —— 它还没事件化, 强行画一个标记会落在
        // ECDF 终点 y=100% 处误导用户。MRL 图已有"已垫 X / 预期还需 Y"标注。
        func drawECDF(_ freq: [Int32], total: Int, color: Color) {
            guard total > 0 else { return }
            var path = Path()
            var cum: Double = 0
            path.move(to: pt(0, 0))
            for k in 1...maxX {
                if freq[k] == 0 { continue }
                path.addLine(to: pt(k, cum))
                cum += Double(freq[k]) / Double(total)
                path.addLine(to: pt(k, cum))
            }
            path.addLine(to: pt(maxX, cum))
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        }
        drawECDF(freq_all, total: count_all, color: .chartBlue)
        drawECDF(freq_up,  total: count_up,  color: .chartRed)

        // ===== KS 标记 (v0.1.2: 双色) =====
        //
        // 在偏离最大处画短虚线连接 经验 ECDF ←→ 理论 CDF, 标注 KS D 值。
        // 标签布局策略:
        //   - 蓝色 (综合): 标签贴 KS 虚线左上方 (anchor = .bottomTrailing)
        //   - 红色 (UP):   标签贴 KS 虚线右下方 (anchor = .topLeading)
        //   两个标签天然不会撞, 颜色与对应 ECDF 实线一致。
        // 标签自带白色描边 (4 偏移方向), 在彩色实线上的可读性更好。
        func drawKSMarker(freq: [Int32], total: Int,
                          theoryCDF: [Double],
                          color: Color,
                          anchor: KSLabelAnchor) {
            guard total > 0, theoryCDF.count >= 2 else { return }
            let upper = min(theoryCDF.count - 1, maxX)
            guard upper >= 1 else { return }
            // v0.1.2.2: 同 drawTheoryCDF, 加 upper_eff 截断避免:
            //   - 辉光池 theoryCDF[241]=0 让 |cum - 0| ≈ 1, 误判为最大偏离点
            //   - 饱和段 (cdf[k]==1 after hard pity) 上做无意义的比较
            let EPS_SAT = 1e-6
            var upperEff = upper
            for k in 1...upper {
                if theoryCDF[k] >= 1.0 - EPS_SAT { upperEff = k; break }
                if theoryCDF[k] + EPS_SAT < theoryCDF[k - 1] { upperEff = k - 1; break }
            }
            guard upperEff >= 1 else { return }
            var maxD = 0.0
            var maxDx = 0
            var cum = 0.0
            for k in 1...upperEff {
                cum += Double(freq[k]) / Double(total)
                let d = abs(cum - theoryCDF[k])
                if d > maxD { maxD = d; maxDx = k }
            }
            guard maxD > 0.01, maxDx > 0 else { return }
            var emp_y: Double = 0
            for k in 1...maxDx { emp_y += Double(freq[k]) / Double(total) }
            let th_y = theoryCDF[maxDx]
            let p1 = pt(maxDx, emp_y)
            let p2 = pt(maxDx, th_y)
            // KS 虚线 (与对应 ECDF 实线同色)
            var ksPath = Path()
            ksPath.move(to: p1); ksPath.addLine(to: p2)
            ctx.stroke(ksPath, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))

            // 标签位置和锚点
            let lbl = Text(String(format: "KS D=%.3f", maxD))
                .font(.system(size: 10).weight(.medium))
            let midY = (p1.y + p2.y) / 2
            let labelPos: CGPoint
            let unitAnchor: UnitPoint
            switch anchor {
            case .leftTop:
                // 标签右下角对齐到虚线左侧偏上处 (整体在虚线左上方)
                labelPos = CGPoint(x: p1.x - 4, y: midY - 2)
                unitAnchor = .bottomTrailing
            case .rightBottom:
                // 标签左上角对齐到虚线右侧偏下处 (整体在虚线右下方)
                labelPos = CGPoint(x: p1.x + 4, y: midY + 2)
                unitAnchor = .topLeading
            }

            // 白色描边
            let outline = lbl.foregroundStyle(Color.chartBackground)
            for dx: CGFloat in [-1, 1] {
                for dy: CGFloat in [-1, 1] {
                    drawText(&ctx, outline,
                             at: CGPoint(x: labelPos.x + dx, y: labelPos.y + dy),
                             anchor: unitAnchor)
                }
            }
            // 主文本
            let main = lbl.foregroundStyle(color)
            drawText(&ctx, main, at: labelPos, anchor: unitAnchor)
        }

        // 蓝色 (综合): 左上
        drawKSMarker(freq: freq_all, total: count_all,
                     theoryCDF: theoryCDF, color: .chartBlue,
                     anchor: .leftTop)
        // 红色 (UP): 右下
        drawKSMarker(freq: freq_up, total: count_up,
                     theoryCDF: theoryCDFUp, color: .chartRed,
                     anchor: .rightBottom)

        // v0.1.2.1: 无出金数据时, 在图中央叠加灰色提示文字 (理论曲线仍可见)
        if !hasData {
            let txt = Text("暂无出金数据 (仅显示理论曲线参考)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            drawText(&ctx, txt, at: CGPoint(x: plotX + plotW / 2, y: plotY + plotH / 2))
        }
    }
}

// MARK: - MRL
struct MRLCanvas: View {
    let title: String
    let freq_all: [Int32]
    let freq_up:  [Int32]
    let count_all: Int
    let count_up:  Int
    let censored_all: Int
    let censored_up:  Int
    let theoryCDF: [Double]
    let theoryCDFUp: [Double]
    let limitBase: Int
    let theoryAllCap: Int
    let theoryUpCap:  Int
    /// v0.1.2.4: 仅辉光池非 0. 见 ChartGridView jointMRL 配置.
    ///   含义: 在 UP 理论 CDF 截断点 (upper_eff) 之后追加一个点质量,
    ///   位置 = upper_eff + tailMeanExcessUp, 质量 = 1 - cdf[upper_eff].
    ///   公式: num += (位置 - t) × 质量, 让辉光池 MRL[0] 从无延伸的
    ///   ~82 修正回完整真值 ~104.68.
    var tailMeanExcessUp: Double = 0.0

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let compact = (hSize == .compact)
        let topInset: CGFloat = compact ? 52 : 32

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.background)
            Canvas { ctx, size in draw(ctx: &ctx, size: size) }
                .padding(.top, topInset)

            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 12) {
                        Text("━━ 综合").font(.system(size: 10)).foregroundStyle(Color.chartBlue)
                        Text("━━ UP").font(.system(size: 10)).foregroundStyle(Color.chartRed)
                        Text("- - 理论").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 14)
                .padding(.trailing, 14)
            } else {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 10).padding(.leading, 14)
                HStack(spacing: 14) {
                    Text("━━ 综合 剩余期望").font(.system(size: 10)).foregroundStyle(Color.chartBlue)
                    Text("━━ UP 剩余期望").font(.system(size: 10)).foregroundStyle(Color.chartRed)
                    Text("- - 理论值").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.top, 11).padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    private func drawText(_ ctx: inout GraphicsContext, _ text: Text, at point: CGPoint,
                          anchor: UnitPoint = .center) {
        ctx.draw(ctx.resolve(text), at: point, anchor: anchor)
    }

    private func computeEmpiricalMRL(freq: [Int32], total: Int, maxX: Int) -> (mrl: [Double], surv: [Int]) {
        var mrl = [Double](repeating: -1.0, count: 260)
        var surv = [Int](repeating: 0, count: 260)
        guard total > 0 else { return (mrl, surv) }
        var sufCount = 0
        var sufWeighted = 0
        var t = maxX
        while t >= 0 {
            surv[t] = sufCount
            if sufCount >= 1 {
                mrl[t] = Double(sufWeighted - t * sufCount) / Double(sufCount)
            }
            if t >= 1 {
                sufCount    += Int(freq[t])
                sufWeighted += t * Int(freq[t])
            }
            t -= 1
        }
        return (mrl, surv)
    }

    // v0.1.2.2 / v0.1.2.4: 加 upper_eff 截断 (避免饱和/未填段) + 长尾点质量延伸.
    //
    //   upper_eff:  扫描 cdf 找饱和点 (>= 1-eps) 或单调性破坏点. 在那里停, 避免:
    //     1) cdf[k]==1 后继续算无意义
    //     2) 未填充末端 (辉光池删哨兵后 cdf[241]=0) 算 pdf=cdf[k]-cdf[k-1] 出负值
    //
    //   长尾点质量 (仅 tailMeanExcess > 0 时启用):
    //     mass = 1 - cdf[upper_eff]
    //     pos  = upper_eff + tailMeanExcess
    //     公式: num += (pos - t) × mass
    //     辉光池 MRL[0] 从 ~82 修正回完整真值 ~104.68.
    private func computeTheoryMRL(cdf: [Double], maxX: Int,
                                  tailMeanExcess: Double = 0.0) -> [Double] {
        var tmrl = [Double](repeating: -1.0, count: 260)
        guard cdf.count >= 2 else { return tmrl }
        let upper = cdf.count - 1
        // upper_eff 截断
        let EPS_SAT = 1e-6
        var upperEff = upper
        for k in 1...upper {
            if cdf[k] >= 1.0 - EPS_SAT { upperEff = k; break }
            if cdf[k] + EPS_SAT < cdf[k - 1] { upperEff = k - 1; break }
        }
        guard upperEff >= 1 else { return tmrl }

        let tailMass     = 1.0 - cdf[upperEff]
        let tailPosition = Double(upperEff) + tailMeanExcess
        let hasTail = (tailMeanExcess > 0.0) && (tailMass > 1e-9)

        for t in 0...min(upperEff - 1, maxX) {
            let surv_t = 1.0 - cdf[t]
            if surv_t < 1e-9 { break }
            var num = 0.0
            for k in (t + 1)...upperEff {
                let pdf_k = cdf[k] - cdf[k-1]
                num += Double(k - t) * pdf_k
            }
            if hasTail {
                num += (tailPosition - Double(t)) * tailMass
            }
            tmrl[t] = num / surv_t
        }
        return tmrl
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        guard freq_all.count >= 260, freq_up.count >= 260 else { return }
        let hasData = (count_all > 0) || (count_up > 0)
        // v0.1.2.1: 无数据时不直接 return, 继续画坐标轴 + 理论曲线,
        // 末尾叠加灰色提示.

        var maxX = limitBase
        for i in 1..<260 {
            if (freq_all[i] > 0 || freq_up[i] > 0) && i > maxX { maxX = i }
        }
        maxX = ((maxX / 10) + 1) * 10
        if maxX > 259 { maxX = 259 }

        let mrlAll = computeEmpiricalMRL(freq: freq_all, total: count_all, maxX: maxX)
        let mrlUp  = computeEmpiricalMRL(freq: freq_up,  total: count_up,  maxX: maxX)
        let theoryMRL   = computeTheoryMRL(cdf: theoryCDF,   maxX: maxX)
        // v0.1.2.4: UP 理论 MRL 用 tailMeanExcessUp 补长尾 (仅辉光池非 0)
        let theoryMRLUp = computeTheoryMRL(cdf: theoryCDFUp, maxX: maxX,
                                           tailMeanExcess: tailMeanExcessUp)

        var maxY = 1.0
        for t in 0...maxX {
            if mrlAll.mrl[t] > maxY { maxY = mrlAll.mrl[t] }
            if mrlUp.mrl[t]  > maxY { maxY = mrlUp.mrl[t] }
            if theoryMRL[t]   > maxY { maxY = theoryMRL[t] }
            if theoryMRLUp[t] > maxY { maxY = theoryMRLUp[t] }
        }
        maxY = ceil(maxY * 1.1 / 10.0) * 10.0
        if maxY < 10 { maxY = 10 }

        let plotX: CGFloat = 50
        let plotY: CGFloat = 16
        let plotW = size.width  - plotX - 20
        let plotH = size.height - plotY - 30
        guard plotW > 10, plotH > 10 else { return }

        func pt(_ x: Int, _ y: Double) -> CGPoint {
            let yClamped = max(0, min(maxY, y))
            return CGPoint(x: plotX + CGFloat(x) / CGFloat(maxX) * plotW,
                           y: plotY + plotH - CGFloat(yClamped / maxY) * plotH)
        }

        let axisColor = Color.secondary.opacity(0.6)
        let gridColor = Color.secondary.opacity(0.25)

        for i in 0...4 {
            let py = plotY + plotH - CGFloat(i) / 4.0 * plotH
            if i > 0 {
                var grid = Path()
                grid.move(to: CGPoint(x: plotX, y: py))
                grid.addLine(to: CGPoint(x: plotX + plotW, y: py))
                ctx.stroke(grid, with: .color(gridColor), lineWidth: 0.5)
            }
            let yVal = maxY * Double(i) / 4.0
            let label = Text(String(format: "%.0f", yVal))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            drawText(&ctx, label, at: CGPoint(x: plotX - 22, y: py))
        }

        var axisPath = Path()
        axisPath.move(to: CGPoint(x: plotX, y: plotY))
        axisPath.addLine(to: CGPoint(x: plotX, y: plotY + plotH))
        axisPath.addLine(to: CGPoint(x: plotX + plotW, y: plotY + plotH))
        ctx.stroke(axisPath, with: .color(axisColor), lineWidth: 1)

        let step = maxX > 140 ? 20 : 10
        for x in stride(from: 0, through: maxX, by: step) {
            let px = plotX + CGFloat(x) / CGFloat(maxX) * plotW
            let tick = Text("\(x)").font(.system(size: 10)).foregroundStyle(.secondary)
            drawText(&ctx, tick, at: CGPoint(x: px, y: plotY + plotH + 10))
        }

        // ===== 理论 MRL (虚线) =====
        // 角色: 折线连相邻整数点 (单抽粒度).
        // 武器: 锯齿状下降 —— 拨内 9 抽斜率 -1 (确定性递减), 拨末跳一段 (条件期望刷新)。
        //       这是机制必然, 不引入插值, 全是 computeTheoryMRL 算出的真实数据。
        // 共用: 单连续 path + lineJoin=.round + dash[4,3]。
        func drawTheoryMRL(_ tmrl: [Double], cap: Int, color: Color) {
            guard cap > 0 else { return }
            let actualCap = min(cap, maxX)
            var path = Path()
            var hasPrev = false
            for t in 0...actualCap {
                if t < tmrl.count && tmrl[t] >= 0 {
                    let p = pt(t, tmrl[t])
                    if hasPrev { path.addLine(to: p) } else { path.move(to: p) }
                    hasPrev = true
                } else {
                    hasPrev = false
                }
            }
            ctx.stroke(path, with: .color(color.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.4,
                                          lineJoin: .round,
                                          dash: [4, 3]))
        }
        drawTheoryMRL(theoryMRL,   cap: theoryAllCap, color: .chartBlue)
        drawTheoryMRL(theoryMRLUp, cap: theoryUpCap,  color: .chartRed)

        // ===== 经验 MRL =====
        // surv >= 2: 满色实线 2.2pt   ← 多样本, 统计可靠
        // surv == 1: 半透明同色实线 1.6pt (alpha 0.45)  ← 高方差区
        //
        // surv==1 不再画虚线 —— 与红色 UP 理论虚线 (dash 4/3) 撞样式无法分辨。
        // 改成半透明实线后, 视觉编码错开:
        //   "颜色淡 = 数据稀薄"   "虚线 = 理论参考"
        func drawEmpMRL(_ data: (mrl: [Double], surv: [Int]), color: Color) {
            var thickPath = Path()
            var thinPath  = Path()
            var thickTail: CGPoint? = nil
            var thinTail:  CGPoint? = nil
            var hasPrev = false
            var prev = CGPoint.zero
            var prevThick = true
            for t in 0...maxX {
                if data.mrl[t] < 0 || data.surv[t] == 0 {
                    hasPrev = false
                    thickTail = nil
                    thinTail = nil
                    continue
                }
                let p = pt(t, data.mrl[t])
                let thick = (data.surv[t] >= 2)
                if hasPrev {
                    if thick && prevThick {
                        if thickTail != prev { thickPath.move(to: prev) }
                        thickPath.addLine(to: p)
                        thickTail = p
                        thinTail = nil
                    } else {
                        if thinTail != prev { thinPath.move(to: prev) }
                        thinPath.addLine(to: p)
                        thinTail = p
                        thickTail = nil
                    }
                }
                prev = p; hasPrev = true; prevThick = thick
            }
            ctx.stroke(thickPath, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            ctx.stroke(thinPath, with: .color(color.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        drawEmpMRL(mrlAll, color: .chartBlue)
        drawEmpMRL(mrlUp,  color: .chartRed)

        // ===== 当前 censored 位置标注 =====
        // 双色都"优先 theory MRL, 否则降级经验 MRL"。computeTheoryMRL 在每个
        // 整数 t 都有真实值 (含武器拨内确定性递减), 所以不需要插值。
        struct CensoredEntry {
            let text: String
            let color: Color
        }
        var entries: [CensoredEntry] = []

        func resolveAndDrawLine(censored: Int,
                                empMRL: [Double],
                                theoryMRL: [Double],
                                theoryCap: Int,
                                color: Color) -> CensoredEntry? {
            guard censored > 0 && censored <= maxX else { return nil }
            var yVal = -1.0
            if censored < theoryMRL.count
                && (theoryCap == 0 || censored <= theoryCap)
                && theoryMRL[censored] > 0 {
                yVal = theoryMRL[censored]
            }
            if yVal <= 0 && censored < empMRL.count && empMRL[censored] > 0 {
                yVal = empMRL[censored]
            }
            guard yVal > 0 else { return nil }
            let top = pt(censored, yVal)
            let bottom = CGPoint(x: top.x, y: plotY + plotH)
            var line = Path()
            line.move(to: top)
            line.addLine(to: bottom)
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            return CensoredEntry(
                text: String(format: "已垫 %d 抽 · 预期还需 %.1f", censored, yVal),
                color: color
            )
        }
        if let e = resolveAndDrawLine(censored: censored_all,
                                      empMRL: mrlAll.mrl,
                                      theoryMRL: theoryMRL,
                                      theoryCap: theoryAllCap,
                                      color: .chartBlue) {
            entries.append(e)
        }
        if let e = resolveAndDrawLine(censored: censored_up,
                                      empMRL: mrlUp.mrl,
                                      theoryMRL: theoryMRLUp,
                                      theoryCap: theoryUpCap,
                                      color: .chartRed) {
            entries.append(e)
        }

        // 右上角固定位置堆叠标签
        let labelAnchorX = plotX + plotW - 6
        let labelAnchorY = plotY + 6
        let lineHeight: CGFloat = 14

        for (i, entry) in entries.enumerated() {
            let y = labelAnchorY + CGFloat(i) * lineHeight
            let pos = CGPoint(x: labelAnchorX, y: y)
            let lbl = Text(entry.text).font(.system(size: 10).weight(.medium))
            // 白色描边
            let outline = lbl.foregroundStyle(Color.chartBackground)
            for dx: CGFloat in [-1, 1] {
                for dy: CGFloat in [-1, 1] {
                    drawText(&ctx, outline,
                             at: CGPoint(x: pos.x + dx, y: pos.y + dy),
                             anchor: .topTrailing)
                }
            }
            // 主文本
            let main = lbl.foregroundStyle(entry.color)
            drawText(&ctx, main, at: pos, anchor: .topTrailing)
        }

        // v0.1.2.1: 无出金数据时, 在图中央叠加灰色提示文字 (理论曲线仍可见)
        if !hasData {
            let txt = Text("暂无出金数据 (仅显示理论曲线参考)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            drawText(&ctx, txt, at: CGPoint(x: plotX + plotW / 2, y: plotY + plotH / 2))
        }
    }
}
