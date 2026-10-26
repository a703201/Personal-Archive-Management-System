// ============================================================
// ams-server · 可执行入口
//
// 职责：
//   1. 装载配置
//   2. 初始化基础设施（ID 生成器、日志、密码学提供者）
//   3. 装配各层并启动 HTTP 服务
//
// 启动顺序不能颠倒：
//   日志 -> 配置 -> ID -> 密码学 -> 存储 -> 数据层 -> 领域 -> 应用 -> 接口 -> HTTP
//
// [配置来源]
//   优先环境变量（生产），其次默认值（本地开发）：
//     AMS_HTTP_HOST / AMS_HTTP_PORT
//     AMS_DB_HOST / AMS_DB_PORT / AMS_DB_NAME / AMS_DB_USER / AMS_DB_PASSWORD
//     AMS_TOKEN_SECRET   令牌签名密钥（≥ 32 字节，**生产必填**）
// ============================================================
package ams.server

import std.collection.*
import std.env.*

import ams.api.http.*
import ams.api.middleware.*
import ams.api.routes.*
import ams.api.server.*
import ams.app.auth.*
import ams.crypto.impl.*
import ams.crypto.provider.*
import ams.data.db.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.authn.*
import ams.security.authz.*

/**
 * 应用配置。
 */
public class ServerConfig {
    public let httpHost: String
    public let httpPort: Int64
    public let db: DbConfig
    public let tokenSecret: Array<Byte>
    public let accessTtlSeconds: Int64
    public let refreshTtlSeconds: Int64

    public init(
        httpHost: String,
        httpPort: Int64,
        db: DbConfig,
        tokenSecret: Array<Byte>,
        accessTtlSeconds: Int64,
        refreshTtlSeconds: Int64
    ) {
        this.httpHost = httpHost
        this.httpPort = httpPort
        this.db = db
        this.tokenSecret = tokenSecret
        this.accessTtlSeconds = accessTtlSeconds
        this.refreshTtlSeconds = refreshTtlSeconds
    }

    /**
     * 从环境变量装载配置。
     */
    public static func load(): ServerConfig {
        let host = getVariable("AMS_HTTP_HOST") ?? "127.0.0.1"
        let portStr = getVariable("AMS_HTTP_PORT") ?? "8080"
        // 端口解析：先校验全为数字，再累加
        //（注意：不能在校验和累加里各写一遍循环，否则会累加两次）
        var port: Int64 = 0
        var portOk = !portStr.isEmpty()
        for (b in portStr.toArray().iterator()) {
            if (b < 48 || b > 57) {
                portOk = false
                break
            }
            port = port * 10 + Int64(b - 48)
        }
        if (!portOk || port <= 0 || port > 65535) {
            port = 8080
        }

        // 口令：优先环境变量，其次本地默认值
        let dbPass = getVariable("AMS_DB_PASSWORD") ?? "Ams@Gauss2026"
        let db = DbConfig(
            getVariable("AMS_DB_HOST") ?? "127.0.0.1",
            15432,
            getVariable("AMS_DB_NAME") ?? "ams",
            getVariable("AMS_DB_USER") ?? "gaussdb",
            dbPass,
            sslMode: "disable"
        )

        // 令牌签名密钥：生产必须显式配置
        // 默认值仅供本地开发（长度 ≥ 32 字节）
        let secretStr = getVariable("AMS_TOKEN_SECRET") ??
            "ams-dev-token-secret-change-me-in-production-2026"
        let secret = secretStr.toArray()
        if (secret.size < 32) {
            throw AppError(AppErrorKind.Internal, "AMS_TOKEN_SECRET 至少需要 32 字节")
        }

        return ServerConfig(host, port, db, secret, 1800, 2592000)
    }
}

main(): Int64 {
    // ---- 1. 日志 ----
    let log = Log.get()
    log.setMinLevel(LogLevel.Info)

    // ---- 2. 配置 ----
    let config = ServerConfig.load()

    // ---- 3. ID 生成器 ----
    Ids.setup(1)

    // ---- 4. 密码学提供者 ----
    let provider: CryptoProvider = StdxCryptoProvider()

    log.info("server.boot", None, [
        ("version", "0.1.0"),
        ("httpHost", config.httpHost),
        ("httpPort", "${config.httpPort}"),
        ("db", config.db.redactedUrl())
    ])

    // ---- 5. 数据层 ----
    let db = Database(config.db)
    if (!db.ping()) {
        log.error("server.db.unavailable", None, [("db", config.db.redactedUrl())])
        return 1
    }
    let userRepo = UserRepo(db)
    let roleRepo = RoleRepo(db)

    // ---- 6. 安全层 ----
    let policy = PasswordPolicy()
    let hasher = PasswordHasher(provider, policy)
    let sessions = MemorySessionStore()
    let tokenService = TokenService(
        provider,
        TokenConfig(
            accessTtlSeconds: config.accessTtlSeconds,
            refreshTtlSeconds: config.refreshTtlSeconds,
            secret: config.tokenSecret
        ),
        sessions
    )
    let authService = AuthService(
        userRepo,
        roleRepo,
        hasher,
        tokenService,
        AuthConfig(kdfIterations: policy.iterations)
    )

    // ---- 7. 接口层 ----
    let router = Router()
    AuthRoutes.health(router)
    AuthRoutes(authService).register(router)
    ManagementRoutes(
        userRepo,
        roleRepo,
        TagRepo(db),
        NotifyRepo(db),
        ConfigRepo(db),
        hasher
    ).register(router)

    let apiServer = ApiServer(config.httpHost, config.httpPort, router)
    // 中间件链顺序：请求ID -> 访问日志 -> 鉴权
    apiServer.use(requestIdMiddleware())
    apiServer.use(accessLogMiddleware())
    apiServer.use(authMiddleware(
        AuthContext(tokenService, { uid: String =>
            let uidNum = UserRepo.parseId(uid)
            (roleRepo.listUserPermCodes(uidNum), roleRepo.listUserRoleCodes(uidNum))
        }),
        router
    ))

    log.info("server.ready", None, [
        ("routes", "${router.size()}"),
        ("startedAt", Times.nowIso8601())
    ])
    apiServer.serve()
    return 0
}
