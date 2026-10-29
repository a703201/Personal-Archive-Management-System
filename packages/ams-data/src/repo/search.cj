// ============================================================
// ams.data.repo.search · 检索执行层仓储
//
// 覆盖：
//   FR-SRC-001 关键词全文检索（GIN tokens 交叠匹配）
//   FR-SRC-002 结构化筛选（分类/状态/机构/时间区间/标签/敏感度/扩展字段）
//   FR-SRC-003 排序（含 attachment_count）
//   FR-SRC-004 游标分页（keyset + has_more）
//   FR-SRC-005 盲索引等值检索（命中后由上层二次明文比对）
//
// [has_more 怎么来的]
//   取 `pageSize + 1` 条：多出的一条只用来判定「还有没有下一页」，
//   不返回给调用方。这样避免为每页都跑一次 COUNT（FR-SRC-004 明确要求 has_more）。
//
// [为什么用 EXISTS 而不是 JOIN arc_search_index]
//   关键词过滤若用 JOIN，一条索引行会把主表行放大；
//   EXISTS 子查询保持主表行数不变，也免去 DISTINCT 开销。
//
// [keyset 分页]
//   形式为 (sort_expr, id) 的复合比较：
//     Desc: sort_expr < ? OR (sort_expr = ? AND id < ?)
//     Asc : sort_expr > ? OR (sort_expr = ? AND id > ?)
//   时间类字段统一换算成**毫秒整数**比较，避免时区/精度差异导致游标失效。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*
import stdx.encoding.hex.*

import ams.core.search.*
import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 检索执行层仓储。
 */
