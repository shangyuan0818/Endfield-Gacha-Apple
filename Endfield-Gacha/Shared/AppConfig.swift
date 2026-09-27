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
//  ★ 内置数据与迁移/切分合并的【纯逻辑】不在本文件, 全在 AppConfigMigration.swift ——
//    那一半只依赖 Foundation, 于是 Tests/app_config_tests.swift 能直接编译运行同一份实现,
//    而不是抄一份副本(抄本会随时间漂移, 测试通过也证明不了 App 的行为)。
//    本文件只留【有状态】的部分: UserDefaults 读写、平台开关、@Observable 属性。
//

import SwiftUI

@Observable
final class AppConfig {
    var chars: String
    var pool:  String
    var weps:  String

    // MARK: - 内置默认值(转发)
    //
    // 唯一定义在 AppConfigMigration。这里只做转发, 让 SettingsView 的「恢复默认」按钮
    // 等调用点继续写 AppConfig.defaultChars —— 但绝不在这里再抄一份字符串字面量。

    static var defaultChars: String { AppConfigMigration.defaultChars }
    static var defaultPool:  String { AppConfigMigration.defaultPool }
    static var defaultWeps:  String { AppConfigMigration.defaultWeps }

    /// 配置结构版本, 见 AppConfigMigration.currentSchemaVersion。
    static var currentSchemaVersion: Int { AppConfigMigration.currentSchemaVersion }

    // MARK: - 给分析用的有效值
    //
    // 「常驻六星角色」与「常驻六星武器」是【排除法】的依据: 不在名单里 = 当期 UP。
    // 清空它们没有任何合法用途, 只会让每一件六星都判成 UP —— 武器池 UP 率恒为 100%,
    // 辉光庆典把 5 名常驻全记成限定, 界面上没有任何提示。
    // 兜底必须放在【取值处】而不是构造处: 放在 init 里的话, 用户在设置页清空后不重启就分析
    // 仍然是空的, 而 macOS 根本不读盘 (persistenceEnabled == false), 那条兜底永远不会执行。
    // 分析调用点一律读这两个属性, 不要直接读 chars / weps。
    // (「当期 UP 角色」映射没有对应物: 空是它的合法降级形态 —— 退回常驻排除法。)
    var effectiveChars: String {
        AppConfigMigration.effective(chars, fallback: AppConfigMigration.defaultChars)
    }
    var effectiveWeps: String {
        AppConfigMigration.effective(weps, fallback: AppConfigMigration.defaultWeps)
    }

    // MARK: - 存储

    private enum Keys {
        static let chars  = "cfg.chars"
        static let pool   = "cfg.pool"
        static let weps   = "cfg.weps"
        static let schema = "cfg.schemaVersion"
    }

    /// macOS 不做配置持久化 (ContentView 与 Endfield_GachaApp 的注释都是这么承诺的:
    /// 改动只在本次运行有效, 重启回到默认值)。把这条做成单点可查的开关, 迁移/写回代码
    /// 就不需要各自记得加平台判断 —— 漏加一处就会让 macOS 悄悄开始持久化, 此后每次版本
    /// 更新的新 UP 映射对 macOS 用户都不可见, 而 macOS 端连"恢复默认"按钮都没有。
    static let persistenceEnabled: Bool = {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }()

    init() {
        let d = UserDefaults.standard
        // 显式标注类型: `cond ? optional : nil` 的三元表达式在推断上容易出问题, 不去赌它。
        let storedChars: String? = Self.persistenceEnabled ? d.string(forKey: Keys.chars) : nil
        let storedPool:  String? = Self.persistenceEnabled ? d.string(forKey: Keys.pool)  : nil
        let storedWeps:  String? = Self.persistenceEnabled ? d.string(forKey: Keys.weps)  : nil
        // 键缺失时 integer(forKey:) 返回 0 = 版本 v0。macOS 不读盘, 直接当作已是最新版本。
        let storedVersion: Int = Self.persistenceEnabled ? d.integer(forKey: Keys.schema)
                                                         : AppConfigMigration.currentSchemaVersion

        let m = AppConfigMigration.migrate(chars: storedChars, pool: storedPool, weps: storedWeps,
                                           fromVersion: storedVersion)
        self.chars = m.chars
        self.pool  = m.pool
        self.weps  = m.weps

        // 只有【确实存过东西】的安装才写回。全新安装 / macOS 上没有任何 cfg.* 键,
        // 这里一个字节都不写, 于是"缺键 == 跟随默认值", 未来的默认值更新自动生效。
        //
        // 走 static 版本而不是调用实例方法 persist(): init 里调实例方法要求 self 已完全初始化,
        // 而 @Observable 把这三个属性变成了计算属性 —— 不必去赌宏展开后的初始化时序。
        // 不加 `if m.changed` 这道条件: 即使迁移一个字都没改, 也要跑一次差量写 —— 它会把
        // "内容恰好等于当前默认值"的冗余键删掉, 从而真正建立起"缺键 == 跟随默认值"这个不变量。
        // 少了这一步, 那批用户的 schemaVersion 已经被盖成 1, 以后的默认值更新对他们永远不可见。
        guard Self.persistenceEnabled,
              storedChars != nil || storedPool != nil || storedWeps != nil else { return }
        Self.writeBack(chars: m.chars, pool: m.pool, weps: m.weps)
    }

    // MARK: - 写回

    /// 把当前配置写回 UserDefaults。
    /// 调用时机:Settings Tab 退出 / App 进入后台。
    ///
    /// v0.1.4.2 改为差量写: 值等于当前默认值就把键【删掉】而不是存下来。
    /// 旧写法无条件全量写, 于是任何一次切后台都会把"当时版本的默认值"快照进 UserDefaults ——
    /// 用户根本没进过设置页, 磁盘上却已经有了一份旧默认值, 而且在字节层面与"用户自定义"
    /// 无法区分。结果是此后每次版本更新的新 UP 映射对老用户 100% 不可见。
    /// 改成差量写之后,"缺键"重新等价于"跟随默认值", 默认值更新自动生效。
    func persist() {
        Self.writeBack(chars: chars, pool: pool, weps: weps)
    }

    /// 差量写的实际实现 (init 与 persist 共用)。
    /// 值等于当前默认值 ⇒ 删键; 只有真正被改过的键才落盘。
    private static func writeBack(chars: String, pool: String, weps: String) {
        guard persistenceEnabled else { return }
        let d = UserDefaults.standard
        func put(_ value: String, _ key: String, default def: String) {
            if value == def { d.removeObject(forKey: key) } else { d.set(value, forKey: key) }
        }
        put(chars, Keys.chars, default: AppConfigMigration.defaultChars)
        put(pool,  Keys.pool,  default: AppConfigMigration.defaultPool)
        put(weps,  Keys.weps,  default: AppConfigMigration.defaultWeps)
        // 版本号【只向上写】。用户从更高版本回退 (TestFlight 回滚 / 来回装) 时, 盘上的版本
        // 可能比本版还高; 盖低之后, 那些已经跑过的高版本迁移步骤会在再次升级时重跑一遍,
        // 而"用户故意删掉的默认映射只补回来一次"这条取舍正是挂在版本号上的。
        if d.integer(forKey: Keys.schema) < AppConfigMigration.currentSchemaVersion {
            d.set(AppConfigMigration.currentSchemaVersion, forKey: Keys.schema)
        }
    }
}
