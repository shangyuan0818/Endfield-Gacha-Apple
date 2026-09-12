// FetchSession.mm 里"定位与判定"逻辑的测试。
//
// 通过 extract_mm_core.py 抽出该文件的匿名 namespace 原文, 所以下面调用的
// LocateUigfPullList / InspectPageEnvelope / ReadIntegerField / ReadTextField
// 就是 App 真正在用的那一份实现, 不是转录副本。
//
// 覆盖范围: 基底存档的接受条件、一页响应的信封解析与池结束判定、字段读取、抽卡/事件分流。
// 不覆盖: ObjC 方法体本身 (网络、文件替换)。那需要 Xcode 里的 XCTest, 见 Tests/README.md。
#include "test_support.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>
#include <memory_resource>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../Endfield-Gacha/ObjC/JsonScan.h"
#include "build/fetch_core.inc"
}   // 补上被截断的匿名 namespace 结尾

// ---- 与 ingestResponseData 的判定阶梯一一对应的最小复刻 ----
// 只用来把 InspectPageEnvelope + 各道闸门的组合结果表达成一个可断言的枚举;
// 每一行都对应 .mm 里同名的那道闸门。
enum class Verdict { Continue, PoolDone, Problem };

struct PageResult {
    Verdict verdict = Verdict::Problem;
    const char* why = "";
    int items = 0;
    JsonArrayScan scan = JsonArrayScan::NotFound;
};

// priorCnt = 本页之前本池已吃进的新记录数 (m.cnt)。
// 注意真实实现里 m.cnt 是【现场求值】的, 本页扫进来的记录也算数 —— 所以下面的 gapRisk
// 取 (priorCnt > 0 || 本页 items > 0), 与 .mm 里各道闸门看到的 m.cnt 口径一致。
// Problem 在真实实现里按缺口风险分流成 Fatal / 跳池 / 池错误 —— 这里只关心"有没有被拦下来"。
static PageResult decide(std::string_view body, bool priorIngested) {
    PageResult r;
    const PageEnvelope env = InspectPageEnvelope(body);
    if (!env.complete)  { r.why = "正文不完整(截断)"; return r; }
    if (!env.codeFound) { r.why = "无 code 字段";     return r; }
    if (env.code != "0"){ r.why = "业务错误码";       return r; }

    if (env.listStatus == LocateResult::Located)
        r.scan = ForEachObjectInArray2(env.listText, [&](std::string_view){ ++r.items; });
    else
        r.scan = (env.listStatus == LocateResult::NotFound) ? JsonArrayScan::NotFound
                                                            : JsonArrayScan::Malformed;

    if (r.scan == JsonArrayScan::Malformed) { r.why = "记录数组结构异常"; return r; }
    const bool gapRisk = priorIngested || r.items > 0;
    if (gapRisk && env.listStatus == LocateResult::NotFound) { r.why = "翻页中途整页没有记录数组"; return r; }
    if (gapRisk && env.hasMoreBad)                           { r.why = "hasMore 类型异常";        return r; }
    if (gapRisk && r.items > 0 && !env.hasMoreKnown)         { r.why = "读不到 hasMore";          return r; }
    if (gapRisk && r.items == 0 && env.hasMoreKnown && env.hasMoreValue) { r.why = "空页但称仍有记录"; return r; }

    r.verdict = (r.items == 0 || !env.hasMoreValue) ? Verdict::PoolDone : Verdict::Continue;
    r.why = (r.verdict == Verdict::PoolDone) ? "本池结束" : "继续翻页";
    return r;
}

static const char* name(Verdict v) {
    switch (v) { case Verdict::Continue: return "Continue";
                 case Verdict::PoolDone: return "PoolDone";
                 default:                return "Problem"; }
}

static void expectPage(const char* label, std::string_view body, bool priorIngested, Verdict want) {
    const PageResult r = decide(body, priorIngested);
    const bool ok = (r.verdict == want);
    if (!ok) ++tst::g_failures;
    std::printf("  %-34s prior=%d items=%d -> %-9s %s (%s)\n",
                label, int(priorIngested), r.items, name(r.verdict), ok ? "OK" : "MISMATCH", r.why);
}

