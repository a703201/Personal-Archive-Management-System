// ============================================================
// ams.api.routes.admin · 运维接口
//
// 覆盖：
//   POST /api/admin/tasks/run —— 触发周期任务（需 system:admin）
//
// 【为什么需要这个端点】
//   周期任务依赖「被触发」，而本仓不引入后台线程（见 D6 选型说明），
//   故由外部 cron 或运维按需调用本端点驱动：
//     # 每天 09:05 跑一次到期提醒与回收站清理
//     5 9 * * * curl -fsS -X POST https://host/api/admin/tasks/run \
//                    -H "Authorization: Bearer $TOKEN"
//
// 【幂等保证】
//   Scheduler 内部有「间隔闸门」（默认 24 小时），
//   即使 cron 配成了每分钟、或运维连点多次，同一任务在窗口内也只真正执行一次。
//
// 【检索索引回填】
//   POST /api/admin/search/reindex —— 为「还没建索引」的存量条目补建。
//   索引是在条目写入路径同步构建的；若某条目在接线补齐之前就已创建，
//   或索引构建当时失败，它就不会出现在关键词检索结果里。该端点按批回填。
// ============================================================
package ams.api.routes

import ams.api.http.*
import ams.app.scheduler.*
import ams.app.search.*
import ams.data.repo.*
import ams.kernel.time.*

/**
 * 运维接口。
 */
public class AdminRoutes {
    private let scheduler: Scheduler
    private let searchService: ?SearchService

    public init(scheduler: Scheduler, searchService!: ?SearchService = None) {
        this.scheduler = scheduler
        this.searchService = searchService
    }

    public func register(router: Router): Unit {
        router.post("/api/admin/tasks/run", { req: ApiRequest => this.runTasks(req) },
                    requiredPerm: "system:admin")
        router.post("/api/admin/search/reindex", { req: ApiRequest => this.reindex(req) },
                    requiredPerm: "system:admin")
    }

    /**
     * 执行所有到期任务。
     *
     * 响应：{"ran":N} —— N 为本次真正执行的任务数（0 = 均被闸门挡下）
     */
    private func runTasks(req: ApiRequest): ApiResponse {
        let ran = this.scheduler.runDue(Times.nowMillis())
        return ApiResponse.ok("{\"ran\":${ran}}", req.requestId)
    }

    /**
     * 回填检索索引。
     *
     * 查询参数 limit（默认 500，上限 5000）：本批最多处理多少条。
     * 响应 {"indexed":N} —— N 为本批真正建好索引的条数（0 = 已全部建完）。
     */
    private func reindex(req: ApiRequest): ApiResponse {
        let limit = AdminRoutes.clampLimit(req.queryParam("limit") ?? "500")
        let n = match (this.searchService) {
            case Some(svc) => svc.reindexUnindexed(limit)
            case None => 0
        }
        return ApiResponse.ok("{\"indexed\":${n}}", req.requestId)
    }

    /**
     * 限制批量上限，避免运维一次触发全表重建拖垮实例。
     */
    private static func clampLimit(raw: String): Int64 {
        let v = UserRepo.parseId(raw)
        if (v <= 0) { return 500 }
        if (v > 5000) { return 5000 }
        return v
    }
}
