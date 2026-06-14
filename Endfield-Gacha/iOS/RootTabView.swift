//
//  RootTabView.swift
//  Endfield-Gacha (iOS)
//
//  根 Tab 容器:分析 / 拉取 / 设置。
//
//  关键交互:
//    - 拉取 Tab 完成后,通过 pendingAnalysisURL 把生成的 JSON URL 传给分析 Tab,
//      并自动切回分析 Tab 触发分析。
//
//  形态适配 (iOS 18+ TabView 体系):
//    iPhone: 始终底部 TabBar (sidebarAdaptable 在 compact size class 下自动降级,
//            顶栏胶囊和 sidebar 都不会出现)
//    iPad 横屏: 默认 sidebar (SwiftUI 系统行为)
//    iPad 竖屏: 默认顶栏胶囊
//    用户可点系统右上角按钮自由切换 → TabViewCustomization 持久化到 UserDefaults
//    持久化是单一的:横竖屏共享同一个偏好(SwiftUI sidebarAdaptable 不支持
//    按方向区分,见 README.md / CHANGELOG 第九节说明)。
//
//  此文件仅在 iOS / iPadOS 编译。
//

#if !os(macOS)

import SwiftUI

struct RootTabView: View {
    /// 待分析的文件 URL。拉取 Tab 完成后会写入,
    /// 分析 Tab 通过 .onChange 监听到后启动分析并消费(置 nil)。
    /// 用 URL (而非 path String): 保留外部文件 (iCloud / 第三方 File Provider) 的安全作用域访问语义。
    @State private var pendingAnalysisURL: URL? = nil

    /// 当前选中 Tab。0=分析 1=拉取 2=设置。
    @State private var selectedTab: Int = 0

    /// Tab 形态偏好 (sidebar / tabBar / 各 Tab 顺序)
    /// @AppStorage 自动持久化到 UserDefaults,App 重启后保留用户选择。
    /// key 用反域名风格避免与其他偏好冲突。
    @AppStorage("tabview.customization.v1")
    private var tabCustomization: TabViewCustomization = TabViewCustomization()

    var body: some View {
        TabView(selection: $selectedTab) {
            // iOS 18 新 Tab API: Tab(标题, 图标, value: 选中 tag) { 内容 }
            // 替代旧 .tabItem 写法,与 sidebarAdaptable 协作良好,
            // 在 sidebar 形态下也能正确显示图标 + 标题。
            Tab("分析", systemImage: "chart.bar.xaxis", value: 0) {
                AnalysisView_iOS(pendingURL: $pendingAnalysisURL)
            }
            // customizationID 是 TabViewCustomization 的稳定标识,
            // 必须给每个 Tab 设置(否则用户的顺序/隐藏状态无法持久化)。
            // 用反域名风格避免与潜在的第三方 Tab 冲突。
            .customizationID("endfield.tab.analysis")

            Tab("拉取", systemImage: "arrow.down.circle", value: 1) {
                FetcherView_iOS { url in
                    // 拉取并保存完成后:写 pending,切回分析 Tab
                    pendingAnalysisURL = url
                    selectedTab = 0
                }
            }
            .customizationID("endfield.tab.fetcher")

            Tab("设置", systemImage: "gearshape", value: 2) {
                SettingsView_iOS()
            }
            .customizationID("endfield.tab.settings")
        }
        // sidebarAdaptable: 在 regular size class (iPad) 上让 TabView
        // 可以在顶栏胶囊 / sidebar 之间切换。系统在右上角自动提供切换按钮。
        // compact size class (iPhone / iPad 多任务窄窗) 下此修饰符不生效,
        // 自动降级为传统底部 TabBar。
        .tabViewStyle(.sidebarAdaptable)
        // 注入持久化对象,让用户的形态选择 / Tab 排序 / Tab 隐藏自动落盘。
        // SwiftUI 自带形态切换动画,无需手动配置。
        .tabViewCustomization($tabCustomization)
    }
}

#endif
