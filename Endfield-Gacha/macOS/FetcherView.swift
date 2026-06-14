//
//  FetcherView.swift
//  Endfield-Gacha
//
//  URL 粘贴 → 拉取 → 进度日志。关闭时把结果 JSON 的 URL 回传给 ContentView 触发分析。
//
//  AsyncFetch-Design v5 改造:
//    - 拉取改用 GachaFetchCoordinator (Swift async), 不再用 GachaFetcherWrapper。
//    - 目标文件【拉取前】就选好 (NSSavePanel 提前弹出): 协调器整周期对该文件加锁,
//      并在成功后原子落地。失败/取消则不写盘, 原文件 (若选了覆盖) 保持不变。
//      —— 比"先拉取后另存"少一个二次对话框, 且满足整周期 lease 的正确性前提。
//    - 可随时点"停止"取消 (Task.cancel)。
//    - 日志走稳定 id (LogLine) + 限 500 行 (设计 F)。
//

#if os(macOS)

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FetcherView: View {
    @Environment(\.dismiss) private var dismiss
    /// 保存成功后回传文件 URL (用户点"完成并分析"); 取消/关闭时回传 nil。
    /// 传 URL 而非 path String: 与 iOS 一致, 保留 NSSavePanel 授予的文件访问 (沙盒分发更稳妥)。
    let onFinish: (URL?) -> Void

    @State private var urlInput: String = ""
    @State private var droppedFileURL: URL? = nil       // 基底文件 (拖入/选择); 用 URL 以便沙盒读
    @State private var isHoveringDropZone: Bool = false

    @State private var logs: [LogLine] = []
    @State private var logSeq: Int = 0
    @State private var isRunning: Bool = false
    @State private var finishedURL: URL? = nil           // 成功后文件已在此; 仅用于"是否分析"
    @State private var errorMessage: String? = nil

    @State private var fetchTask: Task<Void, Never>? = nil

    private struct LogLine: Identifiable { let id: Int; let text: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拉取抽卡数据")
                .font(.title2.bold())

            Text("粘贴游戏内抽卡记录链接(含 token 参数)，工具会自动抓取并生成 JSON。")
                .font(.callout)
                .foregroundStyle(.secondary)

            // 拖拽 / 点击 文件更新区 (清除按钮 X 用 overlay 叠在右侧, 独立于 Button label)
            ZStack(alignment: .trailing) {
                Button {
                    openBaseFilePanel()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 20))
                            .foregroundStyle(droppedFileURL == nil ? Color.secondary : Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("用于更新的基底文件 (可选):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(droppedFileURL != nil
                                 ? droppedFileURL!.lastPathComponent
                                 : "拖入或点击此处选择已有的 UIGF JSON 文件,留空则创建全新文件。")
                                .font(.system(size: 12))
                                .foregroundStyle(droppedFileURL != nil ? .primary : .tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if droppedFileURL != nil {
                            Color.clear.frame(width: 20, height: 20)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)

                if droppedFileURL != nil {
                    Button {
                        droppedFileURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            }
            .padding(12)
            .background(isHoveringDropZone ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHoveringDropZone ? Color.accentColor : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: isHoveringDropZone ? 2 : 1,
                                               dash: droppedFileURL == nil ? [6] : []))
            )

            // URL 输入与开始按钮
            HStack {
                TextField(
                    "https://ef-webview.gryphline.com/api/record/...&token=...&server_id=...",
                    text: $urlInput
                )
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
                .onSubmit { if !isRunning { startFetch() } }

                Button {
                    startFetch()
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("开始")
                            .frame(minWidth: 48)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 日志区
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logs) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(lineColor(line.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 260, maxHeight: 420)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                // 稳定 id + 限 500 行后, 不再整体重建; 滚到末尾且不包 withAnimation (设计 F)。
                .onChange(of: logs.count) { _, _ in
                    if let last = logs.last?.id { sp.scrollTo(last, anchor: .bottom) }
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            // 底部按钮行
            HStack {
                Spacer()
                if isRunning {
                    Button("停止") { fetchTask?.cancel() }
                        .keyboardShortcut(".", modifiers: [.command])
                } else if finishedURL != nil {
                    Button("取消此次") {
                        // 文件已写入用户选定位置; 这里只是不进入分析, 不删用户的文件。
                        onFinish(nil)
                        dismiss()
                    }
                    Button("完成并分析") {
                        onFinish(finishedURL)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("关闭") {
                        onFinish(nil)
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 720)
        .onDrop(of: [.fileURL], isTargeted: $isHoveringDropZone) { providers in
            guard !isRunning, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "json" else { return }
                DispatchQueue.main.async { self.droppedFileURL = url }
            }
            return true
        }
        .onDisappear { fetchTask?.cancel() }
    }

    /// 弹系统文件选择器选基底 JSON 文件。与拖拽等效。
    private func openBaseFilePanel() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择已有的 UIGF JSON 文件"
        panel.prompt = "选择"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.droppedFileURL = url
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("[错误]") || line.contains("[警告]") || line.contains("[池错误]") || line.contains("失败") { return .red }
        if line.hasPrefix(">>>") || line.contains("完成") || line.contains("已保存") { return .accentColor }
        if line.hasPrefix("  获取到") { return .primary.opacity(0.75) }
        return .primary
    }

    private func appendLogs(_ batch: [String]) {
        for t in batch { logSeq += 1; logs.append(LogLine(id: logSeq, text: t)) }
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    /// 点"开始": 先选保存位置 (整周期加锁需要 destination), 选好再拉取。
    private func startFetch() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "uigf_endfield.json"
        panel.message = "选择保存 UIGF 文件的位置 (拉取完成后写入此处)"
        if let base = droppedFileURL {
            panel.directoryURL = base.deletingLastPathComponent()
            panel.nameFieldStringValue = base.lastPathComponent
        }
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }   // 取消保存对话框 → 不拉取
            self.beginFetch(url: trimmed, destination: dest)
        }
    }

    private func beginFetch(url: String, destination: URL) {
        isRunning = true
        errorMessage = nil
        logs.removeAll(); logSeq = 0
        finishedURL = nil
        if droppedFileURL != nil { appendLogs(["尝试读取基底文件..."]) }

        let base = droppedFileURL
        let coordinator = GachaFetchCoordinator()

        fetchTask = Task { @MainActor in
            do {
                let result = try await coordinator.run(
                    inputURL: url,
                    existingFile: base,
                    destination: destination,
                    destinationKind: .externalDocument,   // 文件选择器/保存面板来的 → 外部文档
                    onLogBatch: { batch in appendLogs(batch) },
                    onProgress: { _ in }
                )
                isRunning = false
                appendLogs(["",
                            "====================",
                            "完成! 本次新增 \(result.newCount) 条, 文件内共计 \(result.totalCount) 条",
                            "已保存至: \(result.url.path)"])
                finishedURL = result.url
            } catch is CancellationError {
                isRunning = false
                appendLogs(["", "已停止,本次未写入。"])
            } catch let e as FetchError {
                isRunning = false
                errorMessage = e.userMessage
            } catch {
                isRunning = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
