//
//  app_config_tests.swift
//  Endfield-Gacha 回归测试
//
//  测的是 Endfield-Gacha/Shared/AppConfigMigration.swift 【本体】(run.sh 直接把它一起编译),
//  不是副本。App 那一半 (AppConfig.swift) 只负责读写 UserDefaults, 逻辑全在这里。
//
//  跑法: Tests/run.sh (有 swiftc 才跑), 或
//        swiftc -o /tmp/t Endfield-Gacha/Shared/AppConfigMigration.swift Tests/app_config_tests.swift && /tmp/t
//

import Foundation

private var failures = 0
private var checks = 0

private func check(_ cond: Bool, _ what: String,
                   file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !cond {
        failures += 1
        print("FAIL [\(line)] \(what)")
    }
}

private func checkEq(_ got: String, _ want: String, _ what: String,
                     file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if got != want {
        failures += 1
        print("FAIL [\(line)] \(what)")
        print("     得到: \(got)")
        print("     期望: \(want)")
    }
}

private typealias M = AppConfigMigration

// MARK: - 内置数据本身的不变量
//
// 这些是「数据录入错误」的护栏 —— 名单的语义是"不在名单里 ⇒ 当期 UP", 错一条就系统性地
// 歪曲某个池的 UP 率, 而 App 里没有任何提示。

private func testBuiltinData() {
    let weps = M.defaultWeps.split(separator: ",").map(String.init)
    check(!weps.contains("赤缨"),
          "赤缨是 1.3 上半「绛结申领」的当期 UP, 不能出现在常驻武器白名单里")
    check(Set(weps).count == weps.count, "defaultWeps 不应有重复条目")
    check(weps.allSatisfy { !$0.isEmpty }, "defaultWeps 不应有空条目")

    // 限定武器(只作为某期 UP 出现)一律不得进白名单。
    for limited in ["熔铸火焰", "艺术暴君", "使命必达", "落草", "狼之绯", "孤舟",
                    "镀红祝福", "四二式·肃阵", "曜夜的首演", "寒夜幽影"] {
        check(!weps.contains(limited), "限定武器【\(limited)】不该在常驻白名单里")
    }

    let pool = M.poolEntries(M.defaultPool)
    check(pool.count == 12, "当前内置 UP 映射应有 12 期, 实际 \(pool.count)")
    check(Set(pool.map { $0.name }).count == pool.count, "卡池名不应重复")
    // 「绚丽异彩」是伊冯的复刻(重构寻访), 与 1.0 的原池「热烈色彩」并列, 两条都要在。
    check(pool.contains { $0.name == "绚丽异彩" && $0.up == "伊冯" }, "缺少重构寻访「绚丽异彩:伊冯」")
    check(pool.contains { $0.name == "热烈色彩" && $0.up == "伊冯" }, "缺少原池「热烈色彩:伊冯」")
    // 全角逗号必须留在池名里 —— 切碎了就永远匹配不上存档里的池名。
    check(pool.contains { $0.name == "春雷动，万物生" && $0.up == "庄方宜" },
          "「春雷动，万物生」被全角逗号切碎了")

    let chars = M.defaultChars.split(separator: ",").map(String.init)
    check(chars.count == 5, "常驻六星角色恒为 5 人, 实际 \(chars.count)")
}

// MARK: - 切分 (必须与 C++ ParsePoolMap / ParseCommaSeparated 逐条对齐)

