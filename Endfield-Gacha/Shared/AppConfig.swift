//
//  AppConfig.swift
//  Endfield-Gacha
//
//  跨平台共享配置:常驻角色 / 当期 UP / 常驻武器
//  - iOS: 通过 SettingsView 修改并持久化到 UserDefaults
//  - macOS: ContentView 接入同一个 AppConfig 进行编辑/读取(单一默认值来源),
//           但本期不做持久化,改动仅在本次运行有效(重启回到默认值)
//
//  @Observable 让 SwiftUI 自动追踪字段变化,
//  设置页改完分析页能立即拿到新值。
//

import SwiftUI

@Observable
final class AppConfig {
    var chars: String
    var pool:  String
    var weps:  String

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
    static let defaultPool  = "熔火灼痕:莱万汀,轻飘飘的信使:洁尔佩塔,热烈色彩:伊冯,河流的女儿:汤汤,狼珀:洛茜,春雷动，万物生:庄方宜,拳出无悔:弭弗,逐罪者:卡缪,临渊望北:诀,晨星于此闪耀:梨诺,冬猎:提弗洛斯,绚丽异彩:伊冯"

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
    static let defaultWeps  = "宏愿,不知归,黯色火炬,扶摇,热熔切割器,显赫声名,白夜新星,大雷斑,赫拉芬格,典范,昔日精品,破碎君王,J.E.T.,骁勇,负山,同类相食,楔子,领航者,骑士精神,遗忘,爆破单元,作品：蚀迹,沧溟星梦,光荣记忆,望乡,雾中微光,灯火使命,幻想苦痛"

    init() {
        let d = UserDefaults.standard
        self.chars = d.string(forKey: "cfg.chars") ?? Self.defaultChars
        self.pool  = d.string(forKey: "cfg.pool")  ?? Self.defaultPool
        self.weps  = d.string(forKey: "cfg.weps")  ?? Self.defaultWeps
    }

    /// 把当前配置写回 UserDefaults。
    /// 调用时机:Settings Tab 退出 / App 进入后台。
    func persist() {
        let d = UserDefaults.standard
        d.set(chars, forKey: "cfg.chars")
        d.set(pool,  forKey: "cfg.pool")
        d.set(weps,  forKey: "cfg.weps")
    }
}
