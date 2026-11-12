// ============================================================
// ams.app.notification · 短信发送 provider（FR-NTF-005）
//
// 需求：短信通知（账号安全类事件，如口令重置数字验证码）。
// 术语：这里的「验证码」指邮件/短信下发的数字验证码，
//   与登录用的「图形验证码」无关，二者不可混淆。
//
// 通道（沿用邮件 MailSpool 的「仓颉写 spool → shell 投递」范式）：
//   · SmsProvider 接口   —— 接入任意网关只需实现 send()。
//   · NoopSmsProvider    —— 默认实现：全部开关关闭时不发送，仅记日志。
//   · ConsoleSmsProvider —— 联调后端（SMS_CONSOLE=true）：把正文打进日志。
//   · SpoolSmsProvider   —— 真实投递后端（SMS_ENABLED=true 且 SMS_SPOOL=true）：
//       把任务写成 sms-${Ids.next()}.job，由 deploy/scripts/sms-spool.sh
//       轮询并用 curl POST 到网关；仓颉侧不引入任何网络库 / 新依赖。
//   · makeSmsProvider(c) —— 按部署配置选择实现，默认 Noop（零回归）。
//
// 配置优先级（DeploymentStore.resolve）：部署配置文件 > 环境变量 > 默认值；
//   同时兼容旧 cfg_settings 的 sms.enabled / sms.console。
//   默认全部关闭 → 不写文件、不发网络请求、不阻断主流程，行为与旧版一致。
// ============================================================
package ams.app.notification

import std.collection.*
import std.env.*

import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.storage.*

/**
 * 短信发送接口。接入真实网关时实现本接口并在 makeSmsProvider 注册即可。
 */
public interface SmsProvider {
    /**
     * 发送一条短信。投递失败（如 spool 文件写失败）应当抛错（如 AppError），
     * 交由调用方决定 best-effort 还是 fail-closed；实现**不得**在内部静默吞掉，
     * 否则短信投递故障对用户与运维都不可见。Noop/Console 不会失败，
     * 真实 Spool 后端写失败即抛错。
     */
    func send(phone: String, text: String): Unit
}

/**
 * 默认实现：不发送（所有开关关闭时）。仅记录调用，便于联调确认触发点。
 */
public class NoopSmsProvider <: SmsProvider {
    public init() {}
    public func send(phone: String, text: String): Unit {
        Log.get().info("sms.noop", None, [("phone", phone)])
    }
}

/**
 * 开发后端：SMS_CONSOLE=true 时把短信正文打进日志（等同 mail.console）。
 */
public class ConsoleSmsProvider <: SmsProvider {
    public init() {}
    public func send(phone: String, text: String): Unit {
        Log.get().info("sms.console", None, [("phone", phone), ("text", text)])
    }
}

/**
 * 真实投递后端：把一条短信写成一个 .job 暂存文件，交由容器内
 * deploy/scripts/sms-spool.sh 轮询并用 curl POST 到短信网关。
 *
 * 与 MailSpool 完全同构：send() 只做一次本地文件写。失败关闭原则：
 * spool 写失败**必须抛 AppError**，交由 sendAlert 以 best-effort 方式捕获并
 * 记 ERROR 日志 —— 绝不静默吞掉，否则短信投递故障不可观测。
 * phone 与 text 均经 oneLine 压平换行，防止伪造头 / 换行注入。
 */
public class SpoolSmsProvider <: SmsProvider {
    private let fs: LocalFileStorage

    public init() {
        let dir = getVariable("AMS_SMS_SPOOL_DIR") ?? "./data-sms/spool"
        this.fs = LocalFileStorage(dir)
    }

    public func send(phone: String, text: String): Unit {
        if (phone.isEmpty()) {
            return
        }
        let sb = StringBuilder()
        sb.append("X-AMS-Sms-Phone: ")
        sb.append(SpoolSmsProvider.oneLine(phone))
        sb.append("\n\n")
        sb.append(SpoolSmsProvider.oneLine(text))
        // 失败关闭：spool 写失败抛 AppError，由 sendAlert 捕获并记 ERROR 日志，故障可见。
        try {
            this.fs.put("sms-${Ids.next()}.job", sb.toString().toArray())
        } catch (e: Exception) {
            throw AppError(AppErrorKind.StorageFailure,
                           "短信暂存文件写入失败（phone=${phone}）：${e}")
        }
    }

    /** 头部字段与正文压成单行，避免换行注入伪造头或破坏 KEY: VALUE 结构。 */
    private static func oneLine(s: String): String {
        return s.replace("\n", " ").replace("\r", " ")
    }
}

/**
 * 短信通道总开关是否有效：部署配置 SMS_ENABLED / 环境变量 AMS_SMS_ENABLED
 * 优先，兼容旧 cfg_settings 的 sms.enabled。供 makeSmsProvider 与
 * Mailer.sendAlert 共用，确保「是否发短信」在两处判定一致。
 */
public func smsChannelEnabled(configRepo: ConfigRepo): Bool {
    let store = DeploymentStore()
    let deployOn = store.resolve("SMS_ENABLED", "AMS_SMS_ENABLED", "false") == "true"
    let legacyOn = configRepo.getValue("sms", "enabled", "false") == "true"
    return deployOn || legacyOn
}

/**
 * 按配置构造 provider（签名保持 (configRepo: ConfigRepo)，main.cj 装配不变）：
 *   总开关未开                                → Noop（默认，零回归）
 *   console 开（SMS_CONSOLE / sms.console）    → Console（联调优先）
 *   spool 开（SMS_SPOOL）                     → SpoolSmsProvider（真实投递）
 *   其余                                      → Noop
 */
public func makeSmsProvider(configRepo: ConfigRepo): SmsProvider {
    if (!smsChannelEnabled(configRepo)) {
        return NoopSmsProvider()
    }
    let store = DeploymentStore()
    let consoleDeploy = store.resolve("SMS_CONSOLE", "AMS_SMS_CONSOLE", "false") == "true"
    let consoleLegacy = configRepo.getValue("sms", "console", "false") == "true"
    if (consoleDeploy || consoleLegacy) {
        return ConsoleSmsProvider()
    }
    let spool = store.resolve("SMS_SPOOL", "AMS_SMS_SPOOL", "false") == "true"
    if (spool) {
        return SpoolSmsProvider()
    }
    return NoopSmsProvider()
}
