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
// v0.1.3.3 (A2): 返回值改为 bool —— 是否定位到 "arrKey": [ ... ] 数组结构 (空数组也算)。
// 基底加载用它区分"结构正确的空数据"与"无结构的损坏/异类文件"; 原有调用方不取返回值。
template<typename Cb>
bool ForEachJsonObject2(std::string_view src, std::string_view arrKey, Cb&& cb){
    size_t pos = FindJsonKey2(src, arrKey);
    if(pos==std::string_view::npos) return false;
    pos = src.find(':', pos+arrKey.size()+2);
    if(pos==std::string_view::npos) return false;
    pos = src.find('[', pos);
    if(pos==std::string_view::npos) return false;
    int depth=0; size_t os=0;
    for(size_t i=pos; i<src.size(); ++i){
        char c = src[i];
        if(c=='"'){
            for(++i; i<src.size(); ++i){
                if(src[i]=='\\' && i+1<src.size()){ ++i; continue; }
                if(src[i]=='"') break;
            }
            continue;
        }
        if(c=='{'){ if(!depth) os=i; ++depth; }
        else if(c=='}'){ --depth; if(!depth) cb(src.substr(os, i-os+1)); }
        else if(c==']' && !depth) break;
    }
    return true;   // 已定位数组 (即便其中 0 个对象)
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

        m.pools = {
            {"E_CharacterGachaPoolType_Special",  "角色 - 特许寻访", false},
            {"E_CharacterGachaPoolType_Joint",    "角色 - 辉光庆典", false},   // v0.1.2.0: 辉光庆典池
            {"E_CharacterGachaPoolType_Standard", "角色 - 基础寻访", false},
            {"E_CharacterGachaPoolType_Beginner", "角色 - 启程寻访", false},
            {"",                                   "武器 - 全历史记录", true}
        };

        // ---- PMR arena/pool/alloc + 容器 ----
        m.arena = std::make_unique_for_overwrite<std::byte[]>(kArenaSize);
        m.pool.emplace(m.arena.get(), kArenaSize);
        m.alloc.emplace(&*m.pool);
        m.records.emplace(*m.alloc);    m.records->reserve(10000);
        m.localIds.emplace(*m.alloc);   m.localIds->reserve(10000);
        m.sessionIds.emplace(*m.alloc); m.sessionIds->reserve(2000);

        // ---- 加载基底文件 (mmap → 拷贝到 payloads → 解除映射) ----
        // 拷贝是必须的: 用户选"覆盖保存到原文件"时, 后面要 replace 这个文件, 不能持有它的 mmap;
        // 映射由下方 ScopeExit 在拷贝/解析所在块结束时解除 (远早于 writeExport 的文件替换)。
        // 0 字节文件由 st.st_size>0 守卫排除 (不 mmap(0))。
        m.existFile = _existFile.UTF8String ? _existFile.UTF8String : "";
        if(!m.existFile.empty()){
            bool loaded = false;
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

                        // UIGF v4.2: endfield[0].list。"list" 在整个文件唯一 (仅 endfield[0] 内层),
                        // 直接 ForEachJsonObject2(bv,"list",...) 即命中正确数组。
                        const bool hasListArray =
                        ForEachJsonObject2(bv, "list", [&](std::string_view item){
                            std::string_view rawId = ExtractJsonValue2(item, "id", true);
                            long long pid=0, pts=0;
                            if(!rawId.empty())
                                std::from_chars(rawId.data(), rawId.data()+rawId.size(), pid);
                            std::string_view tsS = ExtractJsonValue2(item, "gacha_ts", true);
                            if(!tsS.empty())
                                std::from_chars(tsS.data(), tsS.data()+tsS.size(), pts);
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
                        // v0.1.3.3 (A2): "加载成功"现在要求定位到 "list" 数组结构。
                        // 结构正确但列表为空 → hasListArray=true, 0 条, 属正常空数据;
                        // 无结构 (异类/截断/损坏) → loaded=false, 走下方致命分支不覆盖原历史。
                        loaded = hasListArray;
                    }
                }
            }
            if(loaded){
                [logs addObject:NSStr("成功加载基底文件，包含 " + std::to_string(m.records->size()) + " 条已有记录")];
            } else {
                // 用户【已明确提供】基底文件却读不出来 → 致命错误: 取消本次拉取, 绝不用全新文件覆盖原历史。
                // v0.1.3.3 (A2): 判定范围扩展 —— open / fstat / mmap 失败、0 字节、以及
                // 【找不到 "list" 数组结构】(异类/截断/损坏文件) 均归此类;
                // "list" 存在但为空属结构正确的空数据, 不在此列 (0 条正常继续)。
                _state = FetchState::Failed;
                [logs addObject:@"❌ 基底文件无法读取、为空或不含 list 数组结构, 已取消本次拉取, 原文件不会被覆盖"];
                r.ok = NO;
                r.errorMessage = @"基底文件无法读取、为空或不含有效记录结构, 已取消本次拉取, 原文件不会被覆盖";
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

            ExportRecord rec;
            rec.safe_id   = sid;
            rec.timestamp = pts;
            rec.poolId    = ExtractJsonValue2(item, "poolId",    true);
            rec.rank_type = ExtractJsonValue2(item, "rarity",    false);
            rec.poolName  = ExtractJsonValue2(item, "poolName",  true);
            rec.isNew  = (uint8_t)(ExtractJsonValue2(item, "isNew",  false)=="true" ? 1 : 0);
            rec.isFree = (uint8_t)(ExtractJsonValue2(item, "isFree", false)=="true" ? 1 : 0);

            if(pc.isWeapon){
                rec.item_id    = ExtractJsonValue2(item, "weaponId",   true);
                rec.name       = ExtractJsonValue2(item, "weaponName", true);
                rec.item_type  = FItemType::Weapon;
                rec.weaponType = ExtractJsonValue2(item, "weaponType", true);
            } else {
                rec.item_id    = ExtractJsonValue2(item, "charId",   true);
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
            //   { "info": { ... }, "endfield": [ { uid, timezone, lang, list:[...] } ] }
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
            w.WriteLit("            ]\n        }\n    ]\n}\n");
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