private func testPoolEntries() {
    // 只切【第一个】冒号
    let e1 = M.poolEntries("A:B:C")
    check(e1.count == 1 && e1[0].name == "A" && e1[0].up == "B:C", "键值只切第一个冒号")

    // 无冒号的段丢弃 (C++ 侧同样丢弃)
    let e2 = M.poolEntries("没有冒号,A:B")
    check(e2.count == 1 && e2[0].name == "A", "无冒号的段应丢弃")

    // 空键 / 空值丢弃
    check(M.poolEntries(":B").isEmpty, "空键应丢弃")
    check(M.poolEntries("A:").isEmpty, "空值应丢弃")
    check(M.poolEntries("").isEmpty, "空串没有条目")
    check(M.poolEntries(",,,").isEmpty, "全是分隔符时没有条目")

    // 全角冒号不是分隔符
    check(M.poolEntries("作品：蚀迹").isEmpty, "全角冒号 U+FF1A 不是分隔符")
    let e3 = M.poolEntries("作品：蚀迹:某人")
    check(e3.count == 1 && e3[0].name == "作品：蚀迹" && e3[0].up == "某人",
          "全角冒号必须留在池名里")

    // trim 只认 ASCII 空白: U+3000(全角空格) 是名字的一部分
    let e4 = M.poolEntries(" \t池名\r\n : \tUP ")
    check(e4.count == 1 && e4[0].name == "池名" && e4[0].up == "UP", "ASCII 空白应被裁掉")
    let e5 = M.poolEntries("\u{3000}池名:UP")
    check(e5.count == 1 && e5[0].name == "\u{3000}池名",
          "U+3000 不该被裁掉 —— 裁了就与 C++ 端 TrimSV 看到的键不是同一个")
    let e6 = M.poolEntries("\u{00A0}池名:UP")
    check(e6.count == 1 && e6[0].name == "\u{00A0}池名", "U+00A0 不该被裁掉")
}

// MARK: - 合并 / 删除

private func testMerging() {
    // 用户已有的同名池一律不动, 缺的【追加在末尾】(C++ 重复键先到先得, 插到前面会盖掉用户的)
    checkEq(M.mergingMissingPoolEntries(into: "冬猎:我改的", from: "冬猎:提弗洛斯,狼珀:洛茜"),
            "冬猎:我改的,狼珀:洛茜",
            "同名池保留用户的值, 缺的追加在后面")

    // 一条都不缺 ⇒ 原样返回 (上层据此判断要不要写盘)
    checkEq(M.mergingMissingPoolEntries(into: "A:1,B:2", from: "B:9"), "A:1,B:2",
            "没有缺项时应原样返回")

    // 尾部已有逗号时不重复加逗号
    checkEq(M.mergingMissingPoolEntries(into: "A:1,", from: "B:2"), "A:1,B:2", "尾逗号不重复")
    // 尾部空白 + 逗号
    checkEq(M.mergingMissingPoolEntries(into: "A:1, \n", from: "B:2"), "A:1,B:2", "尾部空白先裁掉")
    // 空串 ⇒ 直接就是补充项
    checkEq(M.mergingMissingPoolEntries(into: "", from: "B:2"), "B:2", "空串合并后就是补充项")

    // 无结构名单
    checkEq(M.mergingMissingEntries(into: "宏愿", from: "宏愿,扶摇"), "宏愿,扶摇", "补齐缺的武器")
    checkEq(M.mergingMissingEntries(into: "扶摇,宏愿", from: "宏愿,扶摇"), "扶摇,宏愿",
            "用户的顺序不动")
    checkEq(M.mergingMissingEntries(into: " 宏愿 ", from: "宏愿"), " 宏愿 ",
            "带空白也算已有, 不重复追加也不改写用户原文")

    // 删除
    checkEq(M.removingEntries(["赤缨"], from: "宏愿,赤缨,扶摇"), "宏愿,扶摇", "删掉指定条目")
    checkEq(M.removingEntries(["赤缨"], from: "宏愿, 赤缨 ,扶摇"), "宏愿,扶摇", "带空白也能删掉")
    checkEq(M.removingEntries(["赤缨"], from: "宏愿,扶摇"), "宏愿,扶摇", "没命中时原样返回")
    checkEq(M.removingEntries([], from: "宏愿,扶摇"), "宏愿,扶摇", "空删除集原样返回")
}

// MARK: - 迁移

private func testMigrateFreshInstall() {
    let r = M.migrate(chars: nil, pool: nil, weps: nil, fromVersion: 0)
    checkEq(r.chars, M.defaultChars, "全新安装拿当前默认角色")
    checkEq(r.pool,  M.defaultPool,  "全新安装拿当前默认映射")
    checkEq(r.weps,  M.defaultWeps,  "全新安装拿当前默认武器名单")
    check(!r.changed, "全新安装没有【已存在的值】被改动 ⇒ changed 为 false")
}

