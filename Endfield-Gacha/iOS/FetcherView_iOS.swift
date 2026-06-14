//
//  FetcherView_iOS.swift
//  Endfield-Gacha (iOS)
//
//  iOS 版拉取页:
//    - URL 输入 + (可选)基底文件导入
//    - 开始 → GachaFetchCoordinator (Swift async) 拉取 → 日志实时刷新
//    - 完成后用 .fileExporter 让用户选保存位置("文件"App)
//    - 保存成功后回调 onFinish(url),触发上层切回分析 Tab (传 URL 而非 path: 保留外部文件访问语义)
//
//  AsyncFetch-Design v5 改造说明:
//    - iOS 上 SwiftUI 没有"拉取前先选一个可写外部 URL"的干净 API, 故沿用设计里的
//      .appContainer 目标: 协调器把结果原子落到【应用缓存中的会话级 UUID 工作文件】, 拉完
//      读进内存即【同步删除】该工作文件, 再用 .fileExporter 从内存数据导出副本到用户选定位置。
//      —— 工作文件只是 C++→Swift 的序列化通道, 读完即弃, 故不存在异步删除竞态 (见 startFetch)。
//    - 可随时点工具栏"停止"取消 (Task.cancel)。日志走稳定 id + 限 500 行 (设计 F)。
//
//  此文件仅在 iOS / iPadOS 编译。
//

#if !os(macOS)

import SwiftUI
import UniformTypeIdentifiers

struct FetcherView_iOS: View {
    /// 保存成功后回传文件 URL,RootTabView 用它触发分析。
    /// 传 URL (而非 String path): 用户选的外部位置 (iCloud / 第三方 File Provider) 读回时
    /// 需要安全作用域, 而安全作用域绑定在系统返回的 URL 对象上, 从 path 重建会丢失。
    let onFinish: (URL) -> Void

    // MARK: - 输入
    @State private var urlInput: String = ""
    @State private var baseFilePath: String? = nil
    @State private var baseFileURL: URL? = nil   // 持有 SecurityScopedResource 句柄
    @State private var showBaseImporter: Bool = false

    // MARK: - 运行状态
    @State private var logs: [LogLine] = []
    @State private var logSeq: Int = 0
    @State private var isRunning: Bool = false
    @State private var errorMessage: String? = nil
    @State private var fetchTask: Task<Void, Never>? = nil

    // MARK: - 保存
    @State private var pendingDocument: JSONFileDocument? = nil
    @State private var showExporter: Bool = false

    private struct LogLine: Identifiable { let id: Int; let text: String }

    var body: some View {
        NavigationStack {
            Form {
                // 链接
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $urlInput)
                            .frame(minHeight: 90)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .disabled(isRunning)

                        if urlInput.isEmpty {
                            Text("https://ef-webview.gryphline.com/...&token=...")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                } header: {
                    Text("抽卡记录链接")
                } footer: {
                    Text("从游戏内复制,需含 token / server_id 等参数")
                        .font(.caption)
                }

                // 基底文件
                Section {
                    if let p = baseFilePath {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.tint)
                            Text(URL(fileURLWithPath: p).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                releaseBaseFile()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning)
                        }
                    } else {
                        Button {
                            showBaseImporter = true
                        } label: {
                            Label("选择基底 JSON", systemImage: "doc.badge.plus")
                        }
                        .disabled(isRunning)
                    }
                } header: {
                    Text("基底文件 (可选)")
                } footer: {
                    Text("提供已有的 UIGF JSON 进行增量更新,否则将创建全新文件")
                        .font(.caption)
                }

