//
//  FetchSession.mm
//  Endfield-Gacha
//
//  AsyncFetch-Design v5 —— C++ 状态机核心 (字段零额外拷贝)。
//  迁移自旧 GachaFetcherWrapper.mm 的 worker 体; 网络 IO 已全部移除 (FetchURL 删)。
//
//  关键设计 (与旧实现 / Windows main.cpp 对齐):
//   - 所有网络响应 (std::string) 与基底文件内容 (std::string) 都存活在
//     std::deque<std::string> payloads 中。deque 的 emplace_back 不失效已有指针,
//     所以 ExportRecord 全用 std::string_view 指向 payloads 内字节,
//     避免几万次 std::string malloc (字段零额外拷贝, 非严格零拷贝)。
//   - PMR monotonic_buffer_resource 提供临时容器分配池, 避免每元素 malloc。
//   - string_view 必须在拷贝进 payloads 之后【重绑】到 payloads.back() (见 D.1)。
//

#import "FetchSession.h"
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include "JsonScan.h"   // 与 AnalyzerWrapper.mm 共用的 JSON 扫描器 (v0.1.4.2 抽出)

#include <algorithm>
#include <array>
#include <cerrno>            // v0.1.3.3: Flush 的 EINTR 重试
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>            // make_unique_for_overwrite
#include <memory_resource>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>           // std::forward (ForEachJsonObject2 转发回调)
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

// ============================================================
//  JSON / URL 解析
//
//  v0.1.4.2: JSON 扫描器整段提到共享头 JsonScan.h。此前 FetchSession.mm 与
//  AnalyzerWrapper.mm 各抄了一份 (上游 main.cpp / gui.cpp 也是如此), 结果两边悄悄分叉 ——
//  导出器改成按结构路径读存档之后, 分析器还在全文找第一个 "list", 同一份合法存档只要
//  顶层成员顺序不同就读出不同结果。现在两边引用同一份实现。
//
//  下面这组 `2` 后缀的别名是为了让本文件几十处既有调用点保持原样; 新代码直接用
//  efjson:: 里的名字即可。
// ============================================================
using JsonValueKind = efjson::ValueKind;
using JsonValueRef  = efjson::ValueRef;
using JsonArrayScan = efjson::ArrayScan;
using LocateResult  = efjson::LocateResult;

inline size_t FindJsonKey2(std::string_view src, std::string_view key, size_t pos = 0) {
    return efjson::FindKeyToken(src, key, pos);
}
inline std::string_view ExtractJsonValue2(std::string_view src, std::string_view key, bool isStr) {
    return efjson::ExtractValue(src, key, isStr);
}
inline size_t SkipJsonValue2(std::string_view s, size_t i, JsonValueKind& kind) {
    return efjson::SkipValue(s, i, kind);
}
inline JsonValueRef FindTopLevelValue2(std::string_view obj, std::string_view key) {
    return efjson::FindMember(obj, key);
}
inline JsonValueRef FirstArrayElement2(std::string_view arrayText) {
    return efjson::FirstElement(arrayText);
}
inline bool ParseFullInt64(std::string_view s, long long& out) {
    return efjson::ParseFullInt64(s, out);
}
template<typename Cb>
[[nodiscard]] JsonArrayScan ForEachObjectInArray2(std::string_view arrayText, Cb&& cb) {
    return efjson::ForEachObjectIn(arrayText, std::forward<Cb>(cb));
}
template<typename Cb>
[[nodiscard]] JsonArrayScan ForEachJsonObject2(std::string_view src, std::string_view arrKey, Cb&& cb) {
    return efjson::ForEachObjectByKey(src, arrKey, std::forward<Cb>(cb));
}

// 读一个【必须是整数】的字段: 接受 JSON 字符串与数字两种形态, 整串必须解析干净。
//
// v0.1.4.2: 存档里的 id / gacha_ts 此前用 ExtractJsonValue2(..., isStr=true) + 裸 from_chars 读,
// 有三个静默失败: (a) 第三方 UIGF 导出器把 id 写成数字字面量 -> isStr 分支要求以 '"' 开头,
// 直接返回空 -> 解析成 0; (b) "12ab" 被 from_chars 吃成 12; (c) 超 int64 时 from_chars 不写出参,
// 仍是 0。id 同时是去重键, 塌成 0 之后 "触达本地老记录" 永不触发, 整段历史会被重复追加,
// 而且会被以 "id":"0" 回写, 原 id 永久覆盖。这个函数把三种情况统一变成"读不出来"。
// present 的语义是【这个键存在】(不含 null), 而不是"类型对不对" —— 两者必须分开:
//   调用方用 `!ok && present` 表达"写了就必须能解析"。若把 present 定义成"是字符串或数字",
//   那 "gacha_ts": true 会得到 ok=false, present=false, 调用方看成"没写"而放行, 时间戳静默留 0。
inline bool ReadIntegerField(std::string_view obj, std::string_view key, long long& out, bool& present) {
    const JsonValueRef v = efjson::FindMember(obj, key);
    present = (v.kind != JsonValueKind::None && v.kind != JsonValueKind::Null);
    if (v.kind != JsonValueKind::String && v.kind != JsonValueKind::Number) return false;
    return efjson::ParseFullInt64(v.text, out);
}

// 读一个文本字段: 字符串取引号之间的原文 (转义不还原), 数字/布尔取字面量, 缺失/null 取空。
//
// v0.1.4.2: 存档字段此前一律用 ExtractJsonValue2(..., isStr=true) 读, 而它在"值不是以 \" 开头"
// 时返回空视图。UIGF 的 endfield 段没有官方 schema, 第三方转换器把 rank_type 写成 JSON 数字
// ("rank_type": 6) 很常见 —— 旧写法把它读成空, 再以 "rank_type": "" 原样回写, 覆盖用户唯一的
// 长期存档, 稀有度就此永久消失; 分析端随后把这条当成"没出六星的一抽", 其后每个六星的保底
// 水位都少算 1 抽。这里按 kind 取原文, 两种形态都读得进来 (写盘时统一成 UIGF 的字符串形态)。
inline std::string_view ReadTextField(std::string_view obj, std::string_view key) {
    const JsonValueRef v = efjson::FindMember(obj, key);
    if (v.kind == JsonValueKind::String || v.kind == JsonValueKind::Number ||
        v.kind == JsonValueKind::Bool) return v.text;
    return {};
}


// ============================================================
//  可单独测试的两段"定位"逻辑 (v0.1.5.2)
//
//  它们原本内联在 prepare / ingestResponseData 里, 而那两处是 ObjC 方法, 在没有 Apple SDK
//  的机器上编译不了 —— 想验证"哪些输入会被接受"就只能把逻辑抄一份到测试里, 抄的那份迟早
//  与真实实现分叉。提成命名空间级的纯函数之后, Tests/ 下的用例直接调用【同一份实现】。
// ============================================================

// 存档 (UIGF v4.2) 里抽卡记录数组的定位结果。
struct UigfListLocation {
    bool             endfieldPresent = false;  // 根对象里有没有 "endfield" 这个键
    bool             endfieldIsArray = false;
    JsonArrayScan    endfieldScan    = JsonArrayScan::NotFound;  // 外层数组【自身】扫完了吗
    size_t           endfieldEntries = 0;      // 账号个数 (本工具只支持 1)
    bool             usable          = false;  // 外层完整且恰好一个账号
    LocateResult     listStatus      = LocateResult::NotFound;
    std::string_view listText;
};

// 定位 根.endfield[0].list。
//   ★ 外层 endfield 数组自身的扫描结果必须一并带出来: 丢掉它就等于"只要能数出第一项就继续",
//     而 [账号A, null, 账号B] 与 [账号A 账号B] (缺逗号) 都会在第一项之后判 Malformed、计数
//     停在 1 —— "元素数 <= 1" 因此成立, 于是只加载账号 A, 覆盖写盘时账号 B 的历史就没了。
inline UigfListLocation LocateUigfPullList(std::string_view doc) {
    UigfListLocation out;
    const JsonValueRef gameV = FindTopLevelValue2(doc, "endfield");
    out.endfieldPresent = (gameV.kind != JsonValueKind::None) || gameV.malformed;
    out.endfieldIsArray = (gameV.kind == JsonValueKind::Array);
    if (out.endfieldIsArray) {
        out.endfieldScan = ForEachObjectInArray2(gameV.text,
                               [&out](std::string_view){ ++out.endfieldEntries; });
    } else if (gameV.malformed) {
        out.endfieldScan = JsonArrayScan::Malformed;
    }
    out.usable = (out.endfieldScan == JsonArrayScan::Ok && out.endfieldEntries == 1);
    if (!out.usable) return out;

    const JsonValueRef entry0 = FirstArrayElement2(gameV.text);
    if (entry0.kind != JsonValueKind::Object) { out.listStatus = LocateResult::Malformed; return out; }
    const JsonValueRef listV = FindTopLevelValue2(entry0.text, "list");
    if (listV.kind == JsonValueKind::Array) { out.listStatus = LocateResult::Located; out.listText = listV.text; }
    else if (listV.malformed)               { out.listStatus = LocateResult::Malformed; }
    else if (listV.kind == JsonValueKind::None || listV.kind == JsonValueKind::Null)
                                            { out.listStatus = LocateResult::NotFound; }
    else                                    { out.listStatus = LocateResult::Malformed; }
    return out;
}

// 一页接口响应的"信封": 完整性、业务码、记录数组位置、hasMore。
struct PageEnvelope {
    bool             complete   = false;   // 整段正文是一个完整闭合的 JSON 对象
    bool             codeFound  = false;
    std::string_view code;
    std::string_view msg;
    LocateResult     listStatus = LocateResult::NotFound;
    std::string_view listText;
    bool             hasMoreKnown = false;
    bool             hasMoreValue = false;
    bool             hasMoreBad   = false;  // 键在, 但读不出来 / 不是布尔
};

