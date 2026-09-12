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
//  JSON / URL 解析 (与 AnalyzerWrapper 同款; 整段从旧 worker 搬入)
// ============================================================
inline size_t FindJsonKey2(std::string_view src, std::string_view key, size_t pos=0){
    while(true){
        pos = src.find(key, pos);
        if(pos==std::string_view::npos) return pos;
        if(pos>0 && src[pos-1]=='"' && pos+key.size()<src.size() && src[pos+key.size()]=='"')
            return pos-1;
        pos += key.size();
    }
}
inline std::string_view ExtractJsonValue2(std::string_view src, std::string_view key, bool isStr){
    size_t pos = FindJsonKey2(src, key);
    if(pos==std::string_view::npos) return {};
    pos = src.find(':', pos+key.size()+2);
    if(pos==std::string_view::npos) return {};
    ++pos;
    while(pos<src.size() && (src[pos]==' '||src[pos]=='\t'||src[pos]=='\n'||src[pos]=='\r')) ++pos;
    if(isStr){
        if(pos>=src.size() || src[pos]!='"') return {};
        ++pos; size_t e=pos;
        while(e<src.size() && src[e]!='"'){ if(src[e]=='\\' && e+1<src.size()) e+=2; else ++e; }
        return e<src.size() ? src.substr(pos, e-pos) : std::string_view{};
    } else {
        size_t e=pos;
        while(e<src.size() && src[e]!=',' && src[e]!='}' && src[e]!=']' && src[e]!=' ' && src[e]!='\n' && src[e]!='\r') ++e;
        return src.substr(pos, e-pos);
    }
}
// ---- 顶层字段读取 (v0.1.5.0) ----
// FindJsonKey2 / ExtractJsonValue2 都是"全文找首个同名键"的粗放做法: 只要键名在别处
// 出现过 (哪怕是在嵌套对象里、或在别的字段的字符串值里), 就可能读串。对付服务器
// 返回的临时报文够用, 但读【自己写的存档】时不行 —— 读串一条就意味着写盘时把原始
// 数据换成了别的东西, 而抽卡接口只保留 90 天, 原件没有第二份。
// 下面这组函数只认【当前对象本层】的键, 并且把值的类型一并带出来, 供调用方校验。
enum class JsonValueKind : uint8_t { None = 0, String, Number, Object, Array, Bool, Null };

struct JsonValueRef {
    JsonValueKind kind = JsonValueKind::None;
    // 对象本身读不下去 (不是对象 / 键没闭合 / 少冒号 / 值解析不了)。必须与"没有这个键"
    // 分开: 前者是"这段坏了", 后者是"本来就没有", 在存档场景里一个要中止、一个要放行。
    bool malformed = false;
    std::string_view text;   // String: 去掉两端引号的原文(转义未还原); 其余: 值的原文
};

// 从 s[i] 处解析一个 JSON 值, 返回其结束位置(末字符的下一位); 结构不合法返回 npos。
// 括号用位栈严格配对 —— '[' 记 1、'{' 记 0, 闭合时比对, 交叉括号(如 {..])直接判非法。
inline size_t SkipJsonValue2(std::string_view s, size_t i, JsonValueKind& kind){
    const size_t n = s.size();
    while(i<n && (unsigned char)s[i] <= ' ') ++i;
    if(i>=n) return std::string_view::npos;
    const char c = s[i];
    if(c=='"'){
        for(size_t k=i+1; k<n; ++k){
            if(s[k]=='\\'){ ++k; continue; }
            if(s[k]=='"'){ kind = JsonValueKind::String; return k+1; }
        }
        return std::string_view::npos;          // 字符串没闭合
    }
    if(c=='{' || c=='['){
        uint64_t isArr = 0;                     // bit d: 第 d 层是 '[' 吗
        int depth = 0;
        for(size_t k=i; k<n; ++k){
            const char d = s[k];
            if(d=='"'){
                size_t q = k+1;
                for(; q<n; ++q){
                    if(s[q]=='\\'){ ++q; continue; }
                    if(s[q]=='"') break;
                }
                if(q>=n) return std::string_view::npos;
                k = q;
                continue;
            }
            if(d=='{' || d=='['){
                if(depth >= 64) return std::string_view::npos;   // 嵌套过深, 不冒险
                if(d=='[') isArr |= (1ull << depth); else isArr &= ~(1ull << depth);
                ++depth;
            } else if(d=='}' || d==']'){
                if(depth==0) return std::string_view::npos;
                --depth;
                const bool wantArr = ((isArr >> depth) & 1ull) != 0;
                if(wantArr != (d==']')) return std::string_view::npos;   // 括号交叉
                if(depth==0){
                    kind = wantArr ? JsonValueKind::Array : JsonValueKind::Object;
                    return k+1;
                }
            }
        }
        return std::string_view::npos;          // 没闭合 = 被截断
    }
    size_t k = i;
    while(k<n && s[k]!=',' && s[k]!='}' && s[k]!=']' && (unsigned char)s[k] > ' ') ++k;
    if(k==i) return std::string_view::npos;
    const std::string_view lit = s.substr(i, k-i);
    kind = (lit=="true" || lit=="false") ? JsonValueKind::Bool
         : (lit=="null")                 ? JsonValueKind::Null
                                         : JsonValueKind::Number;
    return k;
}

