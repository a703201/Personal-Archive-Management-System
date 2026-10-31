// ============================================================
// ams.security.authz · 权限点与角色定义
//
// 需求（FR-ACL-001 / FR-ACL-003）：
//   - 至少 5 种内置角色：owner / curator / family / org_admin / auditor
//   - 权限点形如 `域:动作[:范围]`，如 `archive:read:own`、`audit:read`、
//     `user:manage`、`attachment:download`
//
// 设计依据（安全章 §6.1 / §6.2 最小必要原则）：
//   有效权限 = 角色授予的权限点 ∩ (数据归属允许 ∪ 显式越权权限)
//
//   判定顺序（不可交换）：
//     1. 认证：令牌有效？→ 否 → 401
//     2. 功能权限：权限点是否在集合中？→ 否 → 403
//     3. 数据归属：资源是否属于可访问主体？
//     4. 分类敏感度：sensitive+ 需显式授权
//     5. 字段敏感度：敏感字段返回掩码
//
// 重要语义（PRD §5.4 脚注）：
//   `archive:read:own` 与 `archive:read:any` 是**互斥的两条路径**，
//   不是同一路径的强弱档位 —— 拥有 `any` 即放弃归属约束，故**不叠加** `own`。
// ============================================================
package ams.security.authz

import std.collection.*

/**
 * 权限点。
 *
 * 形如 `域:动作[:范围]`。范围缺省表示"不限范围"。
 */
public class Perm {
    /** 完整权限码，如 "archive:read:own" */
    public let code: String
    /** 域：archive/attachment/auth/acl/audit/cfg/user/system */
    public let domain: String
    /** 动作：read/write/delete/export/manage/audit */
    public let action: String
    /** 范围：own/any/subject/分类码；空表示不限 */
    public let scope: String
    /** 是否敏感权限（授予需审计） */
    public let isSensitive: Bool

    public init(code: String, domain: String, action: String, scope: String, isSensitive!: Bool = false) {
        this.code = code
        this.domain = domain
        this.action = action
        this.scope = scope
        this.isSensitive = isSensitive
    }

    /**
     * 解析权限码。格式非法返回 None。
     */
    public static func parse(code: String): ?Perm {
        let parts = code.split(":")
        if (parts.size < 2 || parts.size > 3) {
            return None
        }
        if (parts[0].isEmpty() || parts[1].isEmpty()) {
            return None
        }
        let scope = if (parts.size == 3) { parts[2] } else { "" }
        return Some(Perm(code, parts[0], parts[1], scope))
    }

    /**
     * 是否为"任意范围"权限（放弃归属约束）。
     */
    public func isAnyScope(): Bool {
        return this.scope == "any"
    }

    /**
     * 是否为"仅本人"范围权限。
     */
    public func isOwnScope(): Bool {
        return this.scope == "own"
    }
}

/**
 * 内置角色代码。
 */
public enum BuiltinRole {
    | Owner        // 所有者
    | Curator      // 代管人
    | Family       // 家庭成员
    | OrgAdmin     // 机构管理员
    | Auditor      // 审计员

    /**
     * 角色代码（与 sys_roles.code 一致）。
     */
    public func code(): String {
        match (this) {
            case BuiltinRole.Owner => return "owner"
            case BuiltinRole.Curator => return "curator"
            case BuiltinRole.Family => return "family"
            case BuiltinRole.OrgAdmin => return "org_admin"
            case BuiltinRole.Auditor => return "auditor"
        }
    }

    /**
     * 角色显示名。
     */
    public func displayName(): String {
        match (this) {
            case BuiltinRole.Owner => return "所有者"
            case BuiltinRole.Curator => return "代管人"
            case BuiltinRole.Family => return "家庭成员"
            case BuiltinRole.OrgAdmin => return "机构管理员"
            case BuiltinRole.Auditor => return "审计员"
        }
    }

    /**
     * 数据可见上限（对应 sys_roles.max_data_level）：
     *   1 = 仅本人；2 = 本人 + 被授权；3 = 全部（普通档案）
     */
    public func maxDataLevel(): Int64 {
        match (this) {
            case BuiltinRole.Owner => return 3
            case BuiltinRole.Curator => return 2
            case BuiltinRole.Family => return 2
            case BuiltinRole.OrgAdmin => return 3
            case BuiltinRole.Auditor => return 1
        }
    }
}

/**
 * 内置权限点目录。
 *
 * 内置角色的权限映射在此定义（安全章要求「最小必要」）：
 *   - auditor  只有 audit:read，**没有** archive:read（查日志不看内容）
 *   - org_admin 管用户与角色，但**没有** audit:write（审计不可篡改）
 *   - family   只读，不含写与导出
 *   - curator  可写，但不含 export:any 与敏感分类的展开权
 */
