//
//  FetcherView_iOS.swift
//  Endfield-Gacha (iOS)
//
//  iOS 版拉取页:
//    - URL 输入 + (可选)基底文件导入
//    - 开始 → 后台跑 C++ fetchAllPools → 日志实时刷新
//    - 完成后用 .fileExporter 让用户选保存位置("文件"App)
//    - 保存成功后回调 onFinish(path),触发上层切回分析 Tab
//
//  与 macOS 版的对应:
//    - NSSavePanel        → .fileExporter
//    - 拖拽 NSItemProvider → .fileImporter
//    - 弹窗 sheet         → 不需要,本身就是 Tab
//
//  此文件仅在 iOS / iPadOS 编译。
//

#if !os(macOS)

import SwiftUI
import UniformTypeIdentifiers

struct FetcherView_iOS: View {
    /// 保存成功后回传文件路径,RootTabView 用它触发分析。
    let onFinish: (String) -> Void

    // MARK: - 输入
    @State private var urlInput: String = ""
    @State private var baseFilePath: String? = nil
    @State private var baseFileURL: URL? = nil   // 持有 SecurityScopedResource 句柄
    @State private var showBaseImporter: Bool = false

    // MARK: - 运行状态
    @State private var log: [String] = []
    @State private var isRunning: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: - 保存
    @State private var pendingDocument: JSONFileDocument? = nil
    @State private var pendingTempPath: String? = nil
    @State private var showExporter: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // 链接
                Section {
                    // 用 TextEditor 而非 TextField(axis: .vertical):
                    // 后者在 Form Section 里只占 cell 顶部一小条,下方圆角区域
                    // 不是输入区,导致用户点下方没反应。
                    // TextEditor + 显式 frame 高度 + placeholder 覆盖层是
                    // iOS 里多行文本输入的稳定做法。
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $urlInput)
                            .frame(minHeight: 90)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)  // 让 Form 的圆角背景透出来
                            .disabled(isRunning)

                        // placeholder:仅在空时显示,允许点击穿透到下层 TextEditor
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
                if !log.isEmpty {
                    Section("日志") {
                        ScrollViewReader { sp in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(log.enumerated()), id: \.offset) { idx, line in
                                        Text(line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(lineColor(line))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(idx)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(minHeight: 200, maxHeight: 320)
                            .onChange(of: log.count) { _, n in
                                guard n > 0 else { return }
                                withAnimation(.easeOut(duration: 0.1)) {
                                    sp.scrollTo(n - 1, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("拉取数据")
            .navigationBarTitleDisplayMode(.inline)
            // TextEditor 默认不响应"点击外部收起键盘". 在 Form 上加
            // scrollDismissesKeyboard, 用户向下滑动列表时键盘跟着收起 (iOS
            // 系统级标准交互, 与短信/邮件 App 一致).
            .scrollDismissesKeyboard(.interactively)
            // 选择基底文件
            .fileImporter(
                isPresented: $showBaseImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    // iOS 沙盒外文件:必须 startAccessing 才能读
                    let ok = url.startAccessingSecurityScopedResource()
                    if ok {
                        // 释放上一个(如果有)
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
                    log.append("")
                    log.append("已保存至: \(savedURL.lastPathComponent)")
                    let savedPath = savedURL.path
                    cleanupTemp()
                    onFinish(savedPath)
                case .failure(let err):
                    errorMessage = "保存失败: \(err.localizedDescription)"
                    cleanupTemp()
                }
            }
            .onDisappear {
                releaseBaseFile()
            }
        }
    }

    // MARK: - 辅助

    private func lineColor(_ line: String) -> Color {
        if line.contains("[错误]") || line.contains("[警告]") || line.contains("失败") {
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

    private func releaseBaseFile() {
        baseFileURL?.stopAccessingSecurityScopedResource()
        baseFileURL = nil
        baseFilePath = nil
    }

    /// 清理临时拉取文件(用户取消保存或最终取消时调用)
    private func cleanupTemp() {
        let path = pendingTempPath
        pendingTempPath = nil
        pendingDocument = nil
        guard let p = path else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    // MARK: - 拉取

    private func startFetch() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isRunning = true
        errorMessage = nil
        log.removeAll()
        cleanupTemp()  // 清掉上一次未确认的临时文件

        let existFile = baseFilePath ?? ""
        if !existFile.isEmpty {
            log.append("尝试读取基底文件...")
        }

        FetcherBridge.fetchAll(
            url: trimmed,
            existingFile: existFile,
            progress: { msg in
                // ObjC 端已 dispatch 到 main,assumeIsolated 静态消除警告
                MainActor.assumeIsolated {
                    self.log.append(msg)
                }
            },
            completion: { ok, newCount, total, tempPath, err in
                MainActor.assumeIsolated {
                    self.isRunning = false
                    if !ok {
                        self.errorMessage = err.isEmpty ? "拉取失败 (未知错误)" : err
                        return
                    }

                    self.log.append("")
                    self.log.append("====================")
                    self.log.append("完成! 本次新增 \(newCount) 条, 共计 \(total) 条")

                    // 把临时文件包成 FileDocument,触发 .fileExporter
                    self.pendingTempPath = tempPath
                    self.pendingDocument = JSONFileDocument(tempPath: tempPath)
                    self.showExporter = true
                }
            }
        )
    }
}

// MARK: - FileDocument 包装
//
// SwiftUI .fileExporter 要求 Transferable/FileDocument。
// 我们的数据来自 ObjC 写入的临时文件,这里读出来包一层。
//
// 注意:Data() 会全部读到内存,UIGF JSON 一般几十 KB,内存压力可忽略。
// 如果以后数据量上 MB,可以改成 FileWrapper(url:) 走流式。
struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(tempPath: String) {
        self.data = (try? Data(contentsOf: URL(fileURLWithPath: tempPath))) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
