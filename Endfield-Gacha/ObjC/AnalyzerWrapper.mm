//
//  AnalyzerWrapper.mm
//  Endfield-Gacha
//
//  .mm = ObjC++:可以同时写 C++ 和 ObjC。
//  C++ 核心算法(从 Windows gui.cpp 1:1 迁移)在匿名 namespace 里,
//  ObjC 包装把结果转成 NSObject 属性传给 Swift。
//  Swift 侧没有任何 C++ 类型泄漏。
//

#import "AnalyzerWrapper.h"

#include "JsonScan.h"   // 与 FetchSession.mm 共用的 JSON 扫描器 (v0.1.5.1 抽出)

#include <pthread.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <charconv>
#include <memory_resource>
#include <ranges>
#include <span>           // v0.1.3.3: 理论 CDF 表改用 std::span 传参
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <memory>       // std::make_unique_for_overwrite (C++20) —— worker 的 2MB PMR arena 用它在堆上不清零分配
#include <mutex>        // std::once_flag / std::call_once —— CDF 表只初始化一次, 防并发数据竞态
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// ============================================================
// ObjC 私有扩展：允许 C++ 将计算好的数组灌入实例
// ============================================================
@interface GachaChartData ()
- (void)populateFreqAll:(const int*)arr;
- (void)populateFreqUp:(const int*)arr;
- (void)populateHazardAll:(const double*)arr;
- (void)populateHazardUp:(const double*)arr;
@end

@implementation GachaChartData {
    // 内存安全密封在实例内部
    int    _freqAll[260];
    int    _freqUp[260];
    double _hazardAll[260];
    double _hazardUp[260];
}

// ---- 单点查询接口 (保留向后兼容) ----
- (int)freqAllAt:(NSInteger)index    { return ((NSUInteger)index < 260) ? _freqAll[index]    : 0; }
- (int)freqUpAt:(NSInteger)index     { return ((NSUInteger)index < 260) ? _freqUp[index]     : 0; }
- (double)hazardAllAt:(NSInteger)index { return ((NSUInteger)index < 260) ? _hazardAll[index] : 0.0; }
- (double)hazardUpAt:(NSInteger)index  { return ((NSUInteger)index < 260) ? _hazardUp[index]  : 0.0; }

// ---- 批量拷贝接口 (Swift 一次 memcpy 拿全 260 个值) ----
- (void)copyFreqAllInto:(int*)dst    { memcpy(dst, _freqAll,    260 * sizeof(int));    }
- (void)copyFreqUpInto:(int*)dst     { memcpy(dst, _freqUp,     260 * sizeof(int));    }
- (void)copyHazardAllInto:(double*)dst { memcpy(dst, _hazardAll, 260 * sizeof(double)); }
- (void)copyHazardUpInto:(double*)dst  { memcpy(dst, _hazardUp,  260 * sizeof(double)); }

// ---- C++ 灌入数据接口 ----
- (void)populateFreqAll:(const int*)arr     { memcpy(_freqAll,    arr, 260 * sizeof(int));    }
- (void)populateFreqUp:(const int*)arr      { memcpy(_freqUp,     arr, 260 * sizeof(int));    }
- (void)populateHazardAll:(const double*)arr { memcpy(_hazardAll, arr, 260 * sizeof(double)); }
- (void)populateHazardUp:(const double*)arr  { memcpy(_hazardUp,  arr, 260 * sizeof(double)); }
@end

@implementation GachaAnalysisResult
@end


// ============================================================
// C++ 核心(匿名 namespace,外部不可见)
// ============================================================
namespace {

// ------ 枚举 ------
enum class ItemType  : uint8_t { Unknown = 0, Character, Weapon };
enum class RankType  : uint8_t { Unknown = 0, Rank3=3, Rank4=4, Rank5=5, Rank6=6 };
enum class GachaType : uint8_t { Unknown = 0, Beginner, Standard, Special, Constant, Joint, Refactor };

inline bool ContainsCI(std::string_view hay, std::string_view needle) {
    if (needle.empty() || needle.size() > hay.size()) return false;
    for (size_t i = 0; i + needle.size() <= hay.size(); ++i) {
        bool ok = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            char a = hay[i+j], b = needle[j];
            if (a>='A'&&a<='Z') a=(char)(a+32);
            if (b>='A'&&b<='Z') b=(char)(b+32);
            if (a!=b) { ok=false; break; }
        }
        if (ok) return true;
    }
    return false;
}
inline ItemType ParseItemType(std::string_view sv) {
    if (sv=="Character") return ItemType::Character;
    if (sv=="Weapon")    return ItemType::Weapon;
    if (ContainsCI(sv,"character")) return ItemType::Character;
    if (ContainsCI(sv,"weapon"))    return ItemType::Weapon;
    return ItemType::Unknown;
}
inline RankType ParseRankType(std::string_view sv) {
    if (sv=="6") return RankType::Rank6; if (sv=="5") return RankType::Rank5;
    if (sv=="4") return RankType::Rank4; if (sv=="3") return RankType::Rank3;
    return RankType::Unknown;
}
inline GachaType ParseGachaType(std::string_view sv) {
    // Refactor 池 (重构寻访, 1.5「雪凇幽梦」新增, 客户端 GachaCharPoolTypeTable type=4):
    //   poolId 形如 "rerun_chr_yvonne" (角色) / "rerun_wpn_yvonne" (武器),
    //   /api/record/char 的 pool_type 枚举为 E_CharacterGachaPoolType_Rerun
    //   —— 该枚举已向官方接口实测确认 (见 FetchSession.mm 中 pools 表的说明), 不是猜测。
    //   导出器把 poolId 写进 UIGF 的 gacha_type, 故这里匹配 "rerun";
    //   同时兼容其它工具可能写入的 "refactor" 拼法。
    //   必须【最先】匹配: 其余关键字都不会与 "rerun"/"refactor" 冲突, 但顺序写在前面
    //   可避免将来新增关键字时被子串误判。
    if (ContainsCI(sv,"rerun"))    return GachaType::Refactor;
    if (ContainsCI(sv,"refactor")) return GachaType::Refactor;
    if (ContainsCI(sv,"special"))  return GachaType::Special;
    if (ContainsCI(sv,"beginner")) return GachaType::Beginner;
    if (ContainsCI(sv,"standard")) return GachaType::Standard;
    if (ContainsCI(sv,"constant")) return GachaType::Constant;
    if (ContainsCI(sv,"joint"))    return GachaType::Joint;   // v0.1.2.0: 辉光庆典
    return GachaType::Unknown;
}

// ------ JSON 解析 ------
//
// v0.1.5.1: 扫描器整段提到共享头 JsonScan.h, 与 FetchSession.mm 用同一份实现。
//   此前两边各抄一份 (上游 gui.cpp / main.cpp 也是如此), 于是导出器改成按结构路径读存档之后,
//   分析器还停在"全文找第一个 list"上 —— 同一份合法存档只要顶层成员顺序变成
//   non_pull_events 在前, 分析器就会读到事件 raw 里那个空的 "list": [] 而报"无数据"。
//   另外分析器那版 ForEachJsonObject 返回 void: 数组被截断或混进非对象元素时, 已经吃进的
//   前半段照常参与统计, 用户看到的是一份"少了一截但看起来正常"的报表。
using JsonValueKind = efjson::ValueKind;
using JsonValueRef  = efjson::ValueRef;
using JsonArrayScan = efjson::ArrayScan;

inline size_t FindJsonKey(std::string_view src, std::string_view key, size_t pos = 0) {
    return efjson::FindKeyToken(src, key, pos);
}
inline std::string_view ExtractJsonValue(std::string_view src, std::string_view key, bool isStr) {
    return efjson::ExtractValue(src, key, isStr);
}
template<typename Cb>
[[nodiscard]] JsonArrayScan ForEachJsonObject(std::string_view src, std::string_view arrKey, Cb&& cb) {
    return efjson::ForEachObjectByKey(src, arrKey, std::forward<Cb>(cb));
}

// 读 UIGF v4.2 存档里的抽卡记录数组: 结构路径 根.endfield[0].list 优先, 失败再回退全文找键。
//
// 为什么还要保留回退: 分析页接受【用户从任何工具导出的】UIGF 文件, 结构不一定是
//   endfield[0].list (老版本 v3.0、别的游戏段、别人的扩展写法)。结构路径命中时按结构走,
//   彻底消除"顶层成员顺序影响读取结果"这个问题; 没命中时退回原来的宽松路径, 保持兼容。
// 返回值语义与 JsonArrayScan 一致: NotFound = 没有记录数组; Malformed = 找到了但结构坏了
//   (截断 / 非对象元素 / 缺分隔逗号), 调用方必须据此报错而不是按残缺数据出统计。
template<typename Cb>
[[nodiscard]] JsonArrayScan ReadUigfPullList(std::string_view doc, bool& usedStructuredPath, Cb&& cb) {
    usedStructuredPath = false;
    const JsonValueRef game = efjson::FindMember(doc, "endfield");
    if (game.kind == JsonValueKind::Array) {
        const JsonValueRef entry0 = efjson::FirstElement(game.text);
        if (entry0.kind == JsonValueKind::Object) {
            const JsonValueRef listV = efjson::FindMember(entry0.text, "list");
            if (listV.kind == JsonValueKind::Array) {
                usedStructuredPath = true;
                return efjson::ForEachObjectIn(listV.text, std::forward<Cb>(cb));
            }
        }
    }
    return efjson::ForEachObjectByKey(doc, "list", std::forward<Cb>(cb));
}

// ------ 字符串工具 ------
struct StringHash { using is_transparent=void; size_t operator()(std::string_view sv)const{return std::hash<std::string_view>{}(sv);} };

// 注意:UP 映射文本中故意只识别 ASCII ',' 和 ':' 作为分隔符。
// 全角逗号 '，'(U+FF0C) 与全角冒号 '：'(U+FF1A) 不视为分隔符 —— 因为合法的池名
// 本身可能含有全角逗号(如 "春雷动，万物生")。把全角逗号当分隔符会导致该池
// 的 UP 映射被切碎,UP 识别全部失效。
inline bool IsCommaAt(std::string_view s, size_t i, size_t& adv) {
    if (i<s.size()&&s[i]==','){adv=1;return true;}
    adv=0;return false;
}
inline bool IsColonAt(std::string_view s, size_t i, size_t& adv) {
    if (i<s.size()&&s[i]==':'){adv=1;return true;}
    adv=0;return false;
}
inline std::string_view TrimSV(std::string_view s) {
    while (!s.empty()&&(s.front()==' '||s.front()=='\t'||s.front()=='\r'||s.front()=='\n')) s.remove_prefix(1);
    while (!s.empty()&&(s.back()==' '||s.back()=='\t'||s.back()=='\r'||s.back()=='\n')) s.remove_suffix(1);
    return s;
}
auto ParseCommaSeparated(std::string_view text) {
    std::unordered_set<std::string,StringHash,std::equal_to<>> result;
    size_t i=0,start=0;
    while (i<text.size()) {
        size_t adv=0;
        if (IsCommaAt(text,i,adv)) {
            auto seg=TrimSV(text.substr(start,i-start));
            if(!seg.empty()) result.emplace(seg);
            i+=adv; start=i;
        } else ++i;
    }
    auto seg=TrimSV(text.substr(start));
    if(!seg.empty()) result.emplace(seg);
    return result;
}
auto ParsePoolMap(std::string_view text) {
    std::unordered_map<std::string,std::string,StringHash,std::equal_to<>> result;
    std::string cur_pool; bool reading_up=false; size_t i=0,start=0;
    while (i<text.size()) {
        size_t adv=0;
        if (!reading_up && IsColonAt(text,i,adv)) {
            cur_pool=std::string(TrimSV(text.substr(start,i-start)));
            i+=adv; start=i; reading_up=true;
        } else if (IsCommaAt(text,i,adv)) {
            auto seg=std::string(TrimSV(text.substr(start,i-start)));
            if (reading_up && !cur_pool.empty() && !seg.empty()) result.emplace(cur_pool,seg);
            cur_pool.clear(); reading_up=false;
            i+=adv; start=i;
        } else ++i;
    }
    if (reading_up) {
        auto seg=std::string(TrimSV(text.substr(start)));
        if (!cur_pool.empty() && !seg.empty()) result.emplace(cur_pool,seg);
    }
    return result;
}

