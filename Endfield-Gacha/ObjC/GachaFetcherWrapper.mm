//  GachaFetcherWrapper.mm
//  Endfield-Gacha
//  网络拉取实现:NSURLSession + POSIX I/O + ObjC 接口
//
//  关键设计 (与 Windows main.cpp 对齐):
//   - 所有网络响应 (std::string) 与基底文件内容 (std::string) 都存活在
//     std::deque<std::string> 中。deque 的 push_back 不失效已有指针,
//     所以 ExportRecord 可以全用 std::string_view 指向 deque 内字节,
//     避免几万次 std::string malloc。
//   - PMR monotonic_buffer_resource 提供后台线程上的临时容器分配池,
//     避免每个 vector/unordered_set 元素 malloc。

#import "AnalyzerWrapper.h"
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory_resource>
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

// ---- JSON / URL 解析 (与 AnalyzerWrapper 同款) ----
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
template<typename Cb>
void ForEachJsonObject2(std::string_view src, std::string_view arrKey, Cb&& cb){
    size_t pos = FindJsonKey2(src, arrKey);
    if(pos==std::string_view::npos) return;
    pos = src.find(':', pos+arrKey.size()+2);
    if(pos==std::string_view::npos) return;
    pos = src.find('[', pos);
    if(pos==std::string_view::npos) return;
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
}
inline std::string_view ExtractUrlParam(std::string_view url, std::string_view key){
    size_t pos = url.find(key);
    if(pos==std::string_view::npos) return {};
    pos += key.size();
    size_t end = url.find('&', pos);
    return end==std::string_view::npos ? url.substr(pos) : url.substr(pos, end-pos);
}

// ---- 同步 HTTP 拉取 ----
std::string FetchURL(const std::string& urlStr){
    @autoreleasepool {
        NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr.c_str()]];
        if(!url) return {};
        __block NSData* dat = nil;
        __block NSError* err = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession] dataTaskWithURL:url
            completionHandler:^(NSData* d, NSURLResponse*, NSError* e){
                dat = d; err = e;
                dispatch_semaphore_signal(sem);
            }] resume];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if(err || !dat) return {};
        return std::string((const char*)dat.bytes, dat.length);
    }
}

// ---- 缓冲写入 (堆上 64KB 缓冲;次级 GCD 线程栈较小,不放栈) ----
struct BufferedWriter{
    int fd;
    std::vector<char> buf;
    size_t pos = 0;

    explicit BufferedWriter(int f) : fd(f), buf(65536) {}
    ~BufferedWriter(){ Flush(); }

    BufferedWriter(const BufferedWriter&) = delete;
    BufferedWriter& operator=(const BufferedWriter&) = delete;

    void Flush(){
        if(pos>0 && fd>=0){ ::write(fd, buf.data(), pos); pos=0; }
    }
    void Write(const char* d, size_t n){
        while(n>0){
            size_t sp = buf.size()-pos;
            size_t ch = std::min(n, sp);
            memcpy(buf.data()+pos, d, ch);
            pos += ch; d += ch; n -= ch;
            if(pos==buf.size()) Flush();
        }
    }
    void Write(std::string_view sv){ Write(sv.data(), sv.size()); }

    template<size_t N>
    void WriteLit(const char (&s)[N]){
        constexpr size_t n = N-1;
        if(pos+n > buf.size()) Flush();
        memcpy(buf.data()+pos, s, n);
        pos += n;
    }
    void WriteEscaped(std::string_view s){
        const char* p = s.data();
        const char* e = p + s.size();
        while(p<e){
            const char* c = p;
            while(p<e && *p!='"' && *p!='\\') ++p;
            if(p>c) Write(c, (size_t)(p-c));
            if(p<e){
                if(*p=='"') WriteLit("\\\"");
                else        WriteLit("\\\\");
                ++p;
            }
        }
    }
    void WriteKV(std::string_view k, std::string_view v){
        WriteLit("            \"");
        Write(k);
        WriteLit("\": \"");
        WriteEscaped(v);
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

// 与 main.cpp 对齐:全部 string_view 指向 deque<string> 中的字节;deque 不失效指针
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

} // namespace

@implementation GachaFetcherWrapper

+ (void)fetchAllPoolsFromURL:(NSString*)url
                existingFile:(NSString*)existingFile
               progressBlock:(void(^)(NSString*))progressBlock
             completionBlock:(void(^)(BOOL,NSInteger,NSInteger,NSString*,NSString*))completionBlock
{
    // 跨线程上下文:在 fetcher worker pthread 里跑(4MB 栈,容得下 2MB PMR 栈池)。
    // 不用 GCD dispatch_async(global_queue) 因为它的 worker block 默认栈仅 512KB,
    // 撑不住与 main.cpp 对齐的 2MB 栈池。
    struct FetcherCtx {
        NSString* url;
        NSString* existFile;
        void (^progress)(NSString*);
        void (^completion)(BOOL,NSInteger,NSInteger,NSString*,NSString*);
    };
    auto* ctx = new FetcherCtx{
        [url copy],
        [existingFile copy],
        [progressBlock copy],
        [completionBlock copy]
    };

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);

