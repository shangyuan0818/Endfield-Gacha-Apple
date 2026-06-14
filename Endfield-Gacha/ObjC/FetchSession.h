//
//  FetchSession.h
//  Endfield-Gacha
//
//  异步拉取重构 (AsyncFetch-Design v5) 的桥接层接口。
//
//  设计动机:把原 GachaFetcherWrapper 里"pthread + dispatch_semaphore 同步拉取"
//  的单体 worker 拆成 [C++ 状态机核心] + [Swift 异步编排]:
//    - 本类 (FetchSession) 只保留状态机 + 字段零额外拷贝核心 (解析/去重/排序/写盘),
//      不再做任何网络 IO (FetchURL 整函数已删)。
//    - 网络请求 / 重试 / 节流 / 取消 / 落地加锁 全部上移到 Swift 的
//      GachaFetchCoordinator (URLSession async)。
//
//  生命周期 (状态机, 见 .mm 的 FetchState):
//    Created --prepare--> ReadyForRequest --nextRequest--> AwaitingResponse
//      --ingestResponseData--> ReadyForRequest (推进 cursor/池) ... --nextRequest--> Done
//      --writeExport--> Exported
//    任一步失败 → Failed (非法调用返回失败结果, 绝不 crash)。
//
//  Swift 只看到本头文件, 不直接接触任何 C++ 类型。
//  在 Bridging Header 里 #import "FetchSession.h"。
//

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - nextRequest 结果

typedef NS_ENUM(NSInteger, FetchNextRequestStatus) {
    FetchNextRequestReady,        // 有下一页要拉 (urlString 非空)
    FetchNextRequestDone,         // 所有池耗尽, 可以 writeExport
    FetchNextRequestFatalError,   // 状态机致命错误 (errorMessage 非空)
};

@interface FetchNextRequestResult : NSObject
@property (nonatomic, readonly) FetchNextRequestStatus status;
@property (nonatomic, readonly, nullable) NSString *urlString;     // Ready 非空
@property (nonatomic, readonly, nullable) NSString *errorMessage;  // FatalError 非空
@property (nonatomic, readonly) NSArray<NSString *> *logs;
@end

// MARK: - ingest 结果

typedef NS_ENUM(NSInteger, FetchIngestStatus) {
    FetchIngestContinue,     // 继续 (同池下一页 / 换池)
    FetchIngestPoolError,    // 池级 API 错误 / 空响应 → 跳过该池, 继续后续池
    FetchIngestFatalError,   // bad_alloc / 状态非法 / 响应非预期 JSON 结构 → 终止会话, 不写盘
};

@interface FetchPageOutcome : NSObject
@property (nonatomic, readonly) FetchIngestStatus status;
@property (nonatomic, readonly) NSInteger newThisPage;
@property (nonatomic, readonly) NSInteger totalNewSoFar;
@property (nonatomic, readonly) NSInteger delayMsBeforeNext;        // 300 同池 / 500 换池(仍有后续池) / 0 末池或完成
@property (nonatomic, readonly) NSArray<NSString *> *logs;
@property (nonatomic, readonly, nullable) NSString *poolErrorMessage;
@property (nonatomic, readonly, nullable) NSString *fatalErrorMessage;
@end

// MARK: - prepare 结果

@interface FetchPrepareResult : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, nullable) NSString *errorMessage;
@property (nonatomic, readonly) NSInteger baseRecordCount;
@property (nonatomic, readonly) NSArray<NSString *> *logs;
@end

// MARK: - writeExport 结果

@interface FetchExportSummary : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly) NSInteger newCount;
@property (nonatomic, readonly) NSInteger totalCount;
@property (nonatomic, readonly, nullable) NSString *tempFilePath;
@property (nonatomic, readonly, nullable) NSString *errorMessage;
@end

// MARK: - FetchSession

@interface FetchSession : NSObject

// init 不构造 C++ impl, 也不执行文件 IO。所有可捕获的 C++ 分配异常集中在 prepare 内处理。
// (Objective-C 的 [copy] 本身仍可能分配内存, 故不说"绝不失败"。)
- (instancetype)initWithInputURL:(NSString *)inputURL
                    existingFile:(nullable NSString *)existingFilePath;

- (FetchPrepareResult *)prepare;                            // Created → ReadyForRequest (失败→Failed)
- (FetchNextRequestResult *)nextRequest;                    // ReadyForRequest → AwaitingResponse(.ready) | Done(.done) | Failed(.fatal)
- (FetchPageOutcome *)ingestResponseData:(NSData *)data;    // AwaitingResponse → ReadyForRequest | Failed(.fatal)
- (FetchExportSummary *)writeExport;                        // Done → Exported

// 注: 已删除 - (void)skipCurrentPool。理由: 网络重试耗尽默认终止整个会话(协调器 throw networkExhausted),
//     不再自动跳池; 且 void 无法表达失败。日后若要"用户可选跳过当前池", 用返回结果对象的版本恢复:
//     // - (FetchSkipResult *)skipCurrentPool;   // AwaitingResponse → ReadyForRequest | Done

@end

NS_ASSUME_NONNULL_END