// ------ SoA 分桶 ------
// is_free: 标记该记录是否为"第30抽赠送十连"的成员。
// 赠送十连的语义(依据《明日方舟终末地抽卡机制解析》):
//   - 不占用也不增加保底进度 → 不推进 cur_pity / pity_up
//   - 出货时归入 freq_all[30] / freq_up[30] (与理论 CDF 第30抽节点的合并 hazard 对齐)
//   - 出货后玩家本体保底通道独立,cur_pity 不重置
struct PullBucket {
    std::pmr::vector<RankType>         rank_types;
    std::pmr::vector<std::string_view> names;
    std::pmr::vector<std::string_view> poolNames;
    std::pmr::vector<uint8_t>          is_free;   // 1 = 赠送十连内, 0 = 正常抽
    explicit PullBucket(std::pmr::polymorphic_allocator<std::byte> a)
        : rank_types(a), names(a), poolNames(a), is_free(a) {}
    void reserve(size_t n){
        rank_types.reserve(n); names.reserve(n);
        poolNames.reserve(n); is_free.reserve(n);
    }
    void push_back(RankType rt, std::string_view nm, std::string_view pl, uint8_t free_flag){
        rank_types.push_back(rt); names.push_back(nm);
        poolNames.push_back(pl);  is_free.push_back(free_flag);
    }
    size_t size() const { return rank_types.size(); }
};

// ------ StatsAccumulator ------
// 不做 cache-line 对齐: Calculate() 里三个池是【依次】跑的, acc 是单线程局部变量, 不存在多核
// 并发写相邻 accumulator 的 false sharing 场景 —— 旧版 alignas(128) 在此是无操作, 留着只会
// 误导维护者以为有并发。将来若真改成多线程分片归约, 再按实际 cache-line 布局补 padding 即可。
struct StatsAccumulator {
    std::array<int,260> freq_all{}, freq_up{};
    long long sum_all=0, sum_sq_all=0, sum_up=0, sum_sq_up=0, sum_win=0;
    int count_all=0, count_up=0, count_win=0, max_pity_all=0, max_pity_up=0;
    int win_5050=0, lose_5050=0, censored_pity_all=0, censored_pity_up=0;
    // v0.1.5.1: UP 侧的右删失观测【可能不止一条】。重构寻访按系列独立计数, 每个还没出 UP
    //   的系列都是一条"活到 x 抽仍未出 UP"的删失观测; 只取最后活动的那个会把其余系列整条
    //   丢出 Kaplan-Meier 的风险集, 使 hazard 在大 x 处被高估、MRL 给出的"还要多少抽"偏乐观。
    //   censored_pity_up 保留为【界面显示】用的那一个 (玩家正在抽的那期), 风险集用下面两项。
    std::array<int,260> censored_up_marks{};   // 每个水位 x 上有几条 UP 删失观测
    int censored_up_count = 0;                 // 删失观测总条数
    int max_censored_up   = 0;                 // 其中最大的水位
};

// ------ CDF 表 ------
// 综合 6 星: g_cdf_char[0..80] / g_cdf_wep[0..40]
// UP (v0.1.1 新增): g_cdf_char_up[0..120] / g_cdf_wep_up[0..80]
//   角色 UP: 双状态前向迭代 (docs §2.1.2), 第 120 抽硬保底
//   武器 UP: 4×8 状态机 (Reddit Step 4), 第 80 抽 featured 硬保底
// 辉光庆典 UP (v0.1.2.4):
//   g_cdf_joint_up[0..240] + g_joint_tail_mean_excess 长尾解析延伸.
//   池子: 4 个 6 星均匀 (2 限定 + 2 常驻), 无大保底, 无 UP 硬保底.
//   CDF 在 X=240 处 ≈ 0.93 (长尾 ~7%), 用 g_joint_tail_mean_excess 单点近似
//   把截断的长尾质量补回 MRL 计算, 让 MRL[0] 从无延伸的 ~82 修正回 ~104.68.
//   g_joint_tail_mean_excess = E[首限定 | 首限定 > 240] - 240 ≈ 84.37 抽.
//   动态计算 (不写死常量), 保证未来机制改动后自动跟上.
// 角色寻访的基础六星概率 (客户端 GachaCharPoolTypeTable: star6BaseRate = 8000 → 0.8%)。
// 赠送十连(加急招募)恒按【基础概率】判定, 不吃 66 抽起的软保底加成 —— 见下方各
// 免费十连展开循环。
constexpr double kBaseRate6 = 0.008;

double g_cdf_char[82]     = {};
double g_cdf_wep[41]      = {};
double g_cdf_char_up[122] = {};
double g_cdf_wep_up[81]   = {};
double g_cdf_joint_up[242] = {};
// v0.1.4.0 重构寻访 (RE-Factor):
//   g_cdf_refactor[0..80]     综合六星, 与 g_cdf_char 只差赠送十连节点 (30 → 30/60)
//   g_cdf_refactor_up[0..120] 系列内首个 UP, 与 g_cdf_char_up 只差赠送十连节点 (30 → 30/60/90)
double g_cdf_refactor[82]     = {};
double g_cdf_refactor_up[122] = {};
double g_joint_tail_mean_excess = 0.0;
std::once_flag g_cdf_once;   // 保证 CDF 表只初始化一次, 即使多个分析任务并发进入桥接接口