// 解析一页响应的信封。只读不写, 没有副作用 —— 便于直接单测。
//
// hasMore 只按【某个对象的本层】读, 绝不全文查找:
//   全文查找会把 list 元素 (或事件原文) 里同名的 hasMore 一并看见。构造一个根对象写
//   "hasMore": true、而某条记录里嵌着 "hasMore": false 的合法响应, 仅仅把根对象的 hasMore
//   挪到 data 后面 (不改任何值), 全文首个匹配就从 true 变成 false, 本池随即被判"正常结束"
//   —— 而 JSON 对象的成员顺序本来就不该有语义。
inline PageEnvelope InspectPageEnvelope(std::string_view rv) {
    PageEnvelope pi;
    pi.complete = efjson::IsCompleteObjectDocument(rv);
    if (!pi.complete) return pi;

    // code / msg: 结构化优先, 读不到再回退全文 (接口将来改变嵌套层级时不至于整个拉不动)。
    {
        const JsonValueRef cv = FindTopLevelValue2(rv, "code");
        if (cv.kind == JsonValueKind::String || cv.kind == JsonValueKind::Number) pi.code = cv.text;
        else pi.code = ExtractJsonValue2(rv, "code", false);
        pi.codeFound = !pi.code.empty();
        const JsonValueRef mv = FindTopLevelValue2(rv, "msg");
        pi.msg = (mv.kind == JsonValueKind::String) ? mv.text : ExtractJsonValue2(rv, "msg", true);
    }

    // 只要 root.data (或 root 本身) 是对象, 就按本层读 list / hasMore。
    std::string_view host;
    bool structured = false;
    {
        const JsonValueRef dataV = FindTopLevelValue2(rv, "data");
        if (dataV.kind == JsonValueKind::Object) { host = dataV.text; structured = true; }
        else if (FindTopLevelValue2(rv, "list").kind == JsonValueKind::Array) { host = rv; structured = true; }
    }

    auto readHasMore = [&pi](std::string_view obj) {
        if (pi.hasMoreKnown || pi.hasMoreBad) return;
        const JsonValueRef hm = FindTopLevelValue2(obj, "hasMore");
        if (hm.kind == JsonValueKind::Bool) { pi.hasMoreKnown = true; pi.hasMoreValue = (hm.text == "true"); }
        else if (hm.kind == JsonValueKind::String && (hm.text == "true" || hm.text == "false")) {
            pi.hasMoreKnown = true; pi.hasMoreValue = (hm.text == "true");
        } else if (hm.malformed) {
            // 这一层根本读不下去 —— FindMember 此时返回 kind==None + malformed==true, 与
            // "没有这个键"是两回事 (JsonScan.h 的三态契约)。并进静默分支就又成了"读不出来当没有"。
            pi.hasMoreBad = true;
        } else if (hm.kind != JsonValueKind::None && hm.kind != JsonValueKind::Null) {
            pi.hasMoreBad = true;   // 键在, 但既不是布尔也不是布尔字面量字符串
        }
    };

    if (structured) {
        const JsonValueRef lv = FindTopLevelValue2(host, "list");
        if (lv.kind == JsonValueKind::Array) { pi.listStatus = LocateResult::Located; pi.listText = lv.text; }
        else if (lv.malformed)               { pi.listStatus = LocateResult::Malformed; }
        else if (lv.kind == JsonValueKind::None || lv.kind == JsonValueKind::Null)
                                             { pi.listStatus = LocateResult::NotFound; }
        else                                 { pi.listStatus = LocateResult::Malformed; }
        readHasMore(host);
    } else {
        const auto loc = efjson::LocateArrayFullText(rv, "list");
        pi.listStatus = loc.first;
        pi.listText   = loc.second;
    }
    // host 那一层没有 hasMore 时, 再看【根对象本层】—— 这正是要兼容的"list 在 data 里、
    // hasMore 留在根对象"那种形状。host == rv 时这次查询是重复的, 无害。
    readHasMore(rv);
    // 结构路径没拿到记录数组时回退全文。现网形状是 {code,msg,data:{list,hasMore}}, 也就是
    // structured 恒为 true; 接口若把 list 再往里挪一层 (data.page.list), 只认 data 本层就会
    // 读到"这一页没有记录", 第 1 页因此按空池收尾 —— 六个池全这样就是静默 0 条照常写盘。
    if (pi.listStatus == LocateResult::NotFound) {
        const auto loc = efjson::LocateArrayFullText(rv, "list");
        if (loc.first != LocateResult::NotFound) { pi.listStatus = loc.first; pi.listText = loc.second; }
    }
    return pi;
}

inline std::string_view ExtractUrlParam(std::string_view url, std::string_view key){
    size_t pos = url.find(key);
    if(pos==std::string_view::npos) return {};
    pos += key.size();
    size_t end = url.find('&', pos);
    return end==std::string_view::npos ? url.substr(pos) : url.substr(pos, end-pos);
}

// ============================================================
//  RAII 小工具: 文件描述符 + 作用域退出守卫 (建议: writeExport / 基底读取的异常清理)
// ============================================================
struct ScopedFd {
    int fd = -1;
    ScopedFd() = default;
    explicit ScopedFd(int f) : fd(f) {}
    ~ScopedFd(){ if(fd >= 0) ::close(fd); }
    ScopedFd(const ScopedFd&) = delete;
    ScopedFd& operator=(const ScopedFd&) = delete;
    int get() const { return fd; }
    explicit operator bool() const { return fd >= 0; }
};

// 通用作用域退出守卫: 析构时执行 f (除非 dismiss())。用于"未提交即删临时文件"。
template<typename F>
struct ScopeExit {
    F f;
    bool active = true;
    explicit ScopeExit(F fn) : f(std::move(fn)) {}
    ~ScopeExit(){ if(active) f(); }
    void dismiss(){ active = false; }
    ScopeExit(const ScopeExit&) = delete;
    ScopeExit& operator=(const ScopeExit&) = delete;
};

// ============================================================
//  缓冲写入 (64KB 栈缓冲; ok 跟踪 + 循环写入 + 短路; 整段从旧 worker 搬入)
// ============================================================
struct BufferedWriter{
    int fd;
    char buf[65536];
    size_t pos = 0;
    bool ok = true;   // 一旦写失败置 false: 后续 Flush/Write 短路, 调用方据此决定是否提交结果

    explicit BufferedWriter(int f) : fd(f) {}
    ~BufferedWriter(){ Flush(); }

    BufferedWriter(const BufferedWriter&) = delete;
    BufferedWriter& operator=(const BufferedWriter&) = delete;

    bool Flush(){
        if (!ok) return false;
        if (fd < 0) { ok = false; return false; }
        size_t offset = 0;
        while (offset < pos) {
            ssize_t written = ::write(fd, buf + offset, pos - offset);
            if (written < 0) {
                if (errno == EINTR) continue;   // v0.1.3.3: 信号中断且未写出字节 → 重试 (POSIX 卫生项)
                ok = false; return false;       // 真实 I/O 错误
            }
            if (written == 0) { ok = false; return false; }   // 常规文件不应发生, 防御
            offset += (size_t)written;
        }
        pos = 0;
        return true;
    }
    void Write(const char* d, size_t n){
        if (!ok) return;
        while(n>0){
            size_t sp = sizeof(buf)-pos;
            size_t ch = std::min(n, sp);
            memcpy(buf+pos, d, ch);
            pos += ch; d += ch; n -= ch;
            if(pos==sizeof(buf) && !Flush()) return;
        }
    }
    void Write(std::string_view sv){ Write(sv.data(), sv.size()); }

    template<size_t N>
    void WriteLit(const char (&s)[N]){
        if (!ok) return;
        constexpr size_t n = N-1;
        if(pos+n > sizeof(buf) && !Flush()) return;
        memcpy(buf+pos, s, n);
        pos += n;
    }
    void WriteEscaped(std::string_view s){
        const char* p = s.data();
        const char* e = p + s.size();
        while(p<e){
            const char* c = p;
            while(p<e && *p!='"' && *p!='\\') ++p;
            if(p>c) Write(c, (size_t)(p-c));
            if(!ok) return;
            if(p<e){
                if(*p=='"') WriteLit("\\\"");
                else        WriteLit("\\\\");
                ++p;
            }
        }
    }
    // v0.1.3.3: WriteKV 的 v 全部来自 ExtractJsonValue2 的【原始转义形态】视图 (扫描器
    // 不解码转义, 返回引号之间的原文), 本就是合法 JSON 字符串内容, 必须【原样写出】。
    // 旧版再跑一遍 WriteEscaped 会把 `\` 翻倍, 解码后凭空多出反斜杠, 每导出一轮膨胀
    // 一次, 破坏往返幂等 (名称目前不含 `"`/`\`, 属潜伏缺陷)。WriteEscaped 保留, 仅用于
    // 【程序生成】的非转义字符串 (如 Info.plist 版本号 verStr)。
    void WriteKV(std::string_view k, std::string_view v){
        WriteLit("            \"");
        Write(k);
        WriteLit("\": \"");
        Write(v);            // 原始转义形态, 原样写出
        WriteLit("\"");
    }
    void WriteTimeKV(std::string_view k, long long ms){
        time_t t = ms/1000;
        struct tm tmv{};
        char b[64];
        int n = 0;
        // v0.1.4.2: 必须检查返回值。时间戳来自外部文件, 被构造/损坏的值 (例如
        //   "gacha_ts":"-9223372036854775808") 能被 ParseFullInt64 正常解析, 但 localtime_r
        //   对无法表示的时间返回 NULL 且【不写出参】—— 旧写法随后直接读未初始化的 struct tm,
        //   轻则把随机日期写进存档, 重则 UB。
        if (localtime_r(&t, &tmv)) {
            n = snprintf(b, sizeof(b), "%04d-%02d-%02d %02d:%02d:%02d",
                         tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        }
        if (n < 0) n = 0;
        WriteLit("            \"");
        Write(k);
        WriteLit("\": \"");
        Write(b, (size_t)n);   // 无法表示的时间写成空串, 而不是垃圾日期
        WriteLit("\"");
    }
    void WriteI64KV(std::string_view k, long long v, bool q){
        char nb[32];
        auto [p, e] = std::to_chars(nb, nb+32, v);
        WriteLit("            \"");
        Write(k);
        WriteLit("\": ");
        if(q) WriteLit("\"");
        Write(nb, (size_t)(p-nb));
        if(q) WriteLit("\"");
    }
};

enum class FItemType : uint8_t { Unknown=0, Character, Weapon };
inline std::string_view ItemTypeToStr(FItemType t){
    if(t==FItemType::Character) return "Character";
    if(t==FItemType::Weapon)    return "Weapon";
    return "Unknown";
}

// 与 main.cpp 对齐: 全部 string_view 指向 deque<string> 中的字节; deque 不失效指针
struct ExportRecord{
    long long safe_id = 0;
    long long timestamp = 0;
    std::string_view poolId;
    std::string_view item_id;
    std::string_view name;
    FItemType item_type = FItemType::Unknown;
    std::string_view rank_type;
    std::string_view poolName;
    std::string_view weaponType;
    uint8_t isNew  = 0;
    uint8_t isFree = 0;
};
struct PoolCfg{
    std::string poolType;
    std::string displayName;
    bool isWeapon;
    // v0.1.4.2: 这个池型可能【在某些区服/服务端版本上还不存在】。
    //   服务端对未知 pool_type 返回 {"code":40000,"msg":"Invalid pool_type"}, 而协调器
    //   把任何池级错误都升级为"整次拉取失败、不写盘"(见 GachaFetchCoordinator 的注释:
    //   宁可整次作废也不留半份数据)。对一个尚未上线的池型来说, 那意味着拉取功能对
    //   该区服的所有用户【确定性地彻底不可用】—— 重试多少次都一样。
    //   标成 optional 的池: 只在【第一页、本池尚未吃进任何记录】时允许"跳过本池、继续其余池",
    //   翻页中途出错仍按缺口风险整次中止。等该池型在所有区服稳定后把这里改回 false。
    bool optional = false;
};

// ============================================================
// [非抽卡事件]  v0.1.4.1
//
// /api/record/char 的 list 里除了真实抽卡, 还会混入"发放某个道具"的事件行。
// 目前已确认的一种是【寻访情报书】(kind = "gift_intel_book"): 特许寻访累计 60 次本体抽
// 发放 1 本, 于下一次特许寻访开启后自动转化为该池专有寻访凭证 ×10
// (客户端 GachaCharPoolTypeTable type=0 的 testimonialPullCount = 60, 每个 special_* 池
//  带 testimonialRewardItemId 如 "item_gacha_introletter_1_5_1")。
// 这类行有 seqId / gachaTs / poolId / poolName, 但【没有】charId / charName / rarity。
//
// 处理策略:
//   - 不写进 UIGF 的 "list" —— 那是抽卡记录数组, 混入非抽卡行会让所有读这个文件的
//     工具都得知道这个怪癖。放进去还会让不做过滤的工具把保底水位每期多算 1 抽。
//   - 但也【不丢弃】: 抽卡记录接口只保留最近 90 天, 本地文件是唯一的长期存档,
//     丢掉就再也取不回来。历史被 90 天窗口截断时, 这条事件的时间戳还能反推出
//     "此刻我在该池已累计满 60 抽"这一信息。
//   - 折中: 存到顶层的 "non_pull_events" 数组里, 且【原样保留服务器返回的整个 JSON 对象】,
//     这样将来出现新的 kind (例如 240 抽的 UP 信物、武器申领的补充武库箱) 也不会丢字段。
//
// raw 是指向 payloads 里某个 std::string 的视图 (与 ExportRecord 的字段同源),
// 在写盘前始终有效。
// ============================================================
struct NonPullEvent{
    long long        safe_id   = 0;   // 与抽卡记录同一套 id 口径 (角色正 / 武器负), 用于去重
    long long        timestamp = 0;   // gachaTs, 仅用于排序
    std::string_view raw;             // 服务器原始 JSON 对象 (含大括号), 原样回写
};

// ============================================================
//  状态机 (C.2)
// ============================================================
enum class FetchState { Created, ReadyForRequest, AwaitingResponse, Done, Exported, Failed };

// 成员放堆上的 impl; 在 prepare 内创建 (init 不分配 C++ impl, 见 C.1)。
struct FetchSessionImpl {
    std::string inputUrl, existFile, token, serverId, hostName;
    std::unique_ptr<std::byte[]> arena;                       // 2MB, make_unique_for_overwrite
    std::optional<std::pmr::monotonic_buffer_resource> pool;  // 声明序 arena→pool→alloc→容器
    std::optional<std::pmr::polymorphic_allocator<std::byte>> alloc;
    std::deque<std::string> payloads;
    std::optional<std::pmr::vector<ExportRecord>> records;
    // v0.1.4.1: 非抽卡事件 (见 NonPullEvent)。与抽卡记录共用 localIds/sessionIds 去重,
    //   但单独存放、单独写盘, 不进 UIGF 的 "list"。
    std::optional<std::pmr::vector<NonPullEvent>> events;
    size_t migratedLegacy = 0;   // 从旧版 list 里迁出的非抽卡事件条数 (仅用于提示)
    // v0.1.4.2: newCount 此前直接取 sessionIds.size() (抽卡 + 事件), 而 totalCount 只数
    //   records (抽卡), 于是"本次新增 3 条, 文件内共计 101 条"里的两个数字口径不同, 用户
    //   会以为丢了记录。改成分别计数, UI 分开显示。
    int newPulls = 0;            // 本次会话新增的抽卡记录条数
    int newEvents = 0;           // 本次会话新增的非抽卡事件条数
    std::vector<std::string> skippedPools;   // 被跳过的 optional 池 (写进摘要, 不静默)
    std::optional<std::pmr::unordered_set<long long>> localIds, sessionIds;
    std::vector<PoolCfg> pools;