private func testMigrateLegacyDefaults() {
    // 逐字等于某个历史默认值 ⇒ 用户从没改过 ⇒ 整串换成当前默认值
    let r13 = M.migrate(chars: M.defaultChars, pool: M.poolDefault_0_1_3,
                        weps: M.wepsDefault_0_1_3, fromVersion: 0)
    checkEq(r13.pool, M.defaultPool, "0.1.3 默认映射应整串升级")
    checkEq(r13.weps, M.defaultWeps, "0.1.3 默认武器名单应整串升级(含删掉赤缨)")
    check(r13.changed, "0.1.3 升级确实改动了值")

    let r11 = M.migrate(chars: M.defaultChars, pool: M.poolDefault_0_1_1,
                        weps: M.wepsDefault_0_1_1, fromVersion: 0)
    checkEq(r11.pool, M.defaultPool, "0.1.1 默认映射应整串升级")
    // ★ 这条是 wepsDefault_0_1_1 必须登记在案的理由: 它既不等于当前默认值(少三件),
    //   又没有赤缨可删。不登记的话 v0→v1 原样返回, 差量写会把它当"用户自定义"永久留下,
    //   此后所有默认值更新对这批用户都不可见。
    checkEq(r11.weps, M.defaultWeps, "0.1.1 默认武器名单应整串升级")

    // 顺带确认「池映射那个巧合」仍然成立 —— 就算不走 legacy 整串替换, 补齐缺项后也逐字相同。
    // (不能指望这种巧合, 所以两份 legacy 都登记了; 这条只是把巧合钉住, 坏了也不影响正确性。)
    checkEq(M.mergingMissingPoolEntries(into: M.poolDefault_0_1_1, from: M.defaultPool),
            M.defaultPool, "0.1.1 池映射补齐后恰好等于当前默认值")
}

private func testMigrateUserEdited() {
    // 用户改过 ⇒ 只做最小必要修补, 自己写的一律保留
    let userPool = "冬猎:我自己填的,我的私房池:某人"
    let r = M.migrate(chars: nil, pool: userPool, weps: nil, fromVersion: 0)
    check(r.pool.hasPrefix(userPool), "用户改过的映射必须原样保留在最前面")
    let got = M.poolEntries(r.pool)
    check(got.first { $0.name == "冬猎" }?.up == "我自己填的", "用户的同名池不被默认值覆盖")
    check(got.contains { $0.name == "我的私房池" }, "用户自己加的池不被删掉")
    // 默认里有而用户没有的, 全部补齐
    for d in M.poolEntries(M.defaultPool) where d.name != "冬猎" {
        check(got.contains { $0.name == d.name }, "缺的默认池【\(d.name)】应补齐")
    }

    // 武器: 先删分类错误的, 再补用户没有的
    let userWeps = "宏愿,赤缨,我自己加的武器"
    let rw = M.migrate(chars: nil, pool: nil, weps: userWeps, fromVersion: 0)
    let wepList = rw.weps.split(separator: ",").map(String.init)
    check(!wepList.contains("赤缨"), "v0→v1 应删掉误分类的赤缨")
    check(wepList.contains("我自己加的武器"), "用户自己加的武器必须保留")
    check(wepList.first == "宏愿", "用户的顺序不动")
    for d in M.defaultWeps.split(separator: ",").map(String.init) {
        check(wepList.contains(d), "缺的默认武器【\(d)】应补齐")
    }
}

private func testMigrateEmptyStaysEmpty() {
    // 被用户清空的项不去替他填回来 —— 清空是个明确的表态(兜底在取值处 effective())。
    let r = M.migrate(chars: "", pool: "", weps: "", fromVersion: 0)
    checkEq(r.pool, "", "清空的映射保持为空")
    checkEq(r.weps, "", "清空的名单保持为空")
    check(!r.changed, "什么都没改 ⇒ changed 为 false")

    let rws = M.migrate(chars: nil, pool: "  \n ", weps: " \t ", fromVersion: 0)
    checkEq(rws.pool, "  \n ", "纯空白也算清空, 原样保留")
    checkEq(rws.weps, " \t ", "纯空白也算清空, 原样保留")
}