// 在【对象 obj 的本层】查找 key。obj 必须是以 '{' 开头的完整对象。
// 三种结果: 命中 (kind 为具体类型) / 没有这个键 (kind==None, malformed==false) /
// 对象结构读不下去 (malformed==true)。后两者必须分开 —— 把"读不出来"当成"没有",
// 正是这一版要堵的那类静默丢数据。
inline JsonValueRef FindTopLevelValue2(std::string_view obj, std::string_view key){
    JsonValueRef out;
    const size_t n = obj.size();
    size_t i = 0;
    while(i<n && (unsigned char)obj[i] <= ' ') ++i;
    if(i>=n || obj[i] != '{'){ out.malformed = true; return out; }
    ++i;
    while(true){
        while(i<n && (unsigned char)obj[i] <= ' ') ++i;
        if(i>=n){ out.malformed = true; return out; }   // 对象没闭合
        if(obj[i]=='}') return out;                     // 正常读完, 没有这个键
        if(obj[i]==','){ ++i; continue; }
        if(obj[i]!='"'){ out.malformed = true; return out; }   // 键必须是字符串
        const size_t ks = i + 1;
        size_t ke = ks;
        bool escaped = false;
        while(ke<n){
            if(obj[ke]=='\\'){ ke += 2; escaped = true; continue; }
            if(obj[ke]=='"') break;
            ++ke;
        }
        if(ke>=n){ out.malformed = true; return out; }
        const std::string_view thisKey = obj.substr(ks, ke-ks);
        i = ke + 1;
        while(i<n && (unsigned char)obj[i] <= ' ') ++i;
        if(i>=n || obj[i] != ':'){ out.malformed = true; return out; }
        ++i;
        while(i<n && (unsigned char)obj[i] <= ' ') ++i;
        const size_t vs = i;
        JsonValueKind vk = JsonValueKind::None;
        const size_t ve = SkipJsonValue2(obj, i, vk);
        if(ve==std::string_view::npos){ out.malformed = true; return out; }
        // escaped 的键名不做还原, 直接跳过 —— 我们要找的键都是纯 ASCII
        if(!escaped && thisKey==key){
            out.kind = vk;
            out.text = (vk==JsonValueKind::String) ? obj.substr(vs+1, (ve-1)-(vs+1))
                                                   : obj.substr(vs, ve-vs);
            return out;
        }
        i = ve;
    }
}

// 取数组文本里的第 0 个元素 (arrayText 是 FindTopLevelValue2 交回的 Array 原文, 以 '[' 开头)。
// 空数组返回 kind==None 且 malformed==false。
inline JsonValueRef FirstArrayElement2(std::string_view arrayText){
    JsonValueRef out;
    const size_t n = arrayText.size();
    size_t i = 0;
    while(i<n && (unsigned char)arrayText[i] <= ' ') ++i;
    if(i>=n || arrayText[i] != '['){ out.malformed = true; return out; }
    ++i;
    while(i<n && (unsigned char)arrayText[i] <= ' ') ++i;
    if(i>=n){ out.malformed = true; return out; }
    if(arrayText[i]==']') return out;                       // 空数组
    JsonValueKind vk = JsonValueKind::None;
    const size_t ve = SkipJsonValue2(arrayText, i, vk);
    if(ve==std::string_view::npos){ out.malformed = true; return out; }
    out.kind = vk;
    out.text = (vk==JsonValueKind::String) ? arrayText.substr(i+1, (ve-1)-(i+1))
                                           : arrayText.substr(i, ve-i);
    return out;
}