    size_t poolIdx = 0;
    long long cursor = 0;
    int page = 1;
    int cnt = 0;            // 当前池累计新增 (用于"完成,新增 N 条")
    bool hasMore = true;
    bool reached = false;
    bool dupAnomaly = false;   // v0.1.3.3: 同会话重复 seqId (分页游标异常) → 升级 Fatal

    // 进入下一个池: 推进 poolIdx + 重置全部 per-pool 状态。
    void AdvancePool(){
        ++poolIdx;
        cursor = 0; page = 1; cnt = 0;
        hasMore = true; reached = false; dupAnomaly = false;
    }
};

// 末池延迟为 0 (D.3): 仍有后续池→500ms; 已是最后→0, 不空等。
// 注意: 此函数在 AdvancePool() 之后调用, 故 poolIdx 已指向"下一个"池。
int DelayAfterAdvancingPool(const FetchSessionImpl& impl) {
    return impl.poolIdx < impl.pools.size() ? 500 : 0;
}

constexpr size_t kArenaSize = 2 * 1024 * 1024;

// NSString <- std::string_view (拷贝字节, 生命周期独立)
inline NSString* NSStr(std::string_view sv){
    return [[NSString alloc] initWithBytes:sv.data() length:sv.size() encoding:NSUTF8StringEncoding] ?: @"";
}

} // namespace

// ============================================================
//  结果对象: 在 .mm 内把 readonly 重声明为 readwrite 以便构造
// ============================================================
@interface FetchNextRequestResult ()
@property (nonatomic, readwrite) FetchNextRequestStatus status;
@property (nonatomic, readwrite, nullable) NSString *urlString;
@property (nonatomic, readwrite, nullable) NSString *errorMessage;
@property (nonatomic, readwrite) NSArray<NSString *> *logs;
@end
@implementation FetchNextRequestResult
- (instancetype)init { if ((self = [super init])) { _logs = @[]; } return self; }
@end

@interface FetchPageOutcome ()
@property (nonatomic, readwrite) FetchIngestStatus status;
@property (nonatomic, readwrite) NSInteger newThisPage;
@property (nonatomic, readwrite) NSInteger totalNewSoFar;
@property (nonatomic, readwrite) NSInteger delayMsBeforeNext;
@property (nonatomic, readwrite) NSArray<NSString *> *logs;
@property (nonatomic, readwrite, nullable) NSString *poolErrorMessage;
@property (nonatomic, readwrite, nullable) NSString *fatalErrorMessage;
@end
@implementation FetchPageOutcome
- (instancetype)init { if ((self = [super init])) { _logs = @[]; } return self; }
@end

@interface FetchPrepareResult ()
@property (nonatomic, readwrite) BOOL ok;
@property (nonatomic, readwrite, nullable) NSString *errorMessage;
@property (nonatomic, readwrite) NSInteger baseRecordCount;
@property (nonatomic, readwrite) NSArray<NSString *> *logs;
@end
@implementation FetchPrepareResult
- (instancetype)init { if ((self = [super init])) { _logs = @[]; } return self; }
@end

@interface FetchExportSummary ()
@property (nonatomic, readwrite) BOOL ok;
@property (nonatomic, readwrite) NSInteger newCount;
@property (nonatomic, readwrite) NSInteger totalCount;
@property (nonatomic, readwrite) NSInteger newEventCount;
@property (nonatomic, readwrite) NSInteger totalEventCount;
@property (nonatomic, readwrite) NSInteger migratedLegacyCount;
@property (nonatomic, readwrite) NSArray<NSString *> *skippedPoolNames;
@property (nonatomic, readwrite, nullable) NSString *tempFilePath;
@property (nonatomic, readwrite, nullable) NSString *errorMessage;
@end
@implementation FetchExportSummary
// skippedPoolNames 在 NS_ASSUME_NONNULL 下是非空类型, 但失败路径不会给它赋值 ——
// 不在 init 里兜底, Swift 侧拿到的就是一个声明为非空的 nil。
- (instancetype)init { if ((self = [super init])) { _skippedPoolNames = @[]; } return self; }
@end

// ============================================================
//  FetchSession
// ============================================================
@implementation FetchSession {
    NSString *_inputUrl;
    NSString *_existFile;            // 可空
    FetchState _state;               // impl 创建前也要有状态 (= Created), 故独立于 impl
    std::unique_ptr<FetchSessionImpl> _impl;   // ObjC++ ivar: clang 自动 .cxx_construct/destruct
}

- (instancetype)initWithInputURL:(NSString *)inputURL
                    existingFile:(nullable NSString *)existingFilePath {
    if ((self = [super init])) {
        _inputUrl  = [inputURL copy];
        _existFile = [existingFilePath copy];
        _state     = FetchState::Created;
        // 不 new FetchSessionImpl, 不做文件 IO (C.1)。
    }
    return self;
}