public class SearchRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 列表查询统一 SELECT 表达式 */
    private static let COLS: String =
        "i.id, i.subject_id, i.category, i.title, i.status, i.sensitivity, " +
        "COALESCE(i.issuer, '') AS issuer, " +
        "COALESCE(TO_CHAR(i.expires_at, 'YYYY-MM-DD'), '') AS expires_date, " +
        "COALESCE(TO_CHAR(i.issued_date, 'YYYY-MM-DD'), '') AS issued_date, " +
        "COALESCE(i.attachment_count, 0) AS attachment_count, " +
        "i.version, " +
        "CAST(COALESCE(EXTRACT(EPOCH FROM i.updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
        "CAST(COALESCE(EXTRACT(EPOCH FROM i.created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
        "CAST(COALESCE(EXTRACT(EPOCH FROM i.expires_at) * 1000, 0) AS BIGINT) AS expires_ms"

    // ------------------------------------------------------------
    // 索引维护（供 SearchService 调用）
    // ------------------------------------------------------------

    /**
     * 建立/更新某条目的检索索引（幂等 upsert）。
     *
     * 【两个坑，此前导致索引恒为空、关键词检索永不命中】
     *   ① `tokens` 是 TEXT[] 列。直接 `st.set(i, Array<String>)`
     *      驱动无法绑定数组类型，抛 "SqlException: not supported type"。
     *      → 改为拼成 PG 数组字面量（{"a","b"}）后以字符串绑定，
     *        再由 SQL 侧 CAST 成 TEXT[]。
     *   ② `ON CONFLICT (item_id) DO UPDATE` 在 openGauss 不支持
     *      （SQLSTATE 42601，与 itemfield.cj 同一处坑）。
     *      → 改为「先 UPDATE，未命中再 INSERT」。
     */
    public func upsertIndex(
        itemId: Int64,
        subjectId: Int64,
        category: Int64,
        titleNorm: String,
        content: String,
        tokens: Array<String>
    ): Unit {
        let setClause = "subject_id = ?, category = ?, title_norm = ?, " +
                        "content = ?, tokens = CAST(? AS TEXT[]), updated_at = CURRENT_TIMESTAMP"
        let insCols = "item_id, subject_id, category, title_norm, content, tokens, updated_at"
        let insVals = "?, ?, ?, ?, ?, CAST(? AS TEXT[]), CURRENT_TIMESTAMP"
        let c = this.db.connect()
        try {
            let upd = c.prepareStatement(
                "UPDATE arc_search_index SET " + setClause + " WHERE item_id = ?"
            )
            SearchRepo.bindIndex(upd, 0, subjectId, category, titleNorm, content, tokens)
            upd.set(5, itemId)
            if (upd.update().rowCount > 0) {
                return
            }
            let ins = c.prepareStatement(
                "INSERT INTO arc_search_index (" + insCols + ") VALUES (" + insVals + ")"
            )
            ins.set(0, itemId)
            SearchRepo.bindIndex(ins, 1, subjectId, category, titleNorm, content, tokens)
            ins.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 绑定索引写入的公共参数（从 start 起连续 5 个）。 */
    private static func bindIndex(
        st: Statement,
        start: Int64,
        subjectId: Int64,
        category: Int64,
        titleNorm: String,
        content: String,
        tokens: Array<String>
    ): Unit {
        st.set(start, subjectId)
        st.set(start + 1, category)
        st.set(start + 2, titleNorm)
        st.set(start + 3, content)
        st.set(start + 4, SearchRepo.toPgTextArray(tokens))
    }

    /**
     * 字符串数组 → PostgreSQL/openGauss 的数组字面量：{"a","b"}。
     *
     * 规则：元素含 `"` `\` `{` `}` `,` 或空白时加双引号，
     * 并把 `"` 转义为 `\"`、`\` 转义为 `\\`。
     */
    private static func toPgTextArray(items: Array<String>): String {
        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for (it in items) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(SearchRepo.pgQuote(it))
        }
        sb.append("}")
        return sb.toString()
    }

    /**
     * 数组元素引号化。
     */
    private static func pgQuote(s: String): String {
        if (s.isEmpty()) {
            return "\"\""
        }
        let escaped = s.replace("\\", "\\\\").replace("\"", "\\\"")
        let needsQuote = s.contains("\"") || s.contains("\\") || s.contains("{") ||
                         s.contains("}") || s.contains(",") || s.contains(" ")
        if (needsQuote) {
            return "\"" + escaped + "\""
        }
        return escaped
    }

    /**
     * 列出**尚未建立索引**的条目 ID（供存量回填）。
     *
     * 场景：索引接线补齐之前已创建的条目，arc_search_index 里没有对应行，
     * 关键词检索会漏掉它们。运维调用 /api/admin/search/reindex 分批回填。
     */
    public func listUnindexedItemIds(limit: Int64): Array<Int64> {
        let sql = "SELECT i.id FROM arc_items i " +
                  "LEFT JOIN arc_search_index s ON s.item_id = i.id " +
                  "WHERE s.item_id IS NULL AND i.deleted_at IS NULL " +
                  "ORDER BY i.id LIMIT ?"
        let out = ArrayList<Int64>()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, limit)
            let rs = st.query()
            for (row in readRows(rs).all()) {
                out.add(row.i64("id"))
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
        return out.toArray()
    }

    // ------------------------------------------------------------
    // 检索
    // ------------------------------------------------------------

    /**
     * 执行检索。
     *
     * 多取一条用于判定 has_more（调用方按 pageSize 截断）。
     *
     * @param q 查询条件（subjectIds 必须已由服务端填好，FR-ACL-006）
     * @param tokens 关键词分词结果（空数组 = 不过滤）
     * @param tagIds 标签 ID 列表
     * @param likePattern 单字查询的 LIKE 兜底模式（无则空串）
     * @return 结果行（最多 pageSize + 1 条）
     */
    public func search(
        q: SearchQuery,
        tokens: Array<String>,
        tagIds: Array<String>,
        likePattern: String
    ): RowSet {
        let sb = StringBuilder()
        let params = ArrayList<SqlParam>()

        sb.append("SELECT " + SearchRepo.COLS + " FROM arc_items i WHERE i.deleted_at IS NULL ")

        // ---- 归属（服务端强制，禁止前端传参决定）----
        if (q.subjectIds.isEmpty()) {
            // 无可访问主体 → 直接返回空结果，不查库
            return RowSet()
        }
        sb.append("AND i.subject_id IN (")
        for (i in 0..q.subjectIds.size) {
            if (i > 0) {
                sb.append(", ")
            }
            sb.append("?")
            params.add(SqlParam.Str(q.subjectIds[i]))
        }
        sb.append(") ")

        // ---- 分类（FR-SRC-002）----
        if (!q.categoryCodes.isEmpty()) {
            sb.append("AND i.category IN (")
            for (i in 0..q.categoryCodes.size) {
                if (i > 0) {
                    sb.append(", ")
                }
                sb.append("?")
                params.add(SqlParam.Num(q.categoryCodes[i]))
            }
            sb.append(") ")
        }

        // ---- 状态 ----
        if (!q.statuses.isEmpty()) {
            sb.append("AND i.status IN (")
            for (i in 0..q.statuses.size) {
                if (i > 0) {
                    sb.append(", ")
                }
                sb.append("?")
                params.add(SqlParam.Num(q.statuses[i]))
            }
            sb.append(") ")
        }

        // ---- 颁发机构（模糊）----
        if (!q.issuer.isEmpty()) {
            sb.append("AND i.issuer LIKE ? ")
            params.add(SqlParam.Str("%${q.issuer}%"))
        }

        // ---- 时间区间 ----
        if (!q.issuedFrom.isEmpty()) {
            sb.append("AND i.issued_date >= CAST(? AS DATE) ")
            params.add(SqlParam.Str(q.issuedFrom))
        }
        if (!q.issuedTo.isEmpty()) {
            sb.append("AND i.issued_date <= CAST(? AS DATE) ")
            params.add(SqlParam.Str(q.issuedTo))
        }
        if (!q.expiresFrom.isEmpty()) {
            sb.append("AND i.expires_at >= CAST(? AS DATE) ")
            params.add(SqlParam.Str(q.expiresFrom))
        }
        if (!q.expiresTo.isEmpty()) {
            sb.append("AND i.expires_at <= CAST(? AS DATE) ")
            params.add(SqlParam.Str(q.expiresTo))
        }

        // ---- 创建时间范围（FR-SRC-010）----
        if (!q.createdFrom.isEmpty()) {
            sb.append("AND i.created_at >= CAST(? AS TIMESTAMP) ")
            params.add(SqlParam.Str(q.createdFrom))
        }
        if (!q.createdTo.isEmpty()) {
            sb.append("AND i.created_at <= CAST(? AS TIMESTAMP) ")
            params.add(SqlParam.Str(q.createdTo))
        }

        // ---- 来源系统筛选（FR-SRC-010）----
        // 0 视为「不过滤」：手动录入的来源也是 0，故只有显式指定 ≥1 才加条件。
        if (q.source > 0) {
            sb.append("AND i.source = ? ")
            params.add(SqlParam.Num(q.source))
        }

        // ---- 标签（FR-SRC-002）----
        if (!tagIds.isEmpty()) {
            sb.append("AND EXISTS (SELECT 1 FROM arc_item_tags t WHERE t.item_id = i.id AND t.tag_id IN (")
            for (i in 0..tagIds.size) {
                if (i > 0) {
                    sb.append(", ")
                }
                sb.append("?")
                params.add(SqlParam.Str(tagIds[i]))
            }
            sb.append(")) ")
        }

        // ---- 关键词（FR-SRC-001）：GIN tokens 交叠 ----
        if (!tokens.isEmpty()) {
            sb.append("AND EXISTS (SELECT 1 FROM arc_search_index s WHERE s.item_id = i.id ")
            sb.append("AND s.tokens && ARRAY[")
            for (i in 0..tokens.size) {
                if (i > 0) {
                    sb.append(", ")
                }
                sb.append("?")
                params.add(SqlParam.Str(tokens[i]))
            }
            sb.append("]::text[]) ")
        }

        // ---- 单字查询 LIKE 兜底 ----
        if (!likePattern.isEmpty()) {
            sb.append("AND (i.title LIKE ? OR EXISTS (SELECT 1 FROM arc_search_index s2 " +
                      "WHERE s2.item_id = i.id AND s2.content LIKE ?)) ")
            params.add(SqlParam.Str(likePattern))
            params.add(SqlParam.Str(likePattern))
        }

        // ---- 盲索引等值（FR-SRC-005）----
        // value_bidx 是 BYTEA；这里把盲索引值转成十六进制串，
        // 交由数据库 decode(?, 'hex') 还原后比对 —— 避免驱动绑定字节数组的差异。
        for (bf in q.blindFilters) {
            sb.append("AND EXISTS (SELECT 1 FROM arc_item_fields f " +
                      "JOIN arc_field_defs d ON d.id = f.field_def_id " +
                      "WHERE f.item_id = i.id AND d.field_key = ? " +
                      "AND f.value_bidx = decode(?, 'hex')) ")
            params.add(SqlParam.Str(bf[0]))
            params.add(SqlParam.Str(toHexString(bf[1])))
        }

        // ---- keyset 游标（FR-SRC-004）----
        let hasCursor = !q.cursor.sortKey.isEmpty() && !q.cursor.id.isEmpty()
        if (hasCursor) {
            let expr = SearchRepo.sortExpr(q.sort.field)
            // 枚举不能用 == 比较，只能 match
            var op = ">"
            match (q.sort.direction) {
                case SortDirection.Desc => op = "<"
                case SortDirection.Asc => op = ">"
            }
            sb.append("AND (${expr} ${op} ? OR (${expr} = ? AND i.id ${op} ?)) ")
            params.add(SqlParam.Str(q.cursor.sortKey))
            params.add(SqlParam.Str(q.cursor.sortKey))
            params.add(SqlParam.Str(q.cursor.id))
        }

        // ---- 排序 ----
        sb.append(SearchRepo.orderBy(q.sort))

        // ---- 多取一条判定 has_more ----
        sb.append(" LIMIT ? ")
        params.add(SqlParam.Num(q.pageSize + 1))

        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sb.toString())
            SearchRepo.bind(st, params)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------

    /**
     * 排序字段 → SQL 表达式。
     */
    private static func sortExpr(field: SortField): String {
        match (field) {
            case SortField.UpdatedAt => return "updated_ms"
            case SortField.CreatedAt => return "created_ms"
            case SortField.Title => return "i.title"
            case SortField.ExpiresAt => return "expires_ms"
            case SortField.Issuer => return "i.issuer"
            case SortField.AttachmentCount => return "attachment_count"
        }
    }

    /**
     * ORDER BY 子句（含第二排序键 id，保证游标稳定）。
     */
    private static func orderBy(sort: SortSpec): String {
        let expr = SearchRepo.sortExpr(sort.field)
        var dir = "ASC"
        match (sort.direction) {
            case SortDirection.Desc => dir = "DESC"
            case SortDirection.Asc => dir = "ASC"
        }
        return "ORDER BY ${expr} ${dir}, i.id ${dir} "
    }

    private static func bind(st: Statement, params: ArrayList<SqlParam>): Unit {
        var i: Int = 0
        for (p in params.iterator()) {
            match (p) {
                case SqlParam.Str(v) =>
                    if (v.isEmpty()) {
                        st.setNull(i)
                    } else {
                        st.set(i, v)
                    }
                case SqlParam.Num(v) => st.set(i, v)
                case SqlParam.Nul => st.setNull(i)
            }
            i = i + 1
        }
    }

    /**
     * 搜索建议（FR-SRC-007）：匹配 query 的标签名（按使用频次排序）。
     */
    public func suggestTags(q: String, ownerId: Int64): ArrayList<String> {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT name FROM arc_tags WHERE owner_id = ? AND deleted_at IS NULL " +
                "AND name ILIKE ? ORDER BY usage_count DESC, name LIMIT 10"
            )
            st.set(0, ownerId)
            st.set(1, "%${q}%")
            let out = ArrayList<String>()
            for (r in readRows(st.query()).all().iterator()) {
                out.add(r.str("name"))
            }
            return out
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 搜索建议（FR-SRC-007）：匹配 query 的颁发机构（去重）。
     */
    public func suggestOrgs(q: String, subjectIds: Array<String>): ArrayList<String> {
        if (subjectIds.isEmpty()) {
            return ArrayList<String>()
        }
        let c = this.db.connect()
        try {
            let sb = StringBuilder()
            sb.append(
                "SELECT DISTINCT issuer FROM arc_items WHERE deleted_at IS NULL " +
                "AND issuer ILIKE ? AND issuer IS NOT NULL AND issuer <> '' AND subject_id IN ("
            )
            for (i in 0..subjectIds.size) {
                if (i > 0) {
                    sb.append(", ")
                }
                sb.append("?")
            }
            sb.append(") ORDER BY issuer LIMIT 10")
            let st = c.prepareStatement(sb.toString())
            st.set(0, "%${q}%")
            for (i in 0..subjectIds.size) {
                st.set(i + 1, subjectIds[i])
            }
            let out = ArrayList<String>()
            for (r in readRows(st.query()).all().iterator()) {
                out.add(r.str("issuer"))
            }
            return out
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------
    // 保存的筛选视图（FR-SRC-008）
    // ------------------------------------------------------------

    /**
     * 保存命名视图。
     */
    public func saveView(ownerId: Int64, name: String, queryJson: String, pinned: Bool): Int64 {
        let id = Ids.next()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO arc_saved_views (id, owner_id, name, query_json, is_pinned, " +
                "created_at, updated_at) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
            )
            st.set(0, id)
            st.set(1, ownerId)
            st.set(2, name)
            st.set(3, queryJson)
            st.set(4, pinned)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出某用户的视图（置顶优先、最近更新优先）。
     */
    public func listViews(ownerId: Int64): RowSet {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, owner_id, name, query_json, is_pinned, " +
                "(EXTRACT(EPOCH FROM updated_at) * 1000)::bigint AS updated_at_ms " +
                "FROM arc_saved_views WHERE owner_id = ? AND deleted_at IS NULL " +
                "ORDER BY is_pinned DESC, updated_at DESC"
            )
            st.set(0, ownerId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除视图。
     */
    public func deleteView(ownerId: Int64, id: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE arc_saved_views SET deleted_at = CURRENT_TIMESTAMP, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
            )
            st.set(0, id)
            st.set(1, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------
    // 搜索历史（FR-SRC-009）
    // ------------------------------------------------------------

    /**
     * 记录一次搜索：同一 owner+query 则命中计数 +1、刷新时间；否则新建。
     */
    public func recordSearch(ownerId: Int64, query: String): Unit {
        let c = this.db.connect()
        try {
            let upd = c.prepareStatement(
                "UPDATE arc_search_history SET hit_count = hit_count + 1, " +
                "last_used_at = CURRENT_TIMESTAMP WHERE owner_id = ? AND query = ? AND deleted_at IS NULL"
            )
            upd.set(0, ownerId)
            upd.set(1, query)
            if (upd.update().rowCount > 0) {
                return
            }
            let ins = c.prepareStatement(
                "INSERT INTO arc_search_history (id, owner_id, query, hit_count, " +
                "last_used_at, created_at) VALUES (?, ?, ?, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
            )
            ins.set(0, Ids.next())
            ins.set(1, ownerId)
            ins.set(2, query)
            ins.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出个人搜索历史（最近使用优先）。
     */
    public func listSearchHistory(ownerId: Int64, limit: Int64): RowSet {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, owner_id, query, hit_count, " +
                "(EXTRACT(EPOCH FROM last_used_at) * 1000)::bigint AS last_used_at_ms " +
                "FROM arc_search_history WHERE owner_id = ? AND deleted_at IS NULL " +
                "ORDER BY last_used_at DESC LIMIT ?"
            )
            st.set(0, ownerId)
            st.set(1, limit)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 清除个人搜索历史（软删除）。返回清除条数。
     */
    public func clearSearchHistory(ownerId: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE arc_search_history SET deleted_at = CURRENT_TIMESTAMP " +
                "WHERE owner_id = ? AND deleted_at IS NULL"
            )
            st.set(0, ownerId)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