// 真正的表构造逻辑; 只经下方 InitCDFTables() 通过 std::call_once 调用一次, 避免并发写全局数组。
static void InitCDFTables_impl() {
    // ---- 角色池 (综合 6 星 CDF) ----
    // 含 k=30 特殊十连的 11 次合并判定: hazard p —— k=30 用 1-(1-0.008)^11 ≈ 0.08462;
    //   k≤65 为 0.008; k=66..79 每抽 +0.05 软保底; k=80 硬保底必出。
    double surv=1.0;
    for(int i=1;i<=80;++i){
        double p = (i==30) ? 1.0 - std::pow(1.0-0.008, 11)
                 : (i<=65) ? 0.008
                 : (i<=79) ? 0.058 + (i-66)*0.05
                 : 1.0;
        if(p>1.0) p=1.0;
        g_cdf_char[i] = g_cdf_char[i-1] + surv*p;
        surv *= (1.0-p);
    }
    g_cdf_char[81]=1.0;

    // ---- 武器池 (综合 6 星 CDF, “距上次 6 星的抽数 x” 分布) ----
    // 物理模型:
    //   1) 前 3 个十连 (x=1..30) 每抽 4% 独立: P(x=k) = 0.96^(k-1) × 0.04
    //   2) 前 30 抽全未出 (概率 0.96^30), 第 4 个十连保底必出 ≥1 个 6 星; 抽内按
    //      “条件伯努利”展开: 设 Y=本十连内首次命中位置, 无保底 P(Y=j)=0.96^(j-1)×0.04,
    //      P(Y=∞)=0.96^10; 保底强制排除 Y=∞ → P(Y=j|Y≤10)=0.96^(j-1)×0.04 / (1-0.96^10)。
    //   合起来: k=1..30  P_pdf[k]=0.96^(k-1)×0.04;
    //           k=31..40 P_pdf[k]=0.96^30 × [0.96^(k-31)×0.04 / (1-0.96^10)]。
    //   验证 ∫PDF = (1-0.96^30) + 0.96^30×1 = 1 ✓
    //   (简写: bh/bm = 命中/未命中 0.04/0.96, sw = 累计存活, ls = 保底十连内存活,
    //    norm = 1-0.96^10 ≈ 0.3352 为保底十连条件分布归一化常数。)
    {
        double bh=0.04, bm=0.96, sw=1.0;
        // 前 30 抽: 每抽 4% 独立
        for(int k=1;k<=30;++k){g_cdf_wep[k]=g_cdf_wep[k-1]+sw*bh; sw*=bm;}
        // 第 31~40 抽: 保底十连内“条件伯努利”分布 (sw 此时 = 0.96^30 ≈ 0.2939)
        double norm=1.0-std::pow(bm,10), ls=1.0;
        for(int k=31;k<=40;++k){g_cdf_wep[k]=g_cdf_wep[k-1]+sw*(ls*bh/norm); ls*=bm;}
        // g_cdf_wep[40] ≈ 1.0
    }

    // ---- 角色 UP CDF (修正: 删除 v0.1.1.1 的“歪→下次必中”双状态大保底) ----
    //
    // 真实模型: 终末地特许寻访【没有原神/米池式大保底】—— 小保底歪了之后, 下一次出六星
    //   仍是独立 50/50, 可以连续歪多次。唯一的 UP 兜底是【120 抽硬保底】(本期累计 120
    //   抽必出 UP), 每期独立、不继承。经联网核实确认 (官方机制说明 + 社区实测)。
    //   => 状态退化为单维 D[s] (与辉光池同构), 唯一差别是本池在 n=120 强制所有“尚未出
    //      UP”的存活者毕业。
    //   D[s]: 水位 s ∈ [0,80) = 距上次出 6 星的抽数, 概率质量 = “尚未出 UP” 的人群。
    //   每抽: 不出货 → D[s]×(1-ph) 推进到 s+1; 出货(独立 50/50) → 50% 毕业(出 UP),
    //         50% 歪(水位归 0, 仍未出 UP)。
    //   n=30: 展开 11 次判定 (本体抽推进水位; 免费十连水位停, 出货不重置水位)。
    //   n=120: 硬保底, 所有存活者强制出 UP。
    //
    // 历史: v0.1.1 单维 50/50 (无 120 硬保底), E[首 UP] ≈ 81.4;
    //       v0.1.1.1 误加“歪→下次必中”双状态 D[s][h], E[首 UP] ≈ 74.16, 当时以为与社区
    //         74.33 对齐 —— 实则 74.33 是【净成本】(扣前 5 抽免费), 原始抽真值 = 74.33+5
    //         ≈ 79.29; 74.16 只是数值巧合, 掩盖了“终末地根本没有该大保底”这个 bug;
    //       本版改回单维 + 120 硬保底, E[首 UP] = 79.29 原始抽。
    {
        constexpr int hard_cap = 120;
        constexpr int max_soft = 80;
        auto h_char = [](int k) -> double {
            if (k <= 65) return 0.008;
            if (k <= 79) return 0.058 + (k - 66) * 0.05;
            return 1.0;
        };
        // 单维状态: D[s] = 水位 s 且“尚未出 UP”的概率 (无大保底标志, 每次出货独立 50/50)
        std::array<double, max_soft> D{};
        D[0] = 1.0;
        double cum = 0.0;

        for (int n = 1; n <= hard_cap; ++n) {
            if (n == hard_cap) {
                // 120 硬保底: 所有“尚未出 UP”的存活者强制毕业
                double alive = 0.0;
                for (int s = 0; s < max_soft; ++s) alive += D[s];
                cum += alive;
                g_cdf_char_up[n] = std::min(1.0, cum);
                for (int k = n + 1; k <= hard_cap + 1; ++k) g_cdf_char_up[k] = 1.0;
                break;
            }

            std::array<double, max_soft> newD{};
            double p_finish = 0.0;

            if (n == 30) {
                // 1 次本体抽 (推进水位) + 10 次免费抽 (水位停)
                std::array<double, max_soft> stateA{};
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_char(s + 1);
                    if (s + 1 < max_soft) stateA[s + 1] += D[s] * (1.0 - ph);
                    p_finish  += D[s] * ph * 0.5;   // 毕业 (出 UP)
                    stateA[0] += D[s] * ph * 0.5;   // 歪, 水位归 0 (本体抽), 仍未出 UP
                }
                for (int free_step = 0; free_step < 10; ++free_step) {
                    std::array<double, max_soft> stateB{};
                    for (int s = 0; s < max_soft; ++s) {
                        if (stateA[s] == 0) continue;
                        // v0.1.4.0: 赠送十连走【基础概率】, 不吃软保底加成 —— 官方对加急招募的
                        // 原文是「加急招募的干员获取概率与本次寻访的基础概率一致」, 且其结果不计入
                        // 保底计数。本池只有 n=30 一个赠送节点, 此时水位 s <= 30 < 66, h_char() 本
                        // 来就等于基础概率, 故这里数值不变; 改写成 kBaseRate6 是为了与重构寻访
                        // (赠送节点到 n=90, 存活水位可进入 66..79 的软保底段) 用同一套口径。
                        const double ph = kBaseRate6;
                        stateB[s] += stateA[s] * (1.0 - ph);   // 不出货, 水位停
                        p_finish  += stateA[s] * ph * 0.5;     // 毕业 (出 UP)
                        stateB[s] += stateA[s] * ph * 0.5;     // 歪, 水位停 (免费抽)
                    }
                    stateA = stateB;
                }
                cum += p_finish;
                g_cdf_char_up[n] = std::min(1.0, cum);
                D = stateA;
            } else {
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_char(s + 1);
                    if (s + 1 < max_soft) newD[s + 1] += D[s] * (1.0 - ph);
                    p_finish += D[s] * ph * 0.5;   // 毕业 (出 UP)
                    newD[0]  += D[s] * ph * 0.5;   // 歪, 水位归 0, 仍未出 UP
                }
                cum += p_finish;
                g_cdf_char_up[n] = std::min(1.0, cum);
                D = newD;
            }
        }
    }

    // ---- 重构寻访 综合六星 CDF (g_cdf_refactor[0..80]) ----
    // 「重构寻访」(RE-Factor Headhunting) 是 1.5「雪凇幽梦」新增的第五种角色寻访类型,
    // 首期「绚丽异彩」重构寻访#1 于 2026/09/24 12:00 开启 (UP = 伊冯, 旧限定复刻)。
    //
    // 数值来源 (客户端 GachaCharPoolTypeTable type=4, 与特许寻访 type=0 逐字段比对):
    //   star6BaseRate             = 8000    → 0.8%     (与特许寻访相同)
    //   star6RatePromotePullCount = [66]              ┐ 第 66 抽起每抽 +5%
    //   star6RatePromoteValue     = [50000] → +5%     ┘ (与特许寻访相同)
    //   softGuarantee             = 80      → 80 抽硬保底出六星 (与特许寻访相同)
    //   hardGuarantee             = 120     → 120 抽必出 UP     (与特许寻访相同)
    //   shareSoftGuarantee        = true
    //   freeTenPullRewardPullCount = [30, 60, 90]  ← 【唯一的数值差异】
    //     特许寻访是 [30, 0, 0] (只在累计 30 抽送 1 次免费十连),
    //     重构寻访在累计 30 / 60 / 90 抽【各】送 1 次免费十连。
    //   testimonialPullCount      = 0       → 重构寻访没有特许寻访的 60 抽「寻访情报书」
    // 官方规则原文:《「雪凇幽梦」版本研发通讯》 https://endfield.hypergryph.com/news/4776
    //
    // 本表与 g_cdf_char 的唯一差别: 赠送十连的合并 hazard 节点从「只有 30」变成「30 和 60」。
    // 为什么没有 90: 本表按【距上次六星的抽数 x】索引, 而 80 抽硬保底保证 x <= 80,
    //   所以累计第 90 抽的那次赠送十连在本表的坐标系里不可达 (它只能发生在某次六星之后,
    //   此时水位已经归零)。第 3 次赠送十连的贡献在经验侧被并入节点 60 (见 Calculate 中
    //   free_node_all 的说明) —— 这是与既有 g_cdf_char 同一类的、已知且刻意的近似:
    //   赠送十连绑定的是【本期累计抽数】而不是【水位】。
    {
        double surv_rf = 1.0;
        for (int i = 1; i <= 80; ++i) {
            double p;
            if (i == 30 || i == 60) p = 1.0 - std::pow(1.0 - kBaseRate6, 11);  // 本体 1 抽 + 免费十连 10 抽
            else if (i <= 65)       p = 0.008;
            else if (i <= 79)       p = 0.058 + (i - 66) * 0.05;
            else                    p = 1.0;
            if (p > 1.0) p = 1.0;
            g_cdf_refactor[i] = g_cdf_refactor[i - 1] + surv_rf * p;
            surv_rf *= (1.0 - p);
        }
        g_cdf_refactor[81] = 1.0;
    }

    // ---- 重构寻访 UP 理论 CDF (g_cdf_refactor_up[0..120]) ----
    // 与 g_cdf_char_up 同构 (单维水位状态 + 每次出货独立 50/50 + n=120 硬保底强制毕业),
    // 唯一差别: 赠送十连展开点从 {30} 变成 {30, 60, 90}。
    // 注意本表按【累计抽数 n】索引 (不是水位), 所以 30/60/90 三个里程碑都能【精确】表达,
    // 不存在 g_cdf_refactor 那里的坐标系近似。
    //
    // 【重要假设 — 官方未公布】P(UP | 出六星) = 50%。
    //   官方对重构寻访只说「6星干员【伊冯】获取概率大幅提升」, 没有给出 UP 占比数字;
    //   客户端 GachaCharPoolContentTable 的角色条目也【没有】randomWeight 字段
    //   (武器池才有, 武器侧因此能精确算出 20/(20+6*10) = 25%)。
    //   这里沿用特许寻访的 50%, 依据是两池其余全部参数逐字段相同。
    //   ★ 待开池后用游戏内【干员寻访】的概率公示页核对; 若不是 50%, 本表与文本输出里
    //     「理论 50%*」的标注都要跟着改。
    //
    // 【与特许寻访的机制差异 (来自 news/4776 官方原文), 对本表的影响】
    //   - 80 抽小保底:「所有『重构寻访』共享此项保底机制…该保底计数将继承到其他
    //     『重构寻访』中」→ 跨期不清零 (Calculate 里 track_banner 对重构池取 false)。
    //   - 120 抽 UP 保底:「前120次寻访必定能获取概率提升的6星干员, 该规则在同名重构寻访中
    //     【仅生效1次】。该计数将继承到后续的同名重构寻访中」→ 与特许寻访「每期独立重置」
    //     不同, 它是【每个同名系列一生只触发一次】。
    //     ⇒ 本表描述的是【该系列尚未用掉 120 兜底】时的分布 (即首次抽该系列)。
    //       系列兜底一旦用掉, 后续复刻期的理论分布退化为「无 120 硬保底」的长尾形态
    //       (形状接近 g_cdf_joint_up 而非本表)。截至目前「绚丽异彩」#1 是史上第一期
    //       重构寻访, 任何真实数据都只可能处于「兜底未用掉」状态, 故只建首次曲线。
    {
        constexpr int hard_cap = 120;
        constexpr int max_soft = 80;
        auto h_rf = [](int k) -> double {
            if (k <= 65)      return 0.008;
            else if (k <= 79) return 0.058 + (k - 66) * 0.05;
            else              return 1.0;
        };
        std::array<double, max_soft> D{}; D[0] = 1.0;
        double cum = 0.0;
        for (int n = 1; n <= hard_cap; ++n) {
            if (n == hard_cap) {
                double alive = 0.0;
                for (int s = 0; s < max_soft; ++s) alive += D[s];
                cum += alive;
                g_cdf_refactor_up[n] = std::min(1.0, cum);
                for (int k = n + 1; k <= hard_cap + 1; ++k) g_cdf_refactor_up[k] = 1.0;
                break;
            }

            std::array<double, max_soft> newD{};
            double p_hit_grad = 0.0;

            if (n == 30 || n == 60 || n == 90) {
                // ===== 赠送十连里程碑: 11 次独立判定 (本体抽 1 次 + 免费十连 10 次) =====
                // 免费十连不推进也不重置水位 (官方: 其结果不计入保底计数), 与 g_cdf_char_up
                // 在 n=30 的处理完全一致, 这里只是把同一段逻辑用在三个里程碑上。
                std::array<double, max_soft> stateA{};
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_rf(s + 1);
                    if (s + 1 < max_soft) stateA[s + 1] += D[s] * (1.0 - ph);
                    p_hit_grad += D[s] * ph * 0.5;   // 毕业 (出 UP)
                    stateA[0]  += D[s] * ph * 0.5;   // 歪, 水位归 0 (本体抽), 仍未出 UP
                }
                for (int free_step = 0; free_step < 10; ++free_step) {
                    std::array<double, max_soft> newStateA{};
                    for (int s = 0; s < max_soft; ++s) {
                        if (stateA[s] == 0) continue;
                        // 赠送十连走【基础概率】, 不吃软保底加成 —— 官方对加急招募的原文是
                        // 「加急招募的干员获取概率与本次寻访的基础概率一致」, 且其结果不计入
                        // 保底计数。故这里必须用 kBaseRate6 而不是 h_rf(s+1)。
                        //
                        // 为什么特许/辉光池没暴露这个问题: 它们只有 n=30 一个赠送节点, 那时
                        // 水位 s <= 30 < 66, h() 本来就等于基础概率, 两种写法数值相同。
                        // 重构池的第 3 个节点在 n=90, 存活水位可以到 66..79 的软保底段 ——
                        // 若沿用 h_rf, 免费单抽会被算成最高 30.8% 的出货率 (基础是 0.8%)。
                        const double ph = kBaseRate6;
                        newStateA[s] += stateA[s] * (1.0 - ph);   // 不出货, 水位停
                        p_hit_grad   += stateA[s] * ph * 0.5;     // 毕业 (出 UP)
                        newStateA[s] += stateA[s] * ph * 0.5;     // 歪, 水位停 (isFree)
                    }
                    stateA = newStateA;
                }
                newD = stateA;
            } else {
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_rf(s + 1);
                    if (s + 1 < max_soft) newD[s + 1] += D[s] * (1.0 - ph);
                    p_hit_grad += D[s] * ph * 0.5;
                    newD[0]    += D[s] * ph * 0.5;
                }
            }

            cum += p_hit_grad;
            g_cdf_refactor_up[n] = std::min(1.0, cum);
            D = newD;
        }
    }

    // ---- 武器 UP CDF (g_cdf_wep_up[0..80], Reddit “First Featured Weapon Acquisition” Step 4) ----
    // 4×8 状态机:
    //   ns ∈ [0,3]: 已连续多少 10-pull (申领) 没出 6 星 (ns==3 → 第 4 申领触发 6 星保底)
    //   nf ∈ [0,7]: 已连续多少 10-pull 没出 featured (nf==7 → 第 8 申领触发 featured 硬保底)
    //   s = 1 - 0.99^10 ≈ 0.0956   (一次十连含 ≥1 个 featured 的概率)
    //   u = 0.99^10 - 0.96^10 ≈ 0.2395  (无 featured 但有非 featured 6 星)
    //   v = 0.96^10 ≈ 0.6648       (无 6 星)
    //   s_pity = 1 - 0.75 × 0.99^9 ≈ 0.3149  (6 星 pity 拨中 featured 的条件概率)
    // CDF 展开成单抽索引: 只在 10 倍数边界跳变, 其它点平坦 (拨内不出货)。
    {
        const double s = 1.0 - std::pow(0.99, 10);
        const double u = std::pow(0.99, 10) - std::pow(0.96, 10);
        const double v = std::pow(0.96, 10);
        const double s_pity = 1.0 - 0.75 * std::pow(0.99, 9);

        double state[4][8] = {{0}};
        state[0][0] = 1.0;
        std::array<double, 8> finish_per_10pull{};

        for (int k = 0; k < 8; ++k) {
            double newState[4][8] = {{0}};
            double p_feat = 0.0;
            for (int ns = 0; ns < 4; ++ns) {
                for (int nf = 0; nf < 8; ++nf) {
                    double prob = state[ns][nf];
                    if (prob == 0) continue;
                    if (nf == 7) { p_feat += prob; continue; }
                    if (ns == 3) {
                        p_feat += prob * s_pity;
                        newState[0][nf + 1] += prob * (1.0 - s_pity);
                    } else {
                        p_feat += prob * s;
                        newState[0][nf + 1]      += prob * u;
                        newState[ns + 1][nf + 1] += prob * v;
                    }
                }
            }
            finish_per_10pull[k] = p_feat;
            std::memcpy(state, newState, sizeof(state));
        }

        double cum = 0.0;
        for (int k = 0; k < 8; ++k) {
            cum += finish_per_10pull[k];
            int pull_end = (k + 1) * 10;
            g_cdf_wep_up[pull_end] = std::min(1.0, cum);
        }
        for (int i = 1; i <= 80; ++i) {
            if (i % 10 != 0) g_cdf_wep_up[i] = g_cdf_wep_up[(i / 10) * 10];
        }
    }

    // ---- 辉光庆典 UP CDF (v0.1.2.4: 真实前向迭代 + 长尾解析延伸) ----
    //
    // 辉光庆典与 Special 池机制差异关键点:
    //   (1) 池中 4 个 6 星均匀分布: 2 限定 + 2 常驻. P(限定|六星) = 50%
    //   (2) 没有"大保底"——歪了下一次六星不保证是限定
    //   (3) 没有 120 抽 UP 硬保底
    //   (4) n=30 处赠送 10 次免费十连 (水位停)
    //
    // 等价模型: 重复独立"出 6 星"周期, 每周期 50% 概率出限定 (即停止).
    // 完整理论期望: E[首限定] ≈ 104.68 抽.
    //
    // CDF 截到 X=240 (与图表 X 轴一致, 数组 g_cdf_joint_up[242]).
    // CDF[240] ≈ 0.93, 长尾 ~7% 用 g_joint_tail_mean_excess 单点近似补回 MRL.
    {
        constexpr int max_soft = 80;
        constexpr int max_n    = 240;
        auto h_char = [](int k) -> double {
            if (k <= 65)      return 0.008;
            else if (k <= 79) return 0.058 + (k - 66) * 0.05;
            else              return 1.0;
        };
        std::array<double, max_soft> D{}; D[0] = 1.0;
        double cum = 0.0;
        for (int n = 1; n <= max_n; ++n) {
            std::array<double, max_soft> newD{};
            double p_hit_grad = 0.0;

            if (n == 30) {
                // 本体抽 (1 次, 推进水位)
                std::array<double, max_soft> stateA{};
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_char(s + 1);
                    if (s + 1 < max_soft) stateA[s + 1] += D[s] * (1.0 - ph);
                    p_hit_grad += D[s] * ph * 0.5;
                    stateA[0]  += D[s] * ph * 0.5;
                }
                // 免费十连 10 次 (水位停)
                for (int free_step = 0; free_step < 10; ++free_step) {
                    std::array<double, max_soft> newStateA{};
                    for (int s = 0; s < max_soft; ++s) {
                        if (stateA[s] == 0) continue;
                        const double ph = kBaseRate6;   // 赠送十连走基础概率, 不吃软保底加成
                        newStateA[s] += stateA[s] * (1.0 - ph);
                        p_hit_grad   += stateA[s] * ph * 0.5;
                        newStateA[s] += stateA[s] * ph * 0.5;
                    }
                    stateA = newStateA;
                }
                newD = stateA;
            } else {
                for (int s = 0; s < max_soft; ++s) {
                    if (D[s] == 0) continue;
                    double ph = h_char(s + 1);
                    if (s + 1 < max_soft) newD[s + 1] += D[s] * (1.0 - ph);
                    p_hit_grad += D[s] * ph * 0.5;
                    newD[0]    += D[s] * ph * 0.5;
                }
            }

            cum += p_hit_grad;
            g_cdf_joint_up[n] = std::min(1.0, cum);
            D = newD;
        }

        // ---- 长尾解析延伸常量 g_joint_tail_mean_excess ----
        // CDF 在 max_n=240 只到 ~0.93, 直接算 MRL[0] 会低估到 ~82 (真值 ~105).
        // 临时 simulate 到 n=2000 算 E[首限定 | 首限定 > 240] - 240 ≈ 84.37.
        // 见 Windows gui.cpp v0.1.2.4 注释 (此处行为完全一致).
        {
            constexpr int tail_sim_n = 2000;
            std::array<double, max_soft> D2{}; D2[0] = 1.0;
            double tail_sum_k_pdf = 0.0;
            double tail_mass      = 0.0;
            for (int n = 1; n <= tail_sim_n; ++n) {
                std::array<double, max_soft> newD2{};
                double p_hit_grad = 0.0;

                if (n == 30) {
                    std::array<double, max_soft> stateA{};
                    for (int s = 0; s < max_soft; ++s) {
                        if (D2[s] == 0) continue;
                        double ph = h_char(s + 1);
                        if (s + 1 < max_soft) stateA[s + 1] += D2[s] * (1.0 - ph);
                        p_hit_grad  += D2[s] * ph * 0.5;
                        stateA[0]   += D2[s] * ph * 0.5;
                    }
                    for (int free_step = 0; free_step < 10; ++free_step) {
                        std::array<double, max_soft> newStateA{};
                        for (int s = 0; s < max_soft; ++s) {
                            if (stateA[s] == 0) continue;
                            const double ph = kBaseRate6;   // 同上: 赠送十连走基础概率
                            newStateA[s] += stateA[s] * (1.0 - ph);
                            p_hit_grad   += stateA[s] * ph * 0.5;
                            newStateA[s] += stateA[s] * ph * 0.5;
                        }
                        stateA = newStateA;
                    }
                    newD2 = stateA;
                } else {
                    for (int s = 0; s < max_soft; ++s) {
                        if (D2[s] == 0) continue;
                        double ph = h_char(s + 1);
                        if (s + 1 < max_soft) newD2[s + 1] += D2[s] * (1.0 - ph);
                        p_hit_grad += D2[s] * ph * 0.5;
                        newD2[0]   += D2[s] * ph * 0.5;
                    }
                }

                double pdf_n = p_hit_grad;
                if (n > max_n) {
                    tail_sum_k_pdf += (double)n * pdf_n;
                    tail_mass      += pdf_n;
                }
                D2 = newD2;
            }
            if (tail_mass > 1e-12) {
                double E_tail = tail_sum_k_pdf / tail_mass;
                g_joint_tail_mean_excess = E_tail - (double)max_n;
            } else {
                g_joint_tail_mean_excess = 0.0;
            }
            // 预期值: g_joint_tail_mean_excess ≈ 84.37 抽
        }
    }
}