// 整串必须是一个完整的十进制整数 —— from_chars 只报"读到了几个字符", 不检查就会把
// "bad-id" 读成 0、"1006oops" 读成 1006, 于是坏数据被当成好数据落盘。
inline bool ParseFullInt64(std::string_view s, long long& out){
    if(s.empty()) return false;
    const char* const first = s.data();
    const char* const last  = s.data() + s.size();
    long long v = 0;
    const auto res = std::from_chars(first, last, v);
    if(res.ec != std::errc{} || res.ptr != last) return false;
    out = v;
    return true;
}

// 数组扫描的结果。v0.1.5.0: 从 bool 升级为三态 —— 只有"有没有找到"是不够的:
//   * 键存在但值不是数组 ("non_pull_events": { ... }), 或文件正好在 ':' 后被截断 ——
//     旧版靠 src.find('[', pos) 无界前搜, 要么找不到而返回 false, 要么跳到文件后面
//     某个不相干的数组上。返回 false 被上层理解为"旧格式文件, 没有这个键", 于是整段
//     数据被静默丢弃并在写盘时抹掉。
//   * 数组里混进了非对象元素 ("non_pull_events": [[], {...}]) —— 旧版只数花括号深度,
//     内层那个 ']' 在 depth==0 上被当成数组结束, 后面真正的事件一条都读不到, 却报告
//     "已正常闭合"。
// 现在: 元素必须逐个是对象、必须扫到 depth==0 的 ']' 收尾, 任一条不满足都是 Malformed,
// 由调用方升级为"中止, 不写盘" / "本次拉取作废"。
enum class JsonArrayScan : uint8_t {
    NotFound = 0,   // 没有这个键 (或值为 null) —— 旧格式文件 / 空页, 正常
    Ok,             // 值是正常闭合的数组, 元素全是对象 (可以是 0 个)
    Malformed       // 值不是数组 / 数组被截断 / 元素不是对象
};

// O(N) 逐字符扫描【一个已经定位好的数组】。arrayText 以 '[' 开头 (前面允许空白)。
// 结构化读取走这里: 调用方先按路径拿到数组原文, 再交给它遍历。
template<typename Cb>
[[nodiscard]] JsonArrayScan ForEachObjectInArray2(std::string_view arrayText, Cb&& cb){
    const size_t len = arrayText.length();
    size_t pos = 0;
    while(pos<len && (unsigned char)arrayText[pos] <= ' ') ++pos;
    if(pos>=len || arrayText[pos] != '[') return JsonArrayScan::Malformed;

    int depth = 0;
    size_t objStart = 0;
    for(size_t i=pos+1; i<len; ++i){
        const char c = arrayText[i];
        if(depth==0){                           // 数组本层: 只允许空白 / ',' / 对象 / ']'
            if((unsigned char)c <= ' ' || c==',') continue;
            if(c==']') return JsonArrayScan::Ok;
            if(c!='{') return JsonArrayScan::Malformed;
            objStart = i;
            depth = 1;
            continue;
        }
        if(c=='"'){                             // 跳过字符串, 里面的花括号不计深度
            size_t k = i + 1;
            for(; k<len; ++k){
                if(arrayText[k]=='\\'){ ++k; continue; }
                if(arrayText[k]=='"') break;
            }
            if(k>=len) return JsonArrayScan::Malformed;   // 字符串没闭合 = 被截断
            i = k;
            continue;
        }
        if(c=='{') ++depth;
        else if(c=='}'){
            if(--depth==0) cb(arrayText.substr(objStart, i-objStart+1));
        }
    }
    return JsonArrayScan::Malformed;            // 扫到结尾也没等到 ']' = 被截断
}