    pthread_t tid;
    int create_err = pthread_create(&tid, &attr, +[](void* arg) -> void* {
        @autoreleasepool {
        auto* ctx = (FetcherCtx*)arg;
        NSString* capturedUrl       = ctx->url;
        NSString* capturedExistFile = ctx->existFile;
        void (^capturedProgress)(NSString*) = ctx->progress;
        void (^capturedCompletion)(BOOL,NSInteger,NSInteger,NSString*,NSString*) = ctx->completion;
        delete ctx;

        void (^emitProgress)(NSString*) = ^(NSString* msg) {
            if (!capturedProgress) return;
            dispatch_async(dispatch_get_main_queue(), ^{ capturedProgress(msg); });
        };
        void (^emitCompletion)(BOOL,NSInteger,NSInteger,NSString*,NSString*) =
            ^(BOOL ok, NSInteger nc, NSInteger tot, NSString* path, NSString* err) {
                if (!capturedCompletion) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    capturedCompletion(ok, nc, tot, path, err);
                });
            };

        // PMR:栈上 2MB 池 (与 main.cpp 对齐;pthread 4MB 栈容得下)。
        // 栈池 vs 堆池: 分配/释放零开销,L1/L2 cache 热,与 worker 栈局部变量物理相邻。
        std::array<std::byte, 2 * 1024 * 1024> stackBuffer;
        std::pmr::monotonic_buffer_resource pool(stackBuffer.data(), stackBuffer.size());
        std::pmr::polymorphic_allocator<std::byte> alloc(&pool);

        auto report = [&](std::string_view msg){
            // NSString 拷贝 UTF-8 字节,生命周期独立于 msg
            emitProgress([[NSString alloc] initWithBytes:msg.data()
                                                  length:msg.size()
                                                encoding:NSUTF8StringEncoding]);
        };
        auto reportStr = [&](const std::string& msg){
            report(std::string_view(msg));
        };

        // ---- URL 提取 + trim ----
        std::string urlStr = capturedUrl.UTF8String ? capturedUrl.UTF8String : "";
        while(!urlStr.empty() && (urlStr.back()==' '||urlStr.back()=='\n'||urlStr.back()=='\r'||urlStr.back()=='\t'))
            urlStr.pop_back();
        while(!urlStr.empty() && (urlStr.front()==' '||urlStr.front()=='\t'))
            urlStr.erase(urlStr.begin());

        std::string_view inputUrl(urlStr);
        auto token = ExtractUrlParam(inputUrl, "token=");
        if(token.empty()){ emitCompletion(NO, 0, 0, @"", @"错误: 无法提取 token"); return nullptr; }
        auto serverId = ExtractUrlParam(inputUrl, "server_id=");
        if(serverId.empty()) serverId = "1";
        report("已识别 Server ID: " + std::string(serverId));

        std::string hostName = "ef-webview.gryphline.com";
        if(inputUrl.find("hypergryph") != std::string_view::npos){
            hostName = "ef-webview.hypergryph.com";
            report(std::string_view("已识别区服: 国服 (Hypergryph)"));
        } else {
            report(std::string_view("已识别区服: 国际服 (Gryphline)"));
        }

        std::vector<PoolCfg> pools = {
            {"E_CharacterGachaPoolType_Special",  "角色 - 特许寻访", false},
            {"E_CharacterGachaPoolType_Joint",    "角色 - 辉光庆典", false},   // v0.1.2.0: 辉光庆典池
            {"E_CharacterGachaPoolType_Standard", "角色 - 基础寻访", false},
            {"E_CharacterGachaPoolType_Beginner", "角色 - 启程寻访", false},
            {"",                                   "武器 - 全历史记录", true}
        };

        // 关键:payloads 持有所有 std::string 字节;ExportRecord 中的 string_view
        // 全部指向 payloads 内容。deque 的 push_back 不失效已有指针,因此跨多次
        // 网络响应也能安全引用。
        std::deque<std::string> payloads;

        std::pmr::vector<ExportRecord> records(alloc);
        records.reserve(10000);

        std::pmr::unordered_set<long long> localIds(alloc);
        localIds.reserve(10000);

        std::string uigfFile = capturedExistFile.UTF8String ? capturedExistFile.UTF8String : "";

        // ---- 加载基底文件 (mmap → 拷贝到 payloads → 立即解除映射) ----
        // 拷贝是必须的:用户选了"覆盖保存到原文件"时,我们后面要 move/replace 这个文件,
        // 不能持有它的 mmap;一拷贝完就 munmap 释放句柄。
        if(!uigfFile.empty()){
            int fd = ::open(uigfFile.c_str(), O_RDONLY);
            if(fd>=0){
                struct stat st{};
                if(fstat(fd, &st)==0 && st.st_size>0){
                    const size_t fileSize = (size_t)st.st_size;
                    const char* md = (const char*)mmap(nullptr, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
                    if(md != MAP_FAILED){
                        // 拷到 deque,后续 view 全部指向这份字节
                        payloads.emplace_back(md, fileSize);
                        munmap((void*)md, fileSize);

                        std::string_view bv(payloads.back());
                        if(bv.size()>=3
                           && (uint8_t)bv[0]==0xEF && (uint8_t)bv[1]==0xBB && (uint8_t)bv[2]==0xBF)
                        {
                            bv.remove_prefix(3);
                        }

                        // UIGF v4.2: 走 endfield[0].list
                        // ForEachJsonObject2 找的是 "list" 这个 key,而 v4.2 里
                        // endfield 数组的元素本身是 { uid, timezone, lang, list:[...] },
                        // 整个文件里 "list" 这个 key 是唯一的(只在 endfield[0] 内层出现),
                        // 所以直接用 ForEachJsonObject2(bv, "list", ...) 仍然能命中正确的数组,
                        // 不需要先解析 endfield[0]。
                        // (info 块里没有 list,顶层只有 info 和 endfield 两个 key。)
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

                            ExportRecord r;
                            r.safe_id    = pid;
                            r.timestamp  = pts;
                            r.item_type  = ftype;
                            // v4.2: gacha_type 字符串(原 uigf_gacha_type)
                            r.poolId     = ExtractJsonValue2(item, "gacha_type",  true);
                            r.item_id    = ExtractJsonValue2(item, "item_id",     true);
                            // v4.2: item_name (原 name)
                            r.name       = ExtractJsonValue2(item, "item_name",   true);
                            r.rank_type  = ExtractJsonValue2(item, "rank_type",   true);
                            // 自定义字段,snake_case
                            r.poolName   = ExtractJsonValue2(item, "pool_name",   true);
                            r.weaponType = ExtractJsonValue2(item, "weapon_type", true);
                            r.isNew  = (uint8_t)(ExtractJsonValue2(item, "is_new",  false)=="true" ? 1 : 0);
                            r.isFree = (uint8_t)(ExtractJsonValue2(item, "is_free", false)=="true" ? 1 : 0);
                            records.push_back(std::move(r));
                            localIds.insert(pid);
                        });
                    }
                }
                close(fd);
                reportStr("成功加载基底文件，包含 " + std::to_string(records.size()) + " 条已有记录");
            } else {
                report(std::string_view("基底文件读取失败, 将作为全新文件拉取"));
            }
        } else {
            report(std::string_view("未提供基底文件, 将作为全新文件拉取"));
        }