// ---- prepare: Created → ReadyForRequest (失败→Failed) ----
- (FetchPrepareResult *)prepare {
    FetchPrepareResult *r = [FetchPrepareResult new];
    if (_state != FetchState::Created) {
        r.ok = NO; r.errorMessage = @"prepare 在非法状态调用"; return r;
    }

    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    try {
        _impl = std::make_unique<FetchSessionImpl>();
        FetchSessionImpl& m = *_impl;

        // ---- URL 提取 + trim ----
        m.inputUrl = _inputUrl.UTF8String ? _inputUrl.UTF8String : "";
        while(!m.inputUrl.empty() && (m.inputUrl.back()==' '||m.inputUrl.back()=='\n'||m.inputUrl.back()=='\r'||m.inputUrl.back()=='\t'))
            m.inputUrl.pop_back();
        while(!m.inputUrl.empty() && (m.inputUrl.front()==' '||m.inputUrl.front()=='\t'))
            m.inputUrl.erase(m.inputUrl.begin());

        std::string_view inputUrl(m.inputUrl);
        auto token = ExtractUrlParam(inputUrl, "token=");
        if(token.empty()){
            _state = FetchState::Failed;
            r.ok = NO; r.errorMessage = @"错误: 无法提取 token"; r.logs = logs; return r;
        }
        m.token = std::string(token);

        auto serverId = ExtractUrlParam(inputUrl, "server_id=");
        m.serverId = serverId.empty() ? std::string("1") : std::string(serverId);
        [logs addObject:NSStr("已识别 Server ID: " + m.serverId)];

        m.hostName = "ef-webview.gryphline.com";
        if(inputUrl.find("hypergryph") != std::string_view::npos){
            m.hostName = "ef-webview.hypergryph.com";
            [logs addObject:@"已识别区服: 国服 (Hypergryph)"];
        } else {
            [logs addObject:@"已识别区服: 国际服 (Gryphline)"];
        }

        // 角色寻访的 pool_type 枚举。
        //
        // v0.1.4.0 新增 E_CharacterGachaPoolType_Rerun (重构寻访 RE-Factor Headhunting):
        //   1.5「雪凇幽梦」引入的第五种角色寻访类型, 首期「绚丽异彩」2026/09/24 12:00 开启,
        //   poolId 形如 "rerun_chr_yvonne" (与其余四种一样, poolId 前缀 = 枚举后缀的小写)。
        //
        // 这个枚举值是【实测确认】的, 不是猜测 —— /api/record/char 会先校验 pool_type 再校验
        // token, 所以不带有效 token 也能判定一个枚举名是否合法:
        //     合法枚举 → {"code":40100,"msg":"Token is invalid"}
        //     非法枚举 → {"code":40000,"msg":"Invalid pool_type"}
        // 于是可以直接枚举出服务端接受的全集 (大小写敏感), 例如:
        //     curl -sG 'https://ef-webview.gryphline.com/api/record/char' \
        //          --data-urlencode 'lang=zh-cn' --data-urlencode 'token=x' \
        //          --data-urlencode 'server_id=1' \
        //          --data-urlencode 'pool_type=E_CharacterGachaPoolType_Rerun'
        //   2026-09-06 实测: 服务端只接受下面这 5 个值, 没有第 6 个。
        //   将来官方再加新池型时, 用同样的方法几秒就能试出新枚举名。
        //
        // 武器记录接口没有 pool_type 参数, 所有武器池 (含 1.5 新增的「重构申领」
        // rerun_wpn_*) 都在同一条 /api/record/weapon 时间线里返回, 无需在此登记。
        // 第 4 个字段 = optional (见 PoolCfg)。重构寻访是 1.5 新增的池型, 上面那段实测只在
        // 国际服 (ef-webview.gryphline.com) 做过, 国服与更早的服务端版本未验证; 首期
        // 「绚丽异彩」2026/09/24 才开启。标 optional 后, 即使某个区服拒绝这个枚举, 也只是
        // 跳过该池并在摘要里点名, 不会让整次拉取作废。
        m.pools = {
            {"E_CharacterGachaPoolType_Special",  "角色 - 特许寻访", false, false},
            {"E_CharacterGachaPoolType_Joint",    "角色 - 辉光庆典", false, false},  // v0.1.2.0: 辉光庆典池
            {"E_CharacterGachaPoolType_Rerun",    "角色 - 重构寻访", false, true },  // v0.1.4.0: 重构寻访 (可选)
            {"E_CharacterGachaPoolType_Standard", "角色 - 基础寻访", false, false},
            {"E_CharacterGachaPoolType_Beginner", "角色 - 启程寻访", false, false},
            {"",                                   "武器 - 全历史记录", true,  false}
        };

        // ---- PMR arena/pool/alloc + 容器 ----
        m.arena = std::make_unique_for_overwrite<std::byte[]>(kArenaSize);
        m.pool.emplace(m.arena.get(), kArenaSize);
        m.alloc.emplace(&*m.pool);
        m.records.emplace(*m.alloc);    m.records->reserve(10000);
        m.events.emplace(*m.alloc);     m.events->reserve(64);
        m.localIds.emplace(*m.alloc);   m.localIds->reserve(10000);
        m.sessionIds.emplace(*m.alloc); m.sessionIds->reserve(2000);

        // ---- 加载基底文件 (mmap → 拷贝到 payloads → 解除映射) ----
        // 拷贝是必须的: 用户选"覆盖保存到原文件"时, 后面要 replace 这个文件, 不能持有它的 mmap;
        // 映射由下方 ScopeExit 在拷贝/解析所在块结束时解除 (远早于 writeExport 的文件替换)。
        // 0 字节文件由 st.st_size>0 守卫排除 (不 mmap(0))。
        m.existFile = _existFile.UTF8String ? _existFile.UTF8String : "";
        if(!m.existFile.empty()){
            bool loaded = false;
            // v0.1.4.1 存档保护: 事件区读坏了同样必须中止, 不能"读不懂就当没有"然后覆盖。
            //   eventsCorrupt 为真 = 文件里【有】non_pull_events 键, 但数组没闭合 (截断) 或
            //   存在无法解析的条目。此时原文件里那些事件是唯一的副本 —— 抽卡记录接口只保留
            //   90 天, 一旦被覆盖就永久丢失。
            bool   eventsCorrupt  = false;
            bool   eventsBadShape = false;   // 键在, 但值不是一个正常闭合、元素全为对象的数组
            size_t eventsMalformed = 0;
            // v0.1.4.2: 抽卡记录区的 id 解析失败同样是"读不出来", 必须与事件区一个口径 ——
            //   id 是去重键, 静默塌成 0 会让"触达本地老记录"永不触发 (整段历史被重复追加),
            //   还会把原 id 以 "0" 回写覆盖。
            size_t recordsMalformed = 0;    // id / gacha_ts 读不出来的条数
            size_t recordsBadSyntax  = 0;    // 整条记录本身就不是合法 JSON 对象的条数
            size_t endfieldEntries  = 0;     // endfield 数组的元素个数 (多账号存档要拒绝)
            // 外层 endfield 数组【自身】的扫描结果。丢掉它就等于"只要能数出第一项就继续":
            //   [账号A, null, 账号B] 与 [账号A 账号B] (缺逗号) 都会在第一项之后判 Malformed,
            //   计数停在 1, 于是"元素数 <= 1"成立、照常只加载账号 A —— 随后覆盖写盘时账号 B
            //   的历史就没了。必须与内层 list 同等对待。
            JsonArrayScan endfieldScan = JsonArrayScan::NotFound;
            ScopedFd in(::open(m.existFile.c_str(), O_RDONLY));   // RAII: 任何分支/异常都会关闭 fd
            if(in){
                struct stat st{};
                if(fstat(in.get(), &st)==0 && st.st_size>0){
                    const size_t fileSize = (size_t)st.st_size;
                    void* mapped = mmap(nullptr, fileSize, PROT_READ, MAP_PRIVATE, in.get(), 0);
                    if(mapped != MAP_FAILED){
                        // RAII: 即使 emplace_back 抛 bad_alloc, 也会在块结束/异常时解除映射。
                        // (拷贝完即可解除; 解析读的是 payloads 里的副本, 不依赖此映射。)
                        ScopeExit unmap([&]{ munmap(mapped, fileSize); });
                        m.payloads.emplace_back(static_cast<const char*>(mapped), fileSize);

                        std::string_view bv(m.payloads.back());   // D.1: 重绑, 旧 mapped 已失效
                        if(bv.size()>=3
                           && (uint8_t)bv[0]==0xEF && (uint8_t)bv[1]==0xBB && (uint8_t)bv[2]==0xBF)
                            bv.remove_prefix(3);

                        // ---- 存档一律按【结构路径】定位, 不做全文找键 (v0.1.4.1) ----
                        // 抽卡数组的路径是 根.endfield[0].list, 事件数组是 根.non_pull_events。
                        // 全文找首个 "list" 在合法 JSON 上就能读错: 事件的 raw 是服务器原样
                        // 透传的对象, 未知 kind 完全可能自带 "list": [...]; 只要顶层成员顺序
                        // 变成 non_pull_events 在前 (JSON 对象的成员顺序本不该有语义),
                        // 首个匹配就落到 raw 里那个空数组上 —— 抽卡记录一条都读不到, 却
                        // 一路"正常", 写盘时把它们全删了。事件键同理会被
                        // {"x":{"non_pull_events":[]}} 这类嵌套同名键遮住。
                        // 定位走 LocateUigfPullList (同一份实现也被 Tests/ 直接调用, 见该函数注释)。
                        // UIGF v4 的游戏数组是【每个 UID 一个元素】, 多账号合并文件很常见;
                        // 本工具只支持单账号, 所以外层必须完整扫完且恰好一个账号才继续往里读 ——
                        // 只读出其中一部分再覆盖写盘, 会把其余账号的历史永久删除。
                        JsonArrayScan pullScan = JsonArrayScan::Malformed;
                        const UigfListLocation loc = LocateUigfPullList(bv);
                        endfieldScan    = loc.endfieldScan;
                        endfieldEntries = loc.endfieldEntries;
                        if(loc.listStatus == LocateResult::Located){
                        pullScan = ForEachObjectInArray2(loc.listText, [&](std::string_view item){
                            // v0.1.4.2: 每条记录先过一次【完整语法校验】。ForEachObjectInArray2
                            //   只保证元素的括号配对, 元素内部的成员层没有校验; 而下面所有字段
                            //   读取都假设这条记录是完整可读的。一条 {"id":"1","item_id":} 这样
                            //   括号配对正确、成员层却断掉的记录, 各个 FindMember 会在坏成员处
                            //   返回 malformed, 字段读出来全是空 —— 静默回写就等于把用户的字段
                            //   抹掉; 若它恰好被判成"旧版畸形记录", 整段非法字节还会被原样写进
                            //   新存档, 让整个文件对所有第三方工具都不可解析。
                            //   宁可明确报"基底受损、中止不写盘", 也不做这种静默改写。
                            if(!efjson::IsStrictJsonValue(item)){ ++recordsBadSyntax; return; }

                            // id: 接受字符串与数字两种形态, 整串必须解析干净 (见 ReadIntegerField)。
                            long long pid = 0, pts = 0;
                            bool idPresent = false;
                            if(!ReadIntegerField(item, "id", pid, idPresent)){ ++recordsMalformed; return; }
                            // gacha_ts: 允许缺失 (第三方文件可能没有), 但写了就必须能解析。
                            bool tsPresent = false;
                            if(!ReadIntegerField(item, "gacha_ts", pts, tsPresent) && tsPresent){
                                ++recordsMalformed; return;
                            }

                            // ---- 旧版文件的自愈迁移 (v0.1.4.1) ----
                            // v0.1.4.1 之前的版本会把非抽卡事件当成抽卡写进 list, 落地成
                            // item_id / item_name / rank_type 全空的畸形记录 (旧版把只有
                            // seqId 的事件行照单全收, 而那些"抽卡才有"的字段本就不存在)。
                            // 这里把它们就地迁到 non_pull_events, 而不是原样写回 list ——
                            // 否则畸形记录会一直留在抽卡数组里, 每个读这个文件的第三方工具
                            // 都要踩一次, 分析端的保底水位也会每 60 抽多算 1 抽。
                            //
                            // 判据与拉取时同源: 没有物品 id 且没有稀有度 ⇒ 不是一次抽卡。
                            // raw 存【旧文件里那个对象的原文】, 不去猜测、也不补造服务器字段:
                            // 旧版根本没读过 kind / nameText, 凭空写上就是伪造。因此迁移来的
                            // raw 是 UIGF 形状 (snake_case), 与新拉取的服务器原始对象
                            // (camelCase) 形状不同 —— 这一差异本身就标明了它的来历。
                            // v0.1.4.2 判据收紧: 旧写法用 ExtractJsonValue2(..., isStr=true) 判空,
                            //   而它在"值不是以 \" 开头"时也返回空视图 —— 于是 {"item_id":null,
                            //   "rank_type":6} 这种【第三方 UIGF 导出器很常见的写法】会被当成旧版
                            //   畸形记录搬进 non_pull_events, 一次真实六星就此从抽卡数组里消失,
                            //   而且没有回迁路径。改用三态语义: 只有【键确实不存在, 或值是空字符串】
                            //   才算"没有"; 值是数字/布尔/对象说明这是别人写的真实记录, 照常当抽卡读。
                            //   再把 item_name 一并纳入 —— 旧版畸形记录连名字都没有。
                            //   (记录本身的语法完整性已在回调开头统一校验过, 所以这里
                            //    FindMember 不可能返回 malformed, 三态里只剩"有值 / 没有"。)
                            auto fieldAbsentOrEmpty = [](std::string_view obj, std::string_view key){
                                const JsonValueRef v = FindTopLevelValue2(obj, key);
                                if(v.kind == JsonValueKind::None || v.kind == JsonValueKind::Null) return true;
                                return v.kind == JsonValueKind::String && v.text.empty();
                            };
                            if(fieldAbsentOrEmpty(item, "item_id") &&
                               fieldAbsentOrEmpty(item, "rank_type") &&
                               fieldAbsentOrEmpty(item, "item_name")){
                                NonPullEvent ev;
                                ev.safe_id   = pid;
                                ev.timestamp = pts;
                                ev.raw       = item;
                                m.events->push_back(ev);
                                m.localIds->insert(pid);
                                ++m.migratedLegacy;
                                return;
                            }

                            // 全部按本层 + kind 取原文 (见 ReadTextField): 第三方文件把
                            // rank_type / is_new 写成 JSON 数字或布尔都能读进来, 不会静默变空。
                            const std::string_view it2 = ReadTextField(item, "item_type");
                            FItemType ftype = (it2=="Character") ? FItemType::Character
                                            : (it2=="Weapon")    ? FItemType::Weapon
                                                                 : FItemType::Unknown;
                            ExportRecord rec;
                            rec.safe_id    = pid;
                            rec.timestamp  = pts;
                            rec.item_type  = ftype;
                            rec.poolId     = ReadTextField(item, "gacha_type");
                            rec.item_id    = ReadTextField(item, "item_id");
                            rec.name       = ReadTextField(item, "item_name");
                            rec.rank_type  = ReadTextField(item, "rank_type");
                            rec.poolName   = ReadTextField(item, "pool_name");
                            rec.weaponType = ReadTextField(item, "weapon_type");
                            rec.isNew  = (uint8_t)(ReadTextField(item, "is_new")  == "true" ? 1 : 0);
                            rec.isFree = (uint8_t)(ReadTextField(item, "is_free") == "true" ? 1 : 0);
                            m.records->push_back(std::move(rec));
                            m.localIds->insert(pid);
                        });
                        }
                        // Ok 之外的一切 (路径上任一环缺失/类型不对 / 数组没闭合 / 元素不是
                        // 对象) 都判加载失败。此前只要能定位到 "list" 就算加载成功, 于是被
                        // 截断的文件里"读到的那部分"会被当成完整历史写回去, 把尾巴永久抹掉。
                        loaded = (pullScan == JsonArrayScan::Ok)
                                 && recordsMalformed == 0 && recordsBadSyntax == 0
                                 && endfieldScan == JsonArrayScan::Ok && endfieldEntries == 1;

                        // 非抽卡事件的往返读取, 同样按结构路径 —— 取【根对象本层】的
                        // non_pull_events。旧版文件没有这个键 = 0 条, 属正常情况, 不能影响
                        // loaded (那是"文件是否可用"的判据, 只看抽卡数组)。但"键在那儿
                        // 而读不出来"必须中止: 那是这一段坏了, 不是不存在。
                        //
                        // 包装对象的形状是 { "id", "gacha_ts", "raw": {服务器原始对象} }。
                        // 三个字段一律【按本层键】读取: raw 里是服务器原样透传的对象, 里面
                        // 完全可能出现同名的 id / gacha_ts, 而 raw 自身的值也未必真是对象
                        // (文件被别的工具改过、或人工编辑坏了)。用全文找首个匹配的老办法,
                        // 上述任一情况都会读到别的东西, 然后当成好数据落盘。
                        const JsonValueRef evtV = FindTopLevelValue2(bv, "non_pull_events");
                        JsonArrayScan eventsScan = JsonArrayScan::NotFound;
                        if(evtV.malformed){
                            eventsScan = JsonArrayScan::Malformed;      // 根对象读不下去
                        } else if(evtV.kind == JsonValueKind::Array){
                            eventsScan = ForEachObjectInArray2(evtV.text, [&](std::string_view evtStr){
                                NonPullEvent ev;
                                // id: 必须有, 必须是字符串或数字, 且整串都是一个完整的整数。
                                const JsonValueRef idV = FindTopLevelValue2(evtStr, "id");
                                if((idV.kind != JsonValueKind::String && idV.kind != JsonValueKind::Number) ||
                                   !ParseFullInt64(idV.text, ev.safe_id)){ ++eventsMalformed; return; }
                                // gacha_ts: 允许缺失 (老写法留下的条目), 但写了就必须能解析。
                                const JsonValueRef tsV = FindTopLevelValue2(evtStr, "gacha_ts");
                                if(tsV.kind == JsonValueKind::String || tsV.kind == JsonValueKind::Number){
                                    if(!ParseFullInt64(tsV.text, ev.timestamp)){ ++eventsMalformed; return; }
                                } else if(tsV.kind != JsonValueKind::None){
                                    ++eventsMalformed; return;
                                }
                                // raw: 必须是对象, 原样留存 (含大括号)。取不出 = 该条目结构异常,
                                // 不能悄悄跳过 —— 跳过之后写盘就等于把它删了。计数, 由下面统一
                                // 升级为"中止, 不写盘"。
                                const JsonValueRef rawV = FindTopLevelValue2(evtStr, "raw");
                                if(rawV.kind != JsonValueKind::Object){ ++eventsMalformed; return; }
                                // v0.1.4.2: raw 会被逐字节原样写回存档, 所以"是个对象"这一层括号级
                                //   校验不够 —— {"a":} / {"a" 1,,,"b"::2} 都能通过括号配对, 写出去
                                //   就是一份非法 JSON 存档: 本工具自己的扫描器还能一轮轮读回来再写
                                //   出去, 而 NSJSONSerialization 和任何第三方 UIGF 工具都解析不了。
                                //   这里做一次完整语法校验, 不过就计入 eventsMalformed 走中止分支。
                                if(!efjson::IsStrictJsonValue(rawV.text)){ ++eventsMalformed; return; }
                                ev.raw = rawV.text;
                                m.events->push_back(ev);
                                m.localIds->insert(ev.safe_id);
                            });
                        } else if(evtV.kind != JsonValueKind::None &&
                                  evtV.kind != JsonValueKind::Null){
                            eventsScan = JsonArrayScan::Malformed;      // 键在, 但值不是数组
                        }
                        // NotFound = 旧格式文件 (或显式 null), 正常继续 (0 条事件)。
                        // Malformed (值不是数组 / 数组被截断 / 元素不是对象) 或有条目解析
                        // 不了 = 存档受损, 必须中止。
                        eventsBadShape = (eventsScan == JsonArrayScan::Malformed);
                        if(eventsBadShape || (eventsScan == JsonArrayScan::Ok && eventsMalformed > 0))
                            eventsCorrupt = true;
                    }
                }
            }
            if(loaded){
                std::string msg = "成功加载基底文件，包含 " + std::to_string(m.records->size()) + " 条已有记录";
                if(!m.events->empty())
                    msg += " 与 " + std::to_string(m.events->size()) + " 条非抽卡事件";
                [logs addObject:NSStr(msg)];
                if(m.migratedLegacy > 0){
                    [logs addObject:NSStr("已把 " + std::to_string(m.migratedLegacy) +
                                          " 条误存在抽卡数组里的非抽卡事件迁移到 non_pull_events")];
                }
            } else {
                // 用户【已明确提供】基底文件却读不出来 → 致命错误: 取消本次拉取, 绝不用全新文件覆盖原历史。
                // v0.1.3.3 (A2): 判定范围扩展 —— open / fstat / mmap 失败、0 字节、以及
                // 找不到记录数组结构 (异类/截断/损坏文件) 均归此类; 数组存在但为空属
                // 结构正确的空数据, 不在此列 (0 条正常继续)。
                // v0.1.4.1: 判据收紧为"按结构路径 endfield[0].list 完整读完":
                //   键缺失、类型不对、中途被截断、数组里混进非对象元素, 全部算读不出来。
                //   此前只要全文能定位到 "list" 就算成功, 被截断的文件里"读到的那部分"
                //   会被当成完整历史写回去, 把尾巴永久抹掉。
                _state = FetchState::Failed;
                // 分因说明: 多账号存档与"记录读不出来"是两种完全不同的处置, 混成一句
                // 用户没法判断该怎么办。
                std::string why;
                if(endfieldScan == JsonArrayScan::Malformed){
                    why = "基底文件的 endfield 数组结构异常 (未闭合、含非对象元素, 或元素之间缺少"
                          "分隔逗号)。这类文件很可能是多账号合并的产物, 只读出其中一部分再覆盖"
                          "写盘会把其余账号的历史永久删除 (接口只保留最近 90 天), 故已中止。";
                } else if(endfieldEntries > 1){
                    why = "基底文件的 endfield 数组有 " + std::to_string(endfieldEntries) +
                          " 个元素 (多账号 UIGF 存档)。本工具只支持单账号: 继续写盘会把除第一个"
                          "账号之外的全部历史永久删除 (接口只保留最近 90 天), 故已中止。"
                          "请先把该文件按 UID 拆开, 再分别作为基底使用。";
                } else if(endfieldScan == JsonArrayScan::NotFound){
                    why = "基底文件里没有可用的 endfield 数组 (键缺失, 或值不是数组)。"
                          "本工具只认 UIGF v4.2 的 endfield[0].list 结构。";
                } else if(recordsBadSyntax > 0 || recordsMalformed > 0){
                    why = "基底文件里有读不出来的记录: ";
                    if(recordsBadSyntax > 0){
                        why += std::to_string(recordsBadSyntax) +
                               " 条记录本身不是合法的 JSON 对象 (例如缺少分隔逗号、尾逗号、"
                               "非法转义或裸控制字符)";
                    }
                    if(recordsBadSyntax > 0 && recordsMalformed > 0) why += "; ";
                    if(recordsMalformed > 0){
                        why += std::to_string(recordsMalformed) +
                               " 条记录的 id / gacha_ts 缺失、类型不对, 或不是一个完整的整数";
                    }
                    why += "。id 同时是去重键, 读错会导致历史被重复追加并被以 \"0\" 回写覆盖, 故已中止。";
                } else {
                    why = "基底文件无法读取、为空, 或结构不是 UIGF v4.2 的 endfield[0].list 数组 "
                          "(键缺失、类型不对、被截断、含非对象元素或缺少分隔逗号)。";
                }
                why += " 已取消本次拉取, 原文件不会被覆盖。";
                [logs addObject:NSStr("❌ " + why)];
                r.ok = NO;
                r.errorMessage = NSStr(why);
                r.logs = logs;
                return r;
            }

            // v0.1.4.1: 事件区受损与 list 受损同等对待 —— 都中止, 都不写盘。
            //   "读不懂就当没有"在这里是危险的默认: 抽卡记录接口只保留最近 90 天, 本地文件
            //   是这些事件的唯一副本, 一旦按"读到的部分"覆盖回去, 读不出来的那些就永久没了。
            //   宁可让用户看到报错去处理, 也不要静默地少写一段。
            if(eventsCorrupt){
                _state = FetchState::Failed;
                std::string detail = "基底文件的 \"non_pull_events\" 段已损坏";
                if(eventsBadShape)
                    detail += ": 该键的值不是一个正常闭合的对象数组 (被截断、写成了别的类型, 或混进了非对象元素)";
                if(eventsMalformed > 0)
                    detail += "; 有 " + std::to_string(eventsMalformed) +
                              " 条事件的 id / gacha_ts / raw 字段缺失或类型不对而无法解析";
                detail += "。这些事件在本地文件之外没有副本 (接口只保留最近 90 天), 照常写盘会把"
                          "读不出来的那部分永久删除, 已取消本次拉取, 原文件不会被覆盖。";
                [logs addObject:NSStr("❌ " + detail)];
                r.ok = NO;
                r.errorMessage = NSStr(detail);
                r.logs = logs;
                return r;
            }
        } else {
            [logs addObject:@"未提供基底文件, 将作为全新文件拉取"];
        }

        _state = FetchState::ReadyForRequest;
        r.ok = YES;
        r.baseRecordCount = (NSInteger)m.records->size();
        r.logs = logs;
        return r;

    } catch (const std::bad_alloc&) {
        _state = FetchState::Failed;
        r.ok = NO; r.errorMessage = @"内存不足 (基底文件过大?)"; r.logs = logs; return r;
    } catch (const std::exception& e) {
        _state = FetchState::Failed;
        r.ok = NO; r.errorMessage = [NSString stringWithFormat:@"prepare 异常: %s", e.what()]; r.logs = logs; return r;
    } catch (...) {
        _state = FetchState::Failed;
        r.ok = NO; r.errorMessage = @"prepare 未知异常"; r.logs = logs; return r;
    }
}

