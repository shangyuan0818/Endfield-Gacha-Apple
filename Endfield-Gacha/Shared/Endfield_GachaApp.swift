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

    // 冷启动触发 (每进程一次, Command+N / 新窗口不重跑): 准备本进程独占的 generation 工作目录,
    // 并在后台清掉上一/更早进程残留的旧目录。清理只删【其它】进程目录, 永不碰当前目录, 因此与
    // "清理任务晚于本次新工作文件创建"的竞态彻底无关 (按所有权决定生命周期, 见下方 FetchWorkingDirectory)。
    // macOS 不使用工作目录, 故不触发。
    init() {
        #if !os(macOS)
        _ = FetchWorkingDirectory.current
        #endif
    }

    var body: some Scene {
        WindowGroup("终末地抽卡记录分析与可视化") {
            #if os(macOS)
            // macOS:ContentView 已接入同一个 AppConfig (单一默认值来源, 与 iOS 一致)。
            // 本期未启用 macOS 持久化,配置改动仅在本次运行有效。
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

// MARK: - 拉取工作目录 (per-process generation 目录)
//
// 每个进程独占一个 generation 目录: caches/EndfieldFetch/<进程UUID>/。本进程所有拉取的工作文件
// 都建在它里面。清理只删【其它】generation 目录 (上次/更早进程残留), 永不触碰当前进程目录,
// 因此与"清理任务晚于本次新文件创建"的竞态彻底无关 —— 所有权决定生命周期。
// (仅 iOS 使用工作文件; macOS 走 NSSavePanel 外部文档, 不会访问到这里。)
enum FetchWorkingDirectory {
    /// 当前进程独占目录。static let ⇒ 全进程只初始化一次 (线程安全), 且【同步】创建,
    /// 确保在任何 makeWorkingFile() 或清理任务用到它之前就已确定。
    static let current: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EndfieldFetch", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        purgeOldGenerations(base: base, keeping: dir)
        return dir
    }()

    /// 本次拉取的工作文件 = 当前进程目录内的独立 UUID 文件。
    /// 每次都幂等确保 generation 目录存在: Caches 可能在 App 退后台期间被系统回收, 这里重建;
    /// 创建失败则抛给调用方 (清晰报错, 而非稍后 move 失败才暴露)。
    static func makeWorkingFile() throws -> URL {
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        return current.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    /// 后台删除 base 下除当前进程目录外的所有旧 generation 目录。
    /// 用 lastPathComponent (进程 UUID) 比较, 不直接比 URL: 当前目录以 isDirectory:true 创建(带尾斜杠),
    /// 而 contentsOfDirectory 返回的子项多半不带尾斜杠, 直接比 URL 可能把当前目录误判为旧目录删掉。
    /// 目录名是唯一 UUID, 比 lastPathComponent 不受尾斜杠影响。
    private static func purgeOldGenerations(base: URL, keeping current: URL) {
        let currentName = current.lastPathComponent
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
            for item in items where item.lastPathComponent != currentName {
                try? fm.removeItem(at: item)
            }
        }
    }
}