private func testMigrateAtCurrentVersion() {
    // 版本号落盘后不再跑迁移步骤 —— 包括那条"故意删掉的默认映射只补回来一次"的取舍。
    let userPool = "冬猎:我自己填的"
    let userWeps = "宏愿,赤缨"
    let r = M.migrate(chars: "自定义", pool: userPool, weps: userWeps,
                      fromVersion: M.currentSchemaVersion)
    checkEq(r.chars, "自定义", "已是最新版本时原样返回")
    checkEq(r.pool, userPool, "已是最新版本时不补默认映射")
    checkEq(r.weps, userWeps, "已是最新版本时不动武器名单(赤缨也不删)")
    check(!r.changed, "已是最新版本时 changed 为 false")

    // 比当前版本还高(用户从更高版本回退)同样不跑
    let rhi = M.migrate(chars: nil, pool: userPool, weps: userWeps,
                        fromVersion: M.currentSchemaVersion + 5)
    checkEq(rhi.pool, userPool, "版本更高时不跑迁移")
}

private func testMigrateIdempotent() {
    // 再跑一次结果必须不变 —— 否则一次崩溃/中断就可能把补充项叠加两遍。
    let cases: [(String?, String?, String?)] = [
        (nil, nil, nil),
        (M.defaultChars, M.poolDefault_0_1_3, M.wepsDefault_0_1_3),
        (M.defaultChars, M.poolDefault_0_1_1, M.wepsDefault_0_1_1),
        ("自定义角色", "冬猎:我自己填的,我的私房池:某人", "宏愿,赤缨,我自己加的武器"),
        ("", "", ""),
        (nil, "A:1,", "宏愿,"),
    ]
    for (i, c) in cases.enumerated() {
        let once = M.migrate(chars: c.0, pool: c.1, weps: c.2, fromVersion: 0)
        let twice = M.migrate(chars: once.chars, pool: once.pool, weps: once.weps, fromVersion: 0)
        checkEq(twice.pool, once.pool, "用例 \(i): 迁移映射必须幂等")
        checkEq(twice.weps, once.weps, "用例 \(i): 迁移武器名单必须幂等")
        checkEq(twice.chars, once.chars, "用例 \(i): 迁移角色必须幂等")
        check(!twice.changed, "用例 \(i): 第二次迁移不应再改动任何值")
    }
}

private func testChangedFlag() {
    // changed 只描述【已存在的值】有没有被改动 —— nil(缺键) 填上默认值不算"改动"。
    check(!M.migrate(chars: nil, pool: nil, weps: nil, fromVersion: 0).changed,
          "缺键填默认值不算改动")
    check(M.migrate(chars: nil, pool: M.poolDefault_0_1_3, weps: nil, fromVersion: 0).changed,
          "历史默认值被替换 ⇒ changed")
    check(!M.migrate(chars: nil, pool: M.defaultPool, weps: nil, fromVersion: 0).changed,
          "已经是当前默认值 ⇒ 无改动")
}

// MARK: - 取值处兜底

private func testEffective() {
    checkEq(M.effective("", fallback: M.defaultChars), M.defaultChars, "空串走兜底")
    checkEq(M.effective("   \n\t ", fallback: M.defaultChars), M.defaultChars, "纯空白走兜底")
    checkEq(M.effective("\u{3000}", fallback: M.defaultChars), M.defaultChars,
            "全角空格也算空白(这里用的是 .whitespacesAndNewlines, 与切分口径不同, 是有意的)")
    checkEq(M.effective("我的名单", fallback: M.defaultChars), "我的名单", "非空原样返回")
}

// MARK: -

@main
struct AppConfigTests {
    static func main() {
        testBuiltinData()
        testPoolEntries()
        testMerging()
        testMigrateFreshInstall()
        testMigrateLegacyDefaults()
        testMigrateUserEdited()
        testMigrateEmptyStaysEmpty()
        testMigrateAtCurrentVersion()
        testMigrateIdempotent()
        testChangedFlag()
        testEffective()

        if failures == 0 {
            print("app_config_tests: 全部通过 (\(checks) 项)")
        } else {
            print("app_config_tests: \(failures)/\(checks) 项失败")
            exit(1)
        }
    }
}