// ---- nextRequest: ReadyForRequest → AwaitingResponse(.ready) | Done(.done) | Failed(.fatal) ----
- (FetchNextRequestResult *)nextRequest {
    FetchNextRequestResult *r = [FetchNextRequestResult new];
    if (_state != FetchState::ReadyForRequest || !_impl) {
        r.status = FetchNextRequestFatalError;
        r.errorMessage = @"nextRequest 在非法状态调用 (未 prepare / 上次未 ingest / 已完成)";
        _state = FetchState::Failed;
        return r;
    }

    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    try {
        FetchSessionImpl& m = *_impl;

        // 所有池耗尽 → Done。
        if (m.poolIdx >= m.pools.size()) {
            [logs addObject:NSStr("总计新增拉取 " + std::to_string(m.sessionIds->size()) + " 条记录")];
            _state = FetchState::Done;
            r.status = FetchNextRequestDone;
            r.logs = logs;
            return r;
        }

        const PoolCfg& pc = m.pools[m.poolIdx];

        // 新池 (page==1) 的"正在抓取 […]"。
        if (m.page == 1) {
            [logs addObject:NSStr("正在抓取 [" + pc.displayName + "] ...")];
        }

        // 构造 curUrl (weapon vs char?pool_type=; page>1&&cursor>0 追加 &seq_id=)。
        char sbuf[32];
        std::string curUrl = "https://" + m.hostName + (pc.isWeapon
            ? "/api/record/weapon?lang=zh-cn&token=" + m.token + "&server_id=" + m.serverId
            : "/api/record/char?lang=zh-cn&pool_type=" + pc.poolType
                + "&token=" + m.token + "&server_id=" + m.serverId);
        if(m.page>1 && m.cursor>0){
            auto [p, e] = std::to_chars(sbuf, sbuf+32, m.cursor);
            curUrl += "&seq_id=";
            curUrl.append(sbuf, (size_t)(p-sbuf));
        }

        _state = FetchState::AwaitingResponse;
        r.status = FetchNextRequestReady;
        r.urlString = NSStr(curUrl);
        r.logs = logs;
        return r;

    } catch (const std::exception& e) {
        _state = FetchState::Failed;
        r.status = FetchNextRequestFatalError;
        r.errorMessage = [NSString stringWithFormat:@"nextRequest 异常: %s", e.what()];
        r.logs = logs;
        return r;
    } catch (...) {
        _state = FetchState::Failed;
        r.status = FetchNextRequestFatalError;
        r.errorMessage = @"nextRequest 未知异常";
        r.logs = logs;
        return r;
    }
}

