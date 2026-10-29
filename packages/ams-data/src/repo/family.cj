// ============================================================
// ams.data.repo.family · 家庭组 / 成员 / 邀请 / 组授权 仓储（FR-ACL-010）
//
// 设计要点（与 docs/14 的偏离已在 019 迁移头部说明）：
//   · 「授权 → 家庭组」的归属放在侧表 fam_grants，不改动 acl_grants 结构
//     （openGauss 不支持 ADD COLUMN IF NOT EXISTS，ALTER 无法幂等）；
//   · 邀请只存摘要，明文仅在创建响应出现一次；
//   · 计数（used_count / fail_count）**落库并在 SQL 里原子自增**，
//     跨进程、跨重启有效，也避免「先读再写」被并发绕过；
//   · 失效判定在 SQL 里用 CURRENT_TIMESTAMP 现算，不在应用层比时间
//     —— 应用层比时间会踩时区/时钟漂移，且两处口径容易分裂。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 家庭组仓储。
 */
public class FamGroupRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 建组。创建者即 owner（成员的 owner 行由 FamMemberRepo 单独写入）。 */
    public func create(name: String, ownerId: Int64): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO fam_groups (id, name, owner_id, status, created_at, " +
                  "updated_at, version) VALUES (?, ?, ?, 0, CURRENT_TIMESTAMP, " +
                  "CURRENT_TIMESTAMP, 1)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, name)
            st.set(2, ownerId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按 ID 查（**不过滤归属** —— 调用方必须自己校验成员身份）。 */
    public func findById(id: Int64): Option<RowData> {
        let sql = "SELECT id, name, owner_id, status, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms " +
                  "FROM fam_groups WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 该用户加入的全部组（含其在组内的角色、成员数）。
     *
     * 一个用户可属于多个组（docs/14 §5.3），故按用户聚合而不是
     * 假设「一人一组」—— 后者会在第二个组创建时静默丢数据。
     */
    public func listByUser(userId: Int64): RowSet {
        let sql = "SELECT g.id, g.name, g.owner_id, g.status, m.role AS my_role, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM g.created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "(SELECT COUNT(*) FROM fam_members mm WHERE mm.group_id = g.id AND mm.status = 0) AS member_count " +
                  "FROM fam_groups g JOIN fam_members m ON m.group_id = g.id " +
                  "WHERE m.user_id = ? AND m.status = 0 AND g.status = 0 " +
                  "ORDER BY g.created_at DESC, g.id DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 解散（软删）。**只置状态，不删任何条目** —— 条目属于主体所有者。 */
    public func dissolve(id: Int64, ownerId: Int64): Bool {
        let sql = "UPDATE fam_groups SET status = 1, updated_at = CURRENT_TIMESTAMP, " +
                  "version = version + 1 WHERE id = ? AND owner_id = ? AND status = 0"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

/**
 * 组成员仓储。
 */
public class FamMemberRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 加入成员。
     *
     * 幂等语义：唯一索引 (group_id, user_id) 已存在时
     *   · 原状态 = 0（正常）→ 不重复插入，`inserted = false`
     *   · 原状态 = 1（已移除）→ 复活为正常，`inserted = true`
     * 这样「被移除的人重新被邀请」不必先手工删记录。
     *
     * @return (成员行 ID, 是否新增/复活)
     */
    public func join(
        groupId: Int64,
        userId: Int64,
        role: String,
        invitedBy: Int64
    ): (Int64, Bool) {
        match (this.findRow(groupId, userId)) {
            case Some(r) =>
                if (r.i64("status") == 0) {
                    return (r.i64("id"), false)
                }
                let revive = "UPDATE fam_members SET status = 0, role = ?, " +
                             "joined_at = CURRENT_TIMESTAMP, removed_at = NULL, " +
                             "removed_by = NULL, invited_by = ? WHERE id = ?"
                let c0 = this.db.connect()
                try {
                    let st = c0.prepareStatement(revive)
                    st.set(0, role)
                    st.set(1, invitedBy)
                    st.set(2, r.i64("id"))
                    st.update()
                } catch (e: Exception) {
                    throw toDbError(e)
                } finally {
                    c0.close()
                }
                return (r.i64("id"), true)
            case None => ()
        }
        let id = Ids.next()
        let sql = "INSERT INTO fam_members (id, group_id, user_id, role, status, " +
                  "invited_by, joined_at) VALUES (?, ?, ?, ?, 0, ?, CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, groupId)
            st.set(2, userId)
            st.set(3, role)
            st.set(4, invitedBy)
            st.update()
            return (id, true)
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 组内成员行（含已移除，供复活用）。 */
    private func findRow(groupId: Int64, userId: Int64): Option<RowData> {
        let sql = "SELECT id, group_id, user_id, role, status FROM fam_members " +
                  "WHERE group_id = ? AND user_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            st.set(1, userId)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 我在该组的有效成员行（不在组内 / 已移除 → None）。 */
    public func findActive(groupId: Int64, userId: Int64): Option<RowData> {
        let sql = "SELECT id, group_id, user_id, role, status, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM joined_at) * 1000, 0) AS BIGINT) AS joined_ms " +
                  "FROM fam_members WHERE group_id = ? AND user_id = ? AND status = 0"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            st.set(1, userId)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 组内成员列表（含昵称，供前端直接展示）。
     *
     * 用 LEFT JOIN 而不是 JOIN：账号被软删时仍应显示该成员行，
     * 否则「成员数 3 但列表只有 2 人」会让人以为数据丢了。
     */
    public func listByGroup(groupId: Int64): RowSet {
        let sql = "SELECT m.id, m.user_id, m.role, m.status, m.invited_by, " +
                  "COALESCE(u.nickname, '') AS nickname, " +
                  "COALESCE(u.username, '') AS username, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM m.joined_at) * 1000, 0) AS BIGINT) AS joined_ms " +
                  "FROM fam_members m LEFT JOIN sys_users u ON u.id = m.user_id " +
                  "WHERE m.group_id = ? AND m.status = 0 ORDER BY m.joined_at, m.id"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 移除成员（软删，保留行以便审计与复活）。 */
    public func remove(groupId: Int64, userId: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE fam_members SET status = 1, removed_at = CURRENT_TIMESTAMP, " +
                  "removed_by = ? WHERE group_id = ? AND user_id = ? AND status = 0"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, groupId)
            st.set(2, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 该用户当前是否属于任何**正常**的组（用于「家庭成员」身份判定）。 */
    public func isInAnyActiveGroup(userId: Int64): Bool {
        let sql = "SELECT COUNT(*) AS n FROM fam_members m JOIN fam_groups g ON g.id = m.group_id " +
                  "WHERE m.user_id = ? AND m.status = 0 AND g.status = 0"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n") > 0
                case None => return false
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

/**
 * 邀请仓储。
 */
public class FamInviteRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    public func create(
        groupId: Int64,
        inviterId: Int64,
        codeHash: String,
        codeSalt: String,
        tokenHash: String,
        targetRole: String,
        maxUses: Int64,
        maxFails: Int64,
        expiresAtIso: String
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO fam_invites (id, group_id, inviter_id, code_hash, code_salt, " +
                  "token_hash, target_role, max_uses, used_count, fail_count, max_fails, " +
                  "expires_at, revoked, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, " +
                  "CAST(? AS TIMESTAMPTZ), FALSE, CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, groupId)
            st.set(2, inviterId)
            st.set(3, codeHash)
            st.set(4, codeSalt)
            st.set(5, tokenHash)
            st.set(6, targetRole)
            st.set(7, maxUses)
            st.set(8, maxFails)
            st.set(9, expiresAtIso)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按 token 摘要查（公开落地页 + 接受邀请共用）。
     *
     * 返回字段含 SQL 现算的 `expired`，与 `bumpFail` / `consume` 的口径一致。
     *
     * ⚠️ **必须带上 `code_hash` 与 `code_salt`**：`acceptInvite` 要用它们
     *    校验邀请码。漏选时 `RowData.str()` 对不存在的列返回空串，
     *    于是 `hmacHex("", ...)` 抛「HMAC 密钥不能为空」——
     *    报错点离真实原因（少选两列）差了十万八千里，且只在 accept 路径复现，
     *    落地页照常能用，极容易误判成密钥配置问题。
     */
    public func findByTokenHash(tokenHash: String): Option<RowData> {
        let sql = "SELECT id, group_id, inviter_id, target_role, max_uses, used_count, " +
                  "fail_count, max_fails, revoked, code_hash, code_salt, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms " +
                  "FROM fam_invites WHERE token_hash = ? AND token_hash <> ''"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, tokenHash)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按 ID 查（接受邀请时按 token 找到后取完整行）。 */
    public func findById(id: Int64): Option<RowData> {
        let sql = "SELECT id, group_id, inviter_id, target_role, max_uses, used_count, " +
                  "fail_count, max_fails, revoked, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms " +
                  "FROM fam_invites WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 组内有效邀请列表（**不含 code/token 摘要** —— 明文本来也拿不到，
     * 摘要同样不该出接口）。
     */
    public func listByGroup(groupId: Int64, limit: Int64): RowSet {
        let sql = "SELECT id, group_id, inviter_id, target_role, max_uses, used_count, " +
                  "fail_count, max_fails, revoked, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms " +
                  "FROM fam_invites WHERE group_id = ? ORDER BY created_at DESC, id DESC LIMIT ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            st.set(1, limit)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 撤销（按组校验归属，单向）。 */
    public func revoke(id: Int64, groupId: Int64): Bool {
        let sql = "UPDATE fam_invites SET revoked = TRUE WHERE id = ? AND group_id = ? " +
                  "AND revoked = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, groupId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 消耗一次使用次数（**原子**）。
     *
     * 为什么必须原子：docs/14 §12.3 要求「同一邀请并发 accept 10 次 →
     * 仅 1 次成功」。先 SELECT 判定再 UPDATE 的做法，在并发下会全部读到
     * `used_count = 0` 然后各自加一，10 次全成功。
     * 这里把「未撤销 + 未过期 + 次数未满」三个条件全放进 UPDATE 的 WHERE，
     * 由数据库的行锁保证只有一个事务能让 rowCount = 1。
     *
     * @return 是否抢到一次使用机会
     */
    public func consumeOnce(id: Int64): Bool {
        let sql = "UPDATE fam_invites SET used_count = used_count + 1 " +
                  "WHERE id = ? AND revoked = FALSE " +
                  "AND used_count < max_uses " +
                  "AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP) " +
                  "AND (max_fails <= 0 OR fail_count < max_fails)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 记录一次 code 错误，并在达到上限时**同一条语句内**撤销。
     *
     * 与共享链接 `bumpFail` 同样的理由：拆成「自增 → 读 → 撤销」时，
     * 中间任一步之后进程被杀就会留下 `fail_count = max_fails` 但
     * `revoked = FALSE` 的邀请 —— 攻击者白得一次尝试机会。
     */
    public func bumpFail(id: Int64): Int64 {
        let bumpSql = "UPDATE fam_invites SET fail_count = fail_count + 1, " +
                      "revoked = CASE WHEN max_fails > 0 AND fail_count + 1 >= max_fails " +
                      "THEN TRUE ELSE revoked END WHERE id = ?"
        let readSql = "SELECT fail_count FROM fam_invites WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(bumpSql)
            st.set(0, id)
            st.update()
            let st2 = c.prepareStatement(readSql)
            st2.set(0, id)
            let rows = readRows(st2.query())
            match (rows.first()) {
                case Some(r) => return r.i64("fail_count")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 全部未撤销邀请的 ID（供「解散组」级联撤销用）。 */
    public func revokeAllByGroup(groupId: Int64): Int64 {
        let sql = "UPDATE fam_invites SET revoked = TRUE WHERE group_id = ? AND revoked = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

/**
 * 家庭组授权仓储（写 acl_grants + fam_grants 两张表）。
 */
public class FamGrantRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 创建一条组内授权。
     *
     * 语义严格对齐 `Grant.covers()`：
     *   · itemId > 0        → 条目级（命中即放行，不再看主体）
     *   · category > 0      → 同主体内按分类收窄
     *   · 两者都未给        → 主体级（整个主体的全部条目）
     *
     * @param expiresAtMs 0 = 永不过期
     */
    public func create(
        groupId: Int64,
        subjectId: Int64,
        itemId: Int64,
        category: Int64,
        granteeId: Int64,
        permCodes: String,
        grantedBy: Int64,
        expiresAtMs: Int64
    ): Int64 {
        let id = Ids.next()
        let grantSql = "INSERT INTO acl_grants (id, subject_id, item_id, category, " +
                       "grantee_id, perm_codes, granted_by, granted_at, expires_at) " +
                       "VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, " +
                       "CASE WHEN ? > 0 THEN to_timestamp(? / 1000.0) ELSE NULL END)"
        let linkSql = "INSERT INTO fam_grants (grant_id, group_id, created_at) " +
                      "VALUES (?, ?, CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(grantSql)
            st.set(0, id)
            st.set(1, subjectId)
            if (itemId <= 0) {
                st.setNull(2)
            } else {
                st.set(2, itemId)
            }
            st.set(3, if (category < 0) { 0 } else { category })
            st.set(4, granteeId)
            st.set(5, permCodes)
            st.set(6, grantedBy)
            st.set(7, expiresAtMs)
            st.set(8, expiresAtMs)
            st.update()

            let st2 = c.prepareStatement(linkSql)
            st2.set(0, id)
            st2.set(1, groupId)
            st2.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 组内授权列表（join acl_grants 取真实状态）。
     *
     * `expired` / `active` 由 SQL 现算，避免前端再算一遍时间。
     */
    public func listByGroup(groupId: Int64, limit: Int64): RowSet {
        let sql = "SELECT g.id, g.subject_id, g.item_id, g.category, g.grantee_id, " +
                  "g.perm_codes, g.granted_by, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM g.granted_at) * 1000, 0) AS BIGINT) AS granted_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM g.expires_at) * 1000, 0) AS BIGINT) AS expires_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM g.revoked_at) * 1000, 0) AS BIGINT) AS revoked_ms, " +
                  "CASE WHEN g.revoked_at IS NOT NULL THEN FALSE " +
                  "     WHEN g.expires_at IS NOT NULL AND g.expires_at <= CURRENT_TIMESTAMP THEN FALSE " +
                  "     ELSE TRUE END AS active " +
                  "FROM acl_grants g JOIN fam_grants fg ON fg.grant_id = g.id " +
                  "WHERE fg.group_id = ? ORDER BY g.granted_at DESC, g.id DESC LIMIT ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            st.set(1, limit)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 该组是否持有此授权（用于「只能撤销本组的授权」）。 */
    public func belongsToGroup(grantId: Int64, groupId: Int64): Bool {
        let sql = "SELECT COUNT(*) AS n FROM fam_grants WHERE grant_id = ? AND group_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, grantId)
            st.set(1, groupId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n") > 0
                case None => return false
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 该授权属于哪个家庭组（0 = 不属于任何组）。
     *
     * `DELETE /api/family/grants/:id` 的路径里没有 groupId，必须先反查
     * 归属组才能做权限校验 —— 否则任何登录用户都能撤销别人的授权。
     */
    public func groupOf(grantId: Int64): Int64 {
        let sql = "SELECT group_id FROM fam_grants WHERE grant_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, grantId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("group_id")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 撤销单条（保留记录，仅置 revoked_at）。 */
    public func revoke(grantId: Int64, reason: String): Bool {
        let sql = "UPDATE acl_grants SET revoked_at = CURRENT_TIMESTAMP, revoke_reason = ? " +
                  "WHERE id = ? AND revoked_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, reason)
            st.set(1, grantId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 撤销某组的全部授权（解散组 / 移除成员共用）。
     *
     * 移除成员时按 (groupId, granteeId) 收窄，解散组时不带 granteeId。
     *
     * @return 实际撤销条数
     */
    public func revokeAll(groupId: Int64, granteeId: Int64, reason: String): Int64 {
        let whereGrantee = if (granteeId > 0) {
            " AND g.grantee_id = ?"
        } else {
            ""
        }
        let sql = "UPDATE acl_grants SET revoked_at = CURRENT_TIMESTAMP, revoke_reason = ? " +
                  "WHERE revoked_at IS NULL AND id IN (" +
                  "SELECT g.id FROM acl_grants g JOIN fam_grants fg ON fg.grant_id = g.id " +
                  "WHERE fg.group_id = ?" + whereGrantee + ")"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, reason)
            st.set(1, groupId)
            if (granteeId > 0) {
                st.set(2, granteeId)
            }
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 该用户在某主体下的有效授权条数（成员可见性统计用）。
     *
     * 只返回计数，不返回任何条目内容 —— 与 FR-ACL-013 权限预览同口径。
     */
    public func countActiveForGrantee(groupId: Int64, granteeId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM acl_grants g JOIN fam_grants fg ON fg.grant_id = g.id " +
                  "WHERE fg.group_id = ? AND g.grantee_id = ? AND g.revoked_at IS NULL " +
                  "AND (g.expires_at IS NULL OR g.expires_at > CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, groupId)
            st.set(1, granteeId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 家庭成员可见条目列表（FR-ACL-010 的**专用只读出口**）。
     *
     * 为什么不复用 `GET /api/items`：
     *   那条路径要求 `archive:read:own` 等功能权限，而新注册账号默认
     *   **没有任何角色**（默认拒绝是刻意设计）。若强制要求全局角色，
     *   家人必须先找管理员开权限，功能等于不可用；若为此自动写
     *   `sys_user_roles`，又违背 docs/14 §3 T3「入组不改变全局权限」。
     *
     * 于是单独开一条**只认授权、不认角色**的通道：
     *   只要 `acl_grants` 里有覆盖该条目的有效记录就能读，
     *   多余的一条也读不到（谓词与 `Grant.covers()` 逐条对齐）。
     *   写、删、导出、分享仍走主路径，因此这条通道不会放大权限。
     */
    public func listSharedItems(granteeId: Int64, limit: Int64, offset: Int64): RowSet {
        let sql = "SELECT i.id, i.subject_id, i.category, i.title, i.status, i.sensitivity, " +
                  "i.issued_date, i.expires_at, i.issuer, i.remark, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM i.updated_at) * 1000, 0) AS BIGINT) AS updated_ms " +
                  "FROM arc_items i WHERE i.deleted_at IS NULL AND " +
                  FamGrantRepo.sharedPredicate() +
                  " ORDER BY i.updated_at DESC, i.id DESC LIMIT ? OFFSET ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, granteeId)
            st.set(1, limit)
            st.set(2, offset)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 家庭成员可见条目总数（与 listSharedItems 同一谓词，避免分页错乱）。 */
    public func countSharedItems(granteeId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM arc_items i WHERE i.deleted_at IS NULL AND " +
                  FamGrantRepo.sharedPredicate()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, granteeId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 「条目 i 是否被 granteeId 的某条有效授权覆盖」的谓词。
     *
     * 只抽成一个字符串常量式方法，是因为 list / count / 详情三处
     * 必须逐字一致 —— 三份手写 SQL 迟早会漂移出一条「列表能看、
     * 详情打不开」的裂缝，而那种缺陷在测试里极难被发现。
     */
    private static func sharedPredicate(): String {
        return "EXISTS (SELECT 1 FROM acl_grants g WHERE g.grantee_id = ? " +
               "AND g.revoked_at IS NULL " +
               "AND (g.expires_at IS NULL OR g.expires_at > CURRENT_TIMESTAMP) " +
               "AND (g.item_id = i.id " +
               "     OR (g.item_id IS NULL " +
               "         AND g.subject_id = i.subject_id " +
               "         AND (g.category IS NULL OR g.category = 0 " +
               "              OR g.category = i.category))))"
    }

    /** 单条：该条目是否被授权覆盖（详情用；不返回内容，由调用方再查）。 */
    public func canReadItem(granteeId: Int64, itemId: Int64): Bool {
        let sql = "SELECT COUNT(*) AS n FROM arc_items i WHERE i.id = ? AND i.deleted_at IS NULL " +
                  "AND " + FamGrantRepo.sharedPredicate()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            st.set(1, granteeId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n") > 0
                case None => return false
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