// 公开入口: 线程安全, 多次/并发调用只会真正初始化一次 (std::call_once)。
void InitCDFTables() {
    std::call_once(g_cdf_once, InitCDFTables_impl);
}

// ------ KS 检验 ------
// 修复:freq 的合法索引是 [0, 259];max_pity 必须 clamp 否则越界读
double ComputeKS(const std::array<int,260>& freq,int max_pity,int n,std::span<const double> cdf){
    // v0.1.3.3: "裸指针 + 长度"两个散参 → std::span (工程 C++23)。长度随表走,
    // 调用方不可能再把表和长度传错配对; 函数体保留局部 cdf_len, 下方逻辑零改动。
    const int cdf_len = (int)cdf.size();
    if(!n) return 0.0;
    if(max_pity > 259) max_pity = 259;        // 防御性 clamp
    // v0.1.2.2: 找到 CDF 表的"有效末端" last_valid (饱和到 1 或单调性破坏前的最后一格).
    // 越过 last_valid 后, 用 cdf[last_valid] 而非 1.0 作 fallback —— 这对辉光池
    // (cdf 在 X=240 处 ≈ 0.93, X>240 时 CDF 仍未达 1) 很关键; 旧代码用 1.0 fallback
    // 会让长尾区域的 K-S 偏离凭空变大. 此外对"未填充哨兵段"(辉光池 cdf[241]=0)
    // 也需提前截断, 避免单调性破坏导致 |cum - 0| ≈ 1 的虚假最大偏离.
    constexpr double EPS_SAT = 1e-6;
    int last_valid = cdf_len - 1;
    for (int k = 1; k < cdf_len; ++k) {
        if (cdf[k] >= 1.0 - EPS_SAT) { last_valid = k; break; }
        if (cdf[k] + EPS_SAT < cdf[k - 1]) { last_valid = k - 1; break; }
    }
    auto lookup_cdf = [&](int idx) -> double {
        if (idx < 0) return 0.0;
        if (idx > last_valid) return cdf[last_valid];
        return cdf[idx];
    };
    double md=0.0; int cum=0;
    for(int x=1;x<=max_pity;++x){
        double fb=(double)cum/n;
        double cb=lookup_cdf(x - 1);
        cum+=freq[x];
        double fa=(double)cum/n;
        double ca=lookup_cdf(x);
        double d1=std::abs(fb-cb), d2=std::abs(fa-ca);
        if(d1>md) md=d1; if(d2>md) md=d2;
    }
    return md;
}

// ------ t 分布 + 无偏方差 ------
inline double TCritical95(int df){
    if(df<=0) return 1.959964;
    static constexpr double T[]={0,12.706205,4.302653,3.182446,2.776445};
    if(df<=4) return T[df];
    constexpr double z=1.959964, z2=z*z, z3=z2*z, z5=z3*z2, z7=z5*z2, z9=z7*z2;
    constexpr double g1=(z3+z)/4,
                     g2=(5*z5+16*z3+3*z)/96,
                     g3=(3*z7+19*z5+17*z3-15*z)/384,
                     g4=(79*z9+776*z7+1482*z5-1920*z3-945*z)/92160;
    double d=df, inv=1.0/d;
    return z + g1*inv + g2*inv*inv + g3*inv*inv*inv + g4*inv*inv*inv*inv;
}
inline double SampleVariance(long long sum,long long sum_sq,int n){
    if(n<=1) return 0.0;
    double num=(double)sum_sq-(double)sum*sum/(double)n;
    return (num<0?0:num)/(double)(n-1);
}

// ------ 统计结果结构(内部用) ------
struct StatsResult {
    std::array<int,260>    freq_all{}, freq_up{};
    std::array<double,260> hazard_all{}, hazard_up{};
    int count_all=0, count_up=0, win_5050=0, lose_5050=0;
    double avg_all=0, avg_up=0, avg_win=-1, cv_all=0, ci_all_err=0, ci_up_err=0;
    double win_rate_5050=-1, ks_d_all=0, ks_d_up=0;
    bool ks_is_normal=true, ks_is_normal_up=true;
    // v0.1.4.0: UP 侧样本是否为"两种分布的混合", 混合时不输出拟合判定 (见 Calculate)
    bool ks_up_mixed=false;
    int censored_pity_all=0, censored_pity_up=0;
};

