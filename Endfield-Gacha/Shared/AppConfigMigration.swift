//
//  AppConfigMigration.swift
//  Endfield-Gacha
//
//  配置的【内置数据 + 纯逻辑】。只依赖 Foundation, 不碰 SwiftUI / @Observable / UserDefaults ——
//  这样 Tests/app_config_tests.swift 可以直接编译并运行【这一份实现】, 而不是抄一份副本。
//  有状态的那一半 (读写 UserDefaults、平台开关) 留在 AppConfig.swift。
//

import Foundation

enum AppConfigMigration {

    // MARK: - 当前内置数据

    // 常驻(基础寻访)六星角色。截至 2026-09-06 仍是这 5 人, 自公测以来【没有增补过】——
    // 每期「特许寻访」公告都带同一条条款:「※ 在「特许寻访」中概率提升的6星干员, 将于
    // 3次「特许寻访」结束后, 移出「特许寻访」全部可能出现的干员列表。移出后, 概率提升的
    // 6星干员不会进入「基础寻访」。」即终末地【没有】限定角色下放常驻的机制。
    // 数据源: 客户端 GachaCharPoolContentTable 的 standard / beginner 两池六星恒为这 5 人。
    static let defaultChars = "骏卫,黎风,别礼,余烬,艾尔黛拉"

    // 「卡池名 : 当期UP角色」映射。这份映射【必须补全】, 因为特许寻访池里的六星恒为
    // 8 个 = 当期 UP + 前两期的限定干员 + 5 名常驻 (限定角色 UP 期结束后还会在池中滞留
    // 2 期才移出)。例如「冬猎」池 = 提弗洛斯(UP)/梨诺/诀 + 5 常驻 —— 若缺映射而回退到
    // "不在常驻名单 = UP"的排除法, 歪出的 梨诺/诀 会被误判成当期 UP。
    // 下列 12 期与客户端 GachaCharPoolTable 的 name.cn / upCharIds 逐条核对一致:
    //   special_1_0_1 熔火灼痕:莱万汀   special_1_0_2 热烈色彩:伊冯
    //   special_1_0_3 轻飘飘的信使:洁尔佩塔  special_1_1_1 河流的女儿:汤汤
    //   special_1_1_2 狼珀:洛茜        special_1_2_1 春雷动，万物生:庄方宜
    //   special_1_3_1 拳出无悔:弭弗    special_1_3_2 逐罪者:卡缪
    //   special_1_4_1 临渊望北:诀      special_1_4_2 晨星于此闪耀:梨诺
    //   special_1_5_1 冬猎:提弗洛斯    rerun_chr_yvonne 绚丽异彩:伊冯 (重构寻访, 9/24 开)
    // 注意「绚丽异彩」是伊冯的复刻, 与她 1.0 的原池「热烈色彩」并列, 两条都要留。
    static let defaultPool = "熔火灼痕:莱万汀,轻飘飘的信使:洁尔佩塔,热烈色彩:伊冯,河流的女儿:汤汤,狼珀:洛茜,春雷动，万物生:庄方宜,拳出无悔:弭弗,逐罪者:卡缪,临渊望北:诀,晨星于此闪耀:梨诺,冬猎:提弗洛斯,绚丽异彩:伊冯"

