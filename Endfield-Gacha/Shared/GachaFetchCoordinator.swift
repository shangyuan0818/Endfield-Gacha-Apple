//
//  GachaFetchCoordinator.swift
//  Endfield-Gacha
//
//  AsyncFetch-Design v5 —— Swift 异步编排层。
//
//  职责: 网络 / 重试 / 节流 / 取消 / 日志 / 落地 / 按目标文件加锁。
//  C++ 状态机核心 (FetchSession) 只做解析/去重/排序/写盘, 不碰网络。
//
//  工作分配:
//    - URLSession (无 delegate) async API: HTTP 请求 / 等待 / 超时 / 取消
//    - 协调器 (Task.sleep):              分类重试 + 退避 / 300·500ms 节流
//    - .utility 串行队列 (onWork):        URL 构造/解析/去重/排序/写临时文件/落地/临时文件清理 (即所有 bridge + 文件 IO)
//    - 进程级 FetchDestinationGate actor:  目标文件互斥 (lease)
//    - MainActor:                         UI / 进度 / 状态
//
//  无网络白名单 / 重定向限制 (按需求删除); makeRequest 只做"可解析 + http/https scheme"提前报错。
//

import Foundation

// MARK: - 值类型 / 错误

struct PrepareOutcome: Sendable { let ok: Bool; let baseRecordCount: Int; let logs: [String]; let errorMessage: String? }
struct ExportOutcome:  Sendable { let ok: Bool; let newCount: Int; let totalCount: Int; let tempFilePath: String?; let errorMessage: String? }
enum   NextRequest:    Sendable { case ready(urlString: String, logs: [String]); case done(logs: [String]); case fatal(String) }
enum   PageStatus:     Sendable { case continueFetching; case poolError(String?); case fatal(String) }
struct PageOutcome:    Sendable { let status: PageStatus; let totalNewSoFar: Int; let delayMs: Int; let logs: [String] }

/// run 的返回值。设计 E 原型只返回 URL; 这里附带 newCount/totalCount,
/// 以便 View 维持"本次新增 X / 文件内共计 Y"的提示 (小幅扩展, 不改架构)。
struct FetchResult: Sendable { let url: URL; let newCount: Int; let totalCount: Int }

enum FetchError: Error {
    case prepareFailed(String)
    case session(String)               // 状态机 fatal / URL 不可解析 / 非 HTTP 响应
    case auth(Int)                     // 401/403 (token/权限失效) → 终止, 保留原文件
    case unexpectedHTTPStatus(Int)     // 其它非预期状态码 (含跟随/未跟随重定向后的 3xx 等)
    case networkPermanent(Int, String) // 非瞬时 URLError: TLS/证书/不支持的 URL 等 (纯错误处理, 非安全策略)
    case networkExhausted(Int)         // 瞬时错误重试耗尽
    case poolFailed(String)            // 任一卡池返回错误/空响应 → 放弃整次拉取, 保护已有数据
    case write(String)
    case destinationBusy(String)       // 同一目标文件已有拉取在写 (多窗口)
}

extension FetchError {
    /// 给 UI 用的中文描述 (View 兜底 catch 也可直接用)。
    var userMessage: String {
        switch self {
        case .prepareFailed(let m):      return m
        case .session(let m):            return m
        case .auth(let c):               return "鉴权失败 (HTTP \(c)): token 可能已失效, 请重新从游戏内复制链接"
        case .unexpectedHTTPStatus(let c): return "服务器返回非预期状态码 (HTTP \(c))"
        case .networkPermanent(_, let d): return "网络错误: \(d)"
        case .networkExhausted(let c):   return "网络多次重试仍失败 (\(c))"
        case .poolFailed(let m):         return "卡池拉取失败,已放弃本次更新以保护已有数据:\(m)"
        case .write(let m):              return m
        case .destinationBusy(let name): return "目标文件 \(name) 正在被另一处拉取写入, 请稍后再试"
        }
    }
}

// MARK: - SessionBox (受控封装)
// 每次 run 独立; 安全前提 = 只在 work 串行队列内读写 session。
// nonisolated(unsafe): 该属性只在 .utility 串行队列 (onWork) 内访问, 故手动担保并发安全,
//   不受工程"Default Actor Isolation = MainActor"影响 (否则会被推断为 MainActor 隔离)。
private final class SessionBox: @unchecked Sendable {
    nonisolated(unsafe) var session: FetchSession?
}