                // 开始按钮
                Section {
                    Button {
                        startFetch()
                    } label: {
                        HStack {
                            Spacer()
                            if isRunning {
                                ProgressView().controlSize(.small)
                                Text("拉取中...")
                                    .padding(.leading, 6)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("开始拉取").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(isRunning ||
                              urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // 错误
                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                // 日志
                if !logs.isEmpty {
                    Section("日志") {
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
                                .padding(.vertical, 4)
                            }
                            .frame(minHeight: 200, maxHeight: 320)
                            // 稳定 id + 限 500 行后滚到末尾, 不包 withAnimation (设计 F)。
                            .onChange(of: logs.count) { _, _ in
                                if let last = logs.last?.id { sp.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("拉取数据")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if isRunning {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("停止", role: .destructive) { fetchTask?.cancel() }
                    }
                }
            }
            // 选择基底文件
            .fileImporter(
                isPresented: $showBaseImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let ok = url.startAccessingSecurityScopedResource()
                    if ok {
                        baseFileURL?.stopAccessingSecurityScopedResource()
                        baseFileURL = url
                        baseFilePath = url.path
                    } else {
                        errorMessage = "无法访问选中的文件(权限被拒)"
                    }
                }
            }
            // 保存拉取结果到用户选定位置
            .fileExporter(
                isPresented: $showExporter,
                document: pendingDocument,
                contentType: .json,
                defaultFilename: "uigf_endfield"
            ) { result in
                switch result {
                case .success(let savedURL):
                    appendLogs(["", "已保存至: \(savedURL.lastPathComponent)"])
                    pendingDocument = nil          // 工作文件早已删除, 这里只清内存文档
                    onFinish(savedURL)             // 传 URL, 保留外部文件访问语义
                case .failure(let err):
                    errorMessage = "保存失败: \(err.localizedDescription)"
                    pendingDocument = nil
                }
            }
            .onDisappear {
                fetchTask?.cancel()
                releaseBaseFile()
            }
        }
    }

    // MARK: - 辅助

    private func lineColor(_ line: String) -> Color {
        if line.contains("[错误]") || line.contains("[警告]") || line.contains("[池错误]") || line.contains("失败") {
            return .red
        }
        if line.hasPrefix(">>>") || line.contains("完成") || line.contains("已保存") {
            return .accentColor
        }
        if line.hasPrefix("  获取到") {
            return .primary.opacity(0.7)
        }
        return .primary
    }

    private func appendLogs(_ batch: [String]) {
        for t in batch { logSeq += 1; logs.append(LogLine(id: logSeq, text: t)) }
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    private func releaseBaseFile() {
        baseFileURL?.stopAccessingSecurityScopedResource()
        baseFileURL = nil
        baseFilePath = nil
    }

    /// 本次拉取的工作文件 = 当前进程 generation 目录内的独立 UUID 文件。
    /// generation 目录每进程一个; 清理只删【其它】进程的旧目录, 永不碰当前目录, 故与
    /// "清理任务晚于本次新文件创建"的竞态彻底无关 (按所有权决定生命周期, 见 FetchWorkingDirectory)。
    /// (iOS 最终目标文件互斥由 .fileExporter 保证, 不依赖工作文件名。)
    private func workingFileURL() throws -> URL {
        try FetchWorkingDirectory.makeWorkingFile()
    }

    // MARK: - 拉取

    private func startFetch() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        let working: URL
        do { working = try workingFileURL() }
        catch { errorMessage = "无法创建拉取工作目录: \(error.localizedDescription)"; return }

        isRunning = true
        errorMessage = nil
        logs.removeAll(); logSeq = 0
        pendingDocument = nil      // 清掉上一轮未导出的内存文档 (不碰磁盘, 故无异步删除竞态)
        if baseFilePath != nil { appendLogs(["尝试读取基底文件..."]) }

        let base = baseFileURL
        let coordinator = GachaFetchCoordinator()

        fetchTask = Task { @MainActor in
            // 收尾统一解除"拉取中": 覆盖 网络→C++写盘→读入内存→准备导出 整个生命周期。
            // (之前在 run() 返回后就置 false, 后台读 Data 期间用户可重入开始新一轮 → UI 状态交错。)
            defer { isRunning = false }
            do {
                let result = try await coordinator.run(
                    inputURL: trimmed,
                    existingFile: base,
                    destination: working,
                    destinationKind: .appContainer,   // 应用容器内工作文件
                    onLogBatch: { batch in appendLogs(batch) },
                    onProgress: { _ in }
                )
                // 工作文件读进内存即弃: .fileExporter 从内存 Data 导出, 不再依赖磁盘文件。
                // 读取 + 删除都放到 .utility 后台 (不占 MainActor)。.uncached: 一次性中转文件读完即弃,
                //   不污染系统文件缓存。读完回到 MainActor 设置文档并弹导出器。
                // 读失败 → 抛错 → 不导出空文件; 无论成败都删工作文件 (defer)。
                // "完成!" 日志放到读取成功之后记: 读失败时只显示报错, 不再"完成!"与"读取失败"并存。
                let workingURL = result.url
                do {
                    let data = try await Task.detached(priority: .utility) {
                        defer { try? FileManager.default.removeItem(at: workingURL) }
                        return try Data(contentsOf: workingURL, options: .uncached)
                    }.value
                    try Task.checkCancellation()   // 读取期间若已离开页面(本任务被取消)就别再弹导出器
                    appendLogs(["",
                                "====================",
                                "完成! 本次新增 \(result.newCount) 条, 共计 \(result.totalCount) 条"])
                    pendingDocument = JSONFileDocument(data: data)
                    showExporter = true
                } catch is CancellationError {
                    // 已离开/取消: 静默 (未走到"完成!"与导出这一步)
                } catch {
                    errorMessage = "无法读取待导出的工作文件: \(error.localizedDescription)"
                }
            } catch is CancellationError {
                appendLogs(["", "已停止,本次未写入。"])
            } catch let e as FetchError {
                errorMessage = e.userMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - FileDocument 包装
//
// SwiftUI .fileExporter 要求 Transferable/FileDocument。
// 数据来自协调器写入的工作文件, 这里读出来包一层 (Data() 全量读到内存; UIGF JSON 一般几十 KB)。
struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    // data 由调用方在 .utility 后台读好后传入 (读取 + 删除工作文件都不占 MainActor)。
    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