// ------ Calculate (从 gui.cpp 逐行迁移; 含赠送十连机制修正) ------
//
// 第30抽赠送十连的处理 (依据《明日方舟终末地抽卡机制解析》2.1.1):
//   - 该十连享有基础概率 0.008,但不占用也不增加保底进度
//   - 输入数据中赠送十连用 isFree=true 标记 (10 条独立记录)
//   - 不推进 cur_pity / pity_up (本体保底通道独立)
//   - 若赠送内出 6 星,归入 freq_all[30] (与理论 CDF 中第30抽节点的
//     合并 hazard `1-(1-0.008)^11` 对齐),sum_all/sum_up 也用 30 计入
//   - 赠送出货不重置玩家本体的 cur_pity (按"独立通道"语义)
//   - 仍计入 count_all / count_up / win_5050 / lose_5050,因为这是真实出货
//
// win_5050 / lose_5050 / avg_win 的“UP 判定”语义 (三池不同):
//   - 角色池 (Special): 每个 6 星独立 50/50, 无大保底; 唯一兜底 120 抽硬保底 (每期独立、
//             不继承)。win_5050=真实掷中 UP 数 (剔除 120 强制), lose=非 UP 数, avg_win 有义。
//   - 武器池 (Weapon):  每个 6 星独立判定 UP (条件率 25%); 唯一兜底 80 抽(8 申领)限定硬保底
//             (40 小保底 + 80 硬保底每期独立重算、均不继承)。win_5050=真实掷中限定数
//             (剔除 80 强制), lose=非限定 6 星数; avg_win 对武器池无定义, 保持 -1。
//   - 辉光庆典 (Joint): 4 个 6 星均匀 (2 限定 + 2 常驻), P(限定|6星)=50%, 无大保底/无硬保底。
//             “UP”= 不在常驻名单 = 真·限定。综合 CDF 复用 g_cdf_char, 限定 CDF 用专建
//             g_cdf_joint_up (无 120 硬保底, 不复用已加硬保底的 g_cdf_char_up)。
//
// v0.1.2.0 加 isJoint 参数:
//   - 辉光池没有"小保底"概念 (每个 6 星独立 50% 出限定),
//     win_5050 / lose_5050 按"每个 6 星是不是限定"独立计数 (跟武器池一样).
//   - 三池均无“歪→下次必中”大保底 (had_non_up 逻辑已在 v0.1.x 修正中删除).
//   - UP 判定走 standard_names 排除法 (pool_map 为空).
//
// v0.1.4.0 加 isRefactor 参数 (重构寻访 RE-Factor):
//   - 池中六星 = 当期 UP + 5 名常驻 (无往期限定滞留), 所以 pool_map 与常驻排除法
//     两条路径都能正确判 UP; 与 Special 一样走 pool_map 优先。
//   - 80 抽小保底【所有重构寻访之间共享继承】→ cur_pity 全局共享, 不按期重置。
//   - 120 抽 UP 保底 / 累计奖励 / 未使用的加急招募【只在同名系列内继承, 且兜底一生仅
//     生效 1 次】→ 这三样按 pool_name 存进 series_states, 离开某系列再回来能接上进度。
//     不能用"换池就清零"来近似: 那样 A→B→A 时 A 的进度会丢 (见 series_states 处说明)。
//   - 赠送十连有 3 处 (累计 30/60/90 抽), 而非特许寻访的 1 处; 计数同样按系列独立。
//   官方规则原文: https://endfield.hypergryph.com/news/4776
StatsResult Calculate(const PullBucket& bucket, bool isWeapon, bool isJoint,
    const std::unordered_set<std::string,StringHash,std::equal_to<>>& std_names,
    const std::unordered_map<std::string,std::string,StringHash,std::equal_to<>>& pool_map,
    bool isRefactor = false)
{
    StatsAccumulator acc;
    int cur_pity=0, pity_up=0;            // 函数级单份状态 (特许 / 辉光用; 见下方 keyedUp/keyedAll)
    // 保底作用域 (四池各不同 —— 联网核实 + 数据验证):
    //   - 特许池(Special): 仅 120 硬保底每期重置 (pity_up); 80 小保底【继承】(cur_pity 不重置)
    //   - 武器池(Weapon):  40 小保底 + 80 硬保底都【按期】独立 (v0.1.5.1 起改为按 pool_name 存,
    //                      不再靠相邻探测 —— 1.5 起重构申领与武库申领的记录会交错)
    //   - 辉光庆典(Joint): 无硬保底, 连续累加, 不按期重置
    //   - 重构寻访(Refactor): 80 小保底跨所有重构池共享继承 (全局), 120 UP 保底按【同名系列】
    //                      一生一次 (按 pool_name 存)
    //   got_up_banner: 本期/本系列是否已出过 UP (硬保底每期仅生效一次)
    //   hardpity_n:    硬保底强制阈值 —— 角色 120 抽; 武器 8 申领(= 第 71..80 抽强制出限定)
    bool got_up_banner=false;
    const bool track_special = (!isWeapon && !isJoint && !isRefactor);
    const bool track_weapon  = isWeapon;
    // track_banner 现在只表示"这个池型【有】硬保底"(用于 forced_by_hardpity 的剔除),
    // 不再承担边界重置的职责 —— 那已经由下面的按键存状态接管。
    const bool track_banner  = (track_special || track_weapon);   // Joint 没有硬保底
    const int  hardpity_n    = isWeapon ? 71 : 120;

    // 赠送十连块计数 (v0.1.4.0): 重构寻访在累计 30/60/90 抽各送 1 次免费十连,
    //   需要把每个 isFree 块映射到对应的里程碑节点, 否则三个块会全部挤在节点 30,
    //   与理论 CDF 对不上。特许/辉光只有 1 处赠送十连, 恒为节点 30, 不受影响。
    //
    //   计法: 直接数【本桶内累计的 isFree 记录条数】, 第 n 条属于第 (n/10) 块 (0-based)。
    //   不能靠"非 isFree → isFree 的跳变"来分块 —— 官方允许把未使用的加急招募留到后面
    //   (「未使用的加急招募, 将保留到后续同名重构寻访中」), 玩家完全可能攒够 90 抽后
    //   连着开三次十连, 记录里就是连续 30 条 is_free=true, 跳变法只会数出 1 块。
    //
    //   已知局限: 抽卡记录只保留最近 90 天, 历史被截断时第一块可能只剩半截 (甚至整块被切掉),
    //   会让后续块序号整体降一档。无法从记录本身分辨, 故不做补偿。
    //   ★ v0.1.5.1 更正此前的注释: 影响【不】只是"落在哪个理论节点"。slot_up / slot_all 会
    //   直接进 sum_up / sum_all, 所以 avg / 95% CI / CV / K-S D 也会跟着偏低 —— 节点值就是
    //   被计入的抽数, 是同一个量。只有出货计数与胜负统计不受影响。
    int free_pull_count = 0;                       // 非重构池用 (恒为节点 30, 实际不参与计算)

    // 重构寻访的【按系列保存】状态 (v0.1.4.0)。
    //   官方两个作用域不同:
    //     - 80 抽六星保底:「所有『重构寻访』共享」→ cur_pity 全局共享, 不进本表
    //     - 120 抽首个 UP 保底 / 累计奖励 / 未使用的加急招募:
    //       「在【同名】重构寻访中仅生效 1 次 / 将保留到后续【同名】重构寻访中」
    //       → 每个系列各自一份, 离开再回来要能接上
    //   早先的写法是"pool_name 变了就把 UP 侧清零", 那只能处理 A→B, 处理不了
    //   A→B→A: 回到 A 时 A 的进度已经被抹掉, 会把本该是第 120 抽的首个 UP 记成第 60 抽,
    //   也会把已经用掉的兜底额度错误地"还"给 A。而且这【不需要两个系列同时开放】,
    //   依次经历 A 第一期 → B 第一期 → A 第二期就会发生。
    //   系列标识用 pool_name: 同名系列的 #1/#2/#3 共用一个 pool_name, 不同系列名字不同。
    // v0.1.5.1: 这套"按 pool_name 存状态"从重构寻访推广到武器池, 原因见下。
    struct BannerState {
        int  pity_all   = 0;      // 距该池上一个六星的抽数 (只有武器池用: 角色池的小保底是全局的)
        int  pity_up    = 0;      // 距该池/该系列上一个 UP 的抽数 (硬保底的计数)
        int  free_count = 0;      // 该系列已用掉的赠送十连条数 (决定 30/60/90 节点)
        bool got_up     = false;  // 该池/该系列的硬保底额度是否已被本体抽消耗
        int  up_count   = 0;      // 该池/该系列内已出的 UP 个数 (判"样本是否混合", 见 ks_up_mixed)
    };
    std::unordered_map<std::string_view, BannerState> series_states;
    BannerState* last_series = nullptr;   // 收尾算右删失时用最后活动的那一份

    // 状态的作用域 (四种池各不相同):
    //   keyedUp  = UP 侧状态 (硬保底计数 / 额度 / 赠送十连块) 按 pool_name 各存一份
    //   keyedAll = 连综合六星水位也按 pool_name 各存一份 (只有武器池需要)
    //
    // 武器池为什么必须按键存 (v0.1.5.1):
    //   1.5 起「重构申领」(poolId rerun_wpn_*) 与常规「武库申领」【同时开放】, 而武器记录
    //   接口没有 pool_type 参数 —— 所有武器池都在同一条 /api/record/weapon 时间线里返回,
    //   桶内按 |id| 升序 = 真实时间序, 于是两池的记录是【交错】的。旧的"相邻记录 pool_name
    //   变了就算新一期"探测会把玩家每一次来回切池都当成换期而清零水位: 真实垫到第 40 抽才
    //   出的六星可能被记成 pity=10, freq_all / avg / CV / 95% CI / K-S 全部系统性偏低,
    //   pity_up 同样被反复清零使 80 抽硬保底的剔除永不触发, UP 率被抬高。
    //   按 pool_name 各存一份之后, 交错不再互相干扰。
    //   对【顺序出现、不交错】的既有数据, 两种写法逐位等价 (换期时新键的初值就是 0)。
    const bool keyedUp  = (isRefactor || track_weapon);
    const bool keyedAll = track_weapon;

    const size_t total = bucket.size();
    for(size_t i=0; i<total; ++i){
        const bool isFree = bucket.is_free[i];

        // 按 pool_name 取出这一期/这个系列自己的状态 (不存在则默认构造)。
        //   unordered_map 是节点式容器, 插入新键不会让已取得的引用失效。
        //   特许/辉光池仍用函数级的单份状态, 行为与既有版本完全一致。
        BannerState* ss = nullptr;
        if (keyedUp) {
            ss = &series_states[bucket.poolNames[i]];
            last_series = ss;
        }
        int&  pity_all  = keyedAll ? ss->pity_all   : cur_pity;
        int&  up_pity   = keyedUp  ? ss->pity_up    : pity_up;
        bool& up_gotten = keyedUp  ? ss->got_up     : got_up_banner;
        int&  free_cnt  = keyedUp  ? ss->free_count : free_pull_count;

        // 本条若是赠送十连, 先算出它属于第几块 (1-based), 再累加计数
        int free_block_idx = 0;
        if (isFree) free_block_idx = (free_cnt++ / 10) + 1;

        // 卡池边界探测: 只剩【特许寻访】还用"相邻记录 pool_name 变了 = 进入新一期"。
        //   特许池: 120 硬保底不继承 → pity_up + got_up_banner 清零; 80 小保底继承 (cur_pity 不动)。
        //   同一时间只开一期特许寻访, 记录不会交错, 所以相邻探测在这里是安全的。
        //   武器池 / 重构池的状态已经按 pool_name 各存一份 (见上), 换池只是换一份状态,
        //   不需要也不能在这里清零。
        if (track_special && i > 0 && bucket.poolNames[i] != bucket.poolNames[i - 1]) {
            pity_up       = 0;
            got_up_banner = false;
        }

        // 赠送十连: 不推进保底通道
        if (!isFree) {
            ++pity_all; ++up_pity;
        }

        if(bucket.rank_types[i]!=RankType::Rank6) [[likely]] continue;

        // 出 6 星. 决定计入 freq 的位置:
        //   - 赠送十连出货 -> 归入对应里程碑节点 (特许/辉光恒为 30; 重构为 30/60/90)
        //   - 正常出货     -> 归入 freq[cur_pity]
        //
        // 重构寻访的两套坐标系 (v0.1.4.0):
        //   free_node_up  用于 freq_up —— g_cdf_refactor_up 按【累计抽数】索引, 30/60/90
        //                  三个里程碑都能精确表达, 直接按块序号映射。
        //   free_node_all 用于 freq_all —— g_cdf_refactor 按【距上次六星的水位】索引,
        //                  而 80 抽硬保底保证水位 <= 80, 累计第 90 抽的赠送十连在该坐标系
        //                  里不可达, 故第 3 块及以后并入节点 60。这是与既有 g_cdf_char
        //                  同一类的已知近似 (赠送十连绑定累计抽数而非水位), 见 InitCDFTables。
        int free_node_all = 30, free_node_up = 30;
        if (isRefactor && free_block_idx >= 2) {
            free_node_all = 60;
            free_node_up  = (free_block_idx == 2) ? 60 : 90;
        }
        const int slot_all = isFree ? free_node_all : pity_all;
        if(slot_all<260) acc.freq_all[slot_all]++;
        if(slot_all>acc.max_pity_all) acc.max_pity_all=slot_all;
        acc.count_all++;
        acc.sum_all    += slot_all;
        acc.sum_sq_all += (long long)slot_all*slot_all;

        bool isUP=false;
        if (isJoint) {
            // 辉光池: pool_map 为空, 直接走 standard_names 排除法 (非常驻 = 限定)
            isUP = !std_names.contains(bucket.names[i]);
        } else {
            // 特许 / 重构: pool_map 优先, 缺映射时回退"不在常驻名单 = UP"的排除法。
            // 重构池中六星 = 当期 UP + 5 名常驻 (无往期限定滞留), 两条路径都成立。
            auto it=pool_map.find(bucket.poolNames[i]);
            if(it!=pool_map.end()) isUP=(bucket.names[i]==it->second);
            else                   isUP=!std_names.contains(bucket.names[i]);
        }

        if(isUP){
            const int slot_up = isFree ? free_node_up : up_pity;
            if(slot_up<260) acc.freq_up[slot_up]++;
            if(slot_up>acc.max_pity_up) acc.max_pity_up=slot_up;
            acc.count_up++;
            acc.sum_up    += slot_up;
            acc.sum_sq_up += (long long)slot_up*slot_up;
            if (ss) ss->up_count++;   // 重构池: 记在【所属系列】名下, 而不是整桶

            // 胜负统计 (修正: 终末地无“歪→下次必中”, 每个六星/六星武器都是独立判定):
            //   - 角色池 50/50, 武器池 25% 条件率 —— 每个 UP/限定都计入“胜”, 唯一例外:
            //     由【硬保底强制】出的那个 (本期首个 UP/限定, 且当期累计抽数已打满硬保底阈值)
            //     不是掷硬币结果, 必须剔除 (角色 120 抽; 武器 8 申领即第 71..80 抽), 否则把
            //     真实条件率系统性拉高 (角色>50%, 武器>25%)。
            //   - 辉光庆典: 无硬保底, 每个限定直接计入。
            //   - avg_win (count_win/sum_win) 对特许/重构池有物理含义 (两者都有"歪/不歪");
            //     武器池与辉光庆典不累计, avg_win 保持 -1。
            // 重构寻访也【有】120 抽硬保底, 只是作用域是"同名系列一生一次" —— up_gotten
            // 对重构池取的是【该系列】的状态且永不清零, 恰好等价于该语义, 故一并放行。
            // (track_banner 只涵盖特许与武器, 见上方定义。)
            const bool forced_by_hardpity =
                (track_banner || isRefactor) && !up_gotten && !isFree && up_pity >= hardpity_n;
            if(isJoint){
                acc.win_5050++;                 // 辉光庆典无硬保底, 每个限定都是掷硬币结果
            } else if(!forced_by_hardpity){
                acc.win_5050++;
                if(!isWeapon){            // avg_win 仅对特许/重构池定义 (Joint 走上面的分支)
                    acc.count_win++;
                    acc.sum_win += slot_all;
                }
            }
            // 只有【本体抽】出的 UP 才消耗硬保底额度。赠送十连是独立通道, 官方明确
            // 「加急招募所赠送的免费十连, 其抽取结果将不计入本次或其他寻访的保底计数」——
            // 免费十连里出了 UP, 本体的 120 抽硬保底依然成立。
            // (该问题在重构池之前就存在: 旧写法无条件置 true, 会让免费出 UP 之后那次真正
            //  由 120 硬保底强制出的 UP 被误算成一次随机"不歪", 抬高胜率。)
            if (!isFree) {
                up_gotten = true;
                up_pity   = 0;   // 赠送十连出 UP 不重置水位 (独立通道)
            }
        } else {
            // 非 UP/非限定六星 = 一次独立判定的“负”。终末地可连续歪多次, 全部如实计入。
            acc.lose_5050++;
        }
        // 赠送十连出货不重置综合水位 (独立通道); 正常出货重置
        if (!isFree) pity_all=0;
    }
    // 综合六星的右删失: 武器池的水位按期各存一份, 取【最后活动的那一期】—— 与旧写法
    //   (相邻探测每期清零, 收尾时 cur_pity 恰好就是最后一期的残值) 在顺序数据上逐位等价。
    acc.censored_pity_all = (keyedAll && last_series) ? last_series->pity_all : cur_pity;
    // 右删失的 UP 水位: 按键存状态的池型 (武器 / 重构) 取【最后活动的那一份】的进度 ——
    //   界面上的"当前垫刀"关心的是玩家正在抽的那期; 特许/辉光仍用函数级的单份状态。
    //   ★ 这里必须用 keyedUp 而不是 isRefactor: 武器池的 up_pity 现在也绑在按键状态上,
    //     漏掉它会让武器池的"距上次 UP N 抽"恒显示 0。
    acc.censored_pity_up  = (keyedUp && last_series) ? last_series->pity_up : pity_up;
    // Kaplan-Meier 的风险集要把【每一个】还没出 UP 的系列都算上, 见 StatsAccumulator 的说明。
    {
        auto markCensored = [&](int x){
            if (x <= 0) return;
            if (x > 259) x = 259;
            acc.censored_up_marks[x]++;
            acc.censored_up_count++;
            if (x > acc.max_censored_up) acc.max_censored_up = x;
        };
        if (isRefactor) {
            // 重构寻访的 120 兜底计数【跨期继承】(官方: "计数将继承到后续的同名重构寻访中"),
            // 所以每个还没出 UP 的系列都是一条真正还在走的删失观测, 都要进风险集。
            for (const auto& kv : series_states) markCensored(kv.second.pity_up);
        } else if (keyedUp) {
            // 武器池: 每期的 80 抽硬保底【不】继承, 已经结束的那几期不是"还在等", 只有最后
            // 活动的那一期才是删失观测 —— 与旧写法保持一致, 不改动既有用户的武器统计。
            markCensored(last_series ? last_series->pity_up : 0);
        } else {
            markCensored(pity_up);
        }
    }

    // 防御性 clamp:即使数据异常导致 max_pity > 259,后续读取也必须安全
    if (acc.max_pity_all > 259) acc.max_pity_all = 259;
    if (acc.max_pity_up  > 259) acc.max_pity_up  = 259;
    if (acc.censored_pity_all > 259) acc.censored_pity_all = 259;
    if (acc.censored_pity_up  > 259) acc.censored_pity_up  = 259;

    StatsResult s;
    // std::array 整体赋值 = 编译器优化的 memcpy,与 gui.cpp 一致
    s.freq_all = acc.freq_all;
    s.freq_up  = acc.freq_up;
    s.count_all = acc.count_all;
    s.count_up  = acc.count_up;
    s.win_5050  = acc.win_5050;
    s.lose_5050 = acc.lose_5050;
    s.censored_pity_all = acc.censored_pity_all;
    s.censored_pity_up  = acc.censored_pity_up;

    if(acc.count_all>0){
        s.avg_all = (double)acc.sum_all/acc.count_all;
        double var = SampleVariance(acc.sum_all, acc.sum_sq_all, acc.count_all);
        double sd  = std::sqrt(var);
        s.cv_all   = (s.avg_all>0) ? sd/s.avg_all : 0;
        s.ci_all_err = TCritical95(acc.count_all-1) * sd / std::sqrt((double)acc.count_all);
        // 重构寻访另用 g_cdf_refactor —— 与 g_cdf_char 只差赠送十连节点 (30 → 30/60)
        const std::span<const double> cdf = isWeapon
            ? std::span<const double>(g_cdf_wep)              // 41
            : (isRefactor ? std::span<const double>(g_cdf_refactor)   // 82
                          : std::span<const double>(g_cdf_char));    // 82
        s.ks_d_all = ComputeKS(acc.freq_all, acc.max_pity_all, acc.count_all, cdf);
        s.ks_is_normal = (s.ks_d_all <= 1.36/std::sqrt((double)acc.count_all));
    }

    // Kaplan-Meier 经验风险函数 (综合六星):支持右删失
    if(acc.count_all>0 || acc.censored_pity_all>0){
        int surv = acc.count_all + (acc.censored_pity_all>0 ? 1 : 0);
        int maxR = std::max(acc.max_pity_all, acc.censored_pity_all);
        if (maxR > 259) maxR = 259;
        for(int x=1; x<=maxR; ++x){
            if(surv>0){
                s.hazard_all[x] = (double)acc.freq_all[x]/surv;
                surv -= acc.freq_all[x];
                if(x==acc.censored_pity_all) surv--;
            }
        }
    }
    if(acc.count_up>0){
        s.avg_up = (double)acc.sum_up/acc.count_up;
        double var = SampleVariance(acc.sum_up, acc.sum_sq_up, acc.count_up);
        s.ci_up_err = TCritical95(acc.count_up-1) * std::sqrt(var) / std::sqrt((double)acc.count_up);
        // UP KS 检验: 用 g_cdf_*_up
        // v0.1.2.0: 辉光池走 g_cdf_joint_up
        // ★ 选表必须是一条【完整闭合】的 if/else 链, 且后面不能再紧跟别的 if ——
        //   Windows 端 v0.1.4.0 曾在这条链和它的 else 之间插进一个 if, 结果 else 改绑到了
        //   新 if 上, 武器池/辉光池/只有 1 个 UP 的重构池全部被覆盖成 g_cdf_char_up。
        //   编译无警告, 真实数据上武器池的 D 值从 0.2603 被抬到 0.4241。之后若要在这里
        //   加逻辑, 请加在整条链【结束之后】, 并保持每个分支都带花括号。
        std::span<const double> cdf_up;                        // v0.1.3.3: 长度由 span 自带
        if      (isJoint)    { cdf_up = g_cdf_joint_up;    }   // 242
        else if (isWeapon)   { cdf_up = g_cdf_wep_up;      }   // 81
        else if (isRefactor) { cdf_up = g_cdf_refactor_up; }   // 122
        else                 { cdf_up = g_cdf_char_up;     }   // 122

        // g_cdf_refactor_up 描述的是【系列内第一个 UP】的分布 —— 它在 n=120 强制收敛到 1,
        // 依据是「前120次寻访必定获取 UP, 该规则在同名重构寻访中仅生效 1 次」。
        // 而 freq_up 记的是每两个 UP 之间的间隔: 同一系列里第 2 个及以后的 UP 已经没有这个
        // 兜底, 分布是无截断的长尾。两者不是同一个统计对象, 混在一起就没法判"符合/偏离"。
        //
        // v0.1.5.1: 判据从"整桶 count_up > 1"改成"【某个系列内】出现了第 2 个 UP"。
        //   旧写法把"两个不同系列各出 1 个首 UP"也误标成混合 —— 那恰恰是同分布的合法样本,
        //   本可以判定却被吞掉了结论。
        //   已知仍未覆盖的一种真混合: 某系列的 120 兜底在更早的、已被 90 天窗口截掉的记录里
        //   就用掉了, 从记录本身无法分辨; 这种情况会被当成"未混合"而给出判定。
        s.ks_up_mixed = false;
        if (isRefactor) {
            for (const auto& kv : series_states) {
                if (kv.second.up_count > 1) { s.ks_up_mixed = true; break; }
            }
        }
        if (isWeapon) {
            // v0.1.3.3 武器 UP K-S: 先把经验 freq_up 按申领 (10 抽) 粒度向上聚合再比较。
            // 原因: g_cdf_wep_up 的质量只在 10 倍数边界记账 (申领内平坦, 机制如此),
            // 而经验 pity_up 记录的是申领内具体单抽落点 (自然出货 ~截断几何分布,
            // 40/80 保底强制出货的拨内落点游戏未公开)。两条阶梯粒度不同, 逐抽比较会被
            // "拨内错位"系统性抬高 D (落点均匀假设下渐近 ~0.37, 12 期样本伪拒绝率 ~63%)。
            // 聚合到申领边界后, 任何拨内落点都映射到同一申领, K-S 对落点假设免疫,
            // 伪拒绝率回到 <= 名义 5% (模拟: ~2%)。
            // 仅 K-S 内部用聚合副本; ECDF/MRL 图与 avg_up 仍为单抽粒度, 曲线连贯不变。
            std::array<int,260> freq_up_claim{};
            for (int x = 1; x <= acc.max_pity_up; ++x) {
                if (acc.freq_up[x] == 0) continue;
                int slot = ((x + 9) / 10) * 10;   // 向上取整到申领末抽
                if (slot > 259) slot = 259;       // 防御 (正常数据 pity_up <= 80)
                freq_up_claim[slot] += acc.freq_up[x];
            }
            int max_claim = ((acc.max_pity_up + 9) / 10) * 10;
            if (max_claim > 259) max_claim = 259;
            s.ks_d_up = ComputeKS(freq_up_claim, max_claim, acc.count_up, cdf_up);
        } else {
            s.ks_d_up = ComputeKS(acc.freq_up, acc.max_pity_up, acc.count_up, cdf_up);
        }
        s.ks_is_normal_up = (s.ks_d_up <= 1.36/std::sqrt((double)acc.count_up));
    }
    // UP hazard 同理。风险集含【全部】删失观测 (非重构池恒为 0 或 1 条, 与旧行为逐位一致)。
    if(acc.count_up>0 || acc.censored_up_count>0){
        int surv = acc.count_up + acc.censored_up_count;
        int maxR = std::max(acc.max_pity_up, acc.max_censored_up);
        if (maxR > 259) maxR = 259;
        for(int x=1; x<=maxR; ++x){
            if(surv>0){
                s.hazard_up[x] = (double)acc.freq_up[x]/surv;
                surv -= acc.freq_up[x];
                surv -= acc.censored_up_marks[x];
            }
        }
    }
    if(acc.count_win>0)
        s.avg_win = (double)acc.sum_win/acc.count_win;
    if(acc.win_5050+acc.lose_5050>0)
        s.win_rate_5050 = (double)acc.win_5050/(acc.win_5050+acc.lose_5050);
    return s;
}