        std::string tokenStr(token), serverIdStr(serverId);
        std::pmr::unordered_set<long long> sessionIds(alloc);
        sessionIds.reserve(2000);

        // ---- 主循环:逐池拉取 ----
        for(const auto& pc : pools){
            reportStr("正在抓取 [" + pc.displayName + "] ...");
            bool hasMore = true, reached = false;
            long long cursor = 0;
            int page = 1, cnt = 0;
            char sbuf[32];

            while(hasMore && !reached){
                std::string curUrl = "https://" + hostName + (pc.isWeapon
                    ? "/api/record/weapon?lang=zh-cn&token=" + tokenStr + "&server_id=" + serverIdStr
                    : "/api/record/char?lang=zh-cn&pool_type=" + pc.poolType
                        + "&token=" + tokenStr + "&server_id=" + serverIdStr);
                if(page>1 && cursor>0){
                    auto [p, e] = std::to_chars(sbuf, sbuf+32, cursor);
                    curUrl += "&seq_id=";
                    curUrl.append(sbuf, (size_t)(p-sbuf));
                }

                std::string body = FetchURL(curUrl);
                if(body.empty()){
                    report(std::string_view("  [错误] 网络请求失败"));
                    break;
                }
                // 关键:把 body 移入 deque 持有,后续 string_view 指向 deque 内
                payloads.emplace_back(std::move(body));
                std::string_view rv(payloads.back());

                auto code = ExtractJsonValue2(rv, "code", false);
                if(code.empty()){
                    report(std::string_view("  [错误] 非 JSON 响应"));
                    break;
                }
                if(code != "0"){
                    auto msg = ExtractJsonValue2(rv, "msg", true);
                    std::string buf;
                    buf.reserve(20 + msg.size());
                    buf.append("  [提示] 接口: ").append(msg);
                    reportStr(buf);
                    break;
                }

                long long lastSeq = 0;
                ForEachJsonObject2(rv, "list", [&](std::string_view item){
                    if(reached) return;
                    auto seqS = ExtractJsonValue2(item, "seqId", true);
                    if(seqS.empty()) return;
                    long long seq = 0;
                    std::from_chars(seqS.data(), seqS.data()+seqS.size(), seq);
                    lastSeq = seq;
                    long long sid = pc.isWeapon ? -seq : seq;

                    if(localIds.contains(sid)){
                        reached = true;
                        reportStr("  * 触达本地老记录 (ID: " + std::to_string(seq) + ")");
                        return;
                    }
                    if(sessionIds.contains(sid)){
                        reportStr("  [警告] 重复数据 (ID: " + std::to_string(seq) + ")");
                        hasMore = false;
                        return;
                    }
                    sessionIds.insert(sid);

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

                    records.push_back(std::move(rec));
                    cnt++;
                    // name/rank_type 还指向 payloads,直接构造日志字符串
                    std::string log;
                    log.reserve(32 + records.back().name.size() + records.back().rank_type.size());
                    log.append("  获取到: ")
                       .append(records.back().name)
                       .append(" (")
                       .append(records.back().rank_type)
                       .append(" 星)");
                    reportStr(log);
                });

                if(reached || !hasMore) break;
                cursor = lastSeq;
                hasMore = ExtractJsonValue2(rv, "hasMore", false) == "true";
                page++;
                usleep(300000);
            }
            reportStr(">>> [" + pc.displayName + "] 完成,新增: " + std::to_string(cnt) + " 条");
            usleep(500000);
        }

