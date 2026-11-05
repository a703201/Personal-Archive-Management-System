// ============================================================
// ams.storage · 部署期配置 + 邮件投递暂存
// ------------------------------------------------------------
// 背景：
//   数据库/邮件连接参数在「首次部署向导」里就要能填，但那时数据库
//   可能还没配好，配置不能存在数据库里（鸡生蛋）。因此落在容器持久卷
//   /app/config/deployment.env（compose 的 ams-config 卷）。
//
// 零回归原则：
//   · 文件不存在 / 某个键缺失 → 继续用环境变量与既有默认值；
//   · 只有用户在向导或「部署配置」页显式保存过的键才写进文件；
//   · 文件格式 KEY=VALUE，按「第一个 =」切分，故口令里可含 = 。
//
// 邮件投递：
//   仓颉侧不手写 SMTP/TLS 协议，也不调用子进程。启用邮件时把
//   完整信件（含 SMTP 连接参数）写成 .eml 暂存文件，由随镜像分发的
//   deploy/scripts/mail-spool.sh 用 curl smtps 真实投递并清理。
//   配置变更在下一封邮件即生效，无需重启 worker。
// ============================================================
package ams.storage

import std.collection.*
import std.env.*

import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*

/**
 * 部署期配置存储。
 */
public class DeploymentStore {
    public static let FILE_KEY: String = "deployment.env"

    /** 对外展示时必须脱敏的键 */
    private static let SECRET_KEYS: Array<String> = [
        "DB_PASSWORD", "DB_APP_PASSWORD", "MAIL_PASSWORD", "TOKEN_SECRET", "KEK"
    ]

    private let fs: LocalFileStorage
    private var values: HashMap<String, String>

    public init(dir!: String = "") {
        var d = dir
        if (d.isEmpty()) {
            d = getVariable("AMS_CONFIG_DIR") ?? "./config"
        }
        this.fs = LocalFileStorage(d)
        this.values = HashMap<String, String>()
        this.load()
    }

    /** 读一个键；空值等同未设置（等价于「回退环境变量」）。 */
    public func get(key: String): Option<String> {
        return match (this.values.get(key)) {
            case Some(v) => if (v.isEmpty()) { None } else { Some(v) }
            case None => None
        }
    }

    /**
     * 配置优先级：文件 > 环境变量 > 代码默认。
     * 文件里没有的键完全不改变既有行为。
     */
    public func resolve(key: String, envName: String, fallback: String): String {
        return match (this.get(key)) {
            case Some(v) => v
            case None => getVariable(envName) ?? fallback
        }
    }

    /** 批量写入并落盘；值含换行会被拒绝（保证行格式不被破坏）。 */
    public func setAll(updates: HashMap<String, String>): Unit {
        for ((k, v) in updates) {
            if (v.contains("\n") || v.contains("\r")) {
                throw validationError(k, "配置值不能包含换行")
            }
            this.values[k] = v
        }
        this.persist()
    }

    /** 删除若干键（写空串即视为删除），用于「恢复为环境变量默认」。 */
    public func clearAll(keys: Array<String>): Unit {
        for (k in keys) {
            this.values[k] = ""
        }
        this.persist()
    }

    /** 供管理页展示：敏感值一律替换为 ***. */
    public func redactedJson(): String {
        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for ((k, v) in this.values) {
            if (!first) { sb.append(",") }
            first = false
            let shown = if (DeploymentStore.isSecret(k)) { "***" } else { v }
            sb.append("\"")
            sb.append(DeploymentStore.escape(k))
            sb.append("\":\"")
            sb.append(DeploymentStore.escape(shown))
            sb.append("\"")
        }
        sb.append("}")
        return sb.toString()
    }

    private func persist(): Unit {
        let sb = StringBuilder()
        for ((k, v) in this.values) {
            if (!v.isEmpty()) {
                sb.append(k)
                sb.append("=")
                sb.append(v)
                sb.append("\n")
            }
        }
        try {
            this.fs.put(DeploymentStore.FILE_KEY, sb.toString().toArray())
        } catch (e: Exception) {
            throw AppError(AppErrorKind.StorageFailure, "部署配置写入失败，请检查 /app/config 是否可写")
        }
    }

