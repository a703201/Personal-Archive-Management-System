// ============================================================
// ams.app.scheduler · 周期任务调度器
//
// 需求：
//   FR-NTF-002 有效期到期提醒（30/7/1 天前各提醒一次）
//   FR-ARCH-008 回收站到期物理清理（超 30 天）
//   后续可挂：审计哈希链自检（FR-AUD-003）
//
// 【D6 调度器选型 —— 结论：进程内「间隔闸门 + 外部触发」，不引 piles 线程】
//   备选三方案里：
//   - 进程内 Timer/后台线程：需要额外线程 API 与生命周期管理，
//     且本仓此前**零并发原语使用**（除 Times.sleepMillis），
//     贸然引入后台线程会让问题排查与优雅退出变复杂。
//   - 独立调度服务：成本过高，单机部署不划算。
//   - **系统 cron + 管理端点**（本实现）：
//       · 提供 POST /api/admin/tasks/run 供 cron 或运维按需触发
//       · Scheduler 内部用「上次运行时间」做**间隔闸门**，
//         同一任务在窗口期内重复触发也只会真正执行一次 —— 天然幂等
//       · 同时提供 tick(now) 以便将来接入进程内定时器时零改动复用
//
// 【为什么要「间隔闸门」】
//   cron 配置错误（每分钟跑）或运维重复点，都不应造成重复推送/重复清理。
//   闸门以内存记账；进程重启归零，故首次触发一定会执行。
// ============================================================
package ams.app.scheduler

import std.collection.*

import ams.data.repo.*
import ams.kernel.log.*

/**
 * 周期任务调度器。
 */
public class Scheduler {
    /** 一天（毫秒）—— 到期提醒与回收站清理的执行间隔 */
    private static let INTERVAL_DAY: Int64 = 86400000

    private let itemRepo: ItemRepo
    private let notifyRepo: NotifyRepo
    /** 任务名 → 上次成功执行的时刻（内存记账，重启归零） */
    private let lastRun: HashMap<String, Int64>

    public init(itemRepo: ItemRepo, notifyRepo: NotifyRepo) {
        this.itemRepo = itemRepo
        this.notifyRepo = notifyRepo
        this.lastRun = HashMap<String, Int64>()
    }

    /**
     * 执行所有已到期的任务。
     *
     * @param now 当前时刻（毫秒）
     * @return 本次**真正执行**的任务数（被闸门挡下的不计数）
     */
    public func runDue(now: Int64): Int64 {
        var ran: Int64 = 0

        var r1 = 0
        if (this.due("expiry.reminder", Scheduler.INTERVAL_DAY, now)) {
            let n = this.expiryReminder(now)
            Log.get().info("task.expiry.reminder", None, [("pushed", "${n}")])
            r1 = 1
        }
        ran = ran + r1

        var r2 = 0
        if (this.due("recycle.purge", Scheduler.INTERVAL_DAY, now)) {
            let n = this.recyclePurge(now)
            Log.get().info("task.recycle.purge", None, [("purged", "${n}")])
            r2 = 1
        }
        ran = ran + r2

        return ran
    }

    // ------------------------------------------------------------
    // 具体任务
    // ------------------------------------------------------------

    /**
     * FR-NTF-002：扫描「恰好在 N 天后到期」的条目并给拥有者发站内通知。
     *
     * 采用**精确日期匹配**（而非区间），配合每日执行一次，
     * 使 30/7/1 天三个里程碑各自只触发一次，无需额外去重表。
     *
     * @return 实际推送条数
     */
    public func expiryReminder(now: Int64): Int64 {
        let milestones = [30, 7, 1]
        var pushed: Int64 = 0
        for (days in milestones) {
            let rows = this.itemRepo.listExpiringOn(days)
            for (r in rows.all().iterator()) {
                let ownerId = r.i64("owner_id")
                // owner_id 为 0 → 主体无拥有者（数据异常），跳过以免给用户 0 发通知
                if (ownerId > 0) {
                    let itemId = r.i64("id")
                    let title = r.str("title")
                    let expDate = r.str("expires_date")
                    this.notifyRepo.push(
                        ownerId,
                        None,
                        "档案即将到期",
                        "《${title}》将于 ${expDate} 到期（还有 ${days} 天），请及时续期或处理。",
                        Some("/items/${itemId}"),
                        1,
                        Some(now + Scheduler.INTERVAL_DAY * 7)
                    )
                    pushed = pushed + 1
                }
            }
        }
        return pushed
    }

    /**
     * FR-ARCH-008：物理清理回收站中超过 30 天的条目。
     *
     * @return 清理条数
     */
    public func recyclePurge(now: Int64): Int64 {
        return this.itemRepo.purgeExpired()
    }

    // ------------------------------------------------------------

    /**
     * 间隔闸门：判断某任务此刻是否该跑；该跑则登记本次时刻。
     */
    private func due(name: String, intervalMillis: Int64, now: Int64): Bool {
        var last: Int64 = 0
        match (this.lastRun.get(name)) {
            case Some(v) => last = v
            case None => last = 0
        }
        if (last == 0 || now - last >= intervalMillis) {
            this.lastRun[name] = now
            return true
        }
        return false
    }
}
