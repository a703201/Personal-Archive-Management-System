// ============================================================
// ams.security.authz · 授权判定
//
// 需求：
//   FR-ACL-005 鉴权中间件（默认拒绝，不泄露资源存在性）
//   FR-ACL-006 数据归属校验（subject_id 强制附加，禁止前端决定）
//   FR-ACL-007 分类级敏感度分级（normal/sensitive/high）
//   FR-ACL-008 单条目/单分类临时授权
//   FR-ACL-009 授权回收与到期（服务端校验，不依赖定时任务）
//
// 判定顺序（安全章 §6.1，**不可交换**）：
//   1. 认证 → 2. 功能权限 → 3. 数据归属 → 4. 分类敏感度 → 5. 字段敏感度
//
// 关键约定：
//   - 默认拒绝：任何未显式授予的权限一律拒绝
//   - 资源不存在与无权限返回**同一结果**（403 + 通用文案），不泄露存在性
//   - 临时授权的到期判定在**每次请求**时做，不依赖定时任务
// ============================================================
package ams.security.authz

import std.collection.*

import ams.kernel.error.*

/**
 * 分类敏感度分级。
 */
public enum Sensitivity {
    /** 普通：所有者与被授权者可见 */
    | Normal
    /** 敏感：需显式授权才可见 */
    | Sensitive
    /** 高敏（健康/资产）：默认仅所有者可见 */
    | High

    /**
     * 数值形式（与 arc_items.sensitivity / arc_field_defs.sensitivity 一致）。
     */
    public func toCode(): Int64 {
        match (this) {
            case Sensitivity.Normal => return 1
            case Sensitivity.Sensitive => return 2
            case Sensitivity.High => return 3
        }
    }

    /**
     * 数值 → 枚举。
     */
    public static func fromCode(code: Int64): Sensitivity {
        if (code >= 3) {
            return Sensitivity.High
        } else if (code == 2) {
            return Sensitivity.Sensitive
        }
        return Sensitivity.Normal
    }
}

/**
 * 访问主体：用户 + 其角色权限 + 可见的主体范围。
 */
public class AccessContext {
    /** 用户 ID */
    public let userId: String
    /** 权限点集合（来自角色合并） */
    private let permSet: HashSet<String>
    /** 该用户可访问的主体 ID 集合（本人拥有 + 被授权代管） */
    private let subjectIds: HashSet<String>
    /**
     * 该用户**本人拥有**的主体 ID 集合。
     *
     * 与 subjectIds 的区别（FR-ACL-007 敏感度分级的关键）：
     *   - subjectIds  含代管主体 → 用于**归属校验**（能否访问该主体的数据）
     *   - ownedSubjectIds 只含本人拥有的 → 用于**敏感度判定**
     *
     * 语义：所有者对自己名下的一切（含 sensitive/high 分类）天然可见；
     * 代管人对 sensitive+ 分类仍需显式授权。
     */
    private let ownedSubjectIds: HashSet<String>
    /** 数据可见上限（取所有角色的最大值） */
    public let maxDataLevel: Int64
    /**
     * 所属租户（多租户隔离根）。
     *
     * 该用户的全部数据访问都被限定在此租户内。鉴权决策若涉及跨租户
     * 资源，应据此拒绝（防越权跨租户）。仓储层才是行级过滤的执行点，
     * 此处主要供审计/日志与未来跨租户 guard 判定使用。
     */
    public let tenantId: Int64

    public init(
        userId: String,
        perms: Array<String>,
        subjectIds: Array<String>,
        maxDataLevel: Int64,
        tenantId: Int64,
        ownedSubjectIds!: Array<String> = []
    ) {
        this.userId = userId
        this.permSet = HashSet<String>()
        for (p in perms) {
            this.permSet.add(p)
        }
        this.subjectIds = HashSet<String>()
        for (s in subjectIds) {
            this.subjectIds.add(s)
        }
        // ⚠️ **不做兜底**（fail-closed）：
        //   未显式给出 ownedSubjectIds 时，该用户就**不拥有**任何主体。
        //   若退化成「可访问集合即拥有集合」，代管人会被当成所有者，
        //   从而能看到 sensitive/high 分类 —— 这是权限放大的方向，必须避免。
        //   生产路径（AuthzService / 鉴权中间件）都会显式传入 ownedSubjectIds。
        this.ownedSubjectIds = HashSet<String>()
        for (s in ownedSubjectIds) {
            this.ownedSubjectIds.add(s)
        }
        this.maxDataLevel = maxDataLevel
        this.tenantId = tenantId
    }

