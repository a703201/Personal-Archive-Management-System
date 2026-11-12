// ============================================================
// ams.data.repo.tenantquota · 租户配额写路径闸门
//
// 背景：docs/15 §4.2 阶段 3 把 sys_tenant_quota 做成「运营上限声明」，
// 明确标注「尚未在创建用户 / 条目 / 附件的写路径强制拦截」。本文件补上
// 这道闸门，把声明值变成真正生效的约束。
//
// 设计：
//   ① 判定逻辑抽成纯函数 exceeded()，可脱离 DB 单测；
//   ② 由 ams.api.middleware 的统一中间件在鉴权之后调用，不散落改各路由；
//   ③ `AMS_QUOTA_ENFORCE=false` 可一键关闭（灰度/压测回退），默认开启；
//   ④ 配额表缺失 / 查询失败 → 记 warn 后放行。配额是运营约束而非安全边界，
//      绝不能因为运营侧表没迁移就让全站写入 500（真正 fail-closed 的是
//      加密与存储层）。无配额记录视为「不限制」。
//   ⑤ 未鉴权请求（tenantId<=0）跳过，交给鉴权中间件处理。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*
import std.env.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.log.*

/** 受配额约束的写入种类。 */
public enum QuotaKind {
    | Users
    | Items
    | Storage
}

/** 当前用量快照。 */
public class TenantUsage {
    public let users: Int64
    public let items: Int64
    public let storageBytes: Int64

    public init(users: Int64, items: Int64, storageBytes: Int64) {
        this.users = users
        this.items = items
        this.storageBytes = storageBytes
    }
}

public class TenantQuotaGuard {
    private static let MB: Int64 = 1024 * 1024

    private let db: Database
    private let quotaRepo: TenantOpsRepo

    public init(db: Database) {
        this.db = db
        this.quotaRepo = TenantOpsRepo(db)
    }

    /** 总开关：显式设 `false` 才关闭，默认开启。 */
    public static func enforceEnabled(): Bool {
        return (getVariable("AMS_QUOTA_ENFORCE") ?? "true").toAsciiLower() != "false"
    }

    /**
     * 纯判定：本次写入后是否超限。
     * Users/Items 按「+1 条」计，Storage 按「新增字节」计并向上取整到 MiB，
     * 避免 1 字节越界被整除吞掉。
     */
    public static func exceeded(
        q: TenantQuota, u: TenantUsage, kind: QuotaKind, addBytes: Int64
    ): Bool {
        match (kind) {
            case QuotaKind.Users => return u.users + 1 > q.maxUsers
            case QuotaKind.Items => return u.items + 1 > q.maxItems
            case QuotaKind.Storage =>
                let mb = (u.storageBytes + addBytes + TenantQuotaGuard.MB - 1) /
                         TenantQuotaGuard.MB
                return mb > q.maxStorageMb
        }
    }

    /** 配额种类的人类可读名称（进错误信息，不含内部细节）。 */
    public static func labelOf(kind: QuotaKind): String {
        match (kind) {
            case QuotaKind.Users => return "用户数"
            case QuotaKind.Items => return "档案条目数"
            case QuotaKind.Storage => return "附件存储容量"
        }
    }

    /** 查当前用量（三条计数都按 tenant_id 参数化）。 */
    public func usage(tenantId: Int64): TenantUsage {
        let c = this.db.connect()
        try {
            let users = TenantQuotaGuard.countOf(
                c, "SELECT COUNT(*) AS n FROM sys_users WHERE tenant_id = ?", tenantId)
            let items = TenantQuotaGuard.countOf(
                c, "SELECT COUNT(*) AS n FROM arc_items WHERE tenant_id = ? AND status != 3", tenantId)
            // arc_attachments 没有 tenant_id（022 迁移只覆盖 users/subjects/items），
            // 归属必须经 subject_id 关联 arc_subjects，避免把别的租户算进来。
            let bytes = TenantQuotaGuard.countOf(
                c, "SELECT COALESCE(SUM(a.file_size), 0) AS n FROM arc_attachments a " +
                   "JOIN arc_subjects s ON s.id = a.subject_id " +
                   "WHERE s.tenant_id = ? AND a.is_current_deleted = FALSE", tenantId)
            return TenantUsage(users, items, bytes)
        } finally {
            c.close()
        }
    }

    /** 执行闸门；超限抛 QUOTA_EXCEEDED（HTTP 429），其它情况放行。 */
    public func enforce(tenantId: Int64, kind: QuotaKind, addBytes: Int64): Unit {
        if (!TenantQuotaGuard.enforceEnabled() || tenantId <= 0) {
            return
        }
        try {
            let q = match (this.quotaRepo.getQuota(tenantId)) {
                case Some(v) => v
                case None => return   // 无配额记录 = 不限制
            }
            let u = this.usage(tenantId)
            if (TenantQuotaGuard.exceeded(q, u, kind, addBytes)) {
                throw AppError(AppErrorKind.QuotaExceeded,
                    "租户${TenantQuotaGuard.labelOf(kind)}已达配额上限，请联系管理员调整")
            }
        } catch (e: AppError) {
            throw e
        } catch (e: Exception) {
            // 运营侧表未迁移 / DB 抖动：只记日志并放行，不阻断业务写入。
            Log.get().warn("tenant.quota.check.skipped", None, [
                ("tenantId", "${tenantId}"),
                ("reason", e.toString())
            ])
        }
    }

    private static func countOf(c: Connection, sql: String, tenantId: Int64): Int64 {
        let st = c.prepareStatement(sql)
        st.set(0, tenantId)
        let rows = readRows(st.query()).all()
        if (rows.size == 0) {
            return 0
        }
        return rows[0].i64("n")
    }
}
