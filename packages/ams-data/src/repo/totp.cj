// ============================================================
// ams.data.repo.totp · 用户 TOTP 密钥仓储（FR-AUTH-009）
//
// 表：sys_user_totp（见 db/migrations/014_user_totp.sql）
//
// 关键约束：
//   · 一个用户一条（唯一索引），upsertSecret 用「先 UPDATE 再 INSERT」实现，
//     不用 openGauss 不支持的 ON CONFLICT；
//   · touchStep 是**重放保护**的核心：`WHERE last_step < ?` 保证同一个
//     时间步只能成功一次（并发下也只有一个写入者成功）。
// ============================================================
package ams.data.repo

import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 用户 TOTP 仓储。
 */
public class TotpRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 取用户的 TOTP 记录（未绑定返回 None） */
    public func find(userId: Int64): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, CAST(user_id AS BIGINT) AS user_id, secret_b32, " +
                "CAST(digits AS BIGINT) AS digits, CAST(period AS BIGINT) AS period, " +
                "verified, CAST(last_step AS BIGINT) AS last_step " +
                "FROM sys_user_totp WHERE user_id = ?"
            )
            st.set(0, userId)
            let rows = readRows(st.query()).all()
            if (rows.size > 0) {
                return Some(rows[0])
            }
            return None
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 写入/重置密钥（状态置为未验证）。
     *
     * 重新绑定会清空 last_step：换了密钥，旧时间步的语义不再适用。
     */
    public func upsertSecret(userId: Int64, secretB32: String): Unit {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_user_totp SET secret_b32 = ?, verified = FALSE, " +
                "last_step = 0, verified_at = NULL WHERE user_id = ?"
            )
            st.set(0, secretB32)
            st.set(1, userId)
            let n = st.update().rowCount
            if (n > 0) {
                return
            }
            let ins = c.prepareStatement(
                "INSERT INTO sys_user_totp (id, user_id, secret_b32, digits, period, " +
                "verified, last_step, created_at) VALUES (?, ?, ?, 6, 30, FALSE, 0, CURRENT_TIMESTAMP)"
            )
            ins.set(0, Ids.next())
            ins.set(1, userId)
            ins.set(2, secretB32)
            ins.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 标记为已验证（用户成功输入一次动态码后调用）。
     *
     * @return true = 记录存在且已更新
     */
    public func markVerified(userId: Int64, step: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_user_totp SET verified = TRUE, last_step = ?, " +
                "verified_at = CURRENT_TIMESTAMP WHERE user_id = ?"
            )
            st.set(0, step)
            st.set(1, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 推进时间步（重放保护）。
     *
     * @return true = 该时间步此前未被使用（本次校验可放行）
     */
    public func touchStep(userId: Int64, step: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_user_totp SET last_step = ? WHERE user_id = ? AND last_step < ?"
            )
            st.set(0, step)
            st.set(1, userId)
            st.set(2, step)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 解绑（删除记录） */
    public func remove(userId: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement("DELETE FROM sys_user_totp WHERE user_id = ?")
            st.set(0, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
