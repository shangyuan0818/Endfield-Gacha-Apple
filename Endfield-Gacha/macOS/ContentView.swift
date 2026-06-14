//
//  ContentView.swift
//  Endfield-Gacha
//
//  macOS 主界面:三段式布局
//    - 顶部:配置行(常驻角色/当期UP/常驻武器)
//    - 中部:输出文本 + 图表(4 宫格)
//    - Toolbar:拉取数据按钮(点击弹 sheet)
//
//  所有标准控件(Button/TextField/toolbar)在 macOS 26+ 自动渲染为 Liquid Glass。
//  参考: developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
//
//  跨平台改造说明:
//    - 整个文件用 #if os(macOS) 包住,iOS 编译时跳过(iOS 用 RootTabView)
//    - 原 ContentView.AnalysisBundle 嵌套类型已经提到顶层
//      (定义在 AnalyzerBridge.swift),这里直接用顶层 AnalysisBundle
//

#if os(macOS)

import SwiftUI
import Foundation        // NSFileCoordinator
import UniformTypeIdentifiers

struct ContentView: View {
    // 用户配置:接入跨平台共享 AppConfig,与 iOS 共用同一份默认值/状态。
    //   注入点见 Endfield_GachaApp.swift 的 .environment(config)。
    //   注意:本期 macOS 不做持久化 —— 这里的改动只在本次运行有效,
    //   关闭窗口 / 重启 App 后恢复 AppConfig 的默认值 (与改造前 @State 的行为一致)。
    @Environment(AppConfig.self) private var config

    // 分析状态
    @State private var outputText: String = "将 UIGF JSON 文件拖入窗口,或点击工具栏「拉取数据」按钮从 URL 直接抓取"
    @State private var analysis: AnalysisBundle? = nil
    @State private var isHovering: Bool = false
    @State private var isProcessing: Bool = false

    // 拉取弹窗状态
    @State private var showFetcher: Bool = false

