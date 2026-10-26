// ============================================================
// ams.api.routes.search · 检索接口
//
// 覆盖：
//   FR-SRC-001 关键词全文检索 → GET /api/search
//   FR-SRC-002 结构化筛选    → 同上（分类/状态/机构/时间区间/标签）
//   FR-SRC-003 排序          → sort=updated|created|title|expires|issuer|attachment
//   FR-SRC-004 游标分页      → 响应含 nextCursor 与 **has_more**
//   FR-SRC-006 展开留痕      → POST /api/search/reveal（需 archive:read_sensitive）
//
// 【归属强制】
//   subjectIds **只能由服务端**从调用者的可访问主体集合算出（FR-ACL-006），
//   前端任何传入的 subject 参数一律忽略 —— 这是防越权的关键。
//
// 【has_more 的判定】
//   SearchRepo 多取一条；这里按 pageSize 截断，多出来的那条即证明还有下一页。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.search.*
import ams.core.search.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 检索接口。
 */
public class SearchRoutes {
    private let service: SearchService
    private let userRepo: UserRepo

    public init(service: SearchService, userRepo: UserRepo) {
        this.service = service
        this.userRepo = userRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/search", { req: ApiRequest => this.doSearch(req) },
                   requiredPerm: "archive:read:own")
        router.post("/api/search/reveal", { req: ApiRequest => this.reveal(req) },
                    requiredPerm: "archive:read_sensitive")
    }

    // ---------------------------------------------------------

    /**
     * GET /api/search
     *
     * 查询参数：
     *   keyword / category / status / issuer / issuedFrom / issuedTo /
     *   expiresFrom / expiresTo / tags / sort / dir / size / cursor
     */
    private func doSearch(req: ApiRequest): ApiResponse {
        let keyword = match (req.queryParam("keyword")) {
            case Some(v) => v
            case None => ""
        }

        // 归属：服务端算出，忽略任何前端传入
        let uid = UserRepo.parseId(req.subjectId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()

        let categories = SearchRoutes.intList(req, "category")
        let statuses = SearchRoutes.intList(req, "status")
        let tags = SearchRoutes.strList(req, "tags")

        let issuer = match (req.queryParam("issuer")) {
            case Some(v) => v
            case None => ""
        }
        let issuedFrom = SearchRoutes.queryOrEmpty(req, "issuedFrom")
        let issuedTo = SearchRoutes.queryOrEmpty(req, "issuedTo")
        let expiresFrom = SearchRoutes.queryOrEmpty(req, "expiresFrom")
        let expiresTo = SearchRoutes.queryOrEmpty(req, "expiresTo")

        let sort = SearchRoutes.parseSort(req)
        let size = SearchRoutes.intOfQuery(req, "size", 20)
        let pageSize = if (size < 1) { 20 } else if (size > 200) { 200 } else { size }

        var cursor = Cursor("", "")
        match (req.queryParam("cursor")) {
            case Some(v) =>
                match (Cursor.decode(v)) {
                    case Some(c) => cursor = c
                    case None => cursor = Cursor("", "")
                }
            case None => cursor = Cursor("", "")
        }

        let q = SearchQuery(
            keyword,
            subjects,
            categories,
            statuses,
            issuer,
            issuedFrom,
            issuedTo,
            expiresFrom,
            expiresTo,
            tags,
            [],
            [],
            sort,
            pageSize,
            cursor
        )

        let rows = this.service.search(q)
        let all = rows.all()
        let hasMore = all.size > pageSize
        let take = if (hasMore) { pageSize } else { all.size }

        // 掩码：敏感字段默认不返回明文（FR-SRC-006）
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var i: Int64 = 0
        while (i < take) {
            let r = all[i]
            if (i > 0) {
                sb.append(",")
            }
            sb.append(SearchRoutes.toJson(r))
            i = i + 1
        }
        sb.append("],\"hasMore\":${hasMore},\"size\":${pageSize}")

        // 下一页游标：取本页最后一条的排序键
        if (hasMore && take > 0) {
            let last = all[take - 1]
            let key = SearchRoutes.sortKeyOf(last, sort.field)
            sb.append(",\"nextCursor\":\"${Cursor(key, "${last.i64("id")}").encode()}\"")
        } else {
            sb.append(",\"nextCursor\":\"\"")
        }
        sb.append("}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/search/reveal —— 展开敏感字段明文（需 archive:read_sensitive）。
     *
     * 请求体：{"itemId":123,"fieldKey":"id_number"}
     */
    private func reveal(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let itemId = RowData.toI64(json.get("itemId") ?? "0")
        let fieldKey = json.get("fieldKey") ?? ""
        if (itemId == 0 || fieldKey.isEmpty()) {
            throw validationError("itemId", "缺少 itemId 或 fieldKey")
        }
        let actorId = UserRepo.parseId(req.subjectId)
        let plain = this.service.reveal(
            itemId,
            fieldKey,
            actorId,
            true,   // 能进到这里说明路由层已校验 archive:read_sensitive
            req.remoteAddr,
            req.header("user-agent") ?? ""
        )
        return ApiResponse.ok(
            "{\"itemId\":${itemId},\"fieldKey\":\"${ApiResponse.escape(fieldKey)}\"," +
            "\"value\":\"${ApiResponse.escape(plain)}\"}",
            req.requestId
        )
    }

    // ---------------------------------------------------------

    /**
     * 解析排序：sort=updated|created|title|expires|issuer|attachment，dir=asc|desc
     */
    private static func parseSort(req: ApiRequest): SortSpec {
        var field = SortField.UpdatedAt
        match (req.queryParam("sort")) {
            case Some(v) =>
                if (v == "created") { field = SortField.CreatedAt }
                else if (v == "title") { field = SortField.Title }
                else if (v == "expires") { field = SortField.ExpiresAt }
                else if (v == "issuer") { field = SortField.Issuer }
                else if (v == "attachment") { field = SortField.AttachmentCount }
                else { field = SortField.UpdatedAt }
            case None => field = SortField.UpdatedAt
        }
        var direction = SortDirection.Desc
        match (req.queryParam("dir")) {
            case Some(v) =>
                if (v == "asc") { direction = SortDirection.Asc }
                else { direction = SortDirection.Desc }
            case None => direction = SortDirection.Desc
        }
        return SortSpec(field, direction)
    }

    /**
     * 取某行在当前排序字段下的游标键（时间统一用毫秒串，与 SearchRepo 一致）。
     */
    private static func sortKeyOf(r: RowData, field: SortField): String {
        match (field) {
            case SortField.UpdatedAt => return "${r.i64("updated_ms")}"
            case SortField.CreatedAt => return "${r.i64("created_ms")}"
            case SortField.Title => return r.str("title")
            case SortField.ExpiresAt => return "${r.i64("expires_ms")}"
            case SortField.Issuer => return r.str("issuer")
            case SortField.AttachmentCount => return "${r.i64("attachment_count")}"
        }
    }

    private static func toJson(r: RowData): String {
        // 敏感条目（>=2）不在此处返回任何扩展字段明文，仅给元信息
        let sens = r.i64("sensitivity")
        let issuerRaw = r.str("issuer")
        let issuer = if (sens >= 2) { Masker.mask(issuerRaw, sens) } else { issuerRaw }
        let sb = StringBuilder()
        sb.append("{\"id\":${r.i64("id")},")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"title\":\"${ApiResponse.escape(r.str("title"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"sensitivity\":${sens},")
        sb.append("\"issuer\":\"${ApiResponse.escape(issuer)}\",")
        sb.append("\"issuedDate\":\"${ApiResponse.escape(r.str("issued_date"))}\",")
        sb.append("\"expiresDate\":\"${ApiResponse.escape(r.str("expires_date"))}\",")
        sb.append("\"attachmentCount\":${r.i64("attachment_count")},")
        sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    // ---------------------------------------------------------

    private static func queryOrEmpty(req: ApiRequest, key: String): String {
        match (req.queryParam(key)) {
            case Some(v) => return v
            case None => return ""
        }
    }

    private static func intOfQuery(req: ApiRequest, key: String, default: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }

    /**
     * 逗号分隔的整数列表参数（如 category=1,3）。
     */
    private static func intList(req: ApiRequest, key: String): Array<Int64> {
        let out = ArrayList<Int64>()
        match (req.queryParam(key)) {
            case Some(v) =>
                if (!v.isEmpty()) {
                    for (p in v.split(",")) {
                        let t = p.trimStart().trimEnd()
                        if (!t.isEmpty()) {
                            out.add(RowData.toI64(t))
                        }
                    }
                }
            case None => ()
        }
        return out.toArray()
    }

    /**
     * 逗号分隔的字符串列表参数（如 tags=1,2）。
     */
    private static func strList(req: ApiRequest, key: String): Array<String> {
        let out = ArrayList<String>()
        match (req.queryParam(key)) {
            case Some(v) =>
                if (!v.isEmpty()) {
                    for (p in v.split(",")) {
                        let t = p.trimStart().trimEnd()
                        if (!t.isEmpty()) {
                            out.add(t)
                        }
                    }
                }
            case None => ()
        }
        return out.toArray()
    }
}
