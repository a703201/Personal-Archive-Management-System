// ============================================================
// ams.core.family.invite · 家庭邀请的纯逻辑（FR-ACL-010 · 方案 B）
//
// 本文件**不含任何 IO / 数据库 / 加密调用**，只做「给定输入算出结果」，
// 因此可以被单元测试逐条覆盖 —— 邀请是本功能里唯一「凭一串字符就能换到
// 成员身份」的入口，它的判定规则必须有可复现的证据，而不是靠人工点一遍。
//
// 三条不可妥协的规则（见 docs/14 §3 / §7）：
//   ① 邀请码**不可猜测**：32 字符表 × 8 位 = 40 bit 熵；
//   ② 邀请**短时效 + 一次性**：默认 15 分钟 / 1 次，上限 24 小时 / 10 次；
//   ③ 失效原因对**外部统一**（不存在/过期/撤销/用尽一律同一条文案），
//      但对内必须能区分 —— 否则运维无法回答「为什么他进不来」。
//      故本文件把原因算成枚举，由调用方决定「对外说多少」。
// ============================================================
package ams.core.family

import std.collection.*

/**
 * 邀请码的字符表与判定。
 *
 * 为什么是这 32 个字符：
 *   · 去掉 `0` `1`（与 O / I / L 易混）→ 手工抄写、口头念读不出错；
 *   · 保留 `L`（因为已无 `1`，L 不再有歧义）；
 *   · 恰好 32 个 → 每位 5 bit，**8 位正好 40 bit 熵**，
 *     配合「15 分钟 + 1 次 + 5 次失败上限」，爆破成本远超收益。
 */
public class InviteCode {
    /** 字符表（32 个，无 0/1/I/O） */
    public static let ALPHABET: String = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    /** 码长度（8 位 × 5 bit = 40 bit） */
    public static let LENGTH: Int64 = 8
    /** 字符表基数 */
    private static let BASE: Int64 = 32

    /**
     * 用**外部提供的随机字节**生成邀请码。
     *
     * 为什么把随机源作为入参而不是内部调用 CSPRNG：
     *   纯函数才能被单测覆盖「给定字节 → 确定字符串」；随机源由服务层
     *   （`CryptoProvider.randomBytes`）注入，避免这里悄悄用一个弱随机。
     *
     * @param bytes 至少 LENGTH 个字节的随机数
     */
    public static func generate(bytes: Array<Byte>): String {
        if (bytes.size < LENGTH) {
            return ""
        }
        let sb = StringBuilder()
        for (i in 0..LENGTH) {
            // 取低 5 bit（0..31）映射到字符表；字节高位丢弃是有意的简化，
            // 32 与 256 不整除，用取模会引入微弱偏置，而掩码只丢信息不偏置。
            let idx = Int64(bytes[i]) & 31
            // ⚠️ `String` 下标取回的是 **UTF-8 字节（Byte）**，不是 Rune。
            //    若直接 `sb.append(ALPHABET[idx])`，会命中 `append(Int64)` 重载，
            //    把 '2'(=50) 写成字符串 "50" —— 于是产出的「邀请码」变成
            //    "5051525354555657" 这种 16 位数字串，格式校验必然不过。
            //    必须先转成 Rune 再 append（与 normalize 里的写法一致）。
            sb.append(Rune(Int32(ALPHABET[idx])))
        }
        return sb.toString()
    }

    /**
     * 规范化用户输入：去空白与连字符、转大写。
     *
     * 用户会输入 `abcd-efgh`、`abcd efgh`、带首尾空格等形态；
     * 规范化后再比对摘要，否则「码是对的但格式不同」会被判错，
     * 而失败上限只有 5 次 —— 这种误判的代价很真实。
     */
    public static func normalize(raw: String): String {
        let sb = StringBuilder()
        for (b in raw.toArray()) {
            // 空格 / 制表 / 换行 / '-' / '_' 一律丢弃
            if (b == 32 || b == 9 || b == 10 || b == 13 || b == 45 || b == 95) {
                continue
            }
            // 小写字母转大写（a-z → A-Z）
            if (b >= 97 && b <= 122) {
                sb.append(Rune(Int32(b) - 32))
            } else {
                sb.append(Rune(Int32(b)))
            }
        }
        return sb.toString()
    }

    /**
     * 格式是否合法（长度与字符集）。
     *
     * 不合法的输入应当在**查库之前**就被拒掉：否则每次乱输都打一次库，
     * 失败上限还没到，数据库先被刷。
     */
    public static func isWellFormed(code: String): Bool {
        let b = code.toArray()
        if (b.size != LENGTH) {
            return false
        }
        for (i in 0..LENGTH) {
            if (!InviteCode.charAllowed(b[i])) {
                return false
            }
        }
        return true
    }