    // 这份名单的语义是【已知的"非当期 UP"六星武器白名单】: 武器池的 Calculate() 传的
    // pool_map 是空的, UP 判定 100% 靠"不在本名单里 ⇒ 当期 UP"。所以名单里混入一件
    // 限定 UP 武器, 抽到它的玩家就会被记成"歪", 武器池 UP 率被系统性拉低。
    //
    // v0.1.4.0 修正: 删除【赤缨】。它是 1.3 上半「绛结申领」的当期 UP (弭弗专武),
    //   是 2026-06-08 那次数据更新一并塞进来的录入失误 —— 同批的 雾中微光/灯火使命/
    //   幻想苦痛 确实不是 UP, 只有赤缨归类错了。
    //   证据: 把客户端 GachaWeaponPoolContentTable 全部 19 个武器池的六星按
    //   isHardGuaranteeItem 展开后, "当 UP 出现过"与"当陪跑出现过"两个集合【完全不相交】,
    //   赤缨只出现在 weponbox_1_3_1 的 UP 位, 从未作为陪跑六星出现在任何池里。
    //
    // 限定武器 (只作为某期 UP 出现, 都【不该】进本名单):
    //   熔铸火焰、艺术暴君、使命必达、落草、狼之绯、孤舟、赤缨、镀红祝福、
    //   四二式·肃阵 (1.4 军列申领, 诀专武)、曜夜的首演 (1.4 明曜申领, 梨诺专武)、
    //   寒夜幽影 (1.5 幽寒申领, 提弗洛斯专武)
    //   注: "限定"不等于"只出现一次" —— 艺术暴君已在 9/24 的「点绘申领」(重构申领) 复刻。
    //
    // 名单里另有 8 件是【通行证(武器补给)/活动直给】的六星: 黯色火炬、领航者、
    //   作品：蚀迹、光荣记忆、望乡、雾中微光、灯火使命、幻想苦痛。它们不在任何申领池,
    //   永远不会出现在 /api/record/weapon 里, 留着无害也无作用, 保留以免误删。
    //
    // 名单里的 赫拉芬格/沧溟星梦/不知归/负山/大雷斑 是 5 个【常驻武器申领池】各自的固定
    //   UP。按上面的语义它们本不该在白名单里, 但这些池的 poolId 含 "constant" →
    //   ParseGachaType 判为 Constant → 已被整体排除在武器统计之外, 故留着无影响。
    //   ★ 若将来放开 Constant 池参与统计, 这 5 件必须同时移除。
    static let defaultWeps = "宏愿,不知归,黯色火炬,扶摇,热熔切割器,显赫声名,白夜新星,大雷斑,赫拉芬格,典范,昔日精品,破碎君王,J.E.T.,骁勇,负山,同类相食,楔子,领航者,骑士精神,遗忘,爆破单元,作品：蚀迹,沧溟星梦,光荣记忆,望乡,雾中微光,灯火使命,幻想苦痛"

    /// 配置结构版本。每当内置数据发生【需要推送给老用户】的修正 (新增卡池 UP 映射、
    /// 纠正分类错误) 就 +1, 并在 migrate() 里补一条对应的迁移步骤。
    static let currentSchemaVersion = 1

    // MARK: - 历史默认值
    //
    // 用途只有一个: 识别"这个值其实是某个旧版本的默认值, 用户从没改过"。
    // 命中就整串换成当前默认值, 不做逐项合并。这些常量【必须与当年发布的字符串逐字一致】,
    // 改动它们等于改变对老用户的识别结果。

    /// 0.1.3.x 的当期 UP 映射 (7 期)
    static let poolDefault_0_1_3 = "熔火灼痕:莱万汀,轻飘飘的信使:洁尔佩塔,热烈色彩:伊冯,河流的女儿:汤汤,狼珀:洛茜,春雷动，万物生:庄方宜,拳出无悔:弭弗"
    /// 0.1.3.x 的常驻六星武器名单 (含被误分类的【赤缨】)
    static let wepsDefault_0_1_3 = "宏愿,不知归,黯色火炬,扶摇,热熔切割器,显赫声名,白夜新星,大雷斑,赫拉芬格,典范,昔日精品,破碎君王,J.E.T.,骁勇,负山,同类相食,楔子,领航者,骑士精神,遗忘,爆破单元,作品：蚀迹,沧溟星梦,光荣记忆,望乡,雾中微光,灯火使命,赤缨,幻想苦痛"

