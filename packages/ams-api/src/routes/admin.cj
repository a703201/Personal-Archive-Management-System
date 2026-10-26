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
// ============================================================
package ams.api.routes

import ams.api.http.*
import ams.app.scheduler.*
import ams.kernel.time.*

/**
 * 运维接口。
 */
public class AdminRoutes {
    private let scheduler: Scheduler

    public init(scheduler: Scheduler) {
        this.scheduler = scheduler
    }

    public func register(router: Router): Unit {
        router.post("/api/admin/tasks/run", { req: ApiRequest => this.runTasks(req) },
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
}
