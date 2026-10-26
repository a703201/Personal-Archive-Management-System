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
     */
    public func upsertIndex(
        itemId: Int64,
        subjectId: Int64,
        category: Int64,
        titleNorm: String,
        content: String,
        tokens: Array<String>
    ): Unit {
        let sql = "INSERT INTO arc_search_index " +
                  "(item_id, subject_id, category, title_norm, content, tokens, updated_at) " +
                  "VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) " +
                  "ON CONFLICT (item_id) DO UPDATE SET " +
                  "subject_id = EXCLUDED.subject_id, category = EXCLUDED.category, " +
                  "title_norm = EXCLUDED.title_norm, content = EXCLUDED.content, " +
                  "tokens = EXCLUDED.tokens, updated_at = CURRENT_TIMESTAMP"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            st.set(1, subjectId)
            st.set(2, category)
            st.set(3, titleNorm)
            st.set(4, content)
            st.set(5, tokens)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
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

        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sb.toString())
            SearchRepo.bind(st, params)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
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
}