    /** 单字符是否在字符表内（按 ASCII 码直接比对，避免建索引表）。 */
    private static func charAllowed(c: Byte): Bool {
        let v = Int64(c)
        if (v >= 50 && v <= 57) {
            return true      // '2'..'9'
        }
        if (v >= 65 && v <= 90) {
            // 'I'(73) 与 'O'(79) 不在表内
            return v != 73 && v != 79
        }
        return false
    }
}

/**
 * 邀请的失效判定结果。
 *
 * 对内区分原因（便于运维与审计），对外由调用方统一成一条文案。
 */
public enum InviteState {
    /** 可用 */
    | Usable
    /** 已撤销 */
    | Revoked
    /** 已过期 */
    | Expired
    /** 使用次数用尽 */
    | Exhausted
    /** 失败次数超限（等价于已撤销，但原因不同） */
    | TooManyFails

    /** 对外是否一律表现为「邀请无效或已过期」。 */
    public func isDead(): Bool {
        match (this) {
            case InviteState.Usable => return false
            case _ => return true
        }
    }

    /** 内部原因码（写入审计 detail，不对外暴露）。 */
    public func reason(): String {
        match (this) {
            case InviteState.Usable => return "usable"
            case InviteState.Revoked => return "revoked"
            case InviteState.Expired => return "expired"
            case InviteState.Exhausted => return "exhausted"
            case InviteState.TooManyFails => return "too_many_fails"
        }
    }
}

/**
 * 邀请有效期与次数的硬边界（docs/14 §3 原则 5）。
 */
public class InviteLimits {
    /** 默认有效期：15 分钟 */
    public static let DEFAULT_MINUTES: Int64 = 15
    /** 有效期上限：24 小时 */
    public static let MAX_MINUTES: Int64 = 1440
    /** 默认可用次数：1 次 */
    public static let DEFAULT_USES: Int64 = 1
    /** 可用次数上限：10 次 */
    public static let MAX_USES: Int64 = 10
    /** 默认失败上限：5 次 */
    public static let DEFAULT_MAX_FAILS: Int64 = 5

    /** 把外部传入的有效期钳到 [1, MAX_MINUTES]，非正数取默认值。 */
    public static func clampMinutes(v: Int64): Int64 {
        if (v <= 0) {
            return DEFAULT_MINUTES
        }
        if (v > MAX_MINUTES) {
            return MAX_MINUTES
        }
        return v
    }

    /** 把外部传入的可用次数钳到 [1, MAX_USES]，非正数取默认值。 */
    public static func clampUses(v: Int64): Int64 {
        if (v <= 0) {
            return DEFAULT_USES
        }
        if (v > MAX_USES) {
            return MAX_USES
        }
        return v
    }
}

/**
 * 一条邀请的判定快照 + 判定规则。
 *
 * 之所以把「能不能用」算成纯函数，是因为它同时被三个入口使用：
 *   ① 落地页元数据（`GET /api/family/invites/:token`）
 *   ② 接受邀请（`POST /api/family/invites/accept`）
 *   ③ 邀请列表展示（owner 看到「还剩几次 / 已失效」）
 * 三处若各写一遍，必然出现「列表显示有效但接受时报无效」这类不一致。
 */
public class InviteSnapshot {
    public let revoked: Bool
    public let expiresMs: Int64
    public let usedCount: Int64
    public let maxUses: Int64
    public let failCount: Int64
    public let maxFails: Int64

    public init(
        revoked: Bool,
        expiresMs: Int64,
        usedCount: Int64,
        maxUses: Int64,
        failCount: Int64,
        maxFails: Int64
    ) {
        this.revoked = revoked
        this.expiresMs = expiresMs
        this.usedCount = usedCount
        this.maxUses = maxUses
        this.failCount = failCount
        this.maxFails = maxFails
    }

    /**
     * 判定当前状态。
     *
     * 顺序有意为之：撤销 > 失败超限 > 过期 > 用尽。
     * 撤销是最强的否定（人工介入过），排在最前，避免「已撤销」被
     * 报成「已过期」而误导排查方向。
     */
    public func stateAt(nowMs: Int64): InviteState {
        if (this.revoked) {
            return InviteState.Revoked
        }
        if (this.maxFails > 0 && this.failCount >= this.maxFails) {
            return InviteState.TooManyFails
        }
        if (this.expiresMs > 0 && nowMs >= this.expiresMs) {
            return InviteState.Expired
        }
        if (this.usedCount >= this.maxUses) {
            return InviteState.Exhausted
        }
        return InviteState.Usable
    }

    /** 剩余可用次数（已失效时为 0）。 */
    public func remainingUses(nowMs: Int64): Int64 {
        if (this.stateAt(nowMs).isDead()) {
            return 0
        }
        let left = this.maxUses - this.usedCount
        return if (left < 0) { 0 } else { left }
    }
}