// 全文找 "arrKey": [ ... ] 再遍历。只给【服务器临时报文】用 —— 报文的嵌套层级随接口
// 版本会变, 按路径写死反而更脆; 而它是一次性的, 读串了下次重拉即可。
// 本地存档【不要】用这个: 存档里的 non_pull_events[].raw 是服务器原样透传的对象, 完全
// 可能自带 "list": [...], 一旦它排在 endfield 前面, 全文首个匹配就落到那上面, 真正的
// 抽卡数组一条都读不到 —— 而 JSON 对象的成员顺序本来就不该影响语义。存档一律走
// FindTopLevelValue2 + ForEachObjectInArray2 的结构化路径。
template<typename Cb>
[[nodiscard]] JsonArrayScan ForEachJsonObject2(std::string_view src, std::string_view arrKey, Cb&& cb){
    const size_t len = src.length();
    for(size_t search = 0; ; ){
        const size_t hit = FindJsonKey2(src, arrKey, search);
        if(hit==std::string_view::npos) return JsonArrayScan::NotFound;
        size_t p = hit + arrKey.length() + 2;   // FindJsonKey2 返回起始引号, 跳过 "key"
        search = p;
        while(p<len && (unsigned char)src[p] <= ' ') ++p;
        // FindJsonKey2 只认"两侧带引号", 值恰好等于键名时 ("foo":"list") 也会命中。
        // 后面不是 ':' 就说明这不是个键, 换下一处继续找, 而不是判文件损坏。
        if(p>=len || src[p] != ':') continue;
        ++p;
        while(p<len && (unsigned char)src[p] <= ' ') ++p;
        JsonValueKind vk = JsonValueKind::None;
        const size_t ve = SkipJsonValue2(src, p, vk);
        if(ve==std::string_view::npos) return JsonArrayScan::Malformed;   // 值读不完 = 被截断
        // 显式的 null 视同"没有数组"(空页), 不当成损坏。
        if(vk==JsonValueKind::Null)  return JsonArrayScan::NotFound;
        if(vk!=JsonValueKind::Array) return JsonArrayScan::Malformed;
        return ForEachObjectInArray2(src.substr(p, ve-p), std::forward<Cb>(cb));
    }
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
        struct tm tmv;
        localtime_r(&t, &tmv);
        char b[64];
        int n = snprintf(b, sizeof(b), "%04d-%02d-%02d %02d:%02d:%02d",
                         tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        WriteLit("            \"");
        Write(k);
        WriteLit("\": \"");
        Write(b, (size_t)n);
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
};

// ============================================================
// [非抽卡事件]  v0.1.5.0
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
    // v0.1.5.0: 非抽卡事件 (见 NonPullEvent)。与抽卡记录共用 localIds/sessionIds 去重,
    //   但单独存放、单独写盘, 不进 UIGF 的 "list"。
    std::optional<std::pmr::vector<NonPullEvent>> events;
    size_t migratedLegacy = 0;   // 从旧版 list 里迁出的非抽卡事件条数 (仅用于提示)
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
@property (nonatomic, readwrite, nullable) NSString *tempFilePath;
@property (nonatomic, readwrite, nullable) NSString *errorMessage;
@end
@implementation FetchExportSummary
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
        m.pools = {
            {"E_CharacterGachaPoolType_Special",  "角色 - 特许寻访", false},
            {"E_CharacterGachaPoolType_Joint",    "角色 - 辉光庆典", false},   // v0.1.2.0: 辉光庆典池
            {"E_CharacterGachaPoolType_Rerun",    "角色 - 重构寻访", false},   // v0.1.4.0: 重构寻访
            {"E_CharacterGachaPoolType_Standard", "角色 - 基础寻访", false},
            {"E_CharacterGachaPoolType_Beginner", "角色 - 启程寻访", false},
            {"",                                   "武器 - 全历史记录", true}
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
            // v0.1.5.0 存档保护: 事件区读坏了同样必须中止, 不能"读不懂就当没有"然后覆盖。
            //   eventsCorrupt 为真 = 文件里【有】non_pull_events 键, 但数组没闭合 (截断) 或
            //   存在无法解析的条目。此时原文件里那些事件是唯一的副本 —— 抽卡记录接口只保留
            //   90 天, 一旦被覆盖就永久丢失。
            bool   eventsCorrupt  = false;
            bool   eventsBadShape = false;   // 键在, 但值不是一个正常闭合、元素全为对象的数组
            size_t eventsMalformed = 0;
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

                        // ---- 存档一律按【结构路径】定位, 不做全文找键 (v0.1.5.0) ----
                        // 抽卡数组的路径是 根.endfield[0].list, 事件数组是 根.non_pull_events。
                        // 全文找首个 "list" 在合法 JSON 上就能读错: 事件的 raw 是服务器原样
                        // 透传的对象, 未知 kind 完全可能自带 "list": [...]; 只要顶层成员顺序
                        // 变成 non_pull_events 在前 (JSON 对象的成员顺序本不该有语义),
                        // 首个匹配就落到 raw 里那个空数组上 —— 抽卡记录一条都读不到, 却
                        // 一路"正常", 写盘时把它们全删了。事件键同理会被
                        // {"x":{"non_pull_events":[]}} 这类嵌套同名键遮住。
                        JsonArrayScan pullScan = JsonArrayScan::Malformed;
                        const JsonValueRef gameV = FindTopLevelValue2(bv, "endfield");
                        const JsonValueRef entry0 = (gameV.kind == JsonValueKind::Array)
                                                  ? FirstArrayElement2(gameV.text) : JsonValueRef{};
                        const JsonValueRef listV = (entry0.kind == JsonValueKind::Object)
                                                 ? FindTopLevelValue2(entry0.text, "list") : JsonValueRef{};
                        if(listV.kind == JsonValueKind::Array){
                        pullScan = ForEachObjectInArray2(listV.text, [&](std::string_view item){
                            std::string_view rawId = ExtractJsonValue2(item, "id", true);
                            long long pid=0, pts=0;
                            if(!rawId.empty())
                                std::from_chars(rawId.data(), rawId.data()+rawId.size(), pid);
                            std::string_view tsS = ExtractJsonValue2(item, "gacha_ts", true);
                            if(!tsS.empty())
                                std::from_chars(tsS.data(), tsS.data()+tsS.size(), pts);

                            // ---- 旧版文件的自愈迁移 (v0.1.5.0) ----
                            // v0.1.5.0 之前的版本会把非抽卡事件当成抽卡写进 list, 落地成
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
                            if(ExtractJsonValue2(item, "item_id",   true).empty() &&
                               ExtractJsonValue2(item, "rank_type", true).empty()){
                                NonPullEvent ev;
                                ev.safe_id   = pid;
                                ev.timestamp = pts;
                                ev.raw       = item;
                                m.events->push_back(ev);
                                m.localIds->insert(pid);
                                ++m.migratedLegacy;
                                return;
                            }

                            std::string_view it2 = ExtractJsonValue2(item, "item_type", true);
                            FItemType ftype = (it2=="Character") ? FItemType::Character
                                            : (it2=="Weapon")    ? FItemType::Weapon
                                                                 : FItemType::Unknown;
                            ExportRecord rec;
                            rec.safe_id    = pid;
                            rec.timestamp  = pts;
                            rec.item_type  = ftype;
                            rec.poolId     = ExtractJsonValue2(item, "gacha_type",  true);
                            rec.item_id    = ExtractJsonValue2(item, "item_id",     true);
                            rec.name       = ExtractJsonValue2(item, "item_name",   true);
                            rec.rank_type  = ExtractJsonValue2(item, "rank_type",   true);
                            rec.poolName   = ExtractJsonValue2(item, "pool_name",   true);
                            rec.weaponType = ExtractJsonValue2(item, "weapon_type", true);
                            rec.isNew  = (uint8_t)(ExtractJsonValue2(item, "is_new",  false)=="true" ? 1 : 0);
                            rec.isFree = (uint8_t)(ExtractJsonValue2(item, "is_free", false)=="true" ? 1 : 0);
                            m.records->push_back(std::move(rec));
                            m.localIds->insert(pid);
                        });
                        }
                        // Ok 之外的一切 (路径上任一环缺失/类型不对 / 数组没闭合 / 元素不是
                        // 对象) 都判加载失败。此前只要能定位到 "list" 就算加载成功, 于是被
                        // 截断的文件里"读到的那部分"会被当成完整历史写回去, 把尾巴永久抹掉。
                        loaded = (pullScan == JsonArrayScan::Ok);

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
                // v0.1.5.0: 判据收紧为"按结构路径 endfield[0].list 完整读完":
                //   键缺失、类型不对、中途被截断、数组里混进非对象元素, 全部算读不出来。
                //   此前只要全文能定位到 "list" 就算成功, 被截断的文件里"读到的那部分"
                //   会被当成完整历史写回去, 把尾巴永久抹掉。
                _state = FetchState::Failed;
                [logs addObject:@"❌ 基底文件无法读取、为空, 或结构不是 UIGF v4.2 的 endfield[0].list 数组 (键缺失、类型不对、被截断、含非对象元素), 已取消本次拉取, 原文件不会被覆盖"];
                r.ok = NO;
                r.errorMessage = @"基底文件无法读取、为空, 或不是完整的 UIGF v4.2 endfield[0].list 结构, 已取消本次拉取, 原文件不会被覆盖";
                r.logs = logs;
                return r;
            }

            // v0.1.5.0: 事件区受损与 list 受损同等对待 —— 都中止, 都不写盘。
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

        // D.2: 0 长度 / null 不能 emplace (避免 string_view 构造越界); 按池级错误跳过 (宽松, 非 Fatal)。
        // v0.1.3.3 例外: 若本池已吃进部分新记录 (m.cnt > 0, 即翻页中途失败), 跳池导出会留下
        // "上新下缺"的记录缺口 —— 下次增量拉取在最新记录处即触达老记录而停, 缺口永不回补。
        // 此时升级为 Fatal (不写盘); 仅页 1 失败 (本池无部分状态, 无缺口风险) 保留宽松跳池。
        if (data.length == 0 || data.bytes == nullptr) {
            if (m.cnt > 0) {
                _state = FetchState::Failed;
                o.status = FetchIngestFatalError;
                o.fatalErrorMessage = @"接口返回空响应 (翻页中途): 为避免记录缺口, 本次不写盘";
                o.logs = logs;
                return o;
            }
            m.AdvancePool();
            _state = FetchState::ReadyForRequest;
            o.status = FetchIngestPoolError;
            o.poolErrorMessage = @"接口返回空响应";
            o.totalNewSoFar = (NSInteger)m.sessionIds->size();
            o.delayMsBeforeNext = DelayAfterAdvancingPool(m);
            o.logs = logs;
            return o;
        }

        m.payloads.emplace_back(static_cast<const char*>(data.bytes), (size_t)data.length);
        std::string_view rv(m.payloads.back());   // D.1: 重绑

        auto code = ExtractJsonValue2(rv, "code", false);
        if(code.empty()){
            // 非空响应却没有 "code" 键 → 不是 API 的预期 JSON 结构 (多半是网关/错误页/损坏)。
            // 区别于 code!=0 (API 正常应答但业务错误 → 跳池): 这里视为会话级 Fatal, 不写盘。
            // (与设计 H 测试"JSON 整体损坏/解析异常 → FatalError, 不写盘"一致。)
            _state = FetchState::Failed;
            o.status = FetchIngestFatalError;
            o.fatalErrorMessage = @"响应非预期 JSON 结构 (无 code 字段)";
            o.logs = logs;
            return o;
        }
        if(code != "0"){
            // 池级 API 错误 → 跳过当前池, 继续后续池 (设计 D 默认保留行为)。
            // 日后若确认了鉴权/全局错误码, 可在此把特定 code 升级为 Fatal。
            // v0.1.3.3 例外: 翻页中途 (m.cnt > 0) 的业务错误同样会留下记录缺口, 升级 Fatal
            // (理由同上方 D.2 的例外注释); 页 1 业务错误维持宽松跳池。
            auto msg = ExtractJsonValue2(rv, "msg", true);
            if (m.cnt > 0) {
                _state = FetchState::Failed;
                o.status = FetchIngestFatalError;
                o.fatalErrorMessage = NSStr(std::string(
                    "接口业务错误 (翻页中途, 为避免记录缺口本次不写盘): ").append(msg));
                o.logs = logs;
                return o;
            }
            m.AdvancePool();
            _state = FetchState::ReadyForRequest;
            o.status = FetchIngestPoolError;
            o.poolErrorMessage = NSStr(std::string("接口: ").append(msg));
            o.totalNewSoFar = (NSInteger)m.sessionIds->size();
            o.delayMsBeforeNext = DelayAfterAdvancingPool(m);
            o.logs = logs;
            return o;
        }

        // ---- 解析 list ----
        long long lastSeq = 0;
        int newThisPage = 0;
        int itemsSeen = 0;
        // 服务器临时报文走全文找键的宽松路径 (报文嵌套层级随接口版本会变, 写死路径更脆);
        // 但返回值必须接住 —— 见下方 pageScan 的处理。
        const JsonArrayScan pageScan =
        ForEachJsonObject2(rv, "list", [&](std::string_view item){
            if(m.reached) return;
            ++itemsSeen;
            auto seqS = ExtractJsonValue2(item, "seqId", true);
            if(seqS.empty()) return;
            long long seq = 0;
            std::from_chars(seqS.data(), seqS.data()+seqS.size(), seq);
            lastSeq = seq;
            // v0.1.3.3: 取反改无符号形式, 规避 seq==LLONG_MIN 的有符号溢出 UB (服务器正
            // 序列号实际不可达, 零成本加固, 与分析器 abs_ll 口径对齐)。
            long long sid = pc.isWeapon ? (long long)(0ULL - (unsigned long long)seq) : seq;

            // 去重与防缺口的判定【对抽卡和非抽卡事件一视同仁】(v0.1.5.0):
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
            auto tsS = ExtractJsonValue2(item, "gachaTs", true);
            if(!tsS.empty())
                std::from_chars(tsS.data(), tsS.data()+tsS.size(), pts);

            // ---- 抽卡 / 非抽卡事件 的分流 (v0.1.5.0) ----
            // 用【正向判据】而不是"kind == gift_intel_book"的黑名单: 已知的非抽卡 kind
            // 目前只有寻访情报书一种, 但官方还有 240 抽的 UP 干员信物、武器申领累计
            // 10/18 次的补充武库箱等发放节点, 它们会不会也进这个接口尚无证据。
            // 白名单写法让任何未知的新 kind 自动落到事件通道, 而不是等到有人发现
            // 统计数字不对才去补黑名单。
            //   条件一: kind 缺失 (老记录本来就没这个字段) 或等于 "draw"
            //   条件二: 物品 id 与稀有度都在 —— 真实抽卡必然两者俱全, 这道保险能兜住
            //           "服务器某个版本/区服没下发 kind" 的情况
            std::string_view kindStr   = ExtractJsonValue2(item, "kind",   true);
            std::string_view rarityStr = ExtractJsonValue2(item, "rarity", false);
            std::string_view itemIdStr = pc.isWeapon
                ? ExtractJsonValue2(item, "weaponId", true)
                : ExtractJsonValue2(item, "charId",   true);
            const bool kindSaysPull = kindStr.empty() || kindStr == "draw";

            if(!kindSaysPull || itemIdStr.empty() || rarityStr.empty()){
                NonPullEvent ev;
                ev.safe_id   = sid;
                ev.timestamp = pts;
                ev.raw       = item;             // 原样保留整个服务器对象
                m.events->push_back(ev);
                ++m.cnt; ++newThisPage;          // 计入本池已吃进的条数 (缺口保护同样适用)
                std::string_view label = ExtractJsonValue2(item, "nameText", true);
                std::string elog;
                elog.reserve(40 + label.size() + kindStr.size());
                elog.append("  获取到(非抽卡事件): ").append(label)
                    .append(" [kind=").append(kindStr).append("]");
                [logs addObject:NSStr(elog)];
                return;
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
            ++m.cnt; ++newThisPage;
            // name/rank_type 仍指向 payloads, 直接构造日志
            const ExportRecord& back = m.records->back();
            std::string log;
            log.reserve(32 + back.name.size() + back.rank_type.size());
            log.append("  获取到: ").append(back.name).append(" (").append(back.rank_type).append(" 星)");
            [logs addObject:NSStr(log)];
        });

        // v0.1.3.3: 同会话重复 seqId = 分页游标异常 (服务器返回未推进)。已吃进的部分记录
        // 与重复点以下未拉取的历史之间存在缺口 → 升级 Fatal (不写盘), 不再当自然结束。
        if (m.dupAnomaly) {
            _state = FetchState::Failed;
            o.status = FetchIngestFatalError;
            o.fatalErrorMessage = @"分页游标异常 (重复数据): 为避免记录缺口, 本次不写盘";
            o.logs = logs;
            return o;
        }

        // 第四个异常分支 (v0.1.5.0): 记录数组本身结构异常。回调可能已经把本页前半段
        // 吃进来了, 而数组在后面才断 / 混进非对象元素 —— 忽略返回值就等于"半页当整页":
        // 本页后面那些更早的记录不会再被读到, 而已吃进的新记录一旦落地, 下次增量拉取
        // 在最新记录处即触达老记录而停, 中间的缺口永远补不回来。判据与上面的空响应 /
        // 业务错误一致: 本池已吃进部分记录时升级为整次中止, 否则宽松跳池。
        // (NotFound = 本页没有 list 或值为 null, 即空页 —— 属正常的翻页结束条件, 由下面
        //  的 itemsSeen == 0 收尾。)
        // 顺序要紧: 扫描一遇到非法元素就立刻返回, 后面的对象不会再回调, 所以
        // m.reached 为真必然发生在出错点【之前】—— 边界已经找到, 页尾坏不坏都无所谓,
        // 走正常收尾。反过来才需要按缺口处理。
        if(!m.reached && pageScan == JsonArrayScan::Malformed){
            if(m.cnt > 0){
                _state = FetchState::Failed;
                o.status = FetchIngestFatalError;
                o.fatalErrorMessage = @"接口返回的记录数组结构异常 (未闭合或含非对象元素): 为避免记录缺口, 本次不写盘";
                o.newThisPage = newThisPage;
                o.logs = logs;
                return o;
            }
            m.AdvancePool();
            _state = FetchState::ReadyForRequest;
            o.status = FetchIngestPoolError;
            o.poolErrorMessage = @"接口返回的记录数组结构异常 (未闭合或含非对象元素)";
            o.totalNewSoFar = (NSInteger)m.sessionIds->size();
            o.delayMsBeforeNext = DelayAfterAdvancingPool(m);
            o.logs = logs;
            return o;
        }

        // ---- 是否本池结束 ----
        // reached / hasMore=false(本页重复) / itemsSeen==0(空页, 含 list:[]) → 本池结束。
        //   itemsSeen==0 既覆盖"结构正确但 list:[]"的正常无新数据, 也避免 hasMore:true+空页时的死循环。
        // 否则推进 cursor/page, 再看接口 hasMore: 若为 false 同样结束。
        bool poolDone;
        if (m.reached || !m.hasMore || itemsSeen == 0) {
            poolDone = true;
        } else {
            m.cursor = lastSeq;
            m.hasMore = (ExtractJsonValue2(rv, "hasMore", false) == "true");
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
            //     "non_pull_events": [ ... ]   // v0.1.5.0 新增, 仅在非空时出现
            //   }
            //
            // "non_pull_events" 是本工具的扩展键, 不属于 UIGF 标准, 也【不应】被当作抽卡
            // 记录读取。UIGF 标准本身没有规定非抽卡事件该放哪里 (它只定义抽卡记录的
            // schema), 这里选择独立键而非塞进 list, 是为了让 list 对所有第三方 UIGF
            // 工具保持"每一条都是一次抽卡"的语义。详见 NonPullEvent 的说明。
            // (例外: non_pull_events[].raw 里是服务器原始对象, 保持其原有的 camelCase,
            //  因为那一段是原样透传, 不做任何改写。)
            // ==========================================================
            time_t t = exp_ts; struct tm tmv; localtime_r(&t, &tmv);
            char tbuf[64];
            int tl = snprintf(tbuf, sizeof(tbuf), "%04d-%02d-%02d %02d:%02d:%02d",
                              tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                              tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

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
            int tzHours = (int)(tmv.tm_gmtoff / 3600);
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
            // ---- 非抽卡事件 (v0.1.5.0) ----
            // 放在 "endfield" 之后的顶层键。有意【不】混进 list:
            //   list 是 UIGF 定义的抽卡记录数组, 任何读这个文件的第三方工具都会按抽卡来数;
            //   而这些行不是抽卡, 混进去会让不做过滤的工具把保底水位每期多算 1 抽。
            //   放在独立键里, list 对所有 UIGF 工具保持干净, 信息也一条不丢。
            // 每个元素是 { "id", "gacha_ts", "raw" }: 前两个是本工具自用的检索字段
            // (写在前面, 保证全文找键的首个匹配一定命中它们), raw 是服务器原始对象,
            // 原样透传 —— 将来出现新的 kind 也不会因为字段没被识别而丢失。
            // 位置也要紧: endfield 写在前面, 所以按"全文首个 list"读取的分析端仍会命中
            // 真正的抽卡数组; 而本工具自己读存档一律走结构路径, 不依赖成员顺序。
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

        committed = true;   // 写盘完整成功: 保留 tmp 供协调器落地 (ScopeExit 不再删)
        _state = FetchState::Exported;
        s.ok = YES;
        s.newCount   = (NSInteger)m.sessionIds->size();
        s.totalCount = (NSInteger)records.size();
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