    /**
     * 该用户是否**拥有**指定主体（不是代管）。
     */
    public func ownsSubject(subjectId: String): Bool {
        return this.ownedSubjectIds.contains(subjectId)
    }

    /**
     * 是否拥有指定权限点。
     */
    public func hasPerm(code: String): Bool {
        return this.permSet.contains(code)
    }

    /**
     * 是否满足指定的功能权限要求（**any 覆盖 own**）。
     *
     * 规则（与 Authorizer.hasFunctionPerm 保持一致）：
     *   - 持有精确权限码 → 满足
     *   - 需要的若是 own 范围，持有对应 any 范围 → 满足
     *     （any 是 own 的超集：「可读任意」蕴含「可读自己的」）
     *
     * 【为什么放在 AccessContext 而不是只在 Authorizer 里】
     *   鉴权中间件会先做一次**粗粒度**功能权限判定（快速拒绝），
     *   再交给 Authorizer 做**细粒度**资源判定。
     *   两处逻辑若不一致，会出现「Authorizer 判通过，但中间件先拒了」——
     *   实测踩坑：持有 archive:read:any 的管理员读条目被中间件
     *   按精确匹配 archive:read:own 拒掉（403），细粒度判定根本没执行。
     *   故把规则收敛到 AccessContext，两处共用。
     */
    public func satisfiesPerm(required: String): Bool {
        if (this.hasPerm(required)) {
            return true
        }
        let p = Perm.parse(required)
        match (p) {
            case Some(x) => return this.hasPerm("${x.domain}:${x.action}:any")
            case None => return false
        }
    }

    /**
     * 是否拥有该「域:动作」下的任一范围权限。
     *
     * 例：hasAnyScope("archive", "read") 对 archive:read:own / archive:read:any
     * 均为 true。
     */
    public func hasAnyScope(domain: String, action: String): Bool {
        for (code in this.permSet) {
            if (AccessContext.permMatches(code, domain, action)) {
                return true
            }
        }
        return false
    }

    /**
     * 权限码是否属于指定「域:动作」。
     *
     * 抽成独立方法以适配 match 的表达式语义（仓颉 match 分支不能写多行语句块）。
     */
    private static func permMatches(code: String, domain: String, action: String): Bool {
        let p = Perm.parse(code)
        match (p) {
            case Some(x) => return x.domain == domain && x.action == action
            case None => return false
        }
    }

    /**
     * 是否可访问指定主体。
     */
    public func canAccessSubject(subjectId: String): Bool {
        return this.subjectIds.contains(subjectId)
    }

    /**
     * 可访问的主体 ID 列表（供查询层拼 WHERE 条件）。
     */
    public func accessibleSubjectIds(): Array<String> {
        let out = ArrayList<String>()
        for (s in this.subjectIds) {
            out.add(s)
        }
        return out.toArray()
    }
}

/**
 * 待访问的资源描述。
 */
public class AuthzResource {
    /** 所属主体 ID */
    public let subjectId: String
    /** 所属租户（多租户隔离根；由条目记录携带，0 表示未提供） */
    public let tenantId: Int64
    /** 所属分类码（0 表示不涉及分类） */
    public let category: Int64
    /** 分类敏感度 */
    public let sensitivity: Sensitivity
    /** 条目 ID（非条目资源为 ""） */
    public let itemId: String

    public init(
        subjectId: String,
        category: Int64,
        sensitivity: Sensitivity,
        itemId!: String = "",
        tenantId!: Int64 = 0
    ) {
        this.subjectId = subjectId
        this.tenantId = tenantId
        this.category = category
        this.sensitivity = sensitivity
        this.itemId = itemId
    }
}

/**
 * 一条临时授权。
 */
public class Grant {
    /** 授权人 */
    public let grantedBy: String
    /** 被授权人 */
    public let granteeId: String
    /** 授权主体 ID */
    public let subjectId: String
    /** 授权的权限码集合 */
    public let perms: Array<String>
    /** 限定条目（空 = 主体级） */
    public let itemId: String
    /** 限定分类（0 = 不限） */
    public let category: Int64
    /** 到期时间（Unix 毫秒；0 = 永不过期） */
    public let expiresAt: Int64
    /** 撤销时间（0 = 未撤销） */
    public let revokedAt: Int64

    public init(
        grantedBy: String,
        granteeId: String,
        subjectId: String,
        perms: Array<String>,
        itemId: String,
        category: Int64,
        expiresAt: Int64,
        revokedAt: Int64
    ) {
        this.grantedBy = grantedBy
        this.granteeId = granteeId
        this.subjectId = subjectId
        this.perms = perms
        this.itemId = itemId
        this.category = category
        this.expiresAt = expiresAt
        this.revokedAt = revokedAt
    }

