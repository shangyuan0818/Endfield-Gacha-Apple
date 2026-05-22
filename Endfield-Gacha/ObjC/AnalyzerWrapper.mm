//  AnalyzerWrapper.mm
//  Endfield-Gacha
//
//  .mm = ObjC++:可以同时写 C++ 和 ObjC。
//  C++ 核心算法(从 Windows gui.cpp 1:1 迁移)在匿名 namespace 里,
//  ObjC 包装把结果转成 NSObject 属性传给 Swift。
//  Swift 侧没有任何 C++ 类型泄漏。

#import "AnalyzerWrapper.h"
#include <pthread.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <charconv>
#include <memory_resource>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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

// ------ StatsAccumulator (cache-line 对齐,避免与其他热数据共享 cacheline) ------
struct alignas(128) StatsAccumulator {
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
bool   g_cdf_init = false;

void InitCDFTables() {
    if (g_cdf_init) return;
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
    {
        double bh=0.04, bm=0.96, sw=1.0;
        for(int k=1;k<=30;++k){g_cdf_wep[k]=g_cdf_wep[k-1]+sw*bh; sw*=bm;}
        double norm=1.0-std::pow(bm,10), ls=1.0;
        for(int k=31;k<=40;++k){g_cdf_wep[k]=g_cdf_wep[k-1]+sw*(ls*bh/norm); ls*=bm;}
    }

    // ---- 角色 UP CDF (v0.1.1.1: 真实双状态前向迭代, 替换原 v0.1.1 的 50/50 简化) ----
    //
    // 真实双状态模型: D[s][h], h ∈ {0, 1} 表示是否处于 "大保底" 状态.
    //   h=0: 未触发大保底, 出 6 星后 50% UP / 50% 进入 h=1
    //   h=1: 已触发大保底, 出 6 星必为 UP
    // n=30 处展开 11 次免费十连判定 (1 本体抽推进水位 + 10 次免费抽水位停).
    // 第 120 抽硬保底强制全部毕业.
    //
    // 历史: v0.1.1 用单维 D[s] + p_hit * 0.5 简化模型, E[首 UP] ≈ 81.4 (偏差 7 抽),
    //       v0.1.1.1 改真实双状态, E[首 UP] ≈ 74.16, 与社区数据 74.33 对齐.
    {
        constexpr int hard_cap = 120;
        constexpr int max_soft = 80;
        auto h_char = [](int k) -> double {
            if (k <= 65) return 0.008;
            if (k <= 79) return 0.058 + (k - 66) * 0.05;
            return 1.0;
        };
        // D[h][s]: h=0 未触发大保底, h=1 已触发. 水位 s ∈ [0, 80)
        std::array<std::array<double, max_soft>, 2> D{};
        D[0][0] = 1.0;
        double cum = 0.0;

        auto stepOnePull = [&](std::array<std::array<double, max_soft>, 2>& src,
                               std::array<std::array<double, max_soft>, 2>& dst,
                               double& p_finish,
                               bool waterStops /* 免费抽水位停 */) {
            for (int hh = 0; hh < 2; ++hh) {
                for (int s = 0; s < max_soft; ++s) {
                    if (src[hh][s] == 0) continue;
                    double prob = src[hh][s];
                    double ph = h_char(s + 1);
                    // 不出 6 星: 水位推进 (或停)
                    if (waterStops) {
                        dst[hh][s] += prob * (1.0 - ph);
                    } else if (s + 1 < max_soft) {
                        dst[hh][s + 1] += prob * (1.0 - ph);
                    }
                    // 出 6 星
                    if (hh == 1) {
                        // 大保底: 必 UP, 毕业
                        p_finish += prob * ph;
                    } else {
                        // 非大保底: 50% UP 毕业, 50% 非 UP 进入大保底
                        p_finish += prob * ph * 0.5;
                        if (waterStops) {
                            dst[1][s] += prob * ph * 0.5;       // 水位停 (免费抽语义)
                        } else {
                            dst[1][0] += prob * ph * 0.5;       // 水位归 0 (本体抽)
                        }
                    }
                }
            }
        };

        for (int n = 1; n <= hard_cap; ++n) {
            if (n == hard_cap) {
                // 120 硬保底: 所有未毕业概率强制毕业
                double alive = 0.0;
                for (int hh = 0; hh < 2; ++hh)
                    for (int s = 0; s < max_soft; ++s)
                        alive += D[hh][s];
                cum += alive;
                g_cdf_char_up[n] = std::min(1.0, cum);
                for (int k = n + 1; k <= hard_cap + 1; ++k) g_cdf_char_up[k] = 1.0;
                break;
            }

            if (n == 30) {
                // 1 次本体抽 + 10 次免费抽
                std::array<std::array<double, max_soft>, 2> stateA{};
                double p_finish = 0.0;
                stepOnePull(D, stateA, p_finish, /*waterStops=*/false);
                for (int free_step = 0; free_step < 10; ++free_step) {
                    std::array<std::array<double, max_soft>, 2> stateB{};
                    stepOnePull(stateA, stateB, p_finish, /*waterStops=*/true);
                    stateA = stateB;
                }
                cum += p_finish;
                g_cdf_char_up[n] = std::min(1.0, cum);
                D = stateA;
            } else {
                std::array<std::array<double, max_soft>, 2> newD{};
                double p_finish = 0.0;
                stepOnePull(D, newD, p_finish, /*waterStops=*/false);
                cum += p_finish;
                g_cdf_char_up[n] = std::min(1.0, cum);
                D = newD;
            }
        }
    }

    // ---- 武器 UP CDF (4×8 状态机) ----
    // ns ∈ [0,3]: 已连续多少 10-pull 没出 6 星
    // nf ∈ [0,7]: 已连续多少 10-pull 没出 featured
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

    g_cdf_init = true;
}

// ------ KS 检验 ------
// 修复:freq 的合法索引是 [0, 259];max_pity 必须 clamp 否则越界读
double ComputeKS(const std::array<int,260>& freq,int max_pity,int n,const double* cdf,int cdf_len){
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
// v0.1.2.0 加 isJoint 参数:
//   - 辉光池没有"小保底"概念 (每个 6 星独立 50% 出限定),
//     win_5050 / lose_5050 按"每个 6 星是不是限定"独立计数 (跟武器池一样).
//   - 也不维护 had_non_up 状态.
//   - UP 判定走 standard_names 排除法 (pool_map 为空).
StatsResult Calculate(const PullBucket& bucket, bool isWeapon, bool isJoint,
    const std::unordered_set<std::string,StringHash,std::equal_to<>>& std_names,
    const std::unordered_map<std::string,std::string,StringHash,std::equal_to<>>& pool_map)
{
    StatsAccumulator acc;
    int cur_pity=0, pity_up=0;
    bool had_non_up=false;

    const size_t total = bucket.size();
    for(size_t i=0; i<total; ++i){
        const bool isFree = bucket.is_free[i];

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

            if(isWeapon || isJoint){
                // 武器池/辉光池: 每个 6 星独立 50% (joint) 或 25% (weapon) 判定
                acc.win_5050++;
            } else if(!had_non_up){
                // 角色 (Special) 池: 小保底"赢/输"概念
                acc.win_5050++;
                acc.count_win++;
                acc.sum_win += slot_all;
            }
            had_non_up=false;
            // 赠送十连出 UP 不重置 pity_up (独立通道); 正常出 UP 重置
            if (!isFree) pity_up=0;
        } else {
            if(isWeapon || isJoint)   acc.lose_5050++;
            else if(!had_non_up)      acc.lose_5050++;
            had_non_up=true;
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
        const double* cdf = isWeapon ? g_cdf_wep : g_cdf_char;
        int clen = isWeapon ? 41 : 82;
        s.ks_d_all = ComputeKS(acc.freq_all, acc.max_pity_all, acc.count_all, cdf, clen);
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
        const double* cdf_up; int clen_up;
        if (isJoint)       { cdf_up = g_cdf_joint_up; clen_up = 242; }
        else if (isWeapon) { cdf_up = g_cdf_wep_up;   clen_up = 81;  }
        else               { cdf_up = g_cdf_char_up;  clen_up = 122; }
        s.ks_d_up = ComputeKS(acc.freq_up, acc.max_pity_up, acc.count_up, cdf_up, clen_up);
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
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 (理论 ≈ 74.33)   [95%% CI: %.1f ~ %.1f]    |   真实不歪率: %.1f%% (理论 50%%) (%ld胜%ld负)\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 赢下小保底 (不歪) 的出货期望:     %@\n\n"
        @"【角色卡池 (辉光庆典)】 总计六星: %d | 出限定: %d%@\n"
        @" ▶ 综合六星出货平均期望:             %.2f 抽 (理论 ≈ 51.81)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到任一限定 (非常驻) 的平均期望: %.2f 抽 (理论 ≈ 103.62)  [95%% CI: %.1f ~ %.1f]    |   非常驻六星率: %.1f%% (理论 50%%) (%ld限定%ld常驻)\t[K-S 检验偏离度 D值: %.3f (%@)]\n\n"
        @"【武器卡池 (武库申领)】 总计六星: %d | 出当期 UP: %d%@\n"
        @" ▶ 综合六星出货平均期望:             %.2f 抽 (理论 ≈ 19.17)   [95%% CI: %.1f ~ %.1f]    |   波动率 (CV): %.1f%%\t[K-S 检验偏离度 D值: %.3f (%@)]\n"
        @" ▶ 抽到当期限定 UP 的综合平均期望:   %.2f 抽 (理论 ≈ 81.66)   [95%% CI: %.1f ~ %.1f]    |   6 星中 UP 率: %.1f%% (理论 25%%) (%ld UP / %ld 非UP)\t[K-S 检验偏离度 D值: %.3f (%@)]",
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
// 核心分析任务 (运行在独立 pthread 内,享有 4MB 大栈)
// -----------------------------------------------------------
void* analyze_worker(void* arg) {
    @autoreleasepool {
        AnalyzeThreadContext* ctx = (AnalyzeThreadContext*)arg;

        // PMR 栈池:2MB 在 4MB 栈中足够安全
        std::array<std::byte, 2 * 1024 * 1024> stackBuffer;
        std::pmr::monotonic_buffer_resource pool(stackBuffer.data(), stackBuffer.size());
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
        auto abs_ll = [](long long v){return v<0 ? -v : v;};
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
// GachaAnalyzerWrapper 实现 (Pthread 调度,大栈 4MB)
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

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);

    pthread_t thread;
    int create_err = pthread_create(&thread, &attr, analyze_worker, &ctx);
    pthread_attr_destroy(&attr);

    if (create_err != 0) {
        result.textOutput = @"底层大栈线程创建失败";
        return result;
    }

    pthread_join(thread, NULL);
    return result;
}
@end
