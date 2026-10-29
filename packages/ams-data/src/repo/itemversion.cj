// ============================================================
// ams.data.repo.itemversion · 条目历史版本仓储（FR-ARCH-011）
//
// 职责：
//   · create() 写入「更新前」状态的快照（同 item+version 幂等）
//   · list()   列出某条目的全部快照（版本倒序）
//   · get()    取单个快照（回滚用）
//
// 设计约束：
//   snapshot 为 JSON 文本，结构见 db/migrations/012_item_versions.sql。
//   唯一键 (item_id, version) 保证幂等；回滚时 version 继续递增，
//   不覆盖历史，也不破坏乐观锁。
// ============================================================
package ams.data.repo

import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 条目历史版本仓储。
 */
public class ItemVersionRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 写入快照（幂等：同 item_id + version 已存在则跳过）。
     *
     * @param itemId     条目 ID
     * @param version    快照对应的（更新前）版本号
     * @param snapshot   状态 JSON
     * @param operatorId 操作者用户 ID
     */
    public func create(itemId: Int64, version: Int64, snapshot: String, operatorId: Int64): Unit {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO arc_item_versions (id, item_id, version, snapshot, changed_by, changed_at) " +
                "SELECT ?, ?, ?, ?, ?, CURRENT_TIMESTAMP " +
                "WHERE NOT EXISTS (SELECT 1 FROM arc_item_versions WHERE item_id = ? AND version = ?)"
            )
            st.set(0, Ids.next())
            st.set(1, itemId)
            st.set(2, version)
            st.set(3, snapshot)
            st.set(4, operatorId)
            st.set(5, itemId)
            st.set(6, version)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出某条目的全部快照（版本倒序）。
     */
    public func list(itemId: Int64): RowSet {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, item_id, version, snapshot, COALESCE(change_note, '') AS change_note, " +
                "CAST(COALESCE(EXTRACT(EPOCH FROM changed_at) * 1000, 0) AS BIGINT) AS changed_ms, " +
                "CAST(COALESCE(changed_by, 0) AS BIGINT) AS changed_by " +
                "FROM arc_item_versions WHERE item_id = ? ORDER BY version DESC"
            )
            st.set(0, itemId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取单个快照（归属由调用方按 itemId 限定，天然隔离）。
     */
    public func get(itemId: Int64, versionId: Int64): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, item_id, version, snapshot, COALESCE(change_note, '') AS change_note, " +
                "CAST(COALESCE(EXTRACT(EPOCH FROM changed_at) * 1000, 0) AS BIGINT) AS changed_ms, " +
                "CAST(COALESCE(changed_by, 0) AS BIGINT) AS changed_by " +
                "FROM arc_item_versions WHERE item_id = ? AND id = ?"
            )
            st.set(0, itemId)
            st.set(1, versionId)
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
}
