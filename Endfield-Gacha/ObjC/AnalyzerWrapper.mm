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
enum class GachaType : uint8_t { Unknown = 0, Beginner, Standard, Special, Constant, Joint };

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
    if (ContainsCI(sv,"special"))  return GachaType::Special;
    if (ContainsCI(sv,"beginner")) return GachaType::Beginner;
    if (ContainsCI(sv,"standard")) return GachaType::Standard;
    if (ContainsCI(sv,"constant")) return GachaType::Constant;
    if (ContainsCI(sv,"joint"))    return GachaType::Joint;   // v0.1.2.0: 辉光庆典
    return GachaType::Unknown;
}

// ------ JSON 解析 ------
inline size_t FindJsonKey(std::string_view src, std::string_view key, size_t pos=0) {
    while (true) {
        pos = src.find(key, pos);
        if (pos==std::string_view::npos) return pos;
        if (pos>0 && src[pos-1]=='"' && pos+key.size()<src.size() && src[pos+key.size()]=='"')
            return pos-1;
        pos += key.size();
    }
}
inline std::string_view ExtractJsonValue(std::string_view src, std::string_view key, bool isStr) {
    size_t pos = FindJsonKey(src, key);
    if (pos==std::string_view::npos) return {};
    pos = src.find(':', pos+key.size()+2);
    if (pos==std::string_view::npos) return {};
    ++pos;
    while (pos<src.size()&&(src[pos]==' '||src[pos]=='\t'||src[pos]=='\n'||src[pos]=='\r')) ++pos;
    if (isStr) {
        if (pos>=src.size()||src[pos]!='"') return {};
        ++pos; size_t e=pos;
        while (e<src.size()&&src[e]!='"') { if (src[e]=='\\'&&e+1<src.size()) e+=2; else ++e; }
        return e<src.size() ? src.substr(pos,e-pos) : std::string_view{};
    } else {
        size_t e=pos;
        while (e<src.size()&&src[e]!=','&&src[e]!='}'&&src[e]!=']'&&src[e]!=' '&&src[e]!='\n'&&src[e]!='\r') ++e;
        return src.substr(pos,e-pos);
    }
}
template<typename Cb>
void ForEachJsonObject(std::string_view src, std::string_view arrKey, Cb&& cb) {
    size_t pos = FindJsonKey(src,arrKey);
    if (pos==std::string_view::npos) return;
    pos = src.find(':',pos+arrKey.size()+2);
    if (pos==std::string_view::npos) return;
    pos = src.find('[',pos);
    if (pos==std::string_view::npos) return;
    int depth=0; size_t objStart=0;
    for (size_t i=pos; i<src.size(); ++i) {
        char c=src[i];
        if (c=='"') { for(++i;i<src.size();++i){if(src[i]=='\\'&&i+1<src.size()){++i;continue;}if(src[i]=='"')break;} continue; }
        if (c=='{'){if(depth==0)objStart=i;++depth;}
        else if(c=='}'){--depth;if(depth==0)cb(src.substr(objStart,i-objStart+1));}
        else if(c==']'&&depth==0)break;
    }
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
double g_cdf_char[82]     = {};
double g_cdf_wep[41]      = {};
double g_cdf_char_up[122] = {};
double g_cdf_wep_up[81]   = {};
double g_cdf_joint_up[242] = {};
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
                        double ph = h_char(s + 1);
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
                        double ph = h_char(s + 1);
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
                            double ph = h_char(s + 1);
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
StatsResult Calculate(const PullBucket& bucket, bool isWeapon, bool isJoint,
    const std::unordered_set<std::string,StringHash,std::equal_to<>>& std_names,
    const std::unordered_map<std::string,std::string,StringHash,std::equal_to<>>& pool_map)
{
    StatsAccumulator acc;
    int cur_pity=0, pity_up=0;
    // 卡池边界重置策略 (终末地三池各不同 —— 联网核实 + 数据验证):
    //   - 特许池(Special): 仅 120 硬保底每期重置 (pity_up); 80 小保底【继承】(cur_pity 不重置)
    //   - 武器池(Weapon):  40 小保底 + 80 硬保底【都】每期重置 (cur_pity 与 pity_up 都重置, 均不继承)
    //   - 辉光庆典(Joint): 无硬保底, 连续累加, 不按期重置
    //   got_up_banner: 本期是否已出过 UP/限定 (硬保底每期仅生效一次), 每期重置
    //   hardpity_n:    硬保底强制阈值 —— 角色 120 抽; 武器 8 申领(= 第 71..80 抽强制出限定)
    // 边界用 poolName 变化探测 (每期 pool_name 唯一; 武器记录 id 为负, 桶内按 |id| 升序 = 时间序).
    bool got_up_banner=false;
    const bool track_special = (!isWeapon && !isJoint);
    const bool track_weapon  = isWeapon;
    const bool track_banner   = (track_special || track_weapon);   // Joint 不按期重置
    const int  hardpity_n    = isWeapon ? 71 : 120;

    const size_t total = bucket.size();
    for(size_t i=0; i<total; ++i){
        const bool isFree = bucket.is_free[i];

        // 卡池边界探测: poolName 变化 = 进入新一期卡池.
        //   特许池: 120 硬保底不继承 → pity_up + got_up_banner 清零; 80 小保底继承 (cur_pity 不动)
        //   武器池: 40 + 80 都不继承 → cur_pity + pity_up + got_up_banner 全清零
        if (track_banner && i > 0 && bucket.poolNames[i] != bucket.poolNames[i - 1]) {
            pity_up       = 0;
            got_up_banner = false;
            if (track_weapon) cur_pity = 0;   // 武器 40 小保底也每期重算 (角色 80 小保底继承, 不清)
        }

        // 赠送十连: 不推进保底通道
        if (!isFree) {
            ++cur_pity; ++pity_up;
        }

        if(bucket.rank_types[i]!=RankType::Rank6) [[likely]] continue;

        // 出 6 星. 决定计入 freq 的位置:
        //   - 赠送十连出货 -> 归入 freq[30] (与理论 CDF 第30抽合并判定一致)
        //   - 正常出货 -> 归入 freq[cur_pity]
        const int slot_all = isFree ? 30 : cur_pity;
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
            auto it=pool_map.find(bucket.poolNames[i]);
            if(it!=pool_map.end()) isUP=(bucket.names[i]==it->second);
            else                   isUP=!std_names.contains(bucket.names[i]);
        }

        if(isUP){
            const int slot_up = isFree ? 30 : pity_up;
            if(slot_up<260) acc.freq_up[slot_up]++;
            if(slot_up>acc.max_pity_up) acc.max_pity_up=slot_up;
            acc.count_up++;
            acc.sum_up    += slot_up;
            acc.sum_sq_up += (long long)slot_up*slot_up;

            // 胜负统计 (修正: 终末地无“歪→下次必中”, 每个六星/六星武器都是独立判定):
            //   - 角色池 50/50, 武器池 25% 条件率 —— 每个 UP/限定都计入“胜”, 唯一例外:
            //     由【硬保底强制】出的那个 (本期首个 UP/限定, 且当期累计抽数已打满硬保底阈值)
            //     不是掷硬币结果, 必须剔除 (角色 120 抽; 武器 8 申领即第 71..80 抽), 否则把
            //     真实条件率系统性拉高 (角色>50%, 武器>25%)。
            //   - 辉光庆典: 无硬保底, 每个限定直接计入。
            //   - avg_win (count_win/sum_win) 仅特许池有物理含义; 武器/Joint 不累计。
            const bool forced_by_hardpity =
                track_banner && !got_up_banner && !isFree && pity_up >= hardpity_n;
            if(isJoint){
                acc.win_5050++;
            } else if(!forced_by_hardpity){
                acc.win_5050++;
                if(!isWeapon){            // avg_win 仅对特许池定义
                    acc.count_win++;
                    acc.sum_win += slot_all;
                }
            }
            got_up_banner=true;
            // 赠送十连出 UP 不重置 pity_up (独立通道); 正常出 UP/限定 重置
            if (!isFree) pity_up=0;
        } else {
            // 非 UP/非限定六星 = 一次独立判定的“负”。终末地可连续歪多次, 全部如实计入。
            acc.lose_5050++;
        }
        // 赠送十连出货不重置 cur_pity (独立通道); 正常出货重置
        if (!isFree) cur_pity=0;
    }
    acc.censored_pity_all = cur_pity;
    acc.censored_pity_up  = pity_up;

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
        const std::span<const double> cdf = isWeapon
            ? std::span<const double>(g_cdf_wep)      // 41
            : std::span<const double>(g_cdf_char);    // 82
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
        std::span<const double> cdf_up;              // v0.1.3.3: 长度由 span 自带
        if (isJoint)       cdf_up = g_cdf_joint_up;   // 242
        else if (isWeapon) cdf_up = g_cdf_wep_up;     // 81
        else               cdf_up = g_cdf_char_up;    // 122
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
    // UP hazard 同理
    if(acc.count_up>0 || acc.censored_pity_up>0){
        int surv = acc.count_up + (acc.censored_pity_up>0 ? 1 : 0);
        int maxR = std::max(acc.max_pity_up, acc.censored_pity_up);
        if (maxR > 259) maxR = 259;
        for(int x=1; x<=maxR; ++x){
            if(surv>0){
                s.hazard_up[x] = (double)acc.freq_up[x]/surv;
                surv -= acc.freq_up[x];
                if(x==acc.censored_pity_up) surv--;
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
    d.censoredPityAll   = s.censored_pity_all;
    d.censoredPityUp    = s.censored_pity_up;
    return d;
}

// ------ 文本格式化 ------
NSString* FormatOutput(const StatsResult& sc, const StatsResult& sj, const StatsResult& sw) {
    auto pendStr = [](int pa, int pu) -> NSString* {
        if(!pa && !pu) return @"";
        return [NSString stringWithFormat:@"  [当前垫刀: 距上次六星 %d 抽 / 距上次 UP %d 抽]", pa, pu];
    };
    auto ksLabel = [](int n, bool ok) -> NSString* {
        if(!n) return @"-"; return ok ? @"符合理论模型" : @"偏离过大";
    };
    NSString* winC = sc.avg_win>=0 ? [NSString stringWithFormat:@"%.2f 抽", sc.avg_win] : @"[无数据]";
    return [NSString stringWithFormat:
        @"【角色卡池 (特许寻访)】 总计六星: %d | 出当期 UP: %d%@\n"
        @" ▶ 综合六星 (含歪) 出货平均期望:     %.2f 抽 (理论 ≈ 51.81)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 (理论 ≈ 79.29)   [95%% CI: %.1f ~ %.1f]    |   真实不歪率: %.1f%% (理论 50%%) (%ld胜%ld负)\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 赢下小保底 (不歪) 的出货期望:     %@\n\n"
        @"【角色卡池 (辉光庆典)】 总计六星: %d | 出限定: %d%@\n"
        @" ▶ 综合六星出货平均期望:             %.2f 抽 (理论 ≈ 51.81)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到任一限定 (非常驻) 的平均期望: %.2f 抽 (理论 ≈ 104.68)  [95%% CI: %.1f ~ %.1f]    |   非常驻六星率: %.1f%% (理论 50%%) (%ld限定%ld常驻)\t[K-S 检验偏离度 D值: %.3f (%@)]\n\n"
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
            sc.ks_d_up, ksLabel(sc.count_up, sc.ks_is_normal_up),
            winC,
        sj.count_all, sj.count_up, pendStr(sj.censored_pity_all,sj.censored_pity_up),
        sj.avg_all, std::max(1.0, sj.avg_all-sj.ci_all_err), sj.avg_all+sj.ci_all_err,
            sj.cv_all*100, sj.ks_d_all, ksLabel(sj.count_all, sj.ks_is_normal),
        sj.avg_up, std::max(1.0, sj.avg_up-sj.ci_up_err), sj.avg_up+sj.ci_up_err,
            (sj.win_rate_5050>=0?sj.win_rate_5050:0.0)*100,
            (long)sj.win_5050, (long)sj.lose_5050,
            sj.ks_d_up, ksLabel(sj.count_up, sj.ks_is_normal_up),
        sw.count_all, sw.count_up, pendStr(sw.censored_pity_all,sw.censored_pity_up),
        sw.avg_all, std::max(1.0, sw.avg_all-sw.ci_all_err), sw.avg_all+sw.ci_all_err,
            sw.cv_all*100, sw.ks_d_all, ksLabel(sw.count_all, sw.ks_is_normal),
        sw.avg_up, std::max(1.0, sw.avg_up-sw.ci_up_err), sw.avg_up+sw.ci_up_err,
            (sw.win_rate_5050>=0?sw.win_rate_5050:0.0)*100,
            (long)sw.win_5050, (long)sw.lose_5050,
            sw.ks_d_up, ksLabel(sw.count_up, sw.ks_is_normal_up)
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

        ForEachJsonObject(bufView, "list", [&](std::string_view item) {
            // UIGF v4.2 字段读取:
            //   - gacha_type   (替代 v3.0 的 uigf_gacha_type)
            //   - item_name    (替代 v3.0 的 name)
            //   - pool_name    (自定义,snake_case;原 poolName)
            //   - is_free      (自定义,snake_case;原 isFree)
            //
            // ForEachJsonObject 找的是 "list" 这个 key。v4.2 文件里 "list" 只
            // 在 endfield[0] 内层出现一次(顶层 info 块没有 list),所以不需要
            // 先穿透 endfield 数组,直接找到的就是正确的记录数组。
            ItemType  it = ParseItemType (ExtractJsonValue(item, "item_type",  true));
            RankType  rt = ParseRankType (ExtractJsonValue(item, "rank_type",  true));
            GachaType gt = ParseGachaType(ExtractJsonValue(item, "gacha_type", true));
            // v0.1.2.0: 接受三类记录
            //   cp = 角色 Special (特许寻访)
            //   jp = 角色 Joint   (辉光庆典)
            //   wp = 武器 (Special / Joint 之外的武器记录都算武器池)
            bool cp = (it==ItemType::Character && gt==GachaType::Special);
            bool jp = (it==ItemType::Character && gt==GachaType::Joint);
            bool wp = (it==ItemType::Weapon
                      && gt!=GachaType::Constant
                      && gt!=GachaType::Standard
                      && gt!=GachaType::Beginner);
            if(!cp && !jp && !wp) return;

            auto name = ExtractJsonValue(item, "item_name", true);
            auto pn   = ExtractJsonValue(item, "pool_name", true);
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

        if (temps.empty()) {
            munmap((void*)mapData, fileSize);
            ctx->result.textOutput = @"JSON 解析失败或无数据";
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
        PullBucket bucketWep  (alloc); bucketWep.reserve(2000);
        for(const auto& t : temps){
            if(t.it==ItemType::Character && t.gt==GachaType::Special)
                bucketChar.push_back(t.rt, t.name, t.poolName, t.isFree);
            else if(t.it==ItemType::Character && t.gt==GachaType::Joint)
                bucketJoint.push_back(t.rt, t.name, t.poolName, t.isFree);
            else
                bucketWep.push_back(t.rt, t.name, t.poolName, t.isFree);
        }

        StatsResult sc = Calculate(bucketChar,  false, false, stdChars, pm);
        StatsResult sj = Calculate(bucketJoint, false, true,  stdChars, {});  // joint 走 stdChars 排除法, pool_map 空
        StatsResult sw = Calculate(bucketWep,   true,  false, stdWeps,  {});

        // 关键:在 sc/sj/sw 完全完成后才解除映射,因为 PullBucket.names/poolNames
        // 持有指向 mmap 内存的 string_view,Calculate 需要它们有效
        munmap((void*)mapData, fileSize);

        ctx->result.textOutput = FormatOutput(sc, sj, sw);
        ctx->result.statsChar  = ToChartData(sc);
        ctx->result.statsJoint = ToChartData(sj);
        ctx->result.statsWep   = ToChartData(sw);
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