// MARK: - 多窗口安全: 进程级、按【目标文件】加锁, 用 lease token 释放
struct DestinationLease: Sendable { let key: String }

actor FetchDestinationGate {
    static let shared = FetchDestinationGate()
    private var inUse: Set<String> = []
    private func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    func acquire(_ url: URL) throws -> DestinationLease {
        let k = key(url)
        guard inUse.insert(k).inserted else { throw FetchError.destinationBusy(url.lastPathComponent) }
        return DestinationLease(key: k)
    }
    func release(_ lease: DestinationLease) { inUse.remove(lease.key) }   // 用 lease.key, 不重算, 防归一化漂移
}
// 允许不同窗口拉【不同】文件并发; 只拒绝两个会话写【同一】目标。锁覆盖整个拉取周期 (run 起手取, 结束释放),
// 避免两会话基于同一旧基底各自产出。大小写不敏感卷上 "A.json"/"a.json" key 不同 (现实碰撞"同一文件两窗口拉"
// 已覆盖); 要更严可对已存在文件用 inode/.fileResourceIdentifierKey。

// MARK: - 目标文件来源分层
// 文件/文档选择器返回的外部文档 → externalDocument (需 security scope + NSFileCoordinator);
// 应用自有沙盒容器内路径 → appContainer (无需 scope/协调器, 直接 FileManager)。
// 由 View 在调用 run 时按"这个 URL 是怎么来的"指定。
enum DestinationKind: Sendable { case appContainer, externalDocument }

// MARK: - 协调器

final class GachaFetchCoordinator: Sendable {
    private let urlSession: URLSession
    private let work = DispatchQueue(label: "com.endfield.gacha.fetch-session", qos: .utility)

    init() {
        let cfg = URLSessionConfiguration.ephemeral     // 内存级会话: 不把缓存/Cookie/凭据写入磁盘 (不保证服务端/代理/CDN 返回最新内容)
        cfg.waitsForConnectivity = true                 // 网络暂不可用时等待恢复
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData   // 忽略本地 URLCache；服务端、代理或 CDN 仍可能返回缓存响应。
        cfg.urlCache = nil
        urlSession = URLSession(configuration: cfg)      // 无 delegate: 不做 host 白名单 / 重定向限制 (按需求删除)
    }
    deinit { urlSession.invalidateAndCancel() }          // 释放 session 资源, 取消任何在途任务

    private func onWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let q = work
        return try await withCheckedThrowingContinuation { cont in
            q.async { cont.resume(with: Result { try autoreleasepool(invoking: body) }) }
        }
    }

    // "提前报错"式检查 (非安全策略, 不限制 host/端口/重定向):
    // URL 可解析 + scheme 为 http/https。仅做格式检查, 让明显写错的 endpoint 早点报错;
    // 实际分页 URL 仍由 C++ 按官方 endpoint 生成 (当前不支持自定义服务器)。
    private func makeRequest(_ s: String) throws -> URLRequest {
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw FetchError.session("请求 URL 不可解析或非 http/https") }
        var req = URLRequest(url: url); req.httpMethod = "GET"; return req
    }
}

// MARK: - run / runInner
extension GachaFetchCoordinator {
    func run(inputURL: String, existingFile: URL?, destination: URL, destinationKind: DestinationKind,
             onLogBatch: @escaping @MainActor @Sendable ([String]) -> Void,
             onProgress: @escaping @MainActor @Sendable (Int) -> Void) async throws -> FetchResult {
        let lease = try await FetchDestinationGate.shared.acquire(destination)   // 多窗口: 整周期持锁
        do {
            let result = try await runInner(inputURL: inputURL, existingFile: existingFile,
                                            destination: destination, destinationKind: destinationKind,
                                            onLogBatch: onLogBatch, onProgress: onProgress)
            await FetchDestinationGate.shared.release(lease)
            return result
        } catch {
            await FetchDestinationGate.shared.release(lease)
            throw error
        }
    }