// ------ 密封数据到 ObjC ------
GachaChartData* ToChartData(const StatsResult& s) {
    GachaChartData* d = [[GachaChartData alloc] init];
    [d populateFreqAll:   s.freq_all.data()];
    [d populateFreqUp:    s.freq_up.data()];
    [d populateHazardAll: s.hazard_all.data()];
    [d populateHazardUp:  s.hazard_up.data()];

    d.countAll          = s.count_all;
    d.countUp           = s.count_up;
    d.avgAll            = s.avg_all;
    d.avgUp             = s.avg_up;
    d.avgWin            = s.avg_win;
    d.cvAll             = s.cv_all;
    d.ciAllErr          = s.ci_all_err;
    d.ciUpErr           = s.ci_up_err;
    d.win5050           = s.win_5050;
    d.lose5050          = s.lose_5050;
    d.winRate5050       = s.win_rate_5050;
    d.ksDAll            = s.ks_d_all;
    d.ksIsNormal        = s.ks_is_normal;
    d.ksDUp             = s.ks_d_up;
    d.ksIsNormalUp      = s.ks_is_normal_up;
    d.ksUpMixed         = s.ks_up_mixed;
    d.censoredPityAll   = s.censored_pity_all;
    d.censoredPityUp    = s.censored_pity_up;
    return d;
}

