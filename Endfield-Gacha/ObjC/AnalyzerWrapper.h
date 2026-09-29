//
//  AnalyzerWrapper.h
//  Endfield-Gacha
//
//  ObjC 接口层:C++ 核心运行在 .mm 里,结果包成 NSObject 传给 Swift。
//  Swift 只看到这个头文件,不直接接触任何 C++ 类型。
//  在 Bridging Header 里 #import "AnalyzerWrapper.h"
//

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GachaChartData : NSObject

@property (nonatomic) NSInteger countAll;
@property (nonatomic) NSInteger countUp;
@property (nonatomic) double avgAll;
@property (nonatomic) double avgUp;
@property (nonatomic) double avgWin;
@property (nonatomic) double cvAll;
@property (nonatomic) double ciAllErr;
@property (nonatomic) double ciUpErr;
@property (nonatomic) NSInteger win5050;
@property (nonatomic) NSInteger lose5050;
@property (nonatomic) double winRate5050;
@property (nonatomic) double ksDAll;
// 最大偏差处的坐标及两条 CDF 的值, 与 ksDAll / ksDUp 使用相同统计口径。
@property (nonatomic) NSInteger ksXAll;
@property (nonatomic) double ksEmpiricalAll;
@property (nonatomic) double ksTheoryAll;
@property (nonatomic) BOOL ksIsNormal;
@property (nonatomic) double ksDUp;
@property (nonatomic) NSInteger ksXUp;
@property (nonatomic) double ksEmpiricalUp;
@property (nonatomic) double ksTheoryUp;
@property (nonatomic) BOOL ksIsNormalUp;
// v0.1.4.0: UP 侧样本是否为"两种分布的混合"。重构寻访的理论 UP 曲线描述的是
// 【系列内第一个 UP】(带 120 抽兜底), 而经验 freq_up 记的是每两个 UP 之间的间隔 ——
// 一旦样本里出现第 2 个 UP, 两者就不是同一个统计对象, 不再作"符合/偏离"判定。
@property (nonatomic) BOOL ksUpMixed;
@property (nonatomic) NSInteger censoredPityAll;
@property (nonatomic) NSInteger censoredPityUp;
// 理论 CDF 的有效末端及 ECDF 粒度由 C++ 统一提供, 无样本时也有效。
@property (nonatomic) NSInteger theoryLastValidAll;
@property (nonatomic) NSInteger theoryLastValidUp;
@property (nonatomic) NSInteger ecdfUpStepSize;
// 辉光 UP 的 E[X - lastValid | X > lastValid], 其余池为 0。
@property (nonatomic) double theoryTailMeanExcessUp;

// 单点查询接口（保留向后兼容；Swift 端可以选择不用）
- (int)freqAllAt:(NSInteger)index;
- (int)freqUpAt:(NSInteger)index;
- (double)hazardAllAt:(NSInteger)index;
- (double)hazardUpAt:(NSInteger)index;

// 批量拷贝接口：Swift 用 UnsafeMutableBufferPointer 一次拿全 260 个值，
// 避免逐元素 ObjC msgSend。
// dst 必须至少有 260 个元素的容量。
// v0.1.2.0: 数组从 150 扩到 260, 容纳辉光池 0..240 的 pity 范围.
- (void)copyFreqAllInto:(int * _Nonnull)dst;
- (void)copyFreqUpInto:(int * _Nonnull)dst;
// UP ECDF / KS 专用频数: 武器已按十连申领聚合, 原始频数仍供 MRL 使用。
- (void)copyECDFUpInto:(int * _Nonnull)dst NS_SWIFT_NAME(copyECDFUp(into:));
// 有效末端之后保持最后有效 CDF 值, 不导出未填充哨兵。
- (void)copyTheoryCDFAllInto:(double * _Nonnull)dst NS_SWIFT_NAME(copyTheoryCDFAll(into:));
- (void)copyTheoryCDFUpInto:(double * _Nonnull)dst NS_SWIFT_NAME(copyTheoryCDFUp(into:));
- (void)copyHazardAllInto:(double * _Nonnull)dst;
- (void)copyHazardUpInto:(double * _Nonnull)dst;

@end

@interface GachaAnalysisResult : NSObject
@property (nonatomic, strong, nullable) NSString* textOutput;
@property (nonatomic, strong, nullable) GachaChartData* statsChar;
@property (nonatomic, strong, nullable) GachaChartData* statsWep;
// v0.1.2.0: 辉光庆典池数据
@property (nonatomic, strong, nullable) GachaChartData* statsJoint;
// v0.1.4.0: 重构寻访 (RE-Factor Headhunting) 池数据
@property (nonatomic, strong, nullable) GachaChartData* statsRefactor;
@property (nonatomic) BOOL ok;
@end

@interface GachaAnalyzerWrapper : NSObject
+ (GachaAnalysisResult*)analyzeFile:(NSString*)filePath
                              chars:(NSString*)chars
                            poolMap:(NSString*)poolMap
                            weapons:(NSString*)weapons;
@end

// 注: GachaFetcherWrapper 已废弃 (AsyncFetch-Design v5)。
// 同步 pthread 拉取已拆为 [C++ 状态机 FetchSession] + [Swift 异步编排 GachaFetchCoordinator],
// 接口见 FetchSession.h。

NS_ASSUME_NONNULL_END
