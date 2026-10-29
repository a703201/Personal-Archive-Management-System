// ============================================================
// ams.app.notification · 邮件发送器（FR-NTF-004）
//
// 需求：
//   FR-NTF-004 邮件通知：到期提醒、共享通知、异常登录告警
//
// [设计]
//   本仓不引入第三方 SMTP 库，本地也无可用 SMTP 服务，
//   故 Mailer 采用「出站队列」模式：
//     send() 仅把邮件写入 ntf_email_outbox（由 EmailRepo 落库），
//     真正外发由独立 worker（或 mail.enabled=true 时的发送器）出队完成。
//
//   这样做的好处：
//     · 邮件可追溯（落库即留痕，可审计）；
//     · 可重试（worker 按 attempts 重试，失败写 last_error）；
//     · 幂等且非阻塞（主流程不依赖外部 SMTP 可用性）。
// ============================================================
package ams.app.notification

import std.collection.*

import ams.data.repo.*
import ams.kernel.log.*

/**
 * 邮件发送器。
 */
public class Mailer {
    private let emailRepo: EmailRepo
    private let configRepo: ConfigRepo

    public init(emailRepo: EmailRepo, configRepo: ConfigRepo) {
        this.emailRepo = emailRepo
        this.configRepo = configRepo
    }

    /**
     * 发送一封邮件（实际是「入队」）。
     *
     * 入队后由 worker 出队外发；mail.enabled 仅用于日志标识当前是否处于真发模式。
     *
     * @return 入队邮件 id；空地址返回 0（不入队）
     */
    public func send(toAddr: String, subject: String, body: String): Int64 {
        if (toAddr.isEmpty()) {
            return 0
        }
        let id = this.emailRepo.enqueue(toAddr, subject, body)
        let enabled = this.configRepo.getValue("mail", "enabled", "false") == "true"
        // 控制台投递（开发/联调开关）：mail.console=true 时把正文打进日志，
        // 作用等同 Django 的 console email backend —— 本地没有 SMTP 时，
        // 「验证码 / 重置链接」这类必须看到正文才能走完的流程也能端到端联调。
        // 生产环境必须保持 false（否则验证码会进日志，等于自毁）。
        let console = this.configRepo.getValue("mail", "console", "false") == "true"
        if (console) {
            Log.get().info("mail.console", None, [
                ("to", toAddr),
                ("subject", subject),
                ("body", body)
            ])
        }
        Log.get().info("mail.queued", None, [
            ("id", "${id}"),
            ("to", toAddr),
            ("enabled", "${enabled}")
        ])
        return id
    }

    /**
     * 安全发送：发送异常吞掉并记日志，不影响调用方主流程（如告警推送）。
     */
    public func sendSafe(toAddr: String, subject: String, body: String): Int64 {
        try {
            return this.send(toAddr, subject, body)
        } catch (e: Exception) {
            Log.get().error("mail.failed", None, [("to", toAddr), ("err", "${e}")])
            return 0
        }
    }
}