// ------ 文本格式化 ------
//
// v0.1.4.0: 从三池扩到四池 (特许 / 辉光 / 重构 / 武器), 顺序与 Windows 端一致。
NSString* FormatOutput(const StatsResult& sc, const StatsResult& sj,
                       const StatsResult& sr, const StatsResult& sw) {
    auto pendStr = [](int pa, int pu) -> NSString* {
        if(!pa && !pu) return @"";
        return [NSString stringWithFormat:@"  [当前垫刀: 距上次六星 %d 抽 / 距上次 UP %d 抽]", pa, pu];
    };
    auto ksLabel = [](int n, bool ok) -> NSString* {
        if(!n) return @"-"; return ok ? @"符合理论模型" : @"偏离过大";
    };
    // UP 侧的判定标签: 混合样本 (系列内首个 UP 带 120 兜底 / 后续 UP 无兜底) 没有单一
    // 理论分布可比, 不作判定 —— 只有重构寻访会出现这种情况, 见 Calculate 的 ks_up_mixed。
    auto ksUpLabel = [](int n, bool ok, bool mixed) -> NSString* {
        if(!n) return @"-";
        if(mixed) return @"样本混合, 不判定";
        return ok ? @"符合理论模型" : @"偏离过大";
    };
    NSString* winC = sc.avg_win>=0 ? [NSString stringWithFormat:@"%.2f 抽", sc.avg_win] : @"[无数据]";
    NSString* winR = sr.avg_win>=0 ? [NSString stringWithFormat:@"%.2f 抽", sr.avg_win] : @"[无数据]";
    // v0.1.5.1: 重构池的"理论 ≈ 77.83"是 E[系列内第一个 UP] (前提: 120 兜底未用掉)。
    //   样本一旦混进同系列的第 2 个 UP, 这个基准就不适用了 —— 下面的 K-S 判定已经降级成
    //   "样本混合, 不判定", 均值行的理论值也必须跟着说清楚, 否则同一段输出自相矛盾。
    NSString* refTheoryUp = sr.ks_up_mixed ? @"(理论 ≈ 77.83, 仅适用于系列内首个 UP; 本样本混合)"
                                           : @"(理论 ≈ 77.83)                    ";
    return [NSString stringWithFormat:
        @"【角色卡池 (特许寻访)】 总计六星: %d | 出当期 UP: %d%@\n"
        @" ▶ 综合六星 (含歪) 出货平均期望:     %.2f 抽 (理论 ≈ 51.81)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 (理论 ≈ 79.29)   [95%% CI: %.1f ~ %.1f]    |   真实不歪率: %.1f%% (理论 50%%) (%ld胜%ld负)\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 赢下小保底 (不歪) 的出货期望:     %@\n\n"
        @"【角色卡池 (辉光庆典)】 总计六星: %d | 出限定: %d%@\n"
        @" ▶ 综合六星出货平均期望:             %.2f 抽 (理论 ≈ 51.81)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到任一限定 (非常驻) 的平均期望: %.2f 抽 (理论 ≈ 104.68)  [95%% CI: %.1f ~ %.1f]    |   非常驻六星率: %.1f%% (理论 50%%) (%ld限定%ld常驻)\t[K-S 检验偏离度 D值: %.3f (%@)]\n\n"
        // v0.1.4.0: 重构寻访 (RE-Factor)。理论值 51.37 / 77.83 来自 g_cdf_refactor /
        // g_cdf_refactor_up —— 比特许寻访各低约 0.4 / 1.5 抽, 差异全部来自多出的两次
        // 赠送十连 (累计 60 / 90 抽)。UP 占比官方未公布, 暂沿用特许寻访的 50%。
        @"【角色卡池 (重构寻访)】 总计六星: %d | 出当期 UP: %d%@\n"
        @" ▶ 综合六星 (含歪) 出货平均期望:     %.2f 抽 (理论 ≈ 51.37)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 %@ [95%% CI: %.1f ~ %.1f]    |   真实不歪率: %.1f%% (理论 50%%*) (%ld胜%ld负)\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 赢下小保底 (不歪) 的出货期望:     %@\t\t(* UP 占比官方未公布, 暂沿用特许寻访的 50%%, 待开池后核实)\n\n"
        @"【武器卡池 (武库申领)】 总计六星: %d | 出当期 UP: %d%@\n"
        @" ▶ 综合六星出货平均期望:             %.2f 抽 (理论 ≈ 19.17)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        // v0.1.3.3: 武器 UP 理论参考值 81.66 → 54.74。81.66 是 Reddit 原文"忽略 80 抽
        // 硬保底"的无截断期望, 与本程序 K-S/MRL 用的含保底模型 (g_cdf_wep_up, 均值
        // 54.737) 自相矛盾 —— 经验均值必然 <=80, 应与 54.74 对照。另: 经验 pity_up 记
        // 申领内单抽落点, 实测均值常比按申领末记账的 54.74 再低 3~7 抽 (落点未公开)。
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 (理论 ≈ 54.74)   [95%% CI: %.1f ~ %.1f]    |   6 星中 UP 率: %.1f%% (理论 25%%) (%ld UP / %ld 非UP)\t[K-S 检验偏离度 D值: %.3f (%@)]",
        sc.count_all, sc.count_up, pendStr(sc.censored_pity_all,sc.censored_pity_up),
        sc.avg_all, std::max(1.0, sc.avg_all-sc.ci_all_err), sc.avg_all+sc.ci_all_err,
            sc.cv_all*100, sc.ks_d_all, ksLabel(sc.count_all, sc.ks_is_normal),
        sc.avg_up, std::max(1.0, sc.avg_up-sc.ci_up_err), sc.avg_up+sc.ci_up_err,
            (sc.win_rate_5050>=0?sc.win_rate_5050:0.0)*100,
            (long)sc.win_5050, (long)sc.lose_5050,
            sc.ks_d_up, ksUpLabel(sc.count_up, sc.ks_is_normal_up, sc.ks_up_mixed),
            winC,
        sj.count_all, sj.count_up, pendStr(sj.censored_pity_all,sj.censored_pity_up),
        sj.avg_all, std::max(1.0, sj.avg_all-sj.ci_all_err), sj.avg_all+sj.ci_all_err,
            sj.cv_all*100, sj.ks_d_all, ksLabel(sj.count_all, sj.ks_is_normal),
        sj.avg_up, std::max(1.0, sj.avg_up-sj.ci_up_err), sj.avg_up+sj.ci_up_err,
            (sj.win_rate_5050>=0?sj.win_rate_5050:0.0)*100,
            (long)sj.win_5050, (long)sj.lose_5050,
            sj.ks_d_up, ksUpLabel(sj.count_up, sj.ks_is_normal_up, sj.ks_up_mixed),
        sr.count_all, sr.count_up, pendStr(sr.censored_pity_all,sr.censored_pity_up),
        sr.avg_all, std::max(1.0, sr.avg_all-sr.ci_all_err), sr.avg_all+sr.ci_all_err,
            sr.cv_all*100, sr.ks_d_all, ksLabel(sr.count_all, sr.ks_is_normal),
        sr.avg_up, refTheoryUp, std::max(1.0, sr.avg_up-sr.ci_up_err), sr.avg_up+sr.ci_up_err,
            (sr.win_rate_5050>=0?sr.win_rate_5050:0.0)*100,
            (long)sr.win_5050, (long)sr.lose_5050,
            sr.ks_d_up, ksUpLabel(sr.count_up, sr.ks_is_normal_up, sr.ks_up_mixed),
            winR,
        sw.count_all, sw.count_up, pendStr(sw.censored_pity_all,sw.censored_pity_up),
        sw.avg_all, std::max(1.0, sw.avg_all-sw.ci_all_err), sw.avg_all+sw.ci_all_err,
            sw.cv_all*100, sw.ks_d_all, ksLabel(sw.count_all, sw.ks_is_normal),
        sw.avg_up, std::max(1.0, sw.avg_up-sw.ci_up_err), sw.avg_up+sw.ci_up_err,
            (sw.win_rate_5050>=0?sw.win_rate_5050:0.0)*100,
            (long)sw.win_5050, (long)sw.lose_5050,
            sw.ks_d_up, ksUpLabel(sw.count_up, sw.ks_is_normal_up, sw.ks_up_mixed)
    ];
}

// -----------------------------------------------------------
// 线程参数上下文
// -----------------------------------------------------------
struct AnalyzeThreadContext {
    NSString* filePath;
    NSString* chars;
    NSString* poolMap;
    NSString* weapons;
    GachaAnalysisResult* result;
};

