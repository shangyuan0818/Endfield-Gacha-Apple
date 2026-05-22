//
//  Endfield_GachaApp.swift
//  Endfield-Gacha
//
//  跨平台入口。
//  - macOS: 沿用原 ContentView (拖拽 + NSSavePanel 那一套)
//  - iOS / iPadOS: 用 RootTabView (底部 Tab: 分析 / 拉取 / 设置)
//
//  AppConfig 通过 .environment 注入,设置页改完分析页能立即看到。
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@main
struct Endfield_GachaApp: App {
    // iOS 端的设置页要能改这个 config,所以用 @State 持有引用。
    // (@Observable 类只需要持有引用,SwiftUI 会自动追踪字段变化。)
    @State private var config = AppConfig()

    var body: some Scene {
        WindowGroup("终末地抽卡记录分析与可视化") {
            #if os(macOS)
            // macOS:保持现有体验。AppConfig 注入但 ContentView 暂未使用,
            // 留作以后统一时接入。
            // 改为 ScrollView 包裹方案后,只约束最小宽度,不再强制 1100 高度,
            // 小屏 MacBook 可以缩小窗口,内容通过滚动查看;大屏依然能充满。
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
                .environment(config)
            #else
            // iOS / iPadOS:三 Tab 布局
            RootTabView()
                .environment(config)
                // App 进入后台时持久化设置,避免崩溃丢失
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification)) { _ in
                    config.persist()
                }
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
