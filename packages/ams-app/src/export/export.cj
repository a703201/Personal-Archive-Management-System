// ============================================================
// ams.app.export · 导出服务（FR-EXP-004 / FR-EXP-007）
//
// 职责：
//   - 按配额计量导出（5 次/小时、2000 条/天、高敏 24h ≤3 次、并发 2、≤5000 条/次）
//   - 生成 CSV（敏感明文列做掩码，避免导出泄露）
//   - 写入导出审计（AuditAction.DataExport，FR-EXP-004）
//
// [分层] ams-app 不依赖 ams-api；RateLimiter 来自 ams.security.ratelimit（下层）。
// ============================================================
package ams.app.export

import std.collection.*

import ams.app.audit.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.security.ratelimit.*

/**
 * 导出结果。
 */
public class ExportResult {
    /** CSV 文本 */
    public let csv: String
    /** 实际导出行数 */
    public let rowCount: Int64
    /** 是否因单日/单次上限被截断 */
    public let truncated: Bool

    public init(csv: String, rowCount: Int64, truncated: Bool) {
        this.csv = csv
        this.rowCount = rowCount
        this.truncated = truncated
    }
}

/**
 * 导出服务。
 *
 * 配额由共享 RateLimiter 计量（进程内，重启归零）。并发控制为 best-effort
 * （与项目既有内存态一致：不引入锁，牺牲极端并发下的精确性换取简单性）。
 */
public class ExportService {
    private let itemRepo: ItemRepo
    private let limiter: RateLimiter
    private let recorder: ?AuditRecorder
    /** 进行中的导出数（并发 2 控制） */
    private var activeExports: Int64 = 0

    public init(
        itemRepo: ItemRepo,
        limiter: RateLimiter,
        recorder!: ?AuditRecorder = None
    ) {
        this.itemRepo = itemRepo
        this.limiter = limiter
        this.recorder = recorder
    }

    /**
     * 导出条目为 CSV。
     *
     * @param actorId               操作者用户 ID
     * @param subjectIds            可访问的主体范围
     * @param category              分类筛选（0 = 全部）
     * @param status                状态筛选（-1 = 全部）
     * @param keyword               关键字（空 = 不限）
     * @param maxRows               请求行数上限（会被钳制到 5000）
     * @param includeHighSensitivity 是否包含高敏（High）条目（触发更严配额）
     * @param ip / userAgent        审计用
     */
    public func exportCsv(
        actorId: String,
        subjectIds: Array<String>,
        category: Int64,
        status: Int64,
        keyword: String,
        maxRows: Int64,
        includeHighSensitivity: Bool,
        ip: String,
        userAgent: String
    ): ExportResult {
        let now = Times.nowMillis()
        // 并发控制（best-effort）
        if (this.activeExports >= 2) {
            throw AppError(AppErrorKind.RateLimited, "导出任务过多，请稍后再试")
        }
        this.activeExports = this.activeExports + 1
        try {
            let r = this.doExport(
                actorId, subjectIds, category, status, keyword,
                maxRows, includeHighSensitivity, ip, userAgent, now
            )
            this.activeExports = this.activeExports - 1
            return r
        } catch (e: Exception) {
            this.activeExports = this.activeExports - 1
            throw e
        }
    }

    private func doExport(
        actorId: String,
        subjectIds: Array<String>,
        category: Int64,
        status: Int64,
        keyword: String,
        maxRows: Int64,
        includeHighSensitivity: Bool,
        ip: String,
        userAgent: String,
        now: Int64
    ): ExportResult {
        // 配额：5 次/小时
        if (!this.limiter.allow("export:hour", actorId, 5, 3600 * 1000, 1, now)) {
            throw AppError(AppErrorKind.RateLimited, "导出频率超限（5 次/小时）")
        }
        // 单次行数上限（≤5000）
        let cap = if (maxRows <= 0 || maxRows > 5000) { 5000 } else { maxRows }
        // 配额：2000 条/天（按行数计量）
        if (!this.limiter.allow("export:rows:day", actorId, 2000, 24 * 3600 * 1000, cap, now)) {
            throw AppError(AppErrorKind.RateLimited, "导出行数超限（2000 条/天）")
        }
        // 配额：高敏 24h ≤3 次
        if (includeHighSensitivity) {
            if (!this.limiter.allow("export:high", actorId, 3, 24 * 3600 * 1000, 1, now)) {
                throw AppError(AppErrorKind.RateLimited, "高敏数据导出超限（24 小时 3 次）")
            }
        }

        // 查询（cap 行）
        let rows = this.itemRepo.list(subjectIds, category, status, keyword, cap, 0)
        let total = rows.size()

        // 构建 CSV（含表头）
        let sb = StringBuilder()
        sb.append("id,subject_id,category,title,status,sensitivity,issuer,issued_date,expires_at,updated_ms\n")
        for (r in rows.all().iterator()) {
            let sens = r.i64("sensitivity")
            // 未授权包含高敏时，跳过 High 级条目
            if (sens >= 2 && !includeHighSensitivity) {
                continue
            }
            sb.append(csvCell(r.str("id")))
            sb.append(",")
            sb.append(csvCell(r.str("subject_id")))
            sb.append(",")
            sb.append(csvCell(r.str("category")))
            sb.append(",")
            sb.append(csvCell(r.str("title")))
            sb.append(",")
            sb.append(csvCell(r.str("status")))
            sb.append(",")
            sb.append(csvCell(r.str("sensitivity")))
            sb.append(",")
            // issuer / remark 类字段可能含敏感明文 → 掩码（首尾保留，中间打码）
            sb.append(csvCell(mask(r.str("issuer"))))
            sb.append(",")
            sb.append(csvCell(r.str("issued_date")))
            sb.append(",")
            sb.append(csvCell(r.str("expires_at")))
            sb.append(",")
            sb.append(csvCell(r.str("updated_ms")))
            sb.append("\n")
        }

        let csv = sb.toString()
        let truncated = total >= cap

        // 审计（FR-EXP-004）：记录范围、行数、是否含高敏
        this.audit(
            actorId, "archive", "${subjectIds.size}",
            AuditResult.Success,
            "rows=${total};high=${includeHighSensitivity}",
            ip, userAgent
        )

        return ExportResult(csv, total, truncated)
    }

    /**
     * CSV 单元格转义：含逗号/引号/换行用双引号包裹并转义内部引号。
     */
    private func csvCell(s: String): String {
        if (s.contains(",") || s.contains("\"") || s.contains("\n")) {
            return "\"" + s.replace("\"", "\"\"") + "\""
        }
        return s
    }

    /**
     * 敏感明文掩码：保留首字符、中间打码。
     */
    private func mask(s: String): String {
        if (s.size <= 2) {
            return s
        }
        return "${s[0..1]}***"
    }

    private func audit(
        actorId: String,
        targetType: String,
        targetId: String,
        result: AuditResult,
        detail: String,
        ip: String,
        userAgent: String
    ): Unit {
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    actorId,
                    ActorType.User,
                    AuditAction.DataExport,
                    targetType,
                    targetId,
                    "",
                    0,
                    result,
                    "",
                    ip,
                    userAgent,
                    detail,
                    Array<(String, String)>()
                )
            case None => ()
        }
    }
}
