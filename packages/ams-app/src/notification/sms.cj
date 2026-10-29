// ============================================================
// ams.app.notification · 短信发送 provider（FR-NTF-005 · 降级）
//
// 需求：短信通知（账号安全类事件）。
// 边界：本仓无短信网关/供应商，故降级为「provider 接口预留 + 默认关闭」。
//   关键安全事件（口令重置、账号锁定等）走「站内信 + 邮件」双通道，
//   短信作为**可选**补充通道，由部署侧接入网关后启用。
//
// 设计：
//   · SmsProvider 接口        —— 接入任意网关只需实现 send()。
//   · NoopSmsProvider         —— 默认实现（sms.enabled=false 时使用），仅记日志。
//   · ConsoleSmsProvider      —— 开发联调后端（sms.console=true），把正文打进日志。
//   · makeSmsProvider(c)      —— 按配置选择实现，默认 Noop。
// ============================================================
package ams.app.notification

import std.collection.*

import ams.data.repo.*
import ams.kernel.log.*

/**
 * 短信发送接口。接入真实网关时实现本接口并在 makeSmsProvider 注册即可。
 */
public interface SmsProvider {
    /**
     * 发送一条短信；实现内部吞掉异常并记日志，绝不向上游主流程抛错。
     */
    func send(phone: String, text: String): Unit
}

/**
 * 默认实现：不发送（sms.enabled=false）。仅记录调用，便于联调确认触发点。
 */
public class NoopSmsProvider <: SmsProvider {
    public init() {}
    public func send(phone: String, text: String): Unit {
        Log.get().info("sms.noop", None, [("phone", phone)])
    }
}

/**
 * 开发后端：sms.console=true 时把短信正文打进日志（等同 mail.console 的 console backend）。
 */
public class ConsoleSmsProvider <: SmsProvider {
    public init() {}
    public func send(phone: String, text: String): Unit {
        Log.get().info("sms.console", None, [("phone", phone), ("text", text)])
    }
}

/**
 * 按配置构造 provider：
 *   sms.enabled=true 且 sms.console=true → Console（开发模拟）；
 *   其余一律 Noop（生产未接入网关前绝不静默发空短信）。
 */
public func makeSmsProvider(configRepo: ConfigRepo): SmsProvider {
    let enabled = configRepo.getValue("sms", "enabled", "false") == "true"
    let console = configRepo.getValue("sms", "console", "false") == "true"
    if (enabled && console) {
        return ConsoleSmsProvider()
    }
    return NoopSmsProvider()
}