        reportStr("总计新增拉取 " + std::to_string(sessionIds.size()) + " 条记录");

        // ---- 排序 (与 main.cpp 一致) ----
        auto abs_ll = [](long long v){return v<0?-v:v;};
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

        int outFd = ::open(tmpFile.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if(outFd < 0){ emitCompletion(NO, 0, 0, @"", @"临时文件创建失败"); return nullptr; }
        {
            BufferedWriter w(outFd);
            char nb[32];

            // ==========================================================
            // UIGF v4.2 输出
            // ----------------------------------------------------------
            // 文档地址: https://uigf.org/standards/UIGF.html
            //
            // 终末地不在 UIGF 官方支持的游戏列表里(米哈游系: hk4e/hkrpg/nap/hk4e_ugc),
            // 但 v4.2 schema 顶层用 "properties" 而非 "additionalProperties: false",
            // 允许新增自定义游戏 key。我们用 "endfield" 作为终末地的容器。
            //
            // 顶层结构:
            //   { "info": { ... v4.2 公共字段 ... },
            //     "endfield": [ { "uid", "timezone", "lang", "list": [ ... ] } ] }
            //
            // 注意: v4.2 info 不再含 uid/lang/uigf_version,而是:
            //   - export_timestamp / export_app / export_app_version (必需)
            //   - version: "v4.2" (替代 uigf_version)
            // uid/lang 下沉到游戏数组的元素里。
            //
            // 自定义业务字段(API 原始信息保留)统一改为 snake_case:
            //   gacha_ts / pool_name / weapon_type / is_new / is_free
            // ==========================================================

            time_t t = exp_ts; struct tm tmv; localtime_r(&t, &tmv);
            char tbuf[64];
            int tl = snprintf(tbuf, sizeof(tbuf), "%04d-%02d-%02d %02d:%02d:%02d",
                              tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                              tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

            // ---- info 块 ----
            w.WriteLit("{\n    \"info\": {\n");
            w.WriteLit("        \"export_timestamp\": ");
            {
                auto [p, e] = std::to_chars(nb, nb+32, exp_ts);
                w.Write(nb, (size_t)(p-nb));
            }
            w.WriteLit(",\n");
            w.WriteLit("        \"export_app\": \"Endfield Gacha (macOS)\",\n"
                       "        \"export_app_version\": \"v2.6.0\",\n"
                       "        \"version\": \"v4.2\",\n");
            // export_time 不在 v4.2 必需字段里,但保留作为人类可读辅助信息
            w.WriteLit("        \"export_time\": \"");
            w.Write(tbuf, (size_t)tl);
            w.WriteLit("\"\n    },\n");

            // ---- endfield 数组(单账号 → 单元素) ----
            // timezone 用本地时区偏移(单位:小时)。
            // 终末地国服/国际服的服务器时区通常都是 UTC+8(北京时间),
            // 这里直接取本地 tm_gmtoff 换算成小时,通用且不依赖 region。
            int tzHours = (int)(tmv.tm_gmtoff / 3600);
            w.WriteLit("    \"endfield\": [\n        {\n");
            w.WriteLit("            \"uid\": \"0\",\n");
            w.WriteLit("            \"timezone\": ");
            {
                auto [p, e] = std::to_chars(nb, nb+32, tzHours);
                w.Write(nb, (size_t)(p-nb));
            }
            w.WriteLit(",\n");
            w.WriteLit("            \"lang\": \"zh-cn\",\n");
            w.WriteLit("            \"list\": [\n");

            const size_t n = records.size();
            for(size_t i=0; i<n; ++i){
                const auto& r = records[i];
                w.WriteLit("        {\n");
                // v4.2 标准字段:gacha_type (替代 v3.0 的 uigf_gacha_type)
                w.WriteKV("gacha_type", r.poolId);          w.WriteLit(",\n");
                w.WriteI64KV("id", r.safe_id, true);        w.WriteLit(",\n");
                w.WriteKV("item_id", r.item_id);            w.WriteLit(",\n");
                // v4.2 标准字段:item_name (替代 v3.0 的 name,对齐 hk4e_ugc 风格)
                w.WriteKV("item_name", r.name);             w.WriteLit(",\n");
                w.WriteKV("item_type", ItemTypeToStr(r.item_type)); w.WriteLit(",\n");
                w.WriteKV("rank_type", r.rank_type);        w.WriteLit(",\n");
                w.WriteTimeKV("time", r.timestamp);         w.WriteLit(",\n");
                // 自定义业务字段(snake_case)
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
            // BufferedWriter 析构自动 Flush
        }
        ::close(outFd);

        emitCompletion(YES, (NSInteger)sessionIds.size(), (NSInteger)records.size(), tempNS, @"");
        }  // @autoreleasepool
        return nullptr;
    }, ctx);
    pthread_attr_destroy(&attr);

    // 错误检查: pthread_create 失败时 tid 未定义, 不能 detach;
    // 已分配的 ctx 必须手动释放; 必须主动触发 completion 否则 UI 永远卡在
    // "拉取中..." 状态. 对齐 AnalyzerWrapper.mm 的同款错误处理.
    if (create_err != 0) {
        delete ctx;
        if (completionBlock) {
            NSString* errMsg = [NSString stringWithFormat:
                @"底层大栈线程创建失败 (errno=%d)", create_err];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(NO, 0, 0, nil, errMsg);
            });
        }
        return;
    }

    pthread_detach(tid);  // fire-and-forget,worker 完成后自动回收
}
@end