public class BuiltinPerms {
    /**
     * 全部内置权限点（用于初始化 sys_perms 表）。
     */
    public static func all(): Array<Perm> {
        let perms = ArrayList<Perm>()
        // ---- archive 域 ----
        perms.add(Perm("archive:read:own", "archive", "read", "own"))
        perms.add(Perm("archive:read:any", "archive", "read", "any", isSensitive: true))
        perms.add(Perm("archive:write:own", "archive", "write", "own"))
        perms.add(Perm("archive:write:any", "archive", "write", "any", isSensitive: true))
        perms.add(Perm("archive:delete:own", "archive", "delete", "own", isSensitive: true))
        perms.add(Perm("archive:delete:any", "archive", "delete", "any", isSensitive: true))
        perms.add(Perm("archive:export:own", "archive", "export", "own", isSensitive: true))
        perms.add(Perm("archive:export:any", "archive", "export", "any", isSensitive: true))
        perms.add(Perm("archive:read_sensitive", "archive", "read_sensitive", "", isSensitive: true))
        perms.add(Perm("archive:manage", "archive", "manage", "", isSensitive: true))
        // ---- subject 域 ----
        perms.add(Perm("subject:read:own", "subject", "read", "own"))
        perms.add(Perm("subject:read:any", "subject", "read", "any", isSensitive: true))
        perms.add(Perm("subject:write:own", "subject", "write", "own"))
        perms.add(Perm("subject:manage", "subject", "manage", "", isSensitive: true))
        // ---- attachment 域 ----
        perms.add(Perm("attachment:read:own", "attachment", "read", "own"))
        perms.add(Perm("attachment:read:any", "attachment", "read", "any", isSensitive: true))
        perms.add(Perm("attachment:upload:own", "attachment", "upload", "own"))
        perms.add(Perm("attachment:upload:any", "attachment", "upload", "any", isSensitive: true))
        perms.add(Perm("attachment:download:own", "attachment", "download", "own"))
        perms.add(Perm("attachment:download:any", "attachment", "download", "any", isSensitive: true))
        perms.add(Perm("attachment:delete:own", "attachment", "delete", "own", isSensitive: true))
        perms.add(Perm("attachment:delete:any", "attachment", "delete", "any", isSensitive: true))
        perms.add(Perm("attachment:manage", "attachment", "manage", "", isSensitive: true))
        // ---- tag / notify 域 ----
        perms.add(Perm("tag:read:own", "tag", "read", "own"))
        perms.add(Perm("tag:write:own", "tag", "write", "own"))
        perms.add(Perm("notify:read:own", "notify", "read", "own"))
        // ---- acl 域 ----
        perms.add(Perm("acl:read:own", "acl", "read", "own"))
        perms.add(Perm("acl:grant:own", "acl", "grant", "own", isSensitive: true))
        perms.add(Perm("acl:revoke:own", "acl", "revoke", "own", isSensitive: true))
        perms.add(Perm("acl:manage", "acl", "manage", "", isSensitive: true))
        // ---- user 域 ----
        perms.add(Perm("user:read:any", "user", "read", "any", isSensitive: true))
        perms.add(Perm("user:manage", "user", "manage", "", isSensitive: true))
        // ---- cfg 域 ----
        perms.add(Perm("cfg:read", "cfg", "read", ""))
        perms.add(Perm("cfg:manage", "cfg", "manage", "", isSensitive: true))
        perms.add(Perm("cfg:dict:manage", "cfg", "dict_manage", "", isSensitive: true))
        // ---- audit 域 ----
        perms.add(Perm("audit:read", "audit", "read", "", isSensitive: true))
        perms.add(Perm("audit:export", "audit", "export", "", isSensitive: true))
        // ---- system 域 ----
        perms.add(Perm("system:admin", "system", "admin", "", isSensitive: true))
        return perms.toArray()
    }

    /**
     * 内置角色的权限码列表。
     *
     * 【最小必要原则的具体落实，安全章 §6.2】
     */
    public static func permsOf(role: BuiltinRole): Array<String> {
        match (role) {
            case BuiltinRole.Owner => return [
                "archive:read:own", "archive:read:any", "archive:write:own", "archive:write:any",
                "archive:delete:own", "archive:delete:any", "archive:export:own", "archive:export:any",
                "archive:read_sensitive", "archive:manage",
                "subject:read:own", "subject:read:any", "subject:write:own", "subject:manage",
                "attachment:read:own", "attachment:read:any", "attachment:upload:own",
                "attachment:upload:any", "attachment:download:own", "attachment:download:any",
                "attachment:delete:own", "attachment:delete:any", "attachment:manage",
                "tag:read:own", "tag:write:own", "notify:read:own",
                "acl:read:own", "acl:grant:own", "acl:revoke:own"
            ]
            case BuiltinRole.Curator => return [
                // 代管人：可读可写本人代管的主体内容，但不含 export:any 与管理权
                "archive:read:own", "archive:write:own", "archive:delete:own",
                "archive:export:own",
                "subject:read:own", "subject:write:own",
                "attachment:read:own", "attachment:upload:own", "attachment:download:own",
                "attachment:delete:own",
                "tag:read:own", "tag:write:own", "notify:read:own",
                "acl:read:own"
            ]
            case BuiltinRole.Family => return [
                // 家庭成员：只读，且仅可见显式授权内容
                "archive:read:own",
                "subject:read:own",
                "attachment:read:own", "attachment:download:own",
                "tag:read:own", "notify:read:own"
            ]
            case BuiltinRole.OrgAdmin => return [
                // 机构管理员：管用户与角色；**无 audit:write**（审计不可篡改）
                "archive:read:any", "archive:write:any", "archive:delete:any", "archive:export:any",
                "subject:read:any", "subject:write:own", "subject:manage",
                "attachment:read:any", "attachment:upload:any", "attachment:download:any",
                "attachment:delete:any", "attachment:manage",
                "tag:read:own", "tag:write:own", "notify:read:own",
                "acl:read:own", "acl:manage",
                "user:read:any", "user:manage",
                "cfg:read", "cfg:manage", "cfg:dict:manage"
            ]
            case BuiltinRole.Auditor => return [
                // 审计员：只有 audit:read，**没有** archive:read（查日志不看内容）
                "audit:read", "audit:export"
            ]
        }
    }
}