// ---- ingestResponseData: AwaitingResponse → ReadyForRequest | Failed(.fatal) ----
- (FetchPageOutcome *)ingestResponseData:(NSData *)data {
    FetchPageOutcome *o = [FetchPageOutcome new];
    if (_state != FetchState::AwaitingResponse || !_impl) {
        o.status = FetchIngestFatalError;
        o.fatalErrorMessage = @"ingest 在非法状态调用 (未请求 / 重复 ingest)";
        _state = FetchState::Failed;
        return o;
    }

    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    try {
        FetchSessionImpl& m = *_impl;
        const PoolCfg& pc = m.pools[m.poolIdx];

        // ---- 异常的统一处置 (v0.1.4.2) ----
        //   m.cnt > 0: 本池已经吃进了新记录 (可能就是本页前半段吃进的)。此时无论什么原因停下,
        //     写出的文件都会是
        //     "上面有新记录、中间缺一段、下面是老记录" —— 下次增量拉取在最新记录处即触达老记录
        //     而停, 缺口永远补不回来, 而接口只保留最近 90 天。所以一律 Fatal, 不写盘。
        //   m.cnt == 0 且该池标了 optional: 跳过本池、继续其余池, 并把池名记进 skippedPools
        //     由摘要点名 (不静默)。这是为"服务端还不认识某个新池型"准备的 —— 见 PoolCfg::optional。
        //   m.cnt == 0 且必需池: 池级错误。协调器会据此整次中止 (保护已有数据)。
        //
        //   ★ m.cnt 必须【在失败点现场求值】, 不能在方法入口拍快照: 记录数组的回调会边扫边
        //     ++m.cnt, 而 pageScan/seqAnomaly 这两道闸门恰恰是在扫完之后才判的。用快照的话,
        //     "本池第一页吃进了前 N 条、数组在后面才坏"会被当成"本池尚无部分状态"而跳池,
        //     那 N 条随后照常落盘 —— 正是这套闸门要堵的缺口。
        auto problem = [&](const std::string& why) -> FetchPageOutcome * {
            if (m.cnt > 0) {
                _state = FetchState::Failed;
                o.status = FetchIngestFatalError;
                o.fatalErrorMessage = NSStr(why + " (翻页中途: 为避免记录缺口, 本次不写盘)");
                o.newThisPage = 0;
                o.logs = logs;
                return o;
            }
            const bool skip = pc.optional;
            if (skip) {
                m.skippedPools.push_back(pc.displayName);
                [logs addObject:NSStr(">>> [" + pc.displayName + "] 已跳过 (" + why +
                                      ")。该池型可能在本区服/服务端版本上尚未上线, 不影响其余卡池。")];
            }
            m.AdvancePool();
            _state = FetchState::ReadyForRequest;
            o.status = skip ? FetchIngestPoolSkipped : FetchIngestPoolError;
            if (!skip) o.poolErrorMessage = NSStr(why);
            o.totalNewSoFar = (NSInteger)m.sessionIds->size();
            o.delayMsBeforeNext = DelayAfterAdvancingPool(m);
            o.logs = logs;
            return o;
        };

        // D.2: 0 长度 / null 不能 emplace (避免 string_view 构造越界)。
        if (data.length == 0 || data.bytes == nullptr) return problem("接口返回空响应");

        m.payloads.emplace_back(static_cast<const char*>(data.bytes), (size_t)data.length);
        std::string_view rv(m.payloads.back());   // D.1: 重绑
        // 少数网关会给 JSON 加 UTF-8 BOM。下面的完整性闸门要求正文以 '{' 开头, 先剥掉。
        if (rv.size() >= 3 && (uint8_t)rv[0]==0xEF && (uint8_t)rv[1]==0xBB && (uint8_t)rv[2]==0xBF)
            rv.remove_prefix(3);

        // ==========================================================
        // 闸门 1 (v0.1.4.2): 整段正文必须是一个【完整闭合】的 JSON 对象, 后面只剩空白。
        //
        // 这一条是修复"半截正文被当成正常结束"的关键。此前只校验"找到的 list 数组是否异常",
        // 于是两种截断都能一路走到正常收尾:
        //   正文在 list 之前断掉  -> 找不到 list -> NotFound -> 按空页处理 -> 本池正常结束
        //   list 完整但 hasMore 之后断掉 -> 数组 Ok, hasMore 读不到 -> 当 false -> 本池正常结束
        // 两者在已吃进新记录时都会留下永久缺口。括号/引号配对对"被截断"这一类是可靠判据。
        // (注意: 这组 helper 是局部扫描器而非完整 JSON 校验器 —— 见 JsonScan.h 的能力边界。
        //  真正需要逐字回写的片段另走 efjson::IsStrictJsonValue。)
        //
        // 信封的解析整段在 InspectPageEnvelope 里 (同一份实现也被 Tests/ 直接调用)。
        // ==========================================================
        const PageEnvelope env = InspectPageEnvelope(rv);
        if (!env.complete)
            return problem("接口返回的正文不是一个完整的 JSON 对象 (多半是传输被截断)");
        if (!env.codeFound) return problem("响应非预期 JSON 结构 (无 code 字段)");
        if (env.code != "0")
            return problem(std::string("接口业务错误: ").append(env.msg));

        const LocateResult listStatus   = env.listStatus;
        const std::string_view listText = env.listText;
        const bool hasMoreKnown = env.hasMoreKnown;
        const bool hasMoreValue = env.hasMoreValue;
        const bool hasMoreBad   = env.hasMoreBad;

        // ---- 解析 list ----
        long long lastSeq = 0;
        int newThisPage = 0;
        int itemsSeen = 0;
        bool seqAnomaly = false;
        JsonArrayScan pageScan = JsonArrayScan::NotFound;
        if (listStatus == LocateResult::Malformed) {
            pageScan = JsonArrayScan::Malformed;
        } else if (listStatus == LocateResult::Located) {
        pageScan = ForEachObjectInArray2(listText, [&](std::string_view item){
            if(m.reached) return;
            ++itemsSeen;
            // seqId 是【唯一】的去重键兼翻页游标。v0.1.4.2 前用 isStr=true 读 + 裸 from_chars:
            //   数字形态的 seqId 被判空、"12ab" 被吃成 12、解析失败一律静默变 0。
            //   而一旦本地历史里也存在一个 id 0 (基底 id 读不出来时就会), contains(0) 立刻
            //   命中 → 假"触达本地老记录" → 本池就地判完成, 更早的记录再也不拉, 日志却完全正常。
            //   现在读不出来就标异常, 由下面按缺口风险升级, 绝不当成 0。
            long long seq = 0;
            bool seqPresent = false;
            if(!ReadIntegerField(item, "seqId", seq, seqPresent) || seq == 0){
                seqAnomaly = true;
                return;
            }
            lastSeq = seq;
            // v0.1.3.3: 取反改无符号形式, 规避 seq==LLONG_MIN 的有符号溢出 UB (服务器正
            // 序列号实际不可达, 零成本加固, 与分析器 abs_ll 口径对齐)。
            long long sid = pc.isWeapon ? (long long)(0ULL - (unsigned long long)seq) : seq;

            // 去重与防缺口的判定【对抽卡和非抽卡事件一视同仁】(v0.1.4.1):
            //   两者共用同一套 seqId 序列, 都要能触发"触达本地老记录"的停止条件,
            //   否则事件行会被反复重新拉取。分类放在这些检查【之后】。
            if(m.localIds->contains(sid)){
                m.reached = true;
                [logs addObject:NSStr("  * 触达本地老记录 (ID: " + std::to_string(seq) + ")")];
                return;
            }
            if(m.sessionIds->contains(sid)){
                [logs addObject:NSStr("  [警告] 重复数据 (ID: " + std::to_string(seq) + ")")];
                m.hasMore = false;
                m.dupAnomaly = true;   // v0.1.3.3: 游标异常, 在本页解析结束后升级 Fatal
                return;
            }
            m.sessionIds->insert(sid);

            long long pts = 0;
            {
                bool tsPresent = false;
                (void)ReadIntegerField(item, "gachaTs", pts, tsPresent);   // 缺失/读不出 → 0, 与旧版一致
            }

            // ---- 抽卡 / 非抽卡事件 的分流 ----
            // v0.1.4.2 修正判据方向: 旧写法是 "kind 缺失或 == draw" AND "itemId 与 rarity 都在",
            //   三个条件是 AND, 于是注释里号称的"保险"根本兜不住 —— 官方哪天把 kind 从 "draw"
            //   改成别的字符串, 【所有真实抽卡】都会被整体判成事件, 抽卡数组直接清空。
            //   现在由物理判据拿最终决定权: 有物品 id 且有稀有度 ⇒ 是一次抽卡; 两者缺一 ⇒ 事件。
            //   kind 降级为辅助信号: 只在"物品字段俱全但 kind 不是 draw"时打一条提示日志,
            //   让新出现的 kind 能被发现, 而不是靠它来分类。
            const std::string_view kindStr   = ExtractJsonValue2(item, "kind",   true);
            const std::string_view rarityStr = ExtractJsonValue2(item, "rarity", false);
            const std::string_view itemIdStr = pc.isWeapon
                ? ExtractJsonValue2(item, "weaponId", true)
                : ExtractJsonValue2(item, "charId",   true);
            const bool looksLikePull = !itemIdStr.empty() && !rarityStr.empty();

            if(!looksLikePull){
                NonPullEvent ev;
                ev.safe_id   = sid;
                ev.timestamp = pts;
                ev.raw       = item;             // 原样保留整个服务器对象
                m.events->push_back(ev);
                ++m.cnt; ++newThisPage; ++m.newEvents;   // 计入本池已吃进的条数 (缺口保护同样适用)
                const std::string_view label = ExtractJsonValue2(item, "nameText", true);
                std::string elog;
                elog.reserve(40 + label.size() + kindStr.size());
                elog.append("  获取到(非抽卡事件): ").append(label)
                    .append(" [kind=").append(kindStr).append("]");
                [logs addObject:NSStr(elog)];
                return;
            }
            if(!kindStr.empty() && kindStr != "draw"){
                // 物品字段俱全, 按抽卡处理; 但记下这个没见过的 kind, 便于将来核对。
                [logs addObject:NSStr(std::string("  [提示] 未见过的 kind=")
                                          .append(kindStr).append(", 按抽卡记录处理")) ];
            }

            ExportRecord rec;
            rec.safe_id   = sid;
            rec.timestamp = pts;
            rec.poolId    = ExtractJsonValue2(item, "poolId",    true);
            rec.rank_type = rarityStr;
            rec.poolName  = ExtractJsonValue2(item, "poolName",  true);
            rec.isNew  = (uint8_t)(ExtractJsonValue2(item, "isNew",  false)=="true" ? 1 : 0);
            rec.isFree = (uint8_t)(ExtractJsonValue2(item, "isFree", false)=="true" ? 1 : 0);

            if(pc.isWeapon){
                rec.item_id    = itemIdStr;
                rec.name       = ExtractJsonValue2(item, "weaponName", true);
                rec.item_type  = FItemType::Weapon;
                rec.weaponType = ExtractJsonValue2(item, "weaponType", true);
            } else {
                rec.item_id    = itemIdStr;
                rec.name       = ExtractJsonValue2(item, "charName", true);
                rec.item_type  = FItemType::Character;
            }

            m.records->push_back(std::move(rec));
            ++m.cnt; ++newThisPage; ++m.newPulls;
            // name/rank_type 仍指向 payloads, 直接构造日志
            const ExportRecord& back = m.records->back();
            std::string log;
            log.reserve(32 + back.name.size() + back.rank_type.size());
            log.append("  获取到: ").append(back.name).append(" (").append(back.rank_type).append(" 星)");
            [logs addObject:NSStr(log)];
        });
        }

        // v0.1.3.3: 同会话重复 seqId = 分页游标异常 (服务器返回未推进)。已吃进的部分记录
        // 与重复点以下未拉取的历史之间存在缺口 → 升级 Fatal (不写盘), 不再当自然结束。
        if (m.dupAnomaly) {
            _state = FetchState::Failed;
            o.status = FetchIngestFatalError;
            o.fatalErrorMessage = @"分页游标异常 (重复数据): 为避免记录缺口, 本次不写盘";
            o.newThisPage = newThisPage;
            o.logs = logs;
            return o;
        }

        // ---- 结构异常的四道闸门 (v0.1.4.2) ----
        // 顺序要紧: 扫描一遇到非法元素就立刻返回, 后面的对象不会再回调, 所以 m.reached 为真
        // 必然发生在出错点【之前】—— 边界已经找到, 这一页尾巴坏不坏都不影响完整性, 走正常收尾。
        // seqAnomaly 放在 m.reached 判定【之外】: 回调开头就有 if(m.reached) return;, 所以任何
        // 被标记的异常记录一定是在触达本地老记录【之前】扫到的 —— 它比本地边界新, 却既没进
        // records/events 也没报错。若放行, 下次增量拉取在最新记录处即停, 这一条永远补不回来。
        if (seqAnomaly)
            return problem("接口返回的记录缺少可用的 seqId (缺失, 或不是一个完整的整数)");

        if (!m.reached) {
            if (pageScan == JsonArrayScan::Malformed)
                return problem("接口返回的记录数组结构异常 (未闭合、含非对象元素或缺少分隔逗号)");
            // 下面几条只在"本池已有部分记录"时才算异常: 本池第一页就"没有记录数组 / 空页"
            // 是空池的正常形态。同样现场求值 m.cnt。
            if (m.cnt > 0 && listStatus == LocateResult::NotFound)
                return problem("翻页中途返回的这一页里没有记录数组");
            if (m.cnt > 0 && hasMoreBad)
                return problem("接口返回的 hasMore 字段类型异常 (既不是布尔也不是 true/false 字符串)");
            // hasMore 是翻页的唯一依据。读不到它却按"没有更多"收尾, 与 P1 描述的失败模式完全
            // 同类 —— 本池在此静默截断, 更早的记录再也不拉。现行接口一直有这个字段 (结构路径
            // 读不到时下面还会全文兜一次), 所以这条在正常情况下不会触发; 真触发了说明接口变了,
            // 明确报错远好过悄悄少写一段。
            if (m.cnt > 0 && itemsSeen > 0 && !hasMoreKnown)
                return problem("接口返回的这一页里读不到 hasMore, 无法判断是否还有更早的记录");
            if (m.cnt > 0 && itemsSeen == 0 && hasMoreKnown && hasMoreValue)
                return problem("接口称仍有更早的记录, 却返回了空页");
        }

        // ---- 是否本池结束 ----
        // reached / hasMore=false(本页重复) / itemsSeen==0(空页, 含 list:[]) → 本池结束。
        //   itemsSeen==0 既覆盖"结构正确但 list:[]"的正常无新数据, 也避免 hasMore:true+空页时的
        //   死循环; midPool 下的"空页 + hasMore=true"已在上面被升级为异常, 不会走到这里。
        // 否则推进 cursor/page, 再看接口 hasMore: 若为 false 同样结束。
        bool poolDone;
        if (m.reached || !m.hasMore || itemsSeen == 0) {
            poolDone = true;
        } else {
            // v0.1.4.2: 游标必须【严格前进】。服务端按 seqId 倒序返回, 下一页的游标 = 本页最后
            //   一条 (最小的那个 seqId)。若它没变或反而变大, 下一次请求就是同一个 URL → 同一份
            //   响应 → 以 300ms 间隔无限重复。旧代码毫无保护: lastSeq 为 0 时连 &seq_id= 都不会
            //   追加, 直接反复请求第 1 页, UI 永远停在"正在抓取"。
            if (lastSeq <= 0 || (m.page > 1 && m.cursor > 0 && lastSeq >= m.cursor))
                return problem("分页游标没有前进 (服务端重复返回了同一页)");
            m.cursor = lastSeq;
            m.hasMore = hasMoreValue;
            m.page++;
            poolDone = !m.hasMore;
        }

        o.newThisPage = newThisPage;
        if (poolDone) {
            [logs addObject:NSStr(">>> [" + pc.displayName + "] 完成,新增: " + std::to_string(m.cnt) + " 条")];
            m.AdvancePool();
            o.delayMsBeforeNext = DelayAfterAdvancingPool(m);   // 500 仍有后续池 / 0 末池
        } else {
            o.delayMsBeforeNext = 300;                          // 同池下一页
        }
        _state = FetchState::ReadyForRequest;
        o.status = FetchIngestContinue;
        o.totalNewSoFar = (NSInteger)m.sessionIds->size();
        o.logs = logs;
        return o;

    } catch (const std::bad_alloc&) {
        _state = FetchState::Failed;
        o.status = FetchIngestFatalError;
        o.fatalErrorMessage = @"内存不足 (记录过多?)";
        o.logs = logs;
        return o;
    } catch (const std::exception& e) {
        _state = FetchState::Failed;
        o.status = FetchIngestFatalError;
        o.fatalErrorMessage = [NSString stringWithFormat:@"ingest 异常: %s", e.what()];
        o.logs = logs;
        return o;
    } catch (...) {
        _state = FetchState::Failed;
        o.status = FetchIngestFatalError;
        o.fatalErrorMessage = @"ingest 未知异常";
        o.logs = logs;
        return o;
    }
}

