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

import ams.app.notification.*
import ams.data.repo.*
import ams.kernel.log.*

/**
 * 周期任务调度器。
 */
public class Scheduler {
    /** 一天（毫秒）—— 到期提醒与回收站清理、审计归档的执行间隔 */
    private static let INTERVAL_DAY: Int64 = 86400000
    /** 10 分钟 —— 高危告警扫描窗口（高频，配合手动触发幂等） */
    private static let INTERVAL_ALERT: Int64 = 600000
    /** 暴力破解判定阈值：同一 IP 登录失败次数 ≥ 此值视为暴力破解 */
    private static let BRUTE_FORCE_THRESHOLD: Int64 = 5

    private let itemRepo: ItemRepo
    private let notifyRepo: NotifyRepo
    private let auditRepo: AuditRepo
    private let userRepo: UserRepo
    private let configRepo: ConfigRepo
    private let mailer: Mailer
    /** 任务名 → 上次成功执行的时刻（内存记账，重启归零） */
    private let lastRun: HashMap<String, Int64>

    public init(
        itemRepo: ItemRepo,
        notifyRepo: NotifyRepo,
        auditRepo: AuditRepo,
        userRepo: UserRepo,
        configRepo: ConfigRepo,
        mailer: Mailer
    ) {
        this.itemRepo = itemRepo
        this.notifyRepo = notifyRepo
        this.auditRepo = auditRepo
        this.userRepo = userRepo
        this.configRepo = configRepo
        this.mailer = mailer
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

        // FR-AUD-007 高危操作实时告警（高频窗口，可手动即时触发）
        var r3 = 0
        if (this.due("audit.alert", Scheduler.INTERVAL_ALERT, now)) {
            let n = this.auditAlert(now)
            Log.get().info("task.audit.alert", None, [("alerts", "${n}")])
            r3 = 1
        }
        ran = ran + r3

        // FR-AUD-008 审计留存归档（每日）
        var r4 = 0
        if (this.due("audit.retention", Scheduler.INTERVAL_DAY, now)) {
            let n = this.auditRetention(now)
            Log.get().info("task.audit.retention", None, [("archived", "${n}")])
            r4 = 1
        }
        ran = ran + r4

        return ran
    }

    // ------------------------------------------------------------
    // 任务运维接口（FR-NTF-003 / FR-CFG-005）
    // ------------------------------------------------------------

    /**
     * 已登记的任务清单（名称、说明、上次执行时刻）。
     *
     * @return 每行含 name / description / last_run_ms（未跑过为 0）
     */
    public func jobCatalog(): Array<(String, String, Int64)> {
        let jobs = [
            ("expiry.reminder", "到期提醒：扫描 30/7/1 天后到期的条目并推送站内通知", this.lastRunOf("expiry.reminder")),
            ("recycle.purge", "回收站清理：软删除超过留存期的条目", this.lastRunOf("recycle.purge")),
            ("audit.alert", "高危操作实时告警：扫描暴力破解/批量导出/越权/密钥失败并推送管理员（FR-AUD-007）", this.lastRunOf("audit.alert")),
            ("audit.retention", "审计留存归档：将超期热表记录复制至冷存 aud_logs_archive（FR-AUD-008）", this.lastRunOf("audit.retention"))
        ]
        return jobs
    }

    /**
     * 取任务上次执行时刻（毫秒，未执行返回 0）。
     */
    public func lastRunOf(name: String): Int64 {
        match (this.lastRun.get(name)) {
            case Some(t) => return t
            case None => return 0
        }
    }

