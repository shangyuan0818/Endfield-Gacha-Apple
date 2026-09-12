// AnalyzerWrapper.mm 的统计核心测试。
//
// 通过 extract_mm_core.py 抽出该文件的匿名 namespace 原文, 所以 InitCDFTables /
// Calculate / ReadUigfPullList 就是 App 真正在用的那一份实现。
//
// 覆盖: 六张理论 CDF 的期望值、重构寻访的按系列状态、武器池按期状态 (与旧算法的逐位回归)、
//       赠送十连分块、混合样本判定、右删失、存档读取路径。
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
    std::printf("[CDF] char=%.4f charUP=%.4f wep=%.4f wepUP=%.4f refac=%.4f refacUP=%.4f jointTail=%.4f\n",
                expectation(g_cdf_char, 82), expectation(g_cdf_char_up, 122),
                expectation(g_cdf_wep, 41),  expectation(g_cdf_wep_up, 81),
                expectation(g_cdf_refactor, 82), expectation(g_cdf_refactor_up, 122),
                g_joint_tail_mean_excess);
    CHECK(std::abs(expectation(g_cdf_char, 82)        - 51.8051) < 1e-3);
    CHECK(std::abs(expectation(g_cdf_char_up, 122)    - 79.2914) < 1e-3);
    CHECK(std::abs(expectation(g_cdf_wep, 41)         - 19.1711) < 1e-3);
    CHECK(std::abs(expectation(g_cdf_wep_up, 81)      - 54.7370) < 1e-3);
    CHECK(std::abs(expectation(g_cdf_refactor, 82)    - 51.3708) < 1e-3);
    CHECK(std::abs(expectation(g_cdf_refactor_up, 122)- 77.8275) < 1e-3);
    CHECK(std::abs(g_joint_tail_mean_excess           - 84.3666) < 1e-3);
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
        CHECK(r.win_5050 == 1 && r.lose_5050 == 0);
    }
    // 同一系列出第 2 个 UP 才是混合
    {
        PullBucket b(g_alloc);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 0);
        b.push_back(RankType::Rank6, "伊冯", "绚丽异彩", 0);
        const StatsResult r = Calculate(b, false, false, stdChars, pm, true);
        CHECK(r.count_up == 2 && r.ks_up_mixed);
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

    return tst::finish("analyzer");
}
