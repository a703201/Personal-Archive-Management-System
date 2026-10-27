// ============================================================
// ams.data.repo.subject · 档案主体仓储（arc_subjects）
//
// 背景（补齐里程碑缺口）：
//   此前 **全仓无任何 arc_subjects 的写入点** —— 没有 SubjectRepo、
//   没有 /api/subjects 路由、注册也不建主体。
//   而 ItemRoutes.createItem 强制校验：
//     subjectId 必须落在 UserRepo.listAccessibleSubjectIds(userId) 里，
//   否则 403「无权限在该主体下创建条目」。
//   结果就是：任何用户（含 owner 角色）**永远无法创建第一条档案**。
//   本仓储即为该断链的写侧。
//
// 设计要点：
//   ① name_enc 是 BYTEA 密文列，仓储**不做**加解密（分层纪律：
//      仓储只关心「数据库里是什么」），明文 <-> 密文的转换在
//      ams.app.subject.SubjectService 完成；
//   ② 读取时用 encode(name_enc,'hex') 取回十六进制串 ——
//      RowData 只能承载字符串，直接读 BYTEA 取不到值
//      （与 AuditRepo 同一处理方式，见 user.cj 的踩坑注释）；
//   ③ 归属过滤在 SQL 层一次做完（owner_id = ? OR ? = ANY(custodian_ids)），
//      与服务端算出的可访问主体集合同源（FR-ACL-006）；
//   ④ 写操作用 owner_id 兜底，代管人（custodian）可读不可改。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*
import stdx.encoding.hex.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 档案主体仓储。
 */
public class SubjectRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 公共查询列。
     *
     * 姓名只以十六进制密文串返回；alias / summary 为明文列，可直接展示。
     */
    private static let COLUMNS = "id, encode(name_enc, 'hex') AS name_hex, alias, relation, " +
                                 "is_primary, status, completeness, summary, " +
                                 "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                                 "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
                                 "version"

    /**
     * 列出调用者可读的主体（自有 + 被委托代管）。
     *
     * 主主体排在前，其后按关系、ID 稳定排序。
     */
    public func list(userId: Int64): RowSet {
        let sql = "SELECT ${SubjectRepo.COLUMNS} FROM arc_subjects " +
                  "WHERE deleted_at IS NULL " +
                  "AND (owner_id = ? OR ? = ANY(custodian_ids)) " +
                  "ORDER BY is_primary DESC, relation ASC, id ASC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            st.set(1, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按 ID 查主体（**限所有者或代管人**）。
     */
    public func findAccessible(id: Int64, userId: Int64): Option<RowData> {
        let sql = "SELECT ${SubjectRepo.COLUMNS} FROM arc_subjects " +
                  "WHERE id = ? AND deleted_at IS NULL " +
                  "AND (owner_id = ? OR ? = ANY(custodian_ids))"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, userId)
            st.set(2, userId)
            let rows = readRows(st.query())
            return rows.first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计用户名下的主体数（未删除）。
     *
     * 用途：懒建「本人」主体前判断是否已有主体（自愈存量账号）。
     */
    public func countByOwner(ownerId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM arc_subjects WHERE owner_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("n")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 新建主体。
     *
     * @param nameEnc   姓名密文（Encrypt-then-MAC 信封，见 SubjectService）
     * @param alias     别称（明文，可空）
     * @param relation  与主账号关系：0=本人 1=配偶 2=子女 3=父母 4=其他
     * @param isPrimary 是否主主体
     * @param summary   备注摘要（可空）
     * @return 新主体 ID
     */
    public func create(
        ownerId: Int64,
        nameEnc: Array<Byte>,
        alias: String,
        relation: Int64,
        isPrimary: Bool,
        summary: String,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_subjects (" +
                  "id, name_enc, alias, relation, is_primary, owner_id, status, summary, " +
                  "created_at, created_by, updated_at, updated_by, version" +
                  ") VALUES (?, ?, ?, ?, ?, ?, 1, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?, 1)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, nameEnc)
            SubjectRepo.bindText(st, 2, alias)
            st.set(3, relation)
            st.set(4, isPrimary)
            st.set(5, ownerId)
            SubjectRepo.bindText(st, 6, summary)
            st.set(7, operatorId)
            st.set(8, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新主体（乐观锁：version 必须匹配，且只能是所有者本人）。
     *
     * @return false = 版本冲突或无权/不存在
     */
    public func update(
        id: Int64,
        ownerId: Int64,
        expectedVersion: Int64,
        nameEnc: Array<Byte>,
        alias: String,
        relation: Int64,
        summary: String,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_subjects SET name_enc = ?, alias = ?, relation = ?, summary = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL AND version = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, nameEnc)
            SubjectRepo.bindText(st, 1, alias)
            st.set(2, relation)
            SubjectRepo.bindText(st, 3, summary)
            st.set(4, operatorId)
            st.set(5, id)
            st.set(6, ownerId)
            st.set(7, expectedVersion)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除主体。
     *
     * 只标记 deleted_at / status，物理行保留 —— 其下档案条目仍可追溯，
     * 由回收站与审计链保证可审计性（FR-ARCH-006）。
     */
    public func softDelete(id: Int64, ownerId: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE arc_subjects SET deleted_at = CURRENT_TIMESTAMP, status = 3, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, id)
            st.set(2, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计该主体下的档案条目数（删除前提示用）。
     */
    public func itemCount(subjectId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM arc_items WHERE subject_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, subjectId)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("n")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 十六进制串 → 字节数组。
     *
     * 与 AuditRepo.fromHex 同语义：解码失败返回空数组，
     * 由上层（解密）判定为不可读，而不是让整个列表查询失败。
     */
    public static func hexToBytes(hex: String): Array<Byte> {
        if (hex.isEmpty()) {
            return Array<Byte>()
        }
        match (fromHexString(hex)) {
            case Some(b) => return b
            case None => return Array<Byte>()
        }
    }

    /**
     * 空串按 NULL 落库。
     *
     * 为什么：alias / summary 是「可空」语义，
     * 存空串会让「是否填写」的判断失效（也让唯一性/检索口径含糊）。
     */
    private static func bindText(st: Statement, idx: Int, v: String): Unit {
        if (v.isEmpty()) {
            st.setNull(idx)
        } else {
            st.set(idx, v)
        }
    }
}
