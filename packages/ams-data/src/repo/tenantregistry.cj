// ============================================================
// ams.data.repo.tenantregistry · 租户注册与首次引导
//
// 补齐 docs/15 §4.2 阶段 3 的最后一个边界：此前「只有默认租户 id=1，
// 租户注册 / 引导流程未提供」，配额与配置接口因而只能服务于单租户。
//
// 两步式、显式、可回滚：
//   ① createTenant(code, name)  建租户 + 播种默认配额（声明值）；
//   ② bootstrapAdmin(...)       为该租户建**首个** org_admin 账号。
// 引导只允许一次（该租户已有任何用户即 Conflict），避免留一个
// 「谁都能给空租户塞管理员」的越权后门。口令哈希由调用方用
// PasswordHasher 生成，本层只接哈希串，绝不接触明文、不进口令策略。
//
// 为什么不动 UserRepo.create：那是全站注册主路径，写死 tenant_id 默认值；
// 改它会影响所有既有注册流程。引导是低频运维动作，独立 SQL 更安全。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

public class TenantRegistry {
    /** 内置机构管理员角色（db/migrations/003_seed_perms_roles.sql）。 */
    public static let OrgAdminRoleId: Int64 = 800004

    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 租户编码：2~64 位小写字母 / 数字 / 连字符 / 下划线，首字符必须字母。 */
    public static func validCode(code: String): Bool {
        if (code.size < 2 || code.size > 64) {
            return false
        }
        let bs = code.toArray()
        let first = bs[0]
        if (!(first >= 0x61u8 && first <= 0x7Au8)) {
            return false
        }
        for (b in bs) {
            let lower = b >= 0x61u8 && b <= 0x7Au8
            let digit = b >= 0x30u8 && b <= 0x39u8
            let dash = b == 0x2Du8
            let under = b == 0x5Fu8
            if (!(lower || digit || dash || under)) {
                return false
            }
        }
        return true
    }

    /** 租户显示名：1~128 字符，禁止控制字符（防日志 / 页面注入）。 */
    public static func validName(name: String): Bool {
        let n = name.trimAscii()
        if (n.isEmpty() || n.size > 128) {
            return false
        }
        for (b in n.toArray()) {
            if (b < 0x20u8) {
                return false
            }
        }
        return true
    }

    /** 用户名：4~64 位字母 / 数字 / . _ -。 */
    public static func validUsername(u: String): Bool {
        if (u.size < 4 || u.size > 64) {
            return false
        }
        for (b in u.toArray()) {
            let lower = b >= 0x61u8 && b <= 0x7Au8
            let upper = b >= 0x41u8 && b <= 0x5Au8
            let digit = b >= 0x30u8 && b <= 0x39u8
            let dot = b == 0x2Eu8
            let dash = b == 0x2Du8
            let under = b == 0x5Fu8
            if (!(lower || upper || digit || dot || dash || under)) {
                return false
            }
        }
        return true
    }

    /** 列出全部租户（含状态，供管理页 / 运维核对）。 */
    public func listTenants(): RowSet {
        let sql = "SELECT id, code, name, status, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at)*1000, 0) AS BIGINT) AS created_ms " +
                  "FROM sys_tenants ORDER BY id"
        let c = this.db.connect()
        try {
            return readRows(c.prepareStatement(sql).query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 建租户 + 播种默认配额。失败时补偿删除租户行，不留半完成状态。 */
    public func createTenant(code: String, name: String): Int64 {
        if (!TenantRegistry.validCode(code)) {
            throw validationError("code", "租户编码须为 2~64 位小写字母/数字/连字符，且以字母开头")
        }
        if (!TenantRegistry.validName(name)) {
            throw validationError("name", "租户名称须为 1~128 位可打印字符")
        }
        let id = Ids.next()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO sys_tenants (id, code, name, status) VALUES (?, ?, ?, 'active')")
            st.set(0, id); st.set(1, code); st.set(2, name.trimAscii())
            st.update()
            let q = c.prepareStatement(
                "INSERT INTO sys_tenant_quota (tenant_id, max_users, max_items, max_storage_mb) " +
                "VALUES (?, 100, 10000, 1024)")
            q.set(0, id)
            q.update()
            return id
        } catch (e: Exception) {
            // 补偿：配额播种失败或 code 唯一约束冲突时不留孤儿租户。
            try {
                let del = c.prepareStatement("DELETE FROM sys_tenants WHERE id = ?")
                del.set(0, id)
                del.update()
            } catch (e2: Exception) {
                ()   // 补偿失败交由 DBA 按 id 清理，不覆盖原始错误
            }
            throw AppError(AppErrorKind.Conflict, "租户编码已存在或创建失败")
        } finally {
            c.close()
        }
    }

    /**
     * 为租户创建首个管理员。调用方已生成 passwordHash。
     * 该租户已有任何用户时拒绝（引导只允许一次）。
     */
    public func bootstrapAdmin(
        tenantId: Int64, username: String, passwordHash: String, kdfCost: Int64
    ): Int64 {
        if (tenantId <= 0) {
            throw validationError("tenantId", "缺少合法的租户 ID")
        }
        if (!TenantRegistry.validUsername(username)) {
            throw validationError("username", "用户名须为 4~64 位字母/数字/点/连字符/下划线")
        }
        if (passwordHash.isEmpty()) {
            throw validationError("password", "缺少口令哈希")
        }
        let c = this.db.connect()
        try {
            let ts = c.prepareStatement("SELECT COUNT(*) AS n FROM sys_tenants WHERE id = ?")
            ts.set(0, tenantId)
            if (readRows(ts.query()).all()[0].i64("n") == 0) {
                throw notFound("租户")
            }
            let us = c.prepareStatement("SELECT COUNT(*) AS n FROM sys_users WHERE tenant_id = ?")
            us.set(0, tenantId)
            if (readRows(us.query()).all()[0].i64("n") > 0) {
                throw AppError(AppErrorKind.Conflict, "该租户已有用户，首次引导只允许执行一次")
            }
            let uid = Ids.next()
            let ins = c.prepareStatement(
                "INSERT INTO sys_users (id, username, password_hash, password_updated_at, " +
                "kdf_cost, status, created_at, created_by, updated_at, updated_by, tenant_id) " +
                "VALUES (?, ?, ?, CURRENT_TIMESTAMP, ?, 0, CURRENT_TIMESTAMP, 0, " +
                "CURRENT_TIMESTAMP, 0, ?)")
            ins.set(0, uid); ins.set(1, username); ins.set(2, passwordHash)
            ins.set(3, kdfCost); ins.set(4, tenantId)
            ins.update()
            let role = c.prepareStatement(
                "INSERT INTO sys_user_roles (id, user_id, role_id, granted_by) VALUES (?, ?, ?, 0)")
            role.set(0, Ids.next()); role.set(1, uid); role.set(2, TenantRegistry.OrgAdminRoleId)
            role.update()
            return uid
        } catch (e: AppError) {
            throw e
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