// -----------------------------------------------------------
// 核心分析任务 (由调用方在后台队列直接同步调用; arena 在堆上, 用调用方线程栈即可)
// 形参仍是 void*, 保留旧 pthread 入口签名以便最小改动。
// -----------------------------------------------------------
void* analyze_worker(void* arg) {
    @autoreleasepool {
        AnalyzeThreadContext* ctx = (AnalyzeThreadContext*)arg;

        // PMR: 2MB 单调缓冲池 (monotonic_buffer_resource)。v0.1.3.2 起【改放堆上】(此前在栈上)。
        //
        // 为什么从栈改到堆 (用 make_unique_for_overwrite, 而不是 std::vector<std::byte>(2MB)):
        //   - 把 2MB 放进次级线程栈会显著压缩栈余量, 大栈帧还可能触发额外页面触达/栈检查,
        //     后续扩展也更容易栈溢出; 堆 arena 生命周期更明确。
        //   - make_unique_for_overwrite 不主动清零整个 arena (区别于 std::vector(2MB) / 带括号
        //     的 new[]() / calloc 那种值初始化), 可避免无意义地写满 2MB。注意: 实际页面提交、
        //     物理驻留与 page fault 数取决于系统分配器、页面复用与运行时访问模式 —— 别写死成
        //     "只有写入部分才落物理页"或"栈版一定被强制触达整块 2MB"。
        //   - arena 移到堆上后不再需要给 worker 配 4MB 栈, pthread 用系统默认栈即可。
        //   - (先前感到"堆版更卡"是因为当时用了会清零的写法; 本写法无清零, 不复现该开销。)
        // 关于缓存: 别再写"L1/L2 热 / TLB 不 miss"。2MB = 512 页, 远超 L1 DTLB;
        //   能保证的只是减少分配器调用 + 让 temps/bucket 集中在一段连续内存 (利于顺序访问的局部性)。
        // 关于 fallback: pool 没显式指定 upstream, 默认 = get_default_resource() (= new/delete)。
        //   故【不是】严格只用这 2MB: 超大导入耗尽后会 fallback 到堆而非崩溃 (有意为之, 比抛
        //   bad_alloc 退出更实用)。另注 monotonic_buffer_resource 不回收 vector 扩容前的旧块,
        //   直到整个 pool 析构 —— 一旦 reserve() 预估被大幅突破, arena 占用会比普通 allocator
        //   涨得快。
        // 生命周期: 声明顺序 arena → pool → alloc, 析构逆序 (alloc/pool 先, arena 后), 故 pool
        //   引用的 arena 内存在 pool 存活期间始终有效; 各 pmr 容器声明在 alloc 之后, 会更早析构。
        constexpr size_t kArenaSize = 2 * 1024 * 1024;
        auto arena = std::make_unique_for_overwrite<std::byte[]>(kArenaSize);
        std::pmr::monotonic_buffer_resource pool(arena.get(), kArenaSize);
        std::pmr::polymorphic_allocator<std::byte> alloc(&pool);

        InitCDFTables();

        const char* fp = ctx->filePath.UTF8String;
        if (!fp) { ctx->result.textOutput = @"路径无效"; return nullptr; }

        auto stdChars = ParseCommaSeparated(ctx->chars.UTF8String   ?: "");
        auto pm       = ParsePoolMap        (ctx->poolMap.UTF8String ?: "");
        auto stdWeps  = ParseCommaSeparated(ctx->weapons.UTF8String ?: "");

        int fd = open(fp, O_RDONLY);
        if (fd < 0) { ctx->result.textOutput = @"文件读取失败"; return nullptr; }
        struct stat st{};
        if (fstat(fd, &st) != 0 || st.st_size <= 0) {
            close(fd);
            ctx->result.textOutput = @"文件为空";
            return nullptr;
        }
        const size_t fileSize = (size_t)st.st_size;
        const char*  mapData  = (const char*)mmap(nullptr, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (mapData == MAP_FAILED) {
            ctx->result.textOutput = @"内存映射失败";
            return nullptr;
        }

        std::string_view bufView(mapData, fileSize);
        if (bufView.size()>=3
            && (uint8_t)bufView[0]==0xEF
            && (uint8_t)bufView[1]==0xBB
            && (uint8_t)bufView[2]==0xBF)
        {
            bufView.remove_prefix(3);
        }

        struct Temp {
            long long id;
            ItemType  it;
            GachaType gt;
            RankType  rt;
            std::string_view name, poolName;
            uint8_t   isFree;   // 第30抽赠送十连标记 (自定义业务字段 is_free)
        };
        std::pmr::vector<Temp> temps(alloc);
        temps.reserve(6000);

        bool usedStructuredPath = false;
        const JsonArrayScan listScan = ReadUigfPullList(bufView, usedStructuredPath,
                                                        [&](std::string_view item) {
            // UIGF v4.2 字段读取:
            //   - gacha_type   (替代 v3.0 的 uigf_gacha_type)
            //   - item_name    (替代 v3.0 的 name)
            //   - pool_name    (自定义,snake_case;原 poolName)
            //   - is_free      (自定义,snake_case;原 isFree)
            ItemType  it = ParseItemType (ExtractJsonValue(item, "item_type",  true));
            // rank_type: 字符串与数字两种形态都读。UIGF 的 endfield 段没有官方 schema,
            //   第三方转换器把稀有度写成 JSON 数字 ("rank_type": 6) 很常见, 而 isStr=true
            //   在"值不是以 \" 开头"时返回空视图 —— 旧写法会把这些真实记录整条丢掉。
            std::string_view rankSv = ExtractJsonValue(item, "rank_type", true);
            if (rankSv.empty()) rankSv = ExtractJsonValue(item, "rank_type", false);
            RankType  rt = ParseRankType(rankSv);
            GachaType gt = ParseGachaType(ExtractJsonValue(item, "gacha_type", true));
            // v0.1.2.0 / v0.1.4.0: 接受四类记录
            //   cp = 角色 Special  (特许寻访)
            //   jp = 角色 Joint    (辉光庆典)
            //   rp = 角色 Refactor (重构寻访, 1.5 新增)
            //   wp = 武器 (Constant / Standard / Beginner 之外的武器记录都算武器池)
            // 注:「重构申领」(poolId rerun_wpn_*) 的六星概率 / 40 / 80 保底与常规武库申领
            //   逐字段相同 (客户端 GachaWeaponPoolTypeTable type=0 与 type=1 完全一致),
            //   故直接并入武器桶。已知差异: 重构申领的第 8 次申领 UP 保底在【同名系列】
            //   之间继承且一生仅生效 1 次 (常规申领每期清零) —— 首期「点绘申领」是史上
            //   第一期重构申领, 还不存在可继承的历史, 故当前无影响; 待复刻时再拆分。
            bool cp = (it==ItemType::Character && gt==GachaType::Special);
            bool jp = (it==ItemType::Character && gt==GachaType::Joint);
            bool rp = (it==ItemType::Character && gt==GachaType::Refactor);
            bool wp = (it==ItemType::Weapon
                      && gt!=GachaType::Constant
                      && gt!=GachaType::Standard
                      && gt!=GachaType::Beginner);
            if(!cp && !jp && !rp && !wp) return;

            // v0.1.4.0 幽灵记录防御:「寻访情报书」(kind = "gift_intel_book") 会混在
            //   /api/record/char 的 list 里返回 —— 它不是一次寻访, 没有 charId / charName,
            //   也没有 rarity。新版导出器 (FetchSession.mm) 已把它分流到 non_pull_events,
            //   但【旧版导出的 uigf_endfield.json 里可能已经存了这类条目】, 那些记录的
            //   rank_type 是空串 → RankType::Unknown。若照单全收, 它们会被当成"一次没出
            //   六星的抽卡"而把保底水位多推 1 抽 (每 60 抽一本, 特许池尤其明显)。
            //   v0.1.5.1 收紧判据: 旧写法只看 rank_type 解析失败, 比"幽灵记录"的本意宽得多 ——
            //   稀有度写成数字、稀有度不在 3..6、或仅仅缺 rank_type 的【真实记录】都会被静默
            //   丢掉, 而每丢一条, 其后所有六星的保底水位都少算 1 抽, 方向与想修的问题正好相反。
            //   现在与导出器的迁移判据同源: 【没有物品 id 且没有稀有度】才算非抽卡事件。
            //   (数字形态的稀有度已在上面被 rankSv 的双读兜住, 不会再走到这里。)
            if(rt==RankType::Unknown && ExtractJsonValue(item, "item_id", true).empty()) return;

            auto name = ExtractJsonValue(item, "item_name", true);
            // pool_name 是本工具的自定义扩展键, 不属于 UIGF 标准, 而且导出器在它为空时
            // 【根本不写这个字段】。缺了它: 重构池的 series_states 会把所有系列塌缩成同一份
            // 状态 (120 兜底与赠送十连计数全串在一起), 特许/武器池的"换期清零"也因为前后都是
            // 空串而永不触发。回退到 gacha_type (poolId): 它是 UIGF 必填字段且每期唯一。
            auto pn   = ExtractJsonValue(item, "pool_name", true);
            if (pn.empty()) pn = ExtractJsonValue(item, "gacha_type", true);
            auto idStr = ExtractJsonValue(item, "id", true);
            if(idStr.empty()) idStr = ExtractJsonValue(item, "id", false);
            long long pid=0;
            if(!idStr.empty())
                std::from_chars(idStr.data(), idStr.data()+idStr.size(), pid);

            // is_free 是 JSON 中的 bool 字面量(true/false),不带引号
            auto isFreeStr = ExtractJsonValue(item, "is_free", false);
            uint8_t isFree = (isFreeStr == "true") ? 1 : 0;

            temps.push_back({pid, it, gt, rt, name, pn, isFree});
        });

        // v0.1.5.1: 扫描状态必须检查。数组被截断 / 混进非对象元素 / 元素间缺分隔逗号时,
        //   已经吃进的前半段照常在 temps 里, 旧写法只判 temps.empty(), 于是"半截历史"会被
        //   当成全部历史出统计 —— 六星计数、均值、K-S、当前垫刀全部基于残缺样本, 而界面上
        //   与"本来就抽得少"完全无法区分。同一个项目的拉取侧已经为读存档加了这道闸门。
        if (listScan == JsonArrayScan::Malformed) {
            munmap((void*)mapData, fileSize);
            ctx->result.textOutput =
                @"存档文件结构损坏或不完整: 抽卡记录数组没有正常闭合, 或含有非对象元素 / 缺少分隔逗号。\n"
                @"为避免基于残缺数据给出错误统计, 已停止分析。请检查该文件 (例如是否仍在 iCloud 下载中, 或被其它工具写坏)。";
            return nullptr;
        }

        if (temps.empty()) {
            munmap((void*)mapData, fileSize);
            ctx->result.textOutput = (listScan == JsonArrayScan::NotFound)
                ? @"没有在文件里找到抽卡记录数组 (UIGF v4.2 的 endfield[0].list)"
                : @"文件里没有可分析的抽卡记录";
            return nullptr;
        }

        // 按 |id| 升序、武器(id<0)放后面;数据已经有序则跳过排序(常见情形)
        // 防御 LLONG_MIN: 对 v == LLONG_MIN 取 -v 是有符号溢出 (UB)。正常抽卡 id 不会是
        // LLONG_MIN, 但 id 来自外部文件, 用无符号求绝对值规避 UB (升序排序语义不变)。
        auto abs_ll = [](long long v) -> unsigned long long {
            return v < 0 ? (0ULL - static_cast<unsigned long long>(v))
                         : static_cast<unsigned long long>(v);
        };
        auto less = [&](const Temp& a, const Temp& b){
            bool wa = a.id<0, wb = b.id<0;
            if(wa!=wb) return wa<wb;
            return abs_ll(a.id) < abs_ll(b.id);
        };
        bool sorted=true;
        for(size_t i=1; i<temps.size(); ++i)
            if(less(temps[i], temps[i-1])){sorted=false; break;}
        if(!sorted) std::ranges::sort(temps, less);

        PullBucket bucketChar (alloc); bucketChar.reserve(4000);
        PullBucket bucketJoint(alloc); bucketJoint.reserve(2000);
        PullBucket bucketRefac(alloc); bucketRefac.reserve(1000);
        PullBucket bucketWep  (alloc); bucketWep.reserve(2000);
        for(const auto& t : temps){
            // 角色记录: 按 gacha_type 分桶, Special / Joint / Refactor 各走各的
            // (三者机制独立: 保底作用域、赠送十连次数、有无 120 硬保底都不同)
            if(t.it==ItemType::Character && t.gt==GachaType::Special)
                bucketChar.push_back(t.rt, t.name, t.poolName, t.isFree);
            else if(t.it==ItemType::Character && t.gt==GachaType::Joint)
                bucketJoint.push_back(t.rt, t.name, t.poolName, t.isFree);
            else if(t.it==ItemType::Character && t.gt==GachaType::Refactor)
                bucketRefac.push_back(t.rt, t.name, t.poolName, t.isFree);
            else
                bucketWep.push_back(t.rt, t.name, t.poolName, t.isFree);
        }

        StatsResult sc = Calculate(bucketChar,  false, false, stdChars, pm);
        StatsResult sj = Calculate(bucketJoint, false, true,  stdChars, {});  // joint 走 stdChars 排除法, pool_map 空
        // 重构寻访: 与特许寻访一样 pool_map 优先, 但保底作用域不同 → isRefactor=true
        StatsResult sr = Calculate(bucketRefac, false, false, stdChars, pm, /*isRefactor=*/true);
        StatsResult sw = Calculate(bucketWep,   true,  false, stdWeps,  {});

        // 关键:在 sc/sj/sr/sw 完全完成后才解除映射,因为 PullBucket.names/poolNames
        // 持有指向 mmap 内存的 string_view,Calculate 需要它们有效
        munmap((void*)mapData, fileSize);

        // ★ 这里【每加一个池子就必须同步加一行】—— 图表读的是这几个字段, 漏一个会出现
        //   "文字统计有六星, 对应的两张图却显示暂无出金数据"。
        ctx->result.textOutput    = FormatOutput(sc, sj, sr, sw);
        ctx->result.statsChar     = ToChartData(sc);
        ctx->result.statsJoint    = ToChartData(sj);
        ctx->result.statsRefactor = ToChartData(sr);
        ctx->result.statsWep      = ToChartData(sw);
        ctx->result.ok = YES;
    }
    return nullptr;
}

} // anonymous namespace

// ============================================================
// GachaAnalyzerWrapper 实现 (直接调用; 调用方已在后台队列, arena 在堆上, 无需另起线程)
// ============================================================
@implementation GachaAnalyzerWrapper

+ (GachaAnalysisResult*)analyzeFile:(NSString*)filePath
                              chars:(NSString*)chars
                            poolMap:(NSString*)poolMap
                            weapons:(NSString*)weapons {

    GachaAnalysisResult* result = [[GachaAnalysisResult alloc] init];
    result.ok = NO;
    result.textOutput = @"";

    AnalyzeThreadContext ctx = { filePath, chars, poolMap, weapons, result };

    // 历史上这里 pthread_create + 立即 pthread_join, 但调用方 (Swift) 已在
    // DispatchQueue.global(qos: .userInitiated) 后台执行, 且 arena 早已移到堆上 (不再需要大栈),
    // 故再起一条线程并马上 join 不增加并行度, 只多一次线程创建/调度/栈预留。直接同步调用即可。
    // (analyze_worker 内部自带 @autoreleasepool, 同步返回, 仍满足"读取全程在调用方协调块内"。)
    analyze_worker(&ctx);
    return result;
}
@end