    private func runInner(inputURL: String, existingFile: URL?, destination: URL, destinationKind: DestinationKind,
                          onLogBatch: @escaping @MainActor @Sendable ([String]) -> Void,
                          onProgress: @escaping @MainActor @Sendable (Int) -> Void) async throws -> FetchResult {
        let box = SessionBox()

        // 1) prepare —— 方案A: 基底文件 scope 仅裹 prepare; prepare 内 mmap 读 (无读协调器)。
        let prep: PrepareOutcome = try await onWork {
            let scoped = existingFile?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { existingFile?.stopAccessingSecurityScopedResource() } }
            box.session = FetchSession(inputURL: inputURL, existingFile: existingFile?.path)
            let r = box.session!.prepare()
            return PrepareOutcome(ok: r.ok, baseRecordCount: r.baseRecordCount, logs: r.logs, errorMessage: r.errorMessage)
        }
        await MainActor.run { onLogBatch(prep.logs) }
        guard prep.ok else { throw FetchError.prepareFailed(prep.errorMessage ?? "prepare 失败") }

        // 2) 分页链
        loop: while true {
            try Task.checkCancellation()
            let next: NextRequest = try await onWork {
                let r = box.session!.nextRequest()
                switch r.status {
                case .ready:      return .ready(urlString: r.urlString ?? "", logs: r.logs)
                case .done:       return .done(logs: r.logs)
                case .fatalError: return .fatal(r.errorMessage ?? "状态机致命错误")
                @unknown default: return .fatal("未知 next 状态")
                }
            }
            let request: URLRequest
            switch next {
            case .done(let logs):
                await MainActor.run { onLogBatch(logs) }   // "总计新增拉取 N 条记录"
                break loop
            case .fatal(let m): throw FetchError.session(m)
            case .ready(let urlString, let logs):
                await MainActor.run { onLogBatch(logs) }
                request = try makeRequest(urlString)
            }

            let data = try await fetchPageData(request, onLogBatch: onLogBatch)
            try Task.checkCancellation()

            let outcome: PageOutcome = try await onWork {
                let o = box.session!.ingestResponseData(data)
                let st: PageStatus
                switch o.status {
                case .continue:   st = .continueFetching
                case .poolError:  st = .poolError(o.poolErrorMessage)
                case .fatalError: st = .fatal(o.fatalErrorMessage ?? "未知 ingest 错误")
                @unknown default: st = .fatal("未知 ingest 状态")
                }
                return PageOutcome(status: st, totalNewSoFar: o.totalNewSoFar, delayMs: o.delayMsBeforeNext, logs: o.logs)
            }
            try Task.checkCancellation()

            await MainActor.run { onLogBatch(outcome.logs); onProgress(outcome.totalNewSoFar) }
            switch outcome.status {
            case .continueFetching: break
            case .poolError(let m):
                // 任一卡池失败 → 放弃整次拉取 (不写盘), 保护已有数据。
                // 本轮已抓到的其它卡池新数据一并丢弃; 若是覆盖更新, 原文件保持不变。
                await MainActor.run {
                    onLogBatch(["  [池错误] \(m ?? "未知卡池错误")", "已放弃本次更新以保护已有数据(不写盘)。"])
                }
                throw FetchError.poolFailed(m ?? "未知卡池错误")
            case .fatal(let m):     throw FetchError.session(m)
            }
            if outcome.delayMs > 0 { try await Task.sleep(for: .milliseconds(outcome.delayMs)) }   // 末池 0, 不空等
        }

        // 3) 写临时文件 → (查取消) → 落地; 失败/取消时清理也走 .utility。
        try Task.checkCancellation()
        let summary: ExportOutcome = try await onWork {
            let s = box.session!.writeExport()
            return ExportOutcome(ok: s.ok, newCount: s.newCount, totalCount: s.totalCount,
                                 tempFilePath: s.tempFilePath, errorMessage: s.errorMessage)
        }
        guard summary.ok, let tmp = summary.tempFilePath else { throw FetchError.write(summary.errorMessage ?? "写盘失败") }

        do {
            try Task.checkCancellation()                 // 临时文件写完后、覆盖前 再查一次
            let saved = try await onWork { try Self.finalizeExport(tempPath: tmp, destination: destination, kind: destinationKind) }
            return FetchResult(url: saved, newCount: summary.newCount, totalCount: summary.totalCount)
        } catch {
            try? await onWork { try FileManager.default.removeItem(at: URL(fileURLWithPath: tmp)) }
            throw error
        }
    }
}