    /// 0.1.1 / 0.1.2 的当期 UP 映射 (6 期, 还没有「拳出无悔:弭弗」)
    static let poolDefault_0_1_1 = "熔火灼痕:莱万汀,轻飘飘的信使:洁尔佩塔,热烈色彩:伊冯,河流的女儿:汤汤,狼珀:洛茜,春雷动，万物生:庄方宜"
    /// 0.1.1 / 0.1.2 的常驻六星武器名单 (还没有 雾中微光/灯火使命/赤缨/幻想苦痛)
    ///
    /// ★ 这一份必须收录, 否则从 0.1.1/0.1.2 直接升上来的用户会永远收不到武器名单的默认值更新:
    ///   他们盘上那串既不等于当前默认值 (少三件), 又没有赤缨可删, 于是 v0→v1 原样返回、
    ///   差量写把它当"用户自定义"永久留下 —— 正是这次要根除的那种失效模式。
    static let wepsDefault_0_1_1 = "宏愿,不知归,黯色火炬,扶摇,热熔切割器,显赫声名,白夜新星,大雷斑,赫拉芬格,典范,昔日精品,破碎君王,J.E.T.,骁勇,负山,同类相食,楔子,领航者,骑士精神,遗忘,爆破单元,作品：蚀迹,沧溟星梦,光荣记忆,望乡"

    static let legacyPoolDefaults = [poolDefault_0_1_3, poolDefault_0_1_1]
    static let legacyWepsDefaults = [wepsDefault_0_1_3, wepsDefault_0_1_1]
    /// v0 → v1 的分类修正: 从武器白名单里移除的条目 (赤缨是 1.3 上半「绛结申领」的当期 UP)
    static let wepsRemovedInV1: Set<String> = ["赤缨"]

    // MARK: - 给分析用的有效值
    //
    // 「常驻六星角色」与「常驻六星武器」是【排除法】的依据: 不在名单里 = 当期 UP。
    // 清空它们没有任何合法用途, 只会让每一件六星都判成 UP —— 武器池 UP 率恒为 100%,
    // 辉光庆典把 5 名常驻全记成限定, 界面上没有任何提示。
    // 兜底必须放在【取值处】而不是构造处: 放在 init 里的话, 用户在设置页清空后不重启就分析
    // 仍然是空的, 而 macOS 根本不读盘, 那条兜底永远不会执行。
    // (「当期 UP 角色」映射没有对应物: 空是它的合法降级形态 —— 退回常驻排除法。)
    static func effective(_ text: String, fallback: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }

    // MARK: - 迁移

    struct Result: Equatable {
        var chars: String
        var pool: String
        var weps: String
        /// 迁移是否真的改动了某个【已存在的】值 (仅供诊断/测试; 写回不依赖它 —— 见 AppConfig.init)
        var changed: Bool
    }