int main() {
    // ============================================================
    // 一、基底存档的接受条件 (LocateUigfPullList)
    // ============================================================
    std::puts("[基底存档]");
    struct BaseCase { const char* label; const char* fixture; bool acceptable; };
    const BaseCase baseCases[] = {
        { "单账号",                      "base_one_account.json",                 true  },
        { "两个账号 (不支持, 必须拒绝)",  "base_two_accounts.json",                false },
        // 下面两条是第二轮审查点名的反例: 外层数组在第一项之后就坏了, 计数停在 1,
        // 若丢掉扫描结果就会"只加载账号 A"然后覆盖写盘, 账号 B 的历史永久消失。
        { "[账号, null, 账号]",          "base_account_null_account.json",        false },
        { "[账号 账号] (缺分隔逗号)",     "base_missing_account_comma.invalid.json", false },
    };
    for (const auto& c : baseCases) {
        const std::string doc = tst::fixture(c.fixture);
        const UigfListLocation loc = LocateUigfPullList(doc);
        const bool accepted = loc.usable && loc.listStatus == LocateResult::Located;
        if (accepted != c.acceptable) ++tst::g_failures;
        std::printf("  %-30s scan=%-9s 账号数=%zu 接受=%d %s\n", c.label,
                    loc.endfieldScan == JsonArrayScan::Ok ? "Ok"
                      : loc.endfieldScan == JsonArrayScan::Malformed ? "Malformed" : "NotFound",
                    loc.endfieldEntries, int(accepted),
                    accepted == c.acceptable ? "OK" : "MISMATCH");
    }
    // endfield 存在但类型不对 —— 不能当成"没有 endfield"放过去
    {
        const UigfListLocation loc = LocateUigfPullList(R"({"endfield":null,"x":1})");
        CHECK(!loc.usable);
        CHECK(loc.endfieldPresent);
        CHECK(!loc.endfieldIsArray);
    }

    // ============================================================
    // 二、一页响应的信封与池结束判定 (InspectPageEnvelope)
    // ============================================================
    std::puts("\n[翻页中途 (已吃进新记录, 任何异常都可能留下永久缺口)]");
    expectPage("正常空页",              R"({"code":0,"data":{"list":[],"hasMore":false}})",                 true, Verdict::PoolDone);
    expectPage("正常有记录页",           R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":true}})",     true, Verdict::Continue);
    expectPage("最后一页",              R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":false}})",    true, Verdict::PoolDone);
    expectPage("list 之前截断",          R"({"code":0,"data":)",                                            true, Verdict::Problem);
    expectPage("list 之内截断",          R"({"code":0,"data":{"list":[{"seqId":"1"})",                      true, Verdict::Problem);
    expectPage("hasMore 之后截断",       R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":)",          true, Verdict::Problem);
    expectPage("数组含非对象元素",        R"({"code":0,"data":{"list":[[],{"seqId":"1"}]}})",                true, Verdict::Problem);
    expectPage("数组元素缺逗号",          R"({"code":0,"data":{"list":[{"seqId":"1"}{"seqId":"2"}]}})",      true, Verdict::Problem);
    expectPage("完整正文但没有 list",     R"({"code":0,"data":{}})",                                         true, Verdict::Problem);
    expectPage("空页却称仍有记录",        R"({"code":0,"data":{"list":[],"hasMore":true}})",                 true, Verdict::Problem);
    expectPage("hasMore 类型不对",       R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":{"x":1}}})",  true, Verdict::Problem);
    expectPage("hasMore 缺失",          R"({"code":0,"data":{"list":[{"seqId":"1"}]}})",                    true, Verdict::Problem);
    expectPage("业务错误码",             R"({"code":40100,"msg":"Token is invalid","data":null})",          true, Verdict::Problem);
    expectPage("无 code 字段",           R"({"data":{"list":[]}})",                                         true, Verdict::Problem);

    std::puts("\n[本池第一页, 本页也没有任何记录 —— 空池是正常形态]");
    expectPage("正常空页",              R"({"code":0,"data":{"list":[],"hasMore":false}})",                 false, Verdict::PoolDone);
    expectPage("完整正文但没有 list",     R"({"code":0,"data":{}})",                                         false, Verdict::PoolDone);
    expectPage("list 之前截断",          R"({"code":0,"data":)",                                            false, Verdict::Problem);
    expectPage("业务错误码",             R"({"code":40100,"msg":"bad","data":null})",                       false, Verdict::Problem);
    // 本页吃进了记录就已经有缺口风险 —— 即使这是本池第一页。
    expectPage("第一页有记录但 hasMore 缺失", R"({"code":0,"data":{"list":[{"seqId":"1"}]}})",               false, Verdict::Problem);

    std::puts("\n[接口结构变化: 支持的形状 vs 明确不支持的形状]");
    expectPage("list/hasMore 都在根对象",  R"({"code":0,"list":[{"seqId":"1"}],"hasMore":false})",           true, Verdict::PoolDone);
    expectPage("list 在 data、hasMore 在根", R"({"code":0,"hasMore":false,"data":{"list":[{"seqId":"1"}]}})", true, Verdict::PoolDone);
    expectPage("hasMore 是字符串",         R"({"code":0,"data":{"list":[{"seqId":"1"}],"hasMore":"false"}})", true, Verdict::PoolDone);
    // 更深的嵌套: list 能靠全文回退找到, 但 hasMore 【有意】不做全文回退 —— 从任意记录里
    // 读到的同名字段来决定是否继续翻页, 正是会造成静默缺口的那一类。读不到就明确报错,
    // 而不是猜一个值。(若将来接口真变成这种形状, 在 InspectPageEnvelope 里加一条明确的
    // 适配路径, 不要放开全文查找。)
    expectPage("更深的嵌套 (明确不支持)",   R"({"code":0,"p":{"q":{"list":[{"seqId":"1"}],"hasMore":false}}})", true, Verdict::Problem);

    // 第二轮审查的反例: 根对象 hasMore=true, 而某条记录里嵌着 hasMore=false。
    // 只把根对象的 hasMore 挪到 data 后面 (不改任何值), 全文查找就会选中记录里的 false。
    // 现在两份文件必须得到【同一个】结论: 继续翻页。
    std::puts("\n[根对象成员顺序不得影响 hasMore]");
    {
        const std::string first = tst::fixture("page_root_flag_first.json");
        const std::string last  = tst::fixture("page_root_flag_last.json");
        const PageEnvelope a = InspectPageEnvelope(first);
        const PageEnvelope b = InspectPageEnvelope(last);
        std::printf("  root.hasMore 在 data 前: known=%d value=%d\n", int(a.hasMoreKnown), int(a.hasMoreValue));
        std::printf("  root.hasMore 在 data 后: known=%d value=%d\n", int(b.hasMoreKnown), int(b.hasMoreValue));
        CHECK(a.hasMoreKnown && a.hasMoreValue);
        CHECK(b.hasMoreKnown && b.hasMoreValue);
        CHECK(decide(first, true).verdict == Verdict::Continue);
        CHECK(decide(last,  true).verdict == Verdict::Continue);
    }

    // ============================================================
    // 三、字段读取
    // ============================================================
    {
        long long v = -1; bool present = false;
        CHECK(ReadIntegerField(R"({"id":"123"})", "id", v, present) && v == 123 && present);
        v = -1; present = false;
        CHECK(ReadIntegerField(R"({"id":123})", "id", v, present) && v == 123 && present);     // 数字形态
        v = -1; present = false;
        CHECK(ReadIntegerField(R"({"id":-456})", "id", v, present) && v == -456);              // 武器负 id
        v = -1; present = false;
        CHECK(!ReadIntegerField(R"({"id":"12ab"})", "id", v, present) && present);
        v = -1; present = false;
        CHECK(!ReadIntegerField(R"({"id":"1180591620717411303424"})", "id", v, present));
        v = -1; present = false;
        CHECK(!ReadIntegerField(R"({"id":null})", "id", v, present) && !present);              // null = 没有
        v = -1; present = false;
        CHECK(!ReadIntegerField(R"({"x":1})", "id", v, present) && !present);                  // 缺键 = 没有
        // 第二轮审查反例: 类型不对【不等于】不存在 —— 调用方用 (!ok && present) 表达
        // "写了就必须能解析", present 若只表示"是数字或字符串", 这里就会被当成"没写"而放行。
        v = -1; present = false;
        CHECK(!ReadIntegerField(R"({"gacha_ts":true})", "gacha_ts", v, present));
        CHECK(present);
    }
    {
        // ReadTextField: 字符串 / 数字 / 布尔都读得到原文, 缺失与 null 读成空
        CHECK(ReadTextField(R"({"rank_type":"6"})", "rank_type") == "6");
        CHECK(ReadTextField(R"({"rank_type":6})",   "rank_type") == "6");      // 第三方常见写法
        CHECK(ReadTextField(R"({"is_new":true})",   "is_new")    == "true");
        CHECK(ReadTextField(R"({"rank_type":null})","rank_type").empty());
        CHECK(ReadTextField(R"({"x":1})",           "rank_type").empty());
    }

    // ============================================================
    // 四、旧版畸形记录的迁移判据 / 抽卡与事件的分流
    // ============================================================
    {
        auto absentOrEmpty = [](std::string_view obj, std::string_view key){
            const JsonValueRef v = FindTopLevelValue2(obj, key);
            if (v.kind == JsonValueKind::None || v.kind == JsonValueKind::Null) return true;
            return v.kind == JsonValueKind::String && v.text.empty();
        };
        auto wouldMigrate = [&](std::string_view item){
            return absentOrEmpty(item, "item_id") && absentOrEmpty(item, "rank_type")
                && absentOrEmpty(item, "item_name");
        };
        CHECK(wouldMigrate(R"({"id":"7","gacha_ts":"1","gacha_type":"special_1_5_1"})"));
        CHECK(wouldMigrate(R"({"id":"7","item_id":"","item_name":"","rank_type":""})"));
        // 第三方写法的【真实抽卡】不能被迁走
        CHECK(!wouldMigrate(R"({"item_id":null,"rank_type":6,"item_name":"提弗洛斯"})"));
        CHECK(!wouldMigrate(R"({"rank_type":6,"item_name":"提弗洛斯"})"));
        CHECK(!wouldMigrate(R"({"item_id":"c1","rank_type":"6","item_name":"提弗洛斯"})"));
    }
    {
        auto isEvent = [](std::string_view item, bool isWeapon){
            const std::string_view rarity = ExtractJsonValue2(item, "rarity", false);
            const std::string_view itemId = isWeapon ? ExtractJsonValue2(item, "weaponId", true)
                                                     : ExtractJsonValue2(item, "charId",   true);
            return !(!itemId.empty() && !rarity.empty());
        };
        CHECK(isEvent(R"({"seqId":"1","kind":"gift_intel_book","nameText":"寻访情报书"})", false));
        CHECK(!isEvent(R"({"seqId":"2","kind":"draw","charId":"c1","rarity":6})", false));
        // 官方把 kind 改名时仍按抽卡处理 (旧写法会把全部真实抽卡判成事件)
        CHECK(!isEvent(R"({"seqId":"3","kind":"gacha","charId":"c1","rarity":6})", false));
        CHECK(isEvent(R"({"seqId":"4","kind":"up_token","nameText":"UP信物"})", false));
        CHECK(!isEvent(R"({"seqId":"5","weaponId":"w1","rarity":6})", true));
    }

    return tst::finish("fetch_session");
}