// ---- writeExport: Done → Exported (失败→Failed) ----
- (FetchExportSummary *)writeExport {
    FetchExportSummary *s = [FetchExportSummary new];
    if (_state != FetchState::Done || !_impl) {
        s.ok = NO; s.errorMessage = @"writeExport 在非法状态调用"; return s;
    }

    try {
        FetchSessionImpl& m = *_impl;
        auto& records = *m.records;

        // ---- 排序 (与 main.cpp 一致): 角色(id 正)在前/武器(id 负)在后 → 时间升序 → |id| 升序 ----
        // 防御 LLONG_MIN: 无符号求绝对值规避有符号溢出 UB。
        auto abs_ll = [](long long v) -> unsigned long long {
            return v < 0 ? (0ULL - static_cast<unsigned long long>(v))
                         : static_cast<unsigned long long>(v);
        };
        std::ranges::sort(records, [&](const ExportRecord& a, const ExportRecord& b){
            bool wa = a.safe_id<0, wb = b.safe_id<0;
            if(wa!=wb) return wa<wb;
            if(a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
            return abs_ll(a.safe_id) < abs_ll(b.safe_id);
        });

        // ---- 写出到临时 JSON 文件 ----
        time_t rawtime; time(&rawtime);
        long long exp_ts = (long long)rawtime;

        NSString* tempNS = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        tempNS = [tempNS stringByAppendingPathExtension:@"json"];
        std::string tmpFile = tempNS.UTF8String;

        ScopedFd out(::open(tmpFile.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0644));
        if(!out){
            _state = FetchState::Failed;
            s.ok = NO; s.errorMessage = @"临时文件创建失败"; return s;
        }
        // RAII: 未提交 (写失败 / 抛异常 / 提前 return) 时自动删除半截临时文件。
        // committed=true 仅在写盘完整成功后设置, 之后保留 tmp 供协调器落地。
        bool committed = false;
        ScopeExit removeTmp([&]{ if(!committed) ::unlink(tmpFile.c_str()); });

        // #5: 平台与版本元数据 —— export_app 按平台给 (iOS)/(macOS);
        //      版本取 Info.plist 的 CFBundleShortVersionString。
#if TARGET_OS_IOS
        std::string_view platTag = "(iOS)";
#else
        std::string_view platTag = "(macOS)";
#endif
        NSString* verNS = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        std::string verStr = (verNS.UTF8String) ? verNS.UTF8String : "0.0.0";

        bool writeOk = false;   // 写出是否全部成功; 失败则不替换原文件
        {
            BufferedWriter w(out.get());   // BufferedWriter 在本块析构(flush)时 out 仍开着
            char nb[32];

            // ==========================================================
            // UIGF v4.2 输出 (文档: https://uigf.org/standards/UIGF.html)
            // 终末地用 "endfield" 作为自定义游戏容器 (v4.2 顶层 properties 允许新增 key)。
            //   { "info": { ... },
            //     "endfield": [ { uid, timezone, lang, list:[...] } ],
            //     "non_pull_events": [ ... ]   // v0.1.4.1 新增, 仅在非空时出现
            //   }
            //
            // "non_pull_events" 是本工具的扩展键, 不属于 UIGF 标准, 也【不应】被当作抽卡
            // 记录读取。UIGF 标准本身没有规定非抽卡事件该放哪里 (它只定义抽卡记录的
            // schema), 这里选择独立键而非塞进 list, 是为了让 list 对所有第三方 UIGF
            // 工具保持"每一条都是一次抽卡"的语义。详见 NonPullEvent 的说明。
            // (例外: non_pull_events[].raw 里是服务器原始对象, 保持其原有的 camelCase,
            //  因为那一段是原样透传, 不做任何改写。)
            // ==========================================================
            // 与 WriteTimeKV 同口径: 零初始化 + 检查返回值, 不在未初始化的 struct tm 上取字段。
            time_t t = exp_ts;
            struct tm tmv{};
            const bool tmOk = (localtime_r(&t, &tmv) != nullptr);
            char tbuf[64];
            int tl = 0;
            if (tmOk) {
                tl = snprintf(tbuf, sizeof(tbuf), "%04d-%02d-%02d %02d:%02d:%02d",
                              tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                              tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
            }
            if (tl < 0) tl = 0;

            // ---- info 块 ----
            w.WriteLit("{\n    \"info\": {\n");
            w.WriteLit("        \"export_timestamp\": ");
            { auto [p, e] = std::to_chars(nb, nb+32, exp_ts); w.Write(nb, (size_t)(p-nb)); }
            w.WriteLit(",\n");
            // export_app / export_app_version 现按平台 + bundle 版本动态生成 (#5)。
            w.WriteLit("        \"export_app\": \"Endfield Gacha ");
            w.Write(platTag);
            w.WriteLit("\",\n");
            w.WriteLit("        \"export_app_version\": \"v");
            w.WriteEscaped(verStr);
            w.WriteLit("\",\n");
            w.WriteLit("        \"version\": \"v4.2\",\n");
            // export_time 非 v4.2 必需, 保留作人类可读辅助。
            w.WriteLit("        \"export_time\": \"");
            w.Write(tbuf, (size_t)tl);
            w.WriteLit("\"\n    },\n");

            // ---- endfield 数组 (单账号 → 单元素) ----
            const int tzHours = tmOk ? (int)(tmv.tm_gmtoff / 3600) : 0;
            w.WriteLit("    \"endfield\": [\n        {\n");
            w.WriteLit("            \"uid\": \"0\",\n");
            w.WriteLit("            \"timezone\": ");
            { auto [p, e] = std::to_chars(nb, nb+32, tzHours); w.Write(nb, (size_t)(p-nb)); }
            w.WriteLit(",\n");
            w.WriteLit("            \"lang\": \"zh-cn\",\n");
            w.WriteLit("            \"list\": [\n");

            const size_t n = records.size();
            for(size_t i=0; i<n; ++i){
                const auto& r = records[i];
                w.WriteLit("        {\n");
                w.WriteKV("gacha_type", r.poolId);          w.WriteLit(",\n");
                w.WriteI64KV("id", r.safe_id, true);        w.WriteLit(",\n");
                w.WriteKV("item_id", r.item_id);            w.WriteLit(",\n");
                w.WriteKV("item_name", r.name);             w.WriteLit(",\n");
                w.WriteKV("item_type", ItemTypeToStr(r.item_type)); w.WriteLit(",\n");
                w.WriteKV("rank_type", r.rank_type);        w.WriteLit(",\n");
                w.WriteTimeKV("time", r.timestamp);         w.WriteLit(",\n");
                w.WriteI64KV("gacha_ts", r.timestamp, true); w.WriteLit(",\n");
                if(!r.poolName.empty())   { w.WriteKV("pool_name",   r.poolName);   w.WriteLit(",\n"); }
                if(!r.weaponType.empty()) { w.WriteKV("weapon_type", r.weaponType); w.WriteLit(",\n"); }
                w.WriteLit("            \"is_new\": ");
                w.Write(r.isNew ? "true" : "false");
                w.WriteLit(",\n");
                w.WriteLit("            \"is_free\": ");
                w.Write(r.isFree ? "true" : "false");
                w.WriteLit("\n");
                w.WriteLit("        }");
                if(i < n-1) w.WriteLit(",");
                w.WriteLit("\n");
            }
            // ---- 非抽卡事件 (v0.1.4.1) ----
            // 放在 "endfield" 之后的顶层键。有意【不】混进 list:
            //   list 是 UIGF 定义的抽卡记录数组, 任何读这个文件的第三方工具都会按抽卡来数;
            //   而这些行不是抽卡, 混进去会让不做过滤的工具把保底水位每期多算 1 抽。
            //   放在独立键里, list 对所有 UIGF 工具保持干净, 信息也一条不丢。
            // 每个元素是 { "id", "gacha_ts", "raw" }: 前两个是本工具自用的检索字段
            // (写在前面, 保证全文找键的首个匹配一定命中它们), raw 是服务器原始对象,
            // 原样透传 —— 将来出现新的 kind 也不会因为字段没被识别而丢失。
            // 位置: endfield 写在前面。v0.1.4.2 起分析端 (AnalyzerWrapper) 也改走
            // 根.endfield[0].list 的结构路径了, 因此两端都不再依赖这个顺序 —— 保持 endfield
            // 在前只是为了对那些"全文找首个 list"的第三方工具友好。
            auto& events = *m.events;
            if(!events.empty()){
                std::ranges::sort(events, [&](const NonPullEvent& a, const NonPullEvent& b){
                    if(a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
                    return abs_ll(a.safe_id) < abs_ll(b.safe_id);
                });
                w.WriteLit("            ]\n        }\n    ],\n");
                w.WriteLit("    \"non_pull_events\": [\n");
                const size_t m2 = events.size();
                for(size_t i=0; i<m2; ++i){
                    const auto& ev = events[i];
                    w.WriteLit("        {\n");
                    w.WriteI64KV("id", ev.safe_id, true);         w.WriteLit(",\n");
                    w.WriteI64KV("gacha_ts", ev.timestamp, true); w.WriteLit(",\n");
                    w.WriteLit("            \"raw\": ");
                    w.Write(ev.raw);
                    w.WriteLit("\n        }");
                    if(i < m2-1) w.WriteLit(",");
                    w.WriteLit("\n");
                }
                w.WriteLit("    ]\n}\n");
            } else {
                w.WriteLit("            ]\n        }\n    ]\n}\n");
            }
            w.Flush();
            writeOk = w.ok;
        }   // BufferedWriter 在此 flush (out 仍开); fd 由 ScopedFd 在函数返回时关闭

        if (!writeOk) {
            // 写入中途失败 (磁盘满 / IO 错误): 不提交 → ScopeExit 删半截 tmp, ScopedFd 关 fd。
            _state = FetchState::Failed;
            s.ok = NO; s.errorMessage = @"写入失败 (磁盘空间不足或 IO 错误)";
            return s;
        }

        // ---- 落盘持久化 (v0.1.4.2) ----
        // write(2) 返回成功只说明字节进了页缓存。协调器随后会用 replaceItemAt 把这个临时文件
        // 换成用户的存档 —— 换的是目录项, 新 inode 的数据块未必已经落盘。若此时掉电/强杀,
        // 用户拿到的可能是 0 字节或半截文件, 而按本文件自己的说法这份文件是唯一副本
        // (接口只保留最近 90 天)。同样地, close() 的返回值必须检查: 延迟写回的文件系统
        // (iCloud / File Provider) 上, 真正的写入错误要到 close 才浮现, 吞掉它就会出现
        // "报告成功、原档已被替换、内容却是坏的"。
        // F_FULLFSYNC 是 Apple 平台上唯一能把数据真正刷到介质的请求; 它在某些文件系统上
        // 返回 ENOTSUP, 此时退回普通 fsync。
        if (::fcntl(out.get(), F_FULLFSYNC, 0) < 0 && ::fsync(out.get()) < 0) {
            _state = FetchState::Failed;
            s.ok = NO; s.errorMessage = @"写入失败 (数据未能落盘)";
            return s;   // committed 仍为 false → ScopeExit 删掉临时文件
        }
        {
            const int fd = out.fd;
            out.fd = -1;                       // 交出所有权, 避免 ScopedFd 二次 close
            if (fd >= 0 && ::close(fd) != 0) {
                _state = FetchState::Failed;
                s.ok = NO; s.errorMessage = @"写入失败 (关闭文件时报错, 内容可能不完整)";
                return s;
            }
        }

        committed = true;   // 写盘完整成功: 保留 tmp 供协调器落地 (ScopeExit 不再删)
        _state = FetchState::Exported;
        s.ok = YES;
        // 抽卡与事件分开报, 两个"新增/共计"各自同口径 (见 FetchExportSummary 的注释)。
        s.newCount            = (NSInteger)m.newPulls;
        s.totalCount          = (NSInteger)records.size();
        s.newEventCount       = (NSInteger)m.newEvents;
        s.totalEventCount     = (NSInteger)m.events->size();
        s.migratedLegacyCount = (NSInteger)m.migratedLegacy;
        {
            NSMutableArray<NSString *> *skipped = [NSMutableArray array];
            for (const auto& nameStr : m.skippedPools) [skipped addObject:NSStr(nameStr)];
            s.skippedPoolNames = skipped;
        }
        s.tempFilePath = tempNS;
        return s;

    } catch (const std::bad_alloc&) {
        _state = FetchState::Failed;
        s.ok = NO; s.errorMessage = @"内存不足 (排序/写出阶段)"; return s;
    } catch (const std::exception& e) {
        _state = FetchState::Failed;
        s.ok = NO; s.errorMessage = [NSString stringWithFormat:@"writeExport 异常: %s", e.what()]; return s;
    } catch (...) {
        _state = FetchState::Failed;
        s.ok = NO; s.errorMessage = @"writeExport 未知异常"; return s;
    }
}

@end