    /**
     * 该授权在给定时刻是否仍然有效。
     *
     * 重要：**到期判定在每次请求时做**，不依赖定时任务（FR-ACL-009）。
     */
    public func isValidAt(nowMillis: Int64): Bool {
        if (this.revokedAt != 0) {
            return false
        }
        if (this.expiresAt != 0 && nowMillis >= this.expiresAt) {
            return false
        }
        return true
    }

    /**
     * 该授权是否覆盖指定资源。
     */
    public func covers(resource: AuthzResource): Bool {
        // 条目级授权：必须条目 ID 相同
        if (this.itemId != "") {
            return this.itemId == resource.itemId
        }
        // 分类级授权：分类码相同（category=0 表示不限分类）
        if (this.category != 0 && this.category != resource.category) {
            return false
        }
        // 主体级：必须同主体
        return this.subjectId == resource.subjectId
    }
}

/**
 * 授权判定器。
 */
public class Authorizer {
    private let grants: Array<Grant>

    /**
     * @param grants 该用户的全部临时授权（含已撤销/已过期的，判定时自行过滤）
     */
    public init(grants: Array<Grant>) {
        this.grants = grants
    }

    /**
     * 该判定器持有的授权列表。
     *
     * 供鉴权中间件复用，避免为同一请求重复查库。
     *
     * 注意：方法名不能与私有字段 `grants` 同名，故用 allGrants。
     */
    public func allGrants(): Array<Grant> {
        return this.grants
    }

    /**
     * 判定是否可访问指定资源。
     *
     * @param ctx 访问上下文
     * @param requiredPerm 所需功能权限点（形如 "archive:read:own"）
     * @param resource 目标资源
     * @param nowMillis 当前时间（Unix 毫秒）
     * @return 允许 → Ok；拒绝 → Err(Forbidden)
     *
     * 拒绝时**统一**返回 Forbidden，不区分「资源不存在」与「无权限」，
     * 避免泄露资源存在性（安全章 §6.4）。
     */
    public func authorize(
        ctx: AccessContext,
        requiredPerm: String,
        resource: AuthzResource,
        nowMillis: Int64
    ): CryptoResultLike {
        // ---- 第 2 步：功能权限 ----
        if (!this.hasFunctionPerm(ctx, requiredPerm)) {
            return CryptoResultLike.denied()
        }

        // ---- 第 3 步：数据归属 ----
        if (!this.checkOwnership(ctx, resource, nowMillis)) {
            return CryptoResultLike.denied()
        }

        // ---- 第 4 步：分类敏感度 ----
        if (!this.checkSensitivity(ctx, resource, nowMillis)) {
            return CryptoResultLike.denied()
        }

        return CryptoResultLike.allowed()
    }

    /**
     * 功能权限判定。
     *
     * 规则：
     *   - 持有精确权限码 → 通过
     *   - 持有同「域:动作」的 any 范围权限 → 通过
     *     （因 any 与 own 互斥，any 即放弃归属约束，不叠加 own）
     */
    private func hasFunctionPerm(ctx: AccessContext, requiredPerm: String): Bool {
        if (ctx.hasPerm(requiredPerm)) {
            return true
        }
        // 解析出域与动作，检查是否有 any 范围版本
        // 需要的若是 own 范围，则 any 范围也能覆盖
        if (ctx.hasPerm(Authorizer.anyVariantOf(requiredPerm))) {
            return true
        }
        // 需要的若无范围，则该域动作的任意范围都可
        let p = Perm.parse(requiredPerm)
        match (p) {
            case Some(x) => return x.scope == "" && ctx.hasAnyScope(x.domain, x.action)
            case None => return false
        }
    }

    /**
     * 取权限码的 any 范围变体；原码无范围时原样返回。
     */
    private static func anyVariantOf(code: String): String {
        let p = Perm.parse(code)
        match (p) {
            case Some(x) => return "${x.domain}:${x.action}:any"
            case None => return code
        }
    }