    /**
     * 立即执行指定任务（**跳过时间闸门**）。
     *
     * @return 任务产出条数；-1 = 任务名未知
     */
    public func runNow(name: String, now: Int64): Int64 {
        if (name == "expiry.reminder") {
            let n = this.expiryReminder(now)
            this.lastRun[name] = now
            Log.get().info("task.run.now", None, [("job", name), ("pushed", "${n}")])
            return n
        }
        if (name == "recycle.purge") {
            let n = this.recyclePurge(now)
            this.lastRun[name] = now
            Log.get().info("task.run.now", None, [("job", name), ("purged", "${n}")])
            return n
        }
        if (name == "audit.alert") {
            let n = this.auditAlert(now)
            this.lastRun[name] = now
            Log.get().info("task.run.now", None, [("job", name), ("alerts", "${n}")])
            return n
        }
        if (name == "audit.retention") {
            let n = this.auditRetention(now)
            this.lastRun[name] = now
            Log.get().info("task.run.now", None, [("job", name), ("archived", "${n}")])
            return n
        }
        return -1
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
                    // FR-NTF-004：到期提醒同步发送邮件（若有邮箱）
                    match (this.userRepo.findById(ownerId)) {
                        case Some(u) =>
                            if (!u.email.isEmpty()) {
                                this.mailer.sendSafe(
                                    u.email,
                                    "档案即将到期提醒",
                                    "《${title}》将于 ${expDate} 到期（还有 ${days} 天），请及时续期或处理。"
                                )
                            }
                        case None => ()
                    }
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
    // FR-AUD-008 审计留存归档
    // ------------------------------------------------------------

    /**
     * FR-AUD-008：将超期审计记录复制至冷存 aud_logs_archive。
     *
     * 留存天数取自配置 audit.retention_days（默认 180 天，可配置）。
     * aud_logs 不可篡改，故只「复制归档」不「删除热表」。
     *
     * @return 本次归档（复制）的记录数
     */
    public func auditRetention(now: Int64): Int64 {
        let days = this.configRepo.getInt("audit", "retention_days", 180)
        let effectiveDays = if (days <= 0) { 180 } else { days }
        let beforeMillis = now - effectiveDays * Scheduler.INTERVAL_DAY
        return this.auditRepo.archiveExpired(beforeMillis)
    }

    // ------------------------------------------------------------
    // FR-AUD-007 高危操作实时告警
    // ------------------------------------------------------------

    /**
     * FR-AUD-007：扫描高危操作信号并推送管理员（站内通知 + 邮件）。
     *
     * 扫描窗口自上次本任务执行时刻起（首次为近 7 天）。命中后：
     *   · 给每位管理员推送站内通知（优先级 1）；
     *   · 若管理员有邮箱，通过 Mailer 入队邮件（FR-NTF-004 异常登录告警等）。
     *
     * @return 实际推送的「管理员×风险」条数（0 = 无风险）
     */
    public func auditAlert(now: Int64): Int64 {
        let fromMillis = match (this.lastRun.get("audit.alert")) {
            case Some(t) => if (t > 0) { t } else { now - 7 * Scheduler.INTERVAL_DAY }
            case None => now - 7 * Scheduler.INTERVAL_DAY
        }
        let risks = this.auditRepo.scanHighRisk(fromMillis)
        if (risks.isEmpty()) {
            return 0
        }
        let admins = this.userRepo.listAdmins()
        var sent: Int64 = 0
        for (risk in risks.all().iterator()) {
            let rtype = risk.str("risk_type")
            let ip = risk.str("client_ip")
            let action = risk.str("action")
            let cnt = risk.i64("cnt")
            let title = "高危操作告警：${rtype}"
            let body = "检测到 ${cnt} 次 ${action}（来源 IP ${ip}，风险类型 ${rtype}）。" +
                       "请登录审计中心核查。"
            for (a in admins.all().iterator()) {
                this.notifyRepo.push(
                    a.i64("id"),
                    None,
                    title,
                    body,
                    Some("/admin/audit"),
                    1,
                    Some(now + 7 * Scheduler.INTERVAL_DAY)
                )
                let email = a.str("email")
                if (!email.isEmpty()) {
                    this.mailer.sendSafe(email, title, body)
                }
                sent = sent + 1
            }
            Log.get().info("audit.alert.risk", None, [
                ("type", rtype), ("ip", ip), ("action", action), ("cnt", "${cnt}")
            ])
        }
        return sent
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
