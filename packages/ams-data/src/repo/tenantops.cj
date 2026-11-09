// ============================================================
// ams.data.repo.tenantops · 租户运营仓储（阶段 3 / docs/15 §4.2）
//
// 三块能力：配额读写、配置读写、审计聚合视图查询。
//
// 约束：
//   ① 全部按 tenant_id 参数化，杜绝跨租户读取；
//   ② openGauss 不支持 ON CONFLICT，upsert 一律「先 UPDATE，
//      rowCount==0 再 INSERT」，与 config.cj 同款；
//   ③ is_secret 配置只在 SQL 层替换为占位，明文不出库；
//   ④ 配额本阶段是「运营上限声明」，不在写路径强制拦截
//      （悄悄改变写入语义而不压测，比留一个明确边界更危险）。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*

/** 租户配额记录。 */
public class TenantQuota {
    public let tenantId: Int64
    public let maxUsers: Int64
    public let maxItems: Int64
    public let maxStorageMb: Int64

    public init(tenantId: Int64, maxUsers: Int64, maxItems: Int64, maxStorageMb: Int64) {
        this.tenantId = tenantId
        this.maxUsers = maxUsers
        this.maxItems = maxItems
        this.maxStorageMb = maxStorageMb
    }

    /**
     * 配额合法性（纯函数，可单测）：三项都必须落在 [1, 1_000_000] 内。
     * 拒绝 0 / 负数 —— 那会让「上限」变成不可解释的全拒绝状态。
     */
    public static func valid(maxUsers: Int64, maxItems: Int64, maxStorageMb: Int64): Bool {
        return TenantQuota.inRange(maxUsers) &&
               TenantQuota.inRange(maxItems) &&
               TenantQuota.inRange(maxStorageMb)
    }

    private static func inRange(v: Int64): Bool {
        return v >= 1 && v <= 1000000
    }
}

public class TenantOpsRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 查配额；无记录返回 None（迁移会为默认租户播种）。 */
    public func getQuota(tenantId: Int64): Option<TenantQuota> {
        let sql = "SELECT tenant_id, max_users, max_items, max_storage_mb " +
                  "FROM sys_tenant_quota WHERE tenant_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, tenantId)
            let rows = readRows(st.query()).all()
            if (rows.size == 0) {
                return None
            }
            let r = rows[0]
            return Some(TenantQuota(
                r.i64("tenant_id"), r.i64("max_users"),
                r.i64("max_items"), r.i64("max_storage_mb")))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 写入配额（upsert）。返回是否成功。 */
    public func setQuota(tenantId: Int64, maxUsers: Int64, maxItems: Int64,
                         maxStorageMb: Int64): Bool {
        if (!TenantQuota.valid(maxUsers, maxItems, maxStorageMb)) {
            throw validationError("quota", "配额必须是 1 到 1000000 之间的整数")
        }
        let upd = "UPDATE sys_tenant_quota SET max_users = ?, max_items = ?, " +
                  "max_storage_mb = ?, updated_at = CURRENT_TIMESTAMP WHERE tenant_id = ?"
        let ins = "INSERT INTO sys_tenant_quota (tenant_id, max_users, max_items, max_storage_mb) " +
                  "SELECT ?, ?, ?, ? WHERE NOT EXISTS " +
                  "(SELECT 1 FROM sys_tenant_quota WHERE tenant_id = ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(upd)
            st.set(0, maxUsers); st.set(1, maxItems); st.set(2, maxStorageMb); st.set(3, tenantId)
            if (st.update().rowCount > 0) {
                return true
            }
            let si = c.prepareStatement(ins)
            si.set(0, tenantId); si.set(1, maxUsers); si.set(2, maxItems)
            si.set(3, maxStorageMb); si.set(4, tenantId)
            return si.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 列出配置；is_secret 项 value 在 SQL 层替换为 '***'。 */
    public func listSettings(tenantId: Int64): RowSet {
        let sql = "SELECT setting_key, " +
                  "CASE WHEN is_secret THEN '***' ELSE value END AS value, " +
                  "CAST(is_secret AS INT) AS is_secret, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at)*1000, 0) AS BIGINT) AS updated_ms " +
                  "FROM sys_tenant_settings WHERE tenant_id = ? ORDER BY setting_key"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, tenantId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 写配置（upsert）。
     *   · UPDATE 路径只改 value，不触碰 is_secret —— 避免更新值时误把既有机密项
     *     降级为明文；
     *   · INSERT 路径按调用方传入的 isSecret 落库，使 is_secret=TRUE 的项在
     *     listSettings 时被 SQL 层掩码为 '***'，杜绝「API 写入机密后明文回显」
     *     的泄漏面（此前 is_secret 只能靠迁移写死，接口无法创设机密项）。
     */
    public func setSetting(tenantId: Int64, key: String, value: String, isSecret: Bool): Bool {
        if (key.isEmpty() || key.size > 128) {
            throw validationError("key", "配置键长度必须在 1 到 128 之间")
        }
        let upd = "UPDATE sys_tenant_settings SET value = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE tenant_id = ? AND setting_key = ?"
        let ins = "INSERT INTO sys_tenant_settings (tenant_id, setting_key, value, is_secret) " +
                  "SELECT ?, ?, ?, ? WHERE NOT EXISTS " +
                  "(SELECT 1 FROM sys_tenant_settings WHERE tenant_id = ? AND setting_key = ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(upd)
            st.set(0, value); st.set(1, tenantId); st.set(2, key)
            if (st.update().rowCount > 0) {
                return true
            }
            let si = c.prepareStatement(ins)
            si.set(0, tenantId); si.set(1, key); si.set(2, value); si.set(3, isSecret)
            si.set(4, tenantId); si.set(5, key)
            return si.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 租户审计聚合（按动作 / 结果分组，系统动作不计入）。 */
    public func auditSummary(tenantId: Int64): RowSet {
        let sql = "SELECT action, result, event_count, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM last_occurred_at)*1000, 0) AS BIGINT) AS last_ms " +
                  "FROM v_tenant_audit_summary WHERE tenant_id = ? " +
                  "ORDER BY event_count DESC, action"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, tenantId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