    var body: some View {
        // @Bindable 才能把 @Observable 的字段绑成 $cfg.chars (与 iOS SettingsView 一致)
        @Bindable var cfg = config

        // 整个主区域用 ScrollView 包裹:小屏 MacBook 缩小窗口时
        // 武器卡池/底部图表会被 Dock 或屏幕底端遮挡,这里让用户能滚动查看。
        // 注意:
        //  - ScrollView 内部 maxHeight: .infinity 会塌缩,所以图表区改用 minHeight 保底
        //  - padding/overlay/toolbar/onDrop/sheet 等修饰符放在 ScrollView 外,
        //    保证拖入高亮层、工具栏、弹窗依然覆盖整个窗口
        ScrollView {
            VStack(spacing: 14) {
                // ============ 顶部配置行 ============
                VStack(alignment: .leading, spacing: 10) {
                    Text("支持\u{201C}限定角色卡池:当期UP角色\u{201D}映射。未包含的限定角色卡池将仅排查常驻六星角色名单。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    LabeledRow(label: "常驻六星角色", text: $cfg.chars)
                    LabeledRow(label: "当期 UP 角色", text: $cfg.pool)
                    LabeledRow(label: "常驻六星武器", text: $cfg.weps)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                // ============ 文字输出区 ============
                ScrollView {
                    Text(outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 180)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                )

                // ============ 图表区(4 宫格) ============
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background.secondary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.separator, lineWidth: 1)
                        )

                    if isProcessing {
                        ProgressView("分析中...")
                            .controlSize(.large)
                    } else {
                        // 无导入数据时也显示 6 张图: 传入空的 AnalysisBundle,
                        // ChartGridView 内部 ECDFCanvas / MRLCanvas 在 count_all=0
                        // && count_up=0 时会画坐标轴 + 理论参考曲线 + 灰色
                        // "暂无出金数据" 提示 (v0.1.2.1 行为, 与 Windows / iOS 一致).
                        let bundle = analysis ?? AnalysisBundle(
                            statsChar:  ChartData(),
                            statsJoint: ChartData(),
                            statsWep:   ChartData()
                        )
                        ChartGridView(statsChar:  bundle.statsChar,
                                      statsJoint: bundle.statsJoint,
                                      statsWep:   bundle.statsWep,
                                      layout: .grid2x2)
                            .padding(10)
                    }
                }
                // ScrollView 里 maxHeight: .infinity 会塌缩,这里给 minHeight 保底,
                // 让图表始终有足够的展示高度(原窗口约 1100,减去顶部配置+文字输出后剩 ~750)
                .frame(maxWidth: .infinity, minHeight: 750)
            }
            .padding(16)
        }
        .overlay(
            // 拖入高亮层
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [8]))
                .background(Color.accentColor.opacity(0.08))
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFetcher = true
                } label: {
                    // .labelStyle(.titleAndIcon) 强制 toolbar 同时显示图标和文字。
                    // SwiftUI 的 Label 在 toolbar 默认只渲染图标(认为节省空间),
                    // 但本应用拉取数据是核心入口,被吞掉文字会让用户找不到。
                    // 图标用 arrow.down.circle (而非 iOS 端的 tray.and.arrow.down.fill),
                    // 因为 macOS toolbar 上 fill 图标视觉过重,
                    // 圆形 outline 风格与其他工具栏元素更协调。
                    Label("拉取数据", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("从抽卡记录 URL 拉取最新数据并合并到本地")
                .disabled(isProcessing)
            }
        }
        // 拖拽 UIGF 文件
        .onDrop(of: [.fileURL], isTargeted: $isHovering) { providers in
            // 防御:正在处理时拒绝新拖入,避免双开 worker
            guard !isProcessing, let provider = providers.first else { return false }
            let capturedChars = config.chars
            let capturedPool  = config.pool
            let capturedWeps  = config.weps
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // loadObject 回调可能在任意线程,统一切回主线程
                DispatchQueue.main.async {
                    self.isProcessing = true
                    self.analysis = nil
                    self.outputText = "正在读取并解析文件..."
                    self.runAnalysis(url: url,
                                     chars: capturedChars,
                                     pool: capturedPool,
                                     weps: capturedWeps)
                }
            }
            return true
        }
        // 拉取弹窗
        .sheet(isPresented: $showFetcher) {
            FetcherView { resultURL in
                // 用户点击"完成",FetcherView 关闭后自动触发分析
                showFetcher = false
                if let url = resultURL {
                    self.isProcessing = true
                    self.analysis = nil
                    self.outputText = "拉取完成,正在分析 \(url.path)..."
                    runAnalysis(url: url, chars: config.chars, pool: config.pool, weps: config.weps)
                }
            }
        }
    }

    // 后台线程跑 C++ 分析。
    // 接收 URL 而非 path: 沙盒分发时, 拖入/保存面板给的 URL 需安全作用域才能读 (与 iOS 一致);
    //   非沙盒分发时 startAccessingSecurityScopedResource() 返回 false, 这段即 no-op。
    //   注意异步: 作用域要在读取(analyze)期间持有, 故读完才 stop, 不能用 defer。
    private func runAnalysis(url: URL, chars: String, pool: String, weps: String) {
        let needsAccess = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            // 协调读取 (与 iOS 一致): 与协调写互斥, iCloud / 第三方 File Provider 更稳。
            //   analyze 内部仍 mmap coordinatedURL.path —— 不改用 Swift 读取; 协调开销不在解析热路径。
            //   .withoutChanges: 纯读取, 不触发写方先保存。
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var bundle: AnalysisBundleResult?
            coordinator.coordinate(readingItemAt: url,
                                    options: .withoutChanges,
                                    error: &coordError) { coordinatedURL in
                bundle = AnalyzerBridge.analyze(filePath: coordinatedURL.path,
                                                chars: chars, poolMap: pool, weapons: weps)
            }
            if needsAccess { url.stopAccessingSecurityScopedResource() }

            // 协调失败兜底 (极少见: 文件被删 / 权限丢失 / 无法授予协调访问)。
            let result = bundle ?? AnalysisBundleResult(
                outputText: coordError.map { "文件协调读取失败: \($0.localizedDescription)" }
                    ?? "分析失败 (未知错误)",
                charts: nil
            )
            DispatchQueue.main.async {
                self.outputText = result.outputText
                self.analysis = result.charts
                self.isProcessing = false
            }
        }
    }
}

// 一行 "标签 + TextField" 的抽象,避免重复
private struct LabeledRow: View {
    let label: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

#endif