    /// 幂等的配置升级。三条不变量:
    ///   1. 逐字等于某个历史默认值 ⇒ 用户从没改过 ⇒ 整串换成当前默认值。
    ///   2. 用户改过 ⇒ 只做【最小必要】的修补: 补上用户没有的卡池映射 (不覆盖他自己的),
    ///      按修正表删掉分类错误的武器条目, 再补上他没有的默认条目。用户自己写的内容一律保留。
    ///   3. 被用户清空的项不去替他填回来 —— 清空是个明确的表态。
    /// 再跑一次结果不变 (幂等), 版本号落盘后也不会再跑。
    ///
    /// 已知取舍: 若用户【故意删掉】了某条默认 UP 映射, v0→v1 会把它补回来一次。
    /// 没有删除记录就无法区分"删过"与"当年还没有这条", 而版本号保证只发生这一次。
    static func migrate(chars: String?, pool: String?, weps: String?, fromVersion version: Int) -> Result {
        let outChars = chars ?? defaultChars
        var outPool  = pool  ?? defaultPool
        var outWeps  = weps  ?? defaultWeps

        if version < 1 {
            if let p = pool, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outPool = legacyPoolDefaults.contains(p)
                        ? defaultPool
                        : mergingMissingPoolEntries(into: p, from: defaultPool)
            }
            if let w = weps, !w.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 与 pool 对称: 先按修正表删掉分类错误的条目, 再补上用户没有的默认条目。
                // 只删不补的话, 将来往 defaultWeps 里新增一件常驻六星武器时, 改过名单的用户
                // 永远收不到 —— 名单里少一件, 抽到它就被记成当期 UP, 武器池 UP 率被抬高。
                outWeps = legacyWepsDefaults.contains(w)
                        ? defaultWeps
                        : mergingMissingEntries(into: removingEntries(wepsRemovedInV1, from: w),
                                                from: defaultWeps)
            }
            // chars 的默认值在 v0→v1 没有变化, 无需迁移步骤。
        }

        let changed = (chars != nil && outChars != chars!)
                   || (pool  != nil && outPool  != pool!)
                   || (weps  != nil && outWeps  != weps!)
        return Result(chars: outChars, pool: outPool, weps: outWeps, changed: changed)
    }

    // MARK: - 切分 / 合并
    //
    // ★ 这几个函数必须与 C++ 端 (AnalyzerWrapper.mm 的 ParsePoolMap / ParseCommaSeparated)
    //   逐条对齐, 否则迁移会静默做错事:
    //   - 分隔符【只认 ASCII】',' 与 ':'。全角逗号 '，'(U+FF0C) 与全角冒号 '：'(U+FF1A) 是
    //     池名/武器名的一部分 —— 「春雷动，万物生」「作品：蚀迹」都靠这一条才不被切碎。
    //   - 键值只切【第一个】冒号: "A:B:C" ⇒ 键 A、值 "B:C"。
    //   - 重复键先到先得 (C++ 用的是 emplace), 所以补充项必须【追加在后面】, 绝不能插到前面,
    //     否则会盖掉用户自己的映射。
    //   - trim 的字符集严格限定为 空格/\t/\r/\n, 与 C++ 的 TrimSV 一致。用 Swift 的
    //     .whitespaces 会额外裁掉 U+3000/U+00A0, 两边看到的键就不是同一个了。
    //   - 绝不做 Unicode 归一化: C++ 侧是 unordered_map 的精确字节查找, 而池名来自存档里
    //     未反转义、未归一化的原始 JSON 字节。

    static let asciiTrimSet = CharacterSet(charactersIn: " \t\r\n")

    /// 把 "池名:UP角色,池名:UP角色,..." 切成条目 (与 C++ ParsePoolMap 同口径)
    static func poolEntries(_ text: String) -> [(name: String, up: String)] {
        text.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { (seg: Substring) -> (name: String, up: String)? in
                guard let colon = seg.firstIndex(of: ":") else { return nil }   // 无冒号的段 C++ 也会丢弃
                let name = seg[seg.startIndex..<colon].trimmingCharacters(in: asciiTrimSet)
                let up   = seg[seg.index(after: colon)...].trimmingCharacters(in: asciiTrimSet)
                guard !name.isEmpty, !up.isEmpty else { return nil }
                return (name: name, up: up)
            }
    }

    /// 把默认映射里【用户没有的池名】追加到末尾; 用户已有的同名池一律不动。
    static func mergingMissingPoolEntries(into userText: String, from defaultsText: String) -> String {
        let existing = Set(poolEntries(userText).map { $0.name })
        let missing = poolEntries(defaultsText).filter { !existing.contains($0.name) }
        guard !missing.isEmpty else { return userText }
        return appending(missing.map { "\($0.name):\($0.up)" }, to: userText)
    }

    /// 把默认名单里【用户没有的条目】追加到末尾 (同口径, 只是没有"键:值"结构)。
    static func mergingMissingEntries(into userText: String, from defaultsText: String) -> String {
        let existing = Set(splitEntries(userText))
        let missing = splitEntries(defaultsText).filter { !$0.isEmpty && !existing.contains($0) }
        guard !missing.isEmpty else { return userText }
        return appending(missing, to: userText)
    }

    /// 从逗号分隔名单里删掉指定条目, 其余顺序原样保留。没有要删的就返回原串
    /// (返回原串很重要: 上层据此判断要不要写盘)。
    static func removingEntries(_ drop: Set<String>, from text: String) -> String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let kept = parts.filter { !drop.contains($0.trimmingCharacters(in: asciiTrimSet)) }
        guard kept.count != parts.count else { return text }
        return kept.joined(separator: ",")
    }

    private static func splitEntries(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: asciiTrimSet) }
    }

    private static func appending(_ items: [String], to userText: String) -> String {
        let tail = items.joined(separator: ",")
        let trimmed = userText.trimmingCharacters(in: asciiTrimSet)
        if trimmed.isEmpty { return tail }
        return trimmed.hasSuffix(",") ? trimmed + tail : trimmed + "," + tail
    }
}
