//
//  SettingsView_iOS.swift
//  Endfield-Gacha (iOS)
//
//  设置 Tab:三个长字符串配置 + 恢复默认按钮。
//
//  设计:
//    - 用 Form/Section 是 iOS 设置页的标准范式,与系统设置 App 风格一致
//    - TextEditor 比 TextField 适合长字符串(几十个逗号分隔项),用户能滚动查看
//    - 离开页面时自动 persist(),避免用户改了不点保存就丢
//

#if !os(macOS)

import SwiftUI

struct SettingsView_iOS: View {
    @Environment(AppConfig.self) private var config

    var body: some View {
        // @Bindable 才能在子视图里把 @Observable 的字段绑成 $cfg.chars
        @Bindable var cfg = config

        NavigationStack {
            Form {
                Section {
                    Text("支持「限定角色卡池:当期UP角色」映射。未包含的限定角色卡池将仅排查常驻六星角色名单。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("常驻六星角色") {
                    TextEditor(text: $cfg.chars)
                        .frame(minHeight: 80)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("恢复默认") { cfg.chars = AppConfig.defaultChars }
                        .font(.footnote)
                }

                Section("当期 UP 角色") {
                    TextEditor(text: $cfg.pool)
                        .frame(minHeight: 100)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("恢复默认") { cfg.pool = AppConfig.defaultPool }
                        .font(.footnote)
                }

                Section("常驻六星武器") {
                    TextEditor(text: $cfg.weps)
                        .frame(minHeight: 120)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("恢复默认") { cfg.weps = AppConfig.defaultWeps }
                        .font(.footnote)
                }
            }
            // TextEditor 默认不响应"点击外部收起键盘". 在 Form 上加
            // scrollDismissesKeyboard, 用户向下滑动列表时键盘跟着收起 (iOS
            // 系统级标准交互, 与短信/邮件 App 一致).
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            // 切走时落盘
            .onDisappear { config.persist() }
        }
    }
}

#endif
