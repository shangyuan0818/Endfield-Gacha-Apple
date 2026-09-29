// AnalyzerWrapper.mm 的统计核心测试。
//
// 通过 extract_mm_core.py 抽出该文件的匿名 namespace 原文, 所以 InitCDFTables /
// Calculate / ReadUigfPullList 就是 App 真正在用的那一份实现。
//
// 覆盖: 六张理论 CDF 的期望值、重构寻访的按系列状态、武器池按期状态 (与旧算法的逐位回归)、
//       赠送十连分块、混合样本判定、右删失、图表理论/经验数据与 KS 标记、存档读取路径。
#include "test_support.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <ranges>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../Endfield-Gacha/ObjC/JsonScan.h"
#include "build/analyzer_core.inc"
}   // 补上被截断的匿名 namespace 结尾

// E[X] = Σ_{k>=0} (1 - F(k))
static double expectation(const double* cdf, int n) {
    double e = 0.0;
    for (int k = 0; k < n; ++k) e += (1.0 - std::min(1.0, cdf[k]));
    return e;
}

static std::pmr::monotonic_buffer_resource g_pool;
static std::pmr::polymorphic_allocator<std::byte> g_alloc(&g_pool);

int main() {
    InitCDFTables();

    // ---------- 一、理论 CDF 的期望值 ----------
    // 前四个是迁移前就有的, 必须一位不动 (回归); 后两个是重构寻访新增, 与 Windows 端
    // v0.1.4.0 注释里标注的 51.37 / 77.83 对齐。
    //
    // 参考值【不是四舍五入到小数点后四位的展示值】, 而是本实现算出来的原值截到 10 位小数,
    // 误差限 kCdfTol = 1e-9。这样"期望值被改动了"才真的会红 —— 1e-3 的松限把整个第四位
    // 都放走了, 而概率表改错不会崩溃, 只会让界面上的数字悄悄变成另一个游戏的数字。
    // 量化一下这个差别: 把基础出货率 0.008 写成 0.0080001, 角色池期望值从 51.8051403653
    // 变成 51.8049557016 (偏移 1.8e-4) —— 旧的 1e-3 松限【放得过去】, 现在这条会红。
    //
    // 1e-9 是有意留的余量, 不是精度上限: 实测 clang++ (-O0 / -O2 / -O3 -ffp-contract=fast /
    // -O2 -ffp-contract=off) 与 g++ (-O2) 共 5 种构建下这七个值【逐位相同】, 与参考值的偏差
    // ≤ 5e-11 (全部来自参考值自身的截断)。剩下的量级留给不同 libm 的 std::pow 可能相差
    // 1 ulp —— 那点差异传播到期望值也只有 ~1e-14。
    constexpr double kCdfTol = 1e-9;
    std::printf("[CDF] char=%.10f charUP=%.10f wep=%.10f wepUP=%.10f refac=%.10f refacUP=%.10f jointTail=%.10f\n",
                expectation(g_cdf_char, 82), expectation(g_cdf_char_up, 122),
                expectation(g_cdf_wep, 41),  expectation(g_cdf_wep_up, 81),
                expectation(g_cdf_refactor, 82), expectation(g_cdf_refactor_up, 122),
                g_joint_tail_mean_excess);
    CHECK(std::abs(expectation(g_cdf_char, 82)        - 51.8051403653) < kCdfTol);
    CHECK(std::abs(expectation(g_cdf_char_up, 122)    - 79.2913726765) < kCdfTol);
    CHECK(std::abs(expectation(g_cdf_wep, 41)         - 19.1710866709) < kCdfTol);
    CHECK(std::abs(expectation(g_cdf_wep_up, 81)      - 54.7370066515) < kCdfTol);
    CHECK(std::abs(expectation(g_cdf_refactor, 82)    - 51.3708153552) < kCdfTol);
    CHECK(std::abs(expectation(g_cdf_refactor_up, 122)- 77.8274947999) < kCdfTol);
    CHECK(std::abs(g_joint_tail_mean_excess           - 84.3666393185) < kCdfTol);
    // 单调性 + 收敛
    for (int i = 1; i <= 80; ++i)  CHECK(g_cdf_refactor[i]    >= g_cdf_refactor[i-1]);
    for (int i = 1; i <= 120; ++i) CHECK(g_cdf_refactor_up[i] >= g_cdf_refactor_up[i-1]);
    CHECK(std::abs(g_cdf_refactor[80]     - 1.0) < 1e-9);   // 80 抽硬保底
    CHECK(std::abs(g_cdf_refactor_up[120] - 1.0) < 1e-9);   // 120 抽 UP 硬保底

    std::unordered_set<std::string,StringHash,std::equal_to<>> stdChars{"骏卫","黎风","别礼","余烬","艾尔黛拉"};
    std::unordered_map<std::string,std::string,StringHash,std::equal_to<>> pm{
        {"绚丽异彩","伊冯"},{"某重构B","卡缪"},{"冬猎","提弗洛斯"}};

    // ---------- 二、重构寻访: 两个系列各出 1 个首 UP 不是混合样本 ----------
    {
        PullBucket b(g_alloc);
        for (int i = 0; i < 119; ++i) b.push_back(RankType::Rank3, "杂鱼", "绚丽异彩", 0);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 0);   // 第 120 抽, 硬保底强制, 不计胜
        b.push_back(RankType::Rank6, "卡缪", "某重构B", 0);    // B 系列第 1 抽就中
        const StatsResult r = Calculate(b, false, false, stdChars, pm, true);
        std::printf("[重构-跨系列] up=%d win=%d lose=%d mixed=%d\n",
                    r.count_up, r.win_5050, r.lose_5050, int(r.ks_up_mixed));
        CHECK(r.count_up == 2);
        CHECK(!r.ks_up_mixed);                     // 跨系列不算混合
        CHECK(r.freq_ecdf_up == r.freq_up);        // 非武器图表保留逐抽口径
        CHECK(r.win_5050 == 1 && r.lose_5050 == 0);
    }
    // 同一系列出第 2 个 UP 才是混合
    {
        PullBucket b(g_alloc);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 0);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 0);
        const StatsResult r = Calculate(b, false, false, stdChars, pm, true);
        CHECK(r.count_up == 2 && r.ks_up_mixed);
        CHECK(r.freq_ecdf_up == r.freq_up);        // 导出绘图数据不能清掉混合样本标志
    }

    // ---------- 三、重构寻访: 多系列的删失观测都要进风险集 ----------
    {
        PullBucket b(g_alloc);
        for (int i = 0; i < 100; ++i) b.push_back(RankType::Rank3, "杂鱼", "绚丽异彩", 0);
        for (int i = 0; i < 5;   ++i) b.push_back(RankType::Rank3, "杂鱼", "某重构B", 0);
        const StatsResult r = Calculate(b, false, false, stdChars, pm, true);
        CHECK(r.censored_pity_up == 5);            // 界面显示取最后活动的系列
        CHECK(r.censored_pity_all == 105);         // 80 小保底跨所有重构池共享 -> 全局累加
        for (int x = 1; x <= 100; ++x) CHECK(r.hazard_up[x] == 0.0);
    }

    // ---------- 四、非重构池: 删失与旧行为一致 ----------
    {
        PullBucket b(g_alloc);
        b.push_back(RankType::Rank6, "提弗洛斯", "冬猎", 0);
        for (int i = 0; i < 7; ++i) b.push_back(RankType::Rank3, "杂鱼", "冬猎", 0);
        const StatsResult r = Calculate(b, false, false, stdChars, pm, false);
        CHECK(r.count_up == 1 && r.censored_pity_up == 7);
        CHECK(std::abs(r.hazard_up[1] - 0.5) < 1e-12);   // 风险集 = 1 个 UP + 1 条删失
        CHECK(!r.ks_up_mixed);
    }

    // ---------- 五、赠送十连分块 (30/60/90 三个里程碑) ----------
    {
        PullBucket b(g_alloc);
        for (int i = 0; i < 29; ++i) b.push_back(RankType::Rank3, "杂鱼", "绚丽异彩", 1);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 1);   // 第 30 条 free -> 第 3 块
        const StatsResult r = Calculate(b, false, false, stdChars, pm, true);
        CHECK(r.freq_up[90] == 1);     // UP 侧按累计抽数, 精确落在节点 90
        CHECK(r.freq_all[60] == 1);    // 综合侧按水位, 第 3 块并入节点 60 (已知近似)
        CHECK(r.freq_up[30] == 0);
        CHECK(r.win_5050 == 1);
    }

    // ---------- 六、武器池: 顺序数据必须与旧算法逐位一致 ----------
    {
        struct Rec { RankType rt; const char* name; const char* pool; };
        // 旧算法: 单份 cur_pity/pity_up, 相邻 poolName 一变就全部清零
        auto legacy = [](const std::vector<Rec>& recs,
                         const std::unordered_set<std::string,StringHash,std::equal_to<>>& stdw) {
            struct Out { int freq[260]{}; int cnt=0, up=0, win=0, lose=0, cenAll=0, cenUp=0; };
            Out o; int cur = 0, pu = 0; bool got = false;
            for (size_t i = 0; i < recs.size(); ++i) {
                if (i > 0 && std::string_view(recs[i].pool) != std::string_view(recs[i-1].pool)) {
                    pu = 0; got = false; cur = 0;
                }
                ++cur; ++pu;
                if (recs[i].rt != RankType::Rank6) continue;
                o.freq[cur < 260 ? cur : 259]++; o.cnt++;
                if (!stdw.contains(recs[i].name)) {
                    o.up++;
                    if (!(!got && pu >= 71)) o.win++;
                    got = true; pu = 0;
                } else o.lose++;
                cur = 0;
            }
            o.cenAll = cur; o.cenUp = pu;
            return o;
        };
        std::unordered_set<std::string,StringHash,std::equal_to<>> stdWeps{"宏愿","扶摇"};
        std::vector<Rec> recs;
        for (int i = 0; i < 11; ++i) recs.push_back({RankType::Rank3, "杂鱼", "绛结申领"});
        recs.push_back({RankType::Rank6, "宏愿", "绛结申领"});
        for (int i = 0; i < 33; ++i) recs.push_back({RankType::Rank3, "杂鱼", "绛结申领"});
        for (int i = 0; i < 24; ++i) recs.push_back({RankType::Rank3, "杂鱼", "军列申领"});
        recs.push_back({RankType::Rank6, "四二式·肃阵", "军列申领"});
        for (int i = 0; i < 5;  ++i) recs.push_back({RankType::Rank3, "杂鱼", "军列申领"});

        PullBucket b(g_alloc);
        for (const auto& x : recs) b.push_back(x.rt, x.name, x.pool, 0);
        const StatsResult now = Calculate(b, true, false, stdWeps, {}, false);
        const auto old = legacy(recs, stdWeps);
        std::printf("[武器-顺序回归] all=%d up=%d win=%d lose=%d cenAll=%d cenUp=%d\n",
                    now.count_all, now.count_up, now.win_5050, now.lose_5050,
                    now.censored_pity_all, now.censored_pity_up);
        CHECK(now.count_all == old.cnt && now.count_up == old.up);
        CHECK(now.win_5050 == old.win && now.lose_5050 == old.lose);
        CHECK(now.censored_pity_all == old.cenAll && now.censored_pity_up == old.cenUp);
        for (int x = 0; x < 260; ++x) CHECK(now.freq_all[x] == old.freq[x]);
    }

    // ---------- 七、武器池: 两池交错时不再互相清零 ----------
    // 1.5 起「重构申领」与「武库申领」同时开放, 武器接口把它们放在同一条时间线上返回。
    {
        std::unordered_set<std::string,StringHash,std::equal_to<>> stdWeps{"宏愿"};
        PullBucket b(g_alloc);
        for (int i = 0; i < 20; ++i) b.push_back(RankType::Rank3, "杂鱼", "武库申领", 0);
        for (int i = 0; i < 10; ++i) b.push_back(RankType::Rank3, "杂鱼", "点绘申领", 0);
        for (int i = 0; i < 19; ++i) b.push_back(RankType::Rank3, "杂鱼", "武库申领", 0);
        b.push_back(RankType::Rank6, "宏愿", "武库申领", 0);   // A 池第 40 抽
        const StatsResult r = Calculate(b, true, false, stdWeps, {}, false);
        CHECK(r.freq_all[40] == 1);     // 旧算法会记成 pity=20
        CHECK(r.freq_all[20] == 0);
        CHECK(r.censored_pity_all == 0);
    }

    // ---------- 八、存档读取路径 ----------
    std::puts("[存档读取]");
    {
        // 合法存档: 顶层成员顺序 (事件在前) 不得影响读取结果
        const std::string doc = tst::fixture("analyzer_valid_events_first.json");
        int n = 0; bool structured = false;
        const JsonArrayScan sc = ReadUigfPullList(doc, structured, [&](std::string_view){ ++n; });
        std::printf("  事件段在前的合法存档: structured=%d n=%d\n", int(structured), n);
        CHECK(structured && sc == JsonArrayScan::Ok && n == 1);
    }
    {
        // endfield 存在但类型不对 —— 不能回退全文, 否则会读到事件 raw 里的 list
        const std::string doc = tst::fixture("analyzer_endfield_wrong_type.json");
        int n = 0; bool structured = false;
        const JsonArrayScan sc = ReadUigfPullList(doc, structured, [&](std::string_view){ ++n; });
        std::printf("  endfield=null: scan=%d n=%d\n", int(sc), n);
        CHECK(sc == JsonArrayScan::Malformed);
        CHECK(n == 0);
    }
    {
        int n = 0; bool structured = false;
        CHECK(ReadUigfPullList(R"({"endfield":{},"x":1})", structured,
                               [&](std::string_view){ ++n; }) == JsonArrayScan::Malformed);
        n = 0;
        CHECK(ReadUigfPullList(R"({"endfield":"bad"})", structured,
                               [&](std::string_view){ ++n; }) == JsonArrayScan::Malformed);
        // 没有 endfield 段 (UIGF v3.0 / 第三方结构): 保持宽松回退
        n = 0;
        CHECK(ReadUigfPullList(R"({"list":[{"a":1},{"b":2}]})", structured,
                               [&](std::string_view){ ++n; }) == JsonArrayScan::Ok);
        CHECK(!structured && n == 2);
        // 截断: 必须报 Malformed, 调用方据此拒绝出统计
        n = 0;
        CHECK(ReadUigfPullList(R"({"endfield":[{"list":[{"a":1},{"b":2)", structured,
                               [&](std::string_view){ ++n; }) == JsonArrayScan::Malformed);
    }
    {
        // rank_type 写成 JSON 数字的真实记录不能被丢掉
        const std::string_view item =
            R"({"item_type":"Character","gacha_type":"special_1_5_1","item_name":"提弗洛斯","rank_type":6,"item_id":"c1"})";
        std::string_view rankSv = ExtractJsonValue(item, "rank_type", true);
        if (rankSv.empty()) rankSv = ExtractJsonValue(item, "rank_type", false);
        CHECK(ParseRankType(rankSv) == RankType::Rank6);
    }

    // ---------- 九、配置字符串的切分口径 ----------
    // ★ 这一节与 Tests/app_config_tests.swift 的 testPoolEntries 是【同一组用例】。
    //   两边必须逐条一致: Swift 侧负责迁移时的合并/去重, C++ 侧负责分析时的精确查表。
    //   口径一旦分叉, 迁移写出来的键在分析时查不到, 而界面上没有任何提示 —— UP 识别静默失效。
    std::puts("[配置切分]");
    {
        // 键值只切【第一个】冒号: "A:B:C" => 键 A、值 "B:C"
        const auto m1 = ParsePoolMap("A:B:C");
        CHECK(m1.size() == 1 && m1.at("A") == "B:C");

        // 无冒号的段丢弃; 空键 / 空值丢弃
        const auto m2 = ParsePoolMap("没有冒号,A:B");
        CHECK(m2.size() == 1 && m2.contains("A"));
        CHECK(ParsePoolMap(":B").empty());
        CHECK(ParsePoolMap("A:").empty());
        CHECK(ParsePoolMap("").empty());
        CHECK(ParsePoolMap(",,,").empty());

        // 重复键【先到先得】(emplace)。Swift 侧的补充项之所以必须追加在末尾,
        // 就是为了不盖掉用户自己写在前面的映射 —— 这条是那个约束的依据。
        const auto m3 = ParsePoolMap("冬猎:我自己填的,冬猎:提弗洛斯");
        CHECK(m3.size() == 1 && m3.at("冬猎") == "我自己填的");

        // 全角逗号 U+FF0C / 全角冒号 U+FF1A 不是分隔符, 是名字的一部分
        const auto m4 = ParsePoolMap("春雷动，万物生:庄方宜");
        CHECK(m4.size() == 1 && m4.contains("春雷动，万物生"));
        CHECK(ParsePoolMap("作品：蚀迹").empty());
        const auto m5 = ParsePoolMap("作品：蚀迹:某人");
        CHECK(m5.size() == 1 && m5.at("作品：蚀迹") == "某人");

        // trim 只认 ASCII 空白; U+3000 / U+00A0 必须原样留在键里
        const auto m6 = ParsePoolMap(" \t池名\r\n : \tUP ");
        CHECK(m6.size() == 1 && m6.at("池名") == "UP");
        const auto m7 = ParsePoolMap("　池名:UP");
        CHECK(m7.size() == 1 && m7.contains("　池名"));
        const auto m8 = ParsePoolMap(" 池名:UP");
        CHECK(m8.size() == 1 && m8.contains(" 池名"));

        // 无结构名单
        const auto s1 = ParseCommaSeparated("宏愿, 扶摇 ,,作品：蚀迹");
        CHECK(s1.size() == 3);
        CHECK(s1.contains("宏愿") && s1.contains("扶摇") && s1.contains("作品：蚀迹"));
        CHECK(ParseCommaSeparated("").empty());
        CHECK(ParseCommaSeparated("  , \t ").empty());
        CHECK(ParseCommaSeparated("　宏愿").contains("　宏愿"));
        std::printf("  池映射/名单切分: %zu 条用例通过\n", size_t(20));
    }

    // ---------- 十、KS 数值与图表标记必须来自同一统计口径 ----------
    std::puts("[KS 标记]");
    constexpr double kKSTol = 1e-12;
    auto checkLocation = [&](double d, const KSLocation& location,
                             int x, double empirical, double theory) {
        CHECK(location.x == x);
        CHECK(std::abs(location.empirical - empirical) < kKSTol);
        CHECK(std::abs(location.theory - theory) < kKSTol);
        CHECK(std::abs(d - std::abs(empirical - theory)) < kKSTol);
        CHECK(std::abs(d - std::abs(location.empirical - location.theory)) < kKSTol);
    };
    auto checkExportedLocation = [&](const StatsResult& r) {
        const auto& location = r.ks_location_up;
        CHECK(r.count_up > 0);
        CHECK(location.x >= 0 && location.x < 260);
        if (r.count_up == 0 || location.x < 0 || location.x >= 260) return;
        int cumulative = 0;
        for (int x = 1; x <= location.x; ++x) cumulative += r.freq_ecdf_up[x];
        checkLocation(r.ks_d_up, location, location.x,
                      (double)cumulative / r.count_up, r.theory_cdf_up[location.x]);
    };
    {
        // 最小反例: 第 1 抽与第 10 抽都属于第 1 次申领, KS 应同为 1 - F(10)。
        // 第 71 抽归第 8 次申领, 最大偏差出现在此前 F(70) 的平台, D 不会被必然抬高。
        std::unordered_set<std::string,StringHash,std::equal_to<>> stdWeps{"宏愿"};
        for (int interval : {1, 10, 71}) {
            PullBucket b(g_alloc);
            for (int x = 1; x <= interval; ++x) {
                if (x == interval) b.push_back(RankType::Rank6, "四二式·肃阵", "军列申领", 0);
                else if (x == 40) b.push_back(RankType::Rank6, "宏愿", "军列申领", 0);
                else b.push_back(RankType::Rank3, "杂鱼", "军列申领", 0);
            }
            const StatsResult r = Calculate(b, true, false, stdWeps, {});
            CHECK(r.count_up == 1);
            CHECK(r.avg_up == interval);            // 平均值与 MRL 的原始频数仍保留单抽口径
            for (int x = 0; x < 260; ++x) CHECK(r.freq_up[x] == (x == interval ? 1 : 0));
            const int claimEnd = interval == 71 ? 80 : 10;
            for (int x = 0; x < 260; ++x) CHECK(r.freq_ecdf_up[x] == (x == claimEnd ? 1 : 0));
            CHECK(r.hazard_up[interval] == 1.0);
            const int expectedX = interval == 71 ? 70 : 10;
            const double expectedEmpirical = interval == 71 ? 0.0 : 1.0;
            checkLocation(r.ks_d_up, r.ks_location_up, expectedX,
                          expectedEmpirical, g_cdf_wep_up[expectedX]);
            checkExportedLocation(r);
            if (interval <= 10) {
                CHECK(std::abs(r.ks_d_up - std::pow(0.99, 10)) < kKSTol);
                // 综合六星的 KS 继续逐抽计算, 不随武器 UP 一起聚合。
                checkLocation(r.ks_d_all, r.ks_location_all, interval,
                              1.0, g_cdf_wep[interval]);
            }
            std::printf("  武器 UP [%d]: D=%.12f x=%d empirical=%.12f theory=%.12f\n",
                        interval, r.ks_d_up, r.ks_location_up.x,
                        r.ks_location_up.empirical, r.ks_location_up.theory);
        }
    }
    {
        // 普通角色池: 单抽口径不变, all / UP 都要导出对应理论表上的同一位置。
        PullBucket b(g_alloc);
        for (int x = 1; x < 20; ++x) b.push_back(RankType::Rank3, "杂鱼", "冬猎", 0);
        b.push_back(RankType::Rank6, "提弗洛斯", "冬猎", 0);
        const StatsResult r = Calculate(b, false, false, stdChars, pm);
        checkLocation(r.ks_d_all, r.ks_location_all, 20, 1.0, g_cdf_char[20]);
        checkLocation(r.ks_d_up, r.ks_location_up, 20, 1.0, g_cdf_char_up[20]);
        CHECK(r.freq_all[20] == 1 && r.freq_up[20] == 1);
        CHECK(r.freq_ecdf_up == r.freq_up);
        checkExportedLocation(r);
    }
    {
        // 同一申领内的多个落点必须累加, 不能覆盖; 10 / 20 的整申领边界不再向后移动。
        constexpr int intervals[]{1, 9, 10, 11, 20, 21, 71};
        constexpr const char* pools[]{"申领A", "申领B", "申领C", "申领D", "申领E", "申领F", "申领G"};
        std::unordered_set<std::string,StringHash,std::equal_to<>> stdWeps{"宏愿"};
        PullBucket b(g_alloc);
        std::array<int,260> raw{}, claims{};
        for (int i = 0; i < 7; ++i) {
            ++raw[intervals[i]];
            for (int x = 1; x < intervals[i]; ++x) {
                b.push_back(x == 40 ? RankType::Rank6 : RankType::Rank3,
                            x == 40 ? "宏愿" : "杂鱼", pools[i], 0);
            }
            b.push_back(RankType::Rank6, "四二式·肃阵", pools[i], 0);
        }
        claims[10] = 3; claims[20] = 2; claims[30] = 1; claims[80] = 1;
        const StatsResult r = Calculate(b, true, false, stdWeps, {});
        CHECK(r.count_up == 7);
        CHECK(r.freq_up == raw);
        CHECK(r.freq_ecdf_up == claims);
        CHECK(std::abs(r.avg_up - 143.0 / 7.0) < kKSTol);
        checkExportedLocation(r);
    }
    {
        // 异常长间隔仍需安全绘图: 251..259 向上聚合会越界, 必须全部落在 259。
        // 250 是合法边界, 不能连同后面的频数一起移动或重复计数。
        PullBucket b(g_alloc);
        std::array<int,260> raw{}, claims{};
        for (int interval = 250; interval <= 259; ++interval) {
            for (int x = 1; x < interval; ++x) b.push_back(RankType::Rank3, "杂鱼", "异常申领", 0);
            b.push_back(RankType::Rank6, "四二式·肃阵", "异常申领", 0);
        }
        for (int x = 250; x <= 259; ++x) raw[x] = 1;
        claims[250] = 1; claims[259] = 9;
        const StatsResult r = Calculate(b, true, false, {}, {});
        CHECK(r.count_up == 10);
        CHECK(r.freq_up == raw);
        CHECK(r.freq_ecdf_up == claims);
        checkExportedLocation(r);
    }
    {
        // 跳点前最大差应落在 x-1; 不能将该差值标到经验 CDF 已跳到 1 的 x=5 上。
        std::array<int,260> freq{};
        freq[5] = 1;
        const std::array<double,6> cdf{0.0, 0.2, 0.4, 0.6, 0.8, 1.0};
        KSLocation location;
        const double d = ComputeKS(freq, 5, 1, cdf, &location);
        checkLocation(d, location, 4, 0.0, 0.8);
        CHECK(d == ComputeKS(freq, 5, 1, cdf));      // 旧的四参数调用仍兼容

        // 唯一可由首次跳前比较取得的新极值在 x=0, 也要保留真实横坐标。
        freq = {};
        freq[1] = 1;
        const std::array<double,2> startsAboveZero{0.4, 0.7};
        const double atZero = ComputeKS(freq, 1, 1, startsAboveZero, &location);
        checkLocation(atZero, location, 0, 0.0, 0.4);
    }
    {
        // 辉光 UP 表在 240 后是未填充哨兵段; 比较范围和标记都沿用有效尾值。
        std::array<int,260> freq{};
        freq[259] = 1;
        KSLocation location;
        CHECK(g_cdf_joint_up[240] > 0.5 && g_cdf_joint_up[240] < 1.0);
        CHECK(g_cdf_joint_up[241] == 0.0);
        const double d = ComputeKS(freq, 999, 1, g_cdf_joint_up, &location);
        checkLocation(d, location, 240, 0.0, g_cdf_joint_up[240]);
        CHECK(d < 1.0);                           // 不把哨兵 0 当成真正的理论 CDF

        // 近似理论分布后, 将剩余长尾放在 259: 最大差真正落在绘图范围外,
        // 导出位置必须保留 259, 不能为了显示而截成 240。
        freq = {};
        int cumulative = 0;
        for (int x = 1; x <= 240; ++x) {
            const int next = (int)std::floor(1000.0 * g_cdf_joint_up[x]);
            freq[x] = next - cumulative;
            cumulative = next;
        }
        freq[259] = 1000 - cumulative;
        const double tailD = ComputeKS(freq, 259, 1000, g_cdf_joint_up, &location);
        checkLocation(tailD, location, 259, 1.0, g_cdf_joint_up[240]);

        // 真实 Calculate 也导出同一截断理论表, 保留辉光的逐抽经验频数。
        PullBucket b(g_alloc);
        for (int x = 1; x < 259; ++x) {
            b.push_back(x % 80 == 0 ? RankType::Rank6 : RankType::Rank3,
                        x % 80 == 0 ? "骏卫" : "杂鱼", "辉光庆典", 0);
        }
        b.push_back(RankType::Rank6, "提弗洛斯", "辉光庆典", 0);
        const StatsResult r = Calculate(b, false, true, stdChars, {});
        CHECK(r.count_up == 1 && r.freq_up[259] == 1);
        CHECK(r.freq_ecdf_up == r.freq_up);
        CHECK(!r.ks_up_mixed);
        checkLocation(r.ks_d_up, r.ks_location_up, 240, 0.0, g_cdf_joint_up[240]);
        checkExportedLocation(r);
    }
    {
        // 空样本必须清零输出位置, 不能遗留上次有样本的标记。
        std::array<int,260> freq{};
        KSLocation location{70, 0.5, 0.75};
        const double d = ComputeKS(freq, 0, 0, g_cdf_wep_up, &location);
        checkLocation(d, location, 0, 0.0, 0.0);
        PullBucket b(g_alloc);
        const StatsResult r = Calculate(b, true, false, {}, {});
        checkLocation(r.ks_d_all, r.ks_location_all, 0, 0.0, 0.0);
        checkLocation(r.ks_d_up, r.ks_location_up, 0, 0.0, 0.0);
    }

    // ---------- 十一、理论曲线与有效末端由统计核心统一导出, 空池也完整 ----------
    std::puts("[图表理论数据]");
    {
        // 精确的小表钉住有效末端的语义, 不在测试里另写一遍扫描算法。
        const std::array<double,4> saturated{0.0, 0.5, 1.0 - 0.5e-6, 1.0};
        const std::array<double,4> sentinel{0.0, 0.5, 0.9, 0.0};
        const std::array<double,4> roundingNoise{0.0, 0.5, 0.5 - 0.5e-6, 0.8};
        CHECK(FindCDFLastValid(saturated) == 2);
        CHECK(FindCDFLastValid(sentinel) == 2);
        CHECK(FindCDFLastValid(roundingNoise) == 3);
    }
    {
        // 导出缓冲区只有 260 格; 未来理论表延长时只能复制可容纳的前缀。
        std::array<double,300> longer{};
        for (int x = 0; x < 300; ++x) longer[x] = (double)x / 300.0;
        std::array<double,260> exported{};
        CHECK(FindCDFLastValid(longer) == 299);
        CHECK(ExportTheoryCDF(longer, exported) == 259);
        for (int x = 0; x < 260; ++x) CHECK(exported[x] == longer[x]);

        // 空输入必须覆写所有旧值, 不能把上次绘图的尾部残留在结果里。
        CHECK(ExportTheoryCDF({}, exported) == 0);
        for (double value : exported) CHECK(value == 0.0);
    }
    struct TheoryCase {
        const char* name;
        bool isWeapon, isJoint, isRefactor;
        std::span<const double> all, up;
        int step;
        double tail;
    };
    const TheoryCase theoryCases[]{
        {"特许", false, false, false, g_cdf_char, g_cdf_char_up, 1, 0.0},
        {"辉光", false, true,  false, g_cdf_char, g_cdf_joint_up, 1, g_joint_tail_mean_excess},
        {"重构", false, false, true,  g_cdf_refactor, g_cdf_refactor_up, 1, 0.0},
        {"武器", true,  false, false, g_cdf_wep, g_cdf_wep_up, 10, 0.0},
    };
    auto checkTheory = [](const std::array<double,260>& exported, int last,
                          std::span<const double> source) {
        CHECK(last == FindCDFLastValid(source));
        CHECK(last > 0 && last < (int)source.size());
        if (last <= 0 || last >= (int)source.size()) return;
        // 理论值直接核对第一节已验证的源表; 不复制概率计算或假定末端等于硬保底。
        for (int x = 0; x <= last; ++x) CHECK(exported[x] == source[x]);
        for (int x = last + 1; x < 260; ++x) CHECK(exported[x] == source[last]);
    };
    for (const auto& tc : theoryCases) {
        PullBucket empty(g_alloc);
        const StatsResult r = Calculate(empty, tc.isWeapon, tc.isJoint, {}, {}, tc.isRefactor);
        CHECK(r.count_all == 0 && r.count_up == 0);
        CHECK(r.ecdf_up_step_size == tc.step);
        CHECK(r.theory_tail_mean_excess_up == tc.tail);
        CHECK(r.freq_ecdf_up == r.freq_up);
        checkTheory(r.theory_cdf_all, r.theory_last_valid_all, tc.all);
        checkTheory(r.theory_cdf_up, r.theory_last_valid_up, tc.up);
        checkLocation(r.ks_d_all, r.ks_location_all, 0, 0.0, 0.0);
        checkLocation(r.ks_d_up, r.ks_location_up, 0, 0.0, 0.0);
        std::printf("  %s: allEnd=%d upEnd=%d step=%d tail=%.10f\n", tc.name,
                    r.theory_last_valid_all, r.theory_last_valid_up,
                    r.ecdf_up_step_size, r.theory_tail_mean_excess_up);
    }

    return tst::finish("analyzer");
}