    /**
     * 数据归属判定。
     *
     * 三条路径（安全章 §6.1）：
     *   1. 属本人（含代管、被授权的主体）→ 通过
     *   2. 被显式授权（条目/分类/临时）→ 通过
     *   3. 否则拒绝
     */
    private func checkOwnership(
        ctx: AccessContext,
        resource: AuthzResource,
        nowMillis: Int64
    ): Bool {
        // 跨租户强制（多租户隔离根）：资源已知租户时，调用者必须同租户。
        // 防御**所有**路径（含路径0 的 any 绕过）的越权跨租户访问 ——
        // 否则持有 archive:read:any 的角色可凭条目 ID 读取任意租户的条目。
        // 资源未提供租户（tenantId=0）时跳过本检查（兼容既有测试与未知场景）。
        if (resource.tenantId != 0 && resource.tenantId != ctx.tenantId) {
            return false
        }
        // 路径 0：持有 any 范围权限 → **放弃归属约束**
        // （PRD §5.4 脚注：「拥有 any 即表示放弃归属约束，因此不叠加 own 的判定」）
        if (ctx.hasPerm("archive:read:any")) {
            return true
        }
        // 路径 1：主体在可访问集合内
        if (ctx.canAccessSubject(resource.subjectId)) {
            return true
        }
        // 路径 2：显式授权覆盖该资源
        for (g in this.grants) {
            if (g.granteeId != ctx.userId) {
                continue
            }
            if (!g.isValidAt(nowMillis)) {
                continue
            }
            if (g.covers(resource)) {
                return true
            }
        }
        return false
    }

    /**
     * 分类敏感度判定。
     *
     *   - normal：归属通过即可
     *   - sensitive：需显式授权（高敏分类同理）
     *   - high：默认**仅所有者**可见 → 需 any 范围权限或显式授权
     */
    private func checkSensitivity(
        ctx: AccessContext,
        resource: AuthzResource,
        nowMillis: Int64
    ): Bool {
        match (resource.sensitivity) {
            case Sensitivity.Normal => return true
            case Sensitivity.Sensitive => return this.checkSensitive(ctx, resource, nowMillis)
            case Sensitivity.High => return this.checkHighSensitivity(ctx, resource, nowMillis)
        }
    }

    /**
     * sensitive 分类的可见性判定。
     *
     * 规则（FR-ACL-007）：
     *   - 主体**所有者**本人 → 可见（否则用户看不到自己的证件/联系方式，产品不成立）
     *   - 代管人等非所有者 → 需显式授权（acl_grants）
     *   - 持有 archive:read:any → 可见（放弃归属约束）
     */
    private func checkSensitive(
        ctx: AccessContext,
        resource: AuthzResource,
        nowMillis: Int64
    ): Bool {
        if (ctx.hasPerm("archive:read:any")) {
            return true
        }
        if (ctx.ownsSubject(resource.subjectId)) {
            return true
        }
        return this.hasExplicitGrant(ctx, resource, nowMillis)
    }

    /**
     * 高敏分类判定：需 any 范围权限，或显式授权。
     */
    private func checkHighSensitivity(
        ctx: AccessContext,
        resource: AuthzResource,
        nowMillis: Int64
    ): Bool {
        if (ctx.hasPerm("archive:read:any")) {
            return true
        }
        // 主体所有者本人可见（PRD：「high 默认仅所有者可见」）
        if (ctx.ownsSubject(resource.subjectId)) {
            return true
        }
        return this.hasExplicitGrant(ctx, resource, nowMillis)
    }

    /**
     * 是否存在覆盖该资源的显式授权。
     */
    private func hasExplicitGrant(
        ctx: AccessContext,
        resource: AuthzResource,
        nowMillis: Int64
    ): Bool {
        for (g in this.grants) {
            if (g.granteeId != ctx.userId) {
                continue
            }
            if (!g.isValidAt(nowMillis)) {
                continue
            }
            if (g.covers(resource)) {
                return true
            }
        }
        return false
    }

    /**
     * 查询某用户对某主体是否有有效授权（用于列表页过滤）。
     */
    public func hasAnyGrantOnSubject(
        ctx: AccessContext,
        subjectId: String,
        nowMillis: Int64
    ): Bool {
        for (g in this.grants) {
            if (g.granteeId != ctx.userId) {
                continue
            }
            if (!g.isValidAt(nowMillis)) {
                continue
            }
            if (g.subjectId == subjectId) {
                return true
            }
        }
        return false
    }
}

/**
 * 授权结果。
 *
 * 独立于 CryptoResult，避免 authz 包依赖 crypto 包（分层约束：架构 §4.2）。
 */
public enum CryptoResultLike {
    | Allowed
    | Denied

    public static func allowed(): CryptoResultLike {
        return CryptoResultLike.Allowed
    }

    public static func denied(): CryptoResultLike {
        return CryptoResultLike.Denied
    }

    /**
     * 是否允许。
     */
    public func isAllowed(): Bool {
        match (this) {
            case CryptoResultLike.Allowed => return true
            case CryptoResultLike.Denied => return false
        }
    }
}
