// ============================================================
// ams.data.db · 数据库连接与事务管理
//
// 需求：
//   FR-ARCH-001/007 条目持久化（乐观锁：version 冲突返回 409）
//   FR-EXPORT-007 限流配额（job_leases / imp_export_tasks 表）
//   配置管理（cfg_settings / cfg_dict_* 表）
//
// [技术选型]
//   使用 Cangjie-TPC/opengauss-driver（纯仓颉实现 openGauss/PostgreSQL 协议），
//   通过仓颉标准库 `std.database.sql` 的标准接口访问：
//       DriverManager.getDriver("opengauss") -> Driver.open(url) -> Datasource
//       Datasource.connect() -> Connection
//       Connection.prepareStatement(sql) -> Statement
//
//   选择理由：
//     ① 仓颉标准库**不含**任何数据库驱动（std.database 只是接口抽象层），
//        自研 PostgreSQL v3 线路协议客户端成本高且易错；
//     ② 官方 openGauss 驱动已实现 md5 / SCRAM-SHA-256 认证、主备识别、
//        事务路由与故障切换，且提供连接池（sqlpool / tinypool）；
//     ③ 走标准接口意味着未来换 PostgreSQL 无需改业务代码。
//
// [分层约束]（架构 §4.2）
//   ams-data 依赖 ams-kernel（错误类型 / ID / 时间），不依赖 ams-core。
//   领域模型到表行的映射放在 ams-app 层做（data 层只负责行 <-> 字典/基础类型）。
//
// [安全约束]
//   - 所有 SQL 一律用**参数占位符**，禁止字符串拼接（防 SQL 注入）
//   - 连接串中的口令不得进日志
// ============================================================
package ams.data.db

import std.database.sql.*
import std.unicode.*

// opengauss-driver（纯仓颉 openGauss/PostgreSQL 驱动）
// 由 scripts/install-driver.sh + scripts/build-driver.sh 提供，
// 编译产物在 build/drv/，包名带组织前缀 cangjie_tpc::opengauss。
import cangjie_tpc::opengauss.driver.*

import ams.kernel.error.*
import ams.kernel.log.*

/**
 * 数据源配置。
 *
 * 口令单独持有，且提供 `redactedUrl()` 用于日志输出。
 */
public class DbConfig {
    /** 主机地址 */
    public let host: String
    /** 端口（openGauss 默认 5432） */
    public let port: Int64
    /** 数据库名 */
    public let database: String
    /** 用户名 */
    public let user: String
    /** 口令（敏感，禁止进日志） */
    public let password: String
    /** SSL 模式：disable / prefer / require */
    public let sslMode: String
    /** 连接池上限 */
    public let maxPoolSize: Int64
    /** 连接获取超时（毫秒） */
    public let acquireTimeoutMillis: Int64

    public init(
        host: String,
        port: Int64,
        database: String,
        user: String,
        password: String,
        sslMode!: String = "prefer",
        maxPoolSize!: Int64 = 10,
        acquireTimeoutMillis!: Int64 = 5000
    ) {
        this.host = host
        this.port = port
        this.database = database
        this.user = user
        this.password = password
        this.sslMode = sslMode
        this.maxPoolSize = maxPoolSize
        this.acquireTimeoutMillis = acquireTimeoutMillis
    }

    /**
     * 供驱动解析的连接串。
     *
     * 注意：**不做 percent-encoding**。
     * 实测（opengauss-driver）：其 URL 解析器不解码 %XX，
     * 直接透传给服务端，故 `%40` 会被当成字面量导致认证失败
     *（报 "Invalid username/password,login denied (SQLSTATE 28P01)"）。
     *
     * 口令含 URL 保留字符（@ / ? # :）时的正确做法：
     *   由部署方把口令限制在「字母数字 + 常用符号」内（如 Aa1!），
     *   或改用**不含保留字符**的口令。本项目默认口令即遵循此约束。
     */
    public func url(): String {
        return "opengauss://${this.user}:${this.password}@${this.host}:${this.port}/${this.database}?sslmode=${this.sslMode}"
    }

    /**
     * 脱敏连接串（可安全写日志）。
     */
    public func redactedUrl(): String {
        return "opengauss://${this.user}:***@${this.host}:${this.port}/${this.database}?sslmode=${this.sslMode}"
    }
}

/**
 * 数据库句柄。
 *
 * 持有 Datasource（内含连接池），对外提供连接获取与事务包装。
 */
public class Database {
    private let ds: Datasource
    private let cfg: DbConfig

    public init(cfg: DbConfig) {
        this.cfg = cfg
        // DriverManager 里注册名由驱动内部 init() 完成（"opengauss" / "postgres"）。
        // 拿不到时抛内部错误——这是启动期配置问题，不该吞掉。
        let driver = match (DriverManager.getDriver("opengauss")) {
            case Some(d) => d
            case None => throw AppError(AppErrorKind.Internal, "未找到 opengauss 驱动，无法建立数据源")
        }
        this.ds = driver.open(cfg.url(), [])
    }

    /**
     * 打开一个新连接。
     *
     * 调用方负责关闭（用 try/finally）。
     */
    public func connect(): Connection {
        return this.ds.connect()
    }

    /**
     * 健康检查。
     */
    public func ping(): Bool {
        try {
            let c = this.ds.connect()
            c.close()
            return true
        } catch (e: Exception) {
            return false
        }
    }

    /**
     * 关闭数据源。
     */
    public func close(): Unit {
        this.ds.close()
    }

    /**
     * 脱敏连接串（用于日志）。
     */
    public func describe(): String {
        return this.cfg.redactedUrl()
    }
}

/**
 * 把驱动异常转换为统一的 AppError。
 *
 * 关键：**不把 SQL 原文与驱动栈信息透传给上层**，
 * 只保留可归类的错误种类，细节写日志。
 */
public func toDbError(e: Exception): AppError {
    // 统一归为 DatabaseFailure（503），由 api 层映射为对外响应。
    //
    // 关键：**细节只进日志，不进异常消息**（异常消息会透传到 HTTP 响应，
    // 可能泄露 SQL 结构与表名）。这是安全章 §5.4 的要求。
    Log.get().error("db.error", None, [
        ("detail", e.toString())
    ])
    return AppError(AppErrorKind.DatabaseFailure, "数据库操作失败")
}