// MARK: - fetchPageData (分类重试 + 408 + Retry-After 钳 30s; 无安全校验)
extension GachaFetchCoordinator {
    // 正常翻页结束信号来自 ingest, 不走这里; 重试只针对传输/HTTP, 且发生在 cursor 未推进、
    // bridge 未 ingest 时, 重发同一 request 不污染 C++ 状态。
    private func fetchPageData(_ request: URLRequest,
                               onLogBatch: @escaping @MainActor @Sendable ([String]) -> Void) async throws -> Data {
        let maxRetries = 3; var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, resp) = try await urlSession.data(for: request)
                guard let http = resp as? HTTPURLResponse else { throw FetchError.session("收到非 HTTP 响应") }
                switch http.statusCode {
                case 200...299: return data
                case 401, 403:  throw FetchError.auth(http.statusCode)
                case 429:
                    attempt += 1; if attempt > maxRetries { throw FetchError.networkExhausted(429) }
                    let w = retryAfterSeconds(http) ?? backoff(attempt)
                    await MainActor.run { onLogBatch(["  [限流] 429, \(Int(w))s 后重试 (\(attempt)/\(maxRetries))"]) }
                    try await Task.sleep(for: .seconds(w))
                case 408, 500...599:                                   // 408 也纳入有限重试
                    attempt += 1; if attempt > maxRetries { throw FetchError.networkExhausted(http.statusCode) }
                    let w = backoff(attempt)
                    await MainActor.run { onLogBatch(["  [服务器] HTTP \(http.statusCode), 重试 (\(attempt)/\(maxRetries))"]) }
                    try await Task.sleep(for: .seconds(w))
                default: throw FetchError.unexpectedHTTPStatus(http.statusCode)   // 含 3xx 等
                }
            } catch let e as URLError {
                if Task.isCancelled || e.code == .cancelled { throw CancellationError() }
                guard isTransient(e) else { throw FetchError.networkPermanent(e.errorCode, e.localizedDescription) }
                attempt += 1; if attempt > maxRetries { throw FetchError.networkExhausted(e.errorCode) }
                let w = backoff(attempt)
                await MainActor.run { onLogBatch(["  [网络] \(e.localizedDescription), 重试 (\(attempt)/\(maxRetries))"]) }
                try await Task.sleep(for: .seconds(w))
            }
        }
    }
    private func backoff(_ n: Int) -> Double { [0.5, 1, 2][min(max(n,1),3) - 1] }
    private func isTransient(_ e: URLError) -> Bool {
        [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
         .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable].contains(e.code)
    }
    // 钳到 [0,30] + 有限 + 非负; 不支持 HTTP-date 时回退指数退避。
    private func retryAfterSeconds(_ r: HTTPURLResponse) -> Double? {
        guard let raw = r.value(forHTTPHeaderField: "Retry-After"), let s = Double(raw), s.isFinite, s >= 0 else { return nil }
        return min(s, 30)
    }
}

// MARK: - 落地 (按来源分层: 仅外部文档走 NSFileCoordinator; 容器内直接 FileManager)
extension GachaFetchCoordinator {
    nonisolated static func finalizeExport(tempPath: String, destination: URL, kind: DestinationKind) throws -> URL {
        switch kind {
        case .appContainer:     return try finalizeLocalExport(tempPath: tempPath, destination: destination)
        case .externalDocument: return try finalizeExternalExport(tempPath: tempPath, destination: destination)
        }
    }

    // 应用沙盒容器内: 无需 security scope, 无需协调器。
    nonisolated private static func finalizeLocalExport(tempPath: String, destination: URL) throws -> URL {
        try replaceOrMove(tempPath: tempPath, destination: destination)
        return destination
    }

    // 外部文档 (文件选择器返回, 含 iCloud / 第三方 File Provider): scope + 写协调。
    nonisolated private static func finalizeExternalExport(tempPath: String, destination: URL) throws -> URL {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        var coordErr: NSError?; var opErr: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordErr) { url in
            do { try replaceOrMove(tempPath: tempPath, destination: url) } catch { opErr = error }
        }
        if let coordErr { throw coordErr }
        if let opErr { throw opErr }
        return destination
    }

    // 共用替换逻辑: 目标存在→原子 replace (失败回退 stage→replace); 不存在→move (失败 copy+删)。
    nonisolated private static func replaceOrMove(tempPath: String, destination url: URL) throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: tempPath)
        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                let staged = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? fm.removeItem(at: staged) }
                try fm.copyItem(at: tmp, to: staged)
                _ = try fm.replaceItemAt(url, withItemAt: staged)
                try? fm.removeItem(at: tmp)
            }
        } else {
            do { try fm.moveItem(at: tmp, to: url) }
            catch { try fm.copyItem(at: tmp, to: url); try? fm.removeItem(at: tmp) }
        }
    }
}
