// ============================================================
// ams.api.routes.export · 导出接口（FR-EXP-004 / FR-EXP-007）
//
// 路由：POST /api/export  （需 archive:export:own）
//
// 行为：
//   - 解析筛选条件（分类 / 状态 / 关键字 / 行数 / 是否含高敏）
//   - 按权限范围确定可导出主体（export:any → 全部可访问；否则仅本人拥有）
//   - 调用 ExportService（内部计量配额 + 生成 CSV + 写审计）
//   - 以 text/csv 附件形式返回
//
// [安全] 导出属于高敏操作，必须鉴权 + 配额 + 审计三重约束。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.export.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 导出接口处理器。
 */
public class ExportRoutes {
    private let userRepo: UserRepo
    private let exportService: ExportService

    public init(userRepo: UserRepo, exportService: ExportService) {
        this.userRepo = userRepo
        this.exportService = exportService
    }

    /**
     * 注册到路由表。
     */
    public func register(router: Router): Unit {
        router.post("/api/export", { req: ApiRequest => this.export(req) },
            requiredPerm: "archive:export:own")
    }

    /**
     * POST /api/export
     *
     * 请求体：{"category":0,"status":-1,"keyword":"","maxRows":2000,
     *          "includeHighSensitivity":false}
     */
    private func export(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let category = ExportRoutes.intFrom(json, "category", 0)
        let status = ExportRoutes.intFrom(json, "status", -1)
        let keyword = json.get("keyword") ?? ""
        let maxRows = ExportRoutes.intFrom(json, "maxRows", 2000)
        let includeHigh = match (json.get("includeHighSensitivity")) {
            case Some(v) => v == "true" || v == "1"
            case None => false
        }

        // 按权限范围确定可导出主体
        let uid = UserRepo.parseId(req.subjectId)
        let subjectIds = if (req.perms.contains("archive:export:any")) {
            this.userRepo.listAccessibleSubjectIds(uid).toArray()
        } else {
            this.userRepo.listOwnedSubjectIds(uid).toArray()
        }

        let result = this.exportService.exportCsv(
            req.subjectId,
            subjectIds,
            category,
            status,
            keyword,
            maxRows,
            includeHigh,
            req.remoteAddr,
            req.header("user-agent") ?? ""
        )

        let h = HashMap<String, String>()
        h["Content-Type"] = "text/csv; charset=utf-8"
        h["Content-Disposition"] = "attachment; filename=\"archive-export.csv\""
        return ApiResponse(200, result.csv, h)
    }

    /**
     * 取整数字段（缺失 / 空 / 非法 → 默认值）。
     */
    private static func intFrom(json: SimpleJson, key: String, default: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }
}