    private func load(): Unit {
        match (this.fs.get(DeploymentStore.FILE_KEY)) {
            case Some(bytes) =>
                let text = String.fromUtf8(bytes)
                for (raw in text.split("\n").iterator()) {
                    let line = DeploymentStore.stripCr(raw)
                    if (line.isEmpty() || line.startsWith("#")) { continue }
                    let bs = line.toArray()
                    var i: Int64 = 0
                    var eq: Int64 = -1
                    while (i < bs.size) {
                        if (bs[i] == UInt8(61)) { eq = i; break }
                        i = i + 1
                    }
                    if (eq > 0) {
                        let k = String.fromUtf8(bs[0..eq])
                        let v = String.fromUtf8(bs[eq + 1..bs.size])
                        this.values[k] = v
                    }
                }
            case None => ()
        }
    }

    private static func stripCr(s: String): String {
        if (s.endsWith("\r")) {
            let bs = s.toArray()
            return String.fromUtf8(bs[0..bs.size - 1])
        }
        return s
    }

    private static func isSecret(k: String): Bool {
        for (s in DeploymentStore.SECRET_KEYS) {
            if (s == k) { return true }
        }
        return false
    }

    /** 最小 JSON 字符串转义，供管理页读取。 */
    public static func escape(s: String): String {
        let sb = StringBuilder()
        for (b in s.toArray().iterator()) {
            if (b == UInt8(34)) {
                sb.append("\\\"")
            } else if (b == UInt8(92)) {
                sb.append("\\\\")
            } else if (b == UInt8(10)) {
                sb.append("\\n")
            } else if (b == UInt8(13)) {
                sb.append("\\r")
            } else {
                sb.append(String.fromUtf8(Array<Byte>(1, repeat: b)))
            }
        }
        return sb.toString()
    }
}

/**
 * 邮件暂存：把一封信写成一个 .eml，供 mail-spool.sh 投递。
 * 所有参数在构造时注入，Mailer 不必依赖配置文件或网络库。
 */
public class MailSpool {
    private let fs: LocalFileStorage
    private let enabled: Bool
    private let host: String
    private let port: String
    private let user: String
    private let password: String
    private let fromAddr: String
    private let secure: String

    public init(
        dir: String,
        enabled: Bool,
        host: String,
        port: String,
        user: String,
        password: String,
        fromAddr: String,
        secure: String
    ) {
        this.fs = LocalFileStorage(dir)
        this.enabled = enabled
        this.host = host
        this.port = port
        this.user = user
        this.password = password
        this.fromAddr = fromAddr
        this.secure = secure
    }

    /** 默认禁用：不启用邮件时行为与旧版完全一致（只入队、不落盘、不外发）。 */
    public static func disabled(): MailSpool {
        return MailSpool("", false, "", "", "", "", "", "")
    }

    public func isEnabled(): Bool {
        return this.enabled && !this.host.isEmpty()
    }

    public func enqueue(toAddr: String, subject: String, body: String): Unit {
        if (!this.isEnabled() || toAddr.isEmpty()) { return }
        let sb = StringBuilder()
        sb.append("X-AMS-To: ")
        sb.append(MailSpool.oneLine(toAddr))
        sb.append("\nX-AMS-Subject: ")
        sb.append(MailSpool.oneLine(subject))
        sb.append("\nX-AMS-Smtp-Host: ")
        sb.append(MailSpool.oneLine(this.host))
        sb.append("\nX-AMS-Smtp-Port: ")
        sb.append(MailSpool.oneLine(this.port))
        sb.append("\nX-AMS-Smtp-User: ")
        sb.append(MailSpool.oneLine(this.user))
        sb.append("\nX-AMS-Smtp-Password: ")
        sb.append(MailSpool.oneLine(this.password))
        sb.append("\nX-AMS-Smtp-From: ")
        sb.append(MailSpool.oneLine(this.fromAddr))
        sb.append("\nX-AMS-Smtp-Secure: ")
        sb.append(MailSpool.oneLine(this.secure))
        sb.append("\n\n")
        sb.append(body)
        try {
            this.fs.put("mail-${Ids.next()}.eml", sb.toString().toArray())
        } catch (e: Exception) {
            Log.get().error("mail.spool.write_failed", None, [("to", toAddr)])
        }
    }

    /** 头部字段必须是单行，避免注入伪造的 X-AMS-* 头。 */
    private static func oneLine(s: String): String {
        return s.replace("\n", " ").replace("\r", " ")
    }
}