/**
 * 组内角色（与全局 RBAC 解耦，绝不写入 sys_user_roles）。
 */
public enum FamilyRole {
    | Owner
    | Manager
    | Member

    public func code(): String {
        match (this) {
            case FamilyRole.Owner => return "owner"
            case FamilyRole.Manager => return "manager"
            case FamilyRole.Member => return "member"
        }
    }

    /** 未知角色一律降级为 Member（**最小权限**，不是最宽松）。 */
    public static func fromCode(code: String): FamilyRole {
        match (code) {
            case "owner" => return FamilyRole.Owner
            case "manager" => return FamilyRole.Manager
            case _ => return FamilyRole.Member
        }
    }

    /** 能否创建/撤销邀请。 */
    public func canInvite(): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case FamilyRole.Manager => return true
            case FamilyRole.Member => return false
        }
    }

    /** 能否创建/撤销数据授权。 */
    public func canGrant(): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case FamilyRole.Manager => return true
            case FamilyRole.Member => return false
        }
    }

    /**
     * 能否移除成员。
     *
     * Manager **不能**移除 Owner，也不能移除其他 Manager
     * —— 否则一个被提升的成员可以把整组人踢掉再独吞。
     *
     * 注：仓颉的自定义枚举没有内建 `==`，这里用嵌套 match 而不是
     * 比较运算符（写 `target == FamilyRole.Member` 会编译不过）。
     */
    public func canRemove(target: FamilyRole): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case FamilyRole.Manager =>
                match (target) {
                    case FamilyRole.Member => return true
                    case _ => return false
                }
            case FamilyRole.Member => return false
        }
    }

    /** 是否是组所有者。 */
    public func isOwner(): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case _ => return false
        }
    }

    /** 能否解散组（仅 Owner）。 */
    public func canDissolve(): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case _ => return false
        }
    }

    /** 是否能指定他人为 Manager（仅 Owner）。 */
    public func canPromote(): Bool {
        match (this) {
            case FamilyRole.Owner => return true
            case _ => return false
        }
    }
}

/**
 * 授权范围（docs/15 §3 方案 B：主体 + 条目；分类只作同主体内收窄）。
 */
public class GrantScope {
    /**
     * 由「条目 ID / 分类码」推导资源类型。
     *
     * 三者优先级：条目 > 分类 > 主体。
     * 语义与 `Grant.covers()` 完全一致 —— 条目级命中即放行（不再看主体），
     * 分类级与主体级都要求同主体。
     */
    public static func resourceTypeOf(itemId: String, category: Int64): String {
        if (!itemId.isEmpty() && itemId != "0") {
            return "item"
        }
        if (category > 0) {
            return "category"
        }
        return "subject"
    }

    /**
     * 分类值规范化：`< 0` 视为「不限分类」= 0。
     *
     * 为什么把负数归零而不是拒绝：外部接口用「不传 / 传 0」表示不限，
     * 负数属于调用方笔误；归零后语义仍是「主体级」，是**更宽**的授权，
     * 但授权人本来就有该主体的权限，不构成越权。
     * 真正的越权校验在 FamilyService 里按资源归属做。
     */
    public static func normalizeCategory(category: Int64): Int64 {
        if (category < 0) {
            return 0
        }
        return category
    }
}

/**
 * 权限码子集判定（docs/14 §3 原则 9「不越权授权」）。
 */
public class PermSubset {
    /**
     * 授出集合是否被授权人自身的集合覆盖。
     *
     * 规则：
     *   · 逐个被授出的码，必须在授权人集合里**精确存在**，或
     *     其 `any` 变体存在（any 覆盖 own）；
     *   · 空集合视为非法（不允许「授出一片空白」的授权记录）。
     */
    public static func isSubsetOf(granted: Array<String>, grantor: Array<String>): Bool {
        if (granted.isEmpty()) {
            return false
        }
        let grantorSet = HashSet<String>()
        for (p in grantor) {
            grantorSet.add(p)
        }
        for (p in granted) {
            if (grantorSet.contains(p)) {
                continue
            }
            // 尝试 any 变体：把最后一段范围替换为 any
            let anyVariant = PermSubset.anyVariant(p)
            if (!anyVariant.isEmpty() && grantorSet.contains(anyVariant)) {
                continue
            }
            return false
        }
        return true
    }

    /**
     * 取 `域:动作:范围` 的 any 变体（`域:动作:any`）。
     *
     * 只有形如 `a:b:c` 的三段式才有变体；其余原样返回空串表示「无变体」。
     */
    private static func anyVariant(code: String): String {
        let parts = code.split(":")
        if (parts.size != 3) {
            return ""
        }
        return "${parts[0]}:${parts[1]}:any"
    }
}
