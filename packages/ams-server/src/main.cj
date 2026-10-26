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
import ams.app.audit.*
import ams.app.authz.*
import ams.app.export.*
import ams.app.item.*
import ams.app.scheduler.*
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
import ams.security.ratelimit.*

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
        // [FR-AUD-006] 受限运行时账号：
        //   生产应通过 AMS_DB_APP_USER / AMS_DB_APP_PASSWORD 让应用以「受限角色」连接，
        //   该角色业务表全 DML、审计表仅 SELECT/INSERT（见 006_audit_restricted_role.sql）。
        //   未配置时回退到管理账号（本地开发兼容）。
        let appUser = getVariable("AMS_DB_APP_USER")
        let dbUser = appUser ?? (getVariable("AMS_DB_USER") ?? "gaussdb")
        let dbRuntimePass = match (appUser) {
            case Some(_) => getVariable("AMS_DB_APP_PASSWORD") ?? dbPass
            case None => dbPass
        }

        let db = DbConfig(
            getVariable("AMS_DB_HOST") ?? "127.0.0.1",
            15432,
            getVariable("AMS_DB_NAME") ?? "ams",
            dbUser,
            dbRuntimePass,
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
    // 审计记录器（FR-AUD-001）：AuthService 的登录/登出要留痕
    let auditRecorder = AuditRecorder(AuditRepo(db), StdxCryptoProvider())

    // ---- 口令策略校验器（FR-AUTH-004）----
    // 此前 PasswordValidator 已实现且有单测，但**没有任何业务路径调用**，
    // 弱口令 / 过短口令都能建账号。现接入 createUser、resetPassword 与注册（FR-AUTH-001）。
    let passwordValidator = PasswordValidator(
        policy,
        StdxCryptoProvider(),
        WeakPasswords.common()
    )

    let authService = AuthService(
        userRepo,
        roleRepo,
        hasher,
        tokenService,
        AuthConfig(kdfIterations: policy.iterations),
        passwordValidator,
        recorder: auditRecorder
    )

    // ---- 限流器：导出专属配额（按用户）与通用兜底限流（按 IP）共用一个实例 ----
    let rateLimiter = RateLimiter()

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
        hasher,
        passwordValidator: passwordValidator,
        passwordPolicy: policy
    ).register(router)
    // 条目接口（FR-ARCH-001~008）：带资源守卫，对象级鉴权在此生效
    let itemRepo = ItemRepo(db)
    ItemRoutes(itemRepo, userRepo).register(router)

    // ---- 字段定义与扩展字段（FR-ARCH-003 / 004 / 005）----
    // ① 先播种 11 套内置分类字段模板：此前模板只存在于代码里（catalog.cj），
    //    未写入 arc_field_defs —— 现在启动时幂等落库（已存在则跳过）。
    let fieldDefRepo = FieldDefRepo(db)
    let itemFieldRepo = ItemFieldRepo(db)
    let seeded = FieldTemplateService(fieldDefRepo).ensureBuiltinTemplates()
    Log.get().info("startup.field.templates", None, [("seeded", "${seeded}")])
    // ② 字段定义 CRUD（ARCH-003）+ 条目扩展字段明细读写（ARCH-004）
    FieldDefRoutes(fieldDefRepo, userRepo).register(router)
    ItemFieldRoutes(itemRepo, fieldDefRepo, itemFieldRepo, userRepo).register(router)

    // ---- 导出接口（FR-EXP-004 / FR-EXP-007）----
    // 配额由共享 rateLimiter 计量；导出审计经 auditRecorder 落库
    let exportService = ExportService(itemRepo, rateLimiter, recorder: auditRecorder)
    ExportRoutes(userRepo, exportService).register(router)

    // ---- 周期任务（FR-NTF-002 到期提醒 / FR-ARCH-008 回收站清理；D6 选型）----
    // 不在启动即刻执行：避免频繁重启造成重复推送。
    // 由 cron 或运维调用 POST /api/admin/tasks/run 驱动（内部有 24h 间隔闸门）。
    let scheduler = Scheduler(itemRepo, NotifyRepo(db))
    AdminRoutes(scheduler).register(router)

    // ---- 审计查询接口（FR-AUD-003/004）----
    // auditRecorder 已在上面创建（供 AuthService 记录登录/登出）
    AuditRoutes(auditRecorder).register(router)

    let apiServer = ApiServer(config.httpHost, config.httpPort, router)

    // 中间件链顺序：请求ID -> 访问日志 -> 限流 -> 鉴权
    apiServer.use(requestIdMiddleware())
    apiServer.use(accessLogMiddleware())
    apiServer.use(rateLimitMiddleware(rateLimiter))
    // ---- 授权服务（FR-ACL-005/006/007/009 的接线层）----
    // Authorizer 此前实现了但零业务调用 —— 敏感度分级与授权到期实际不生效。
    let authzService = AuthzService(userRepo, roleRepo)
    apiServer.use(authMiddleware(
        AuthContext(
            tokenService,
            { uid: String =>
                // 鉴权中间件需要：权限点 + 角色 + 可访问主体 + 数据可见上限
                let uidNum = UserRepo.parseId(uid)
                UserAccess(
                    roleRepo.listUserPermCodes(uidNum),
                    roleRepo.listUserRoleCodes(uidNum),
                    userRepo.listAccessibleSubjectIds(uidNum),
                    userRepo.maxDataLevel(uidNum),
                    ownedSubjectIds: userRepo.listOwnedSubjectIds(uidNum)
                )
            },
            grantLoader: { uid: String => authzService.loadAuthorizer(uid).allGrants() }
        ),
        router
    ))

    log.info("server.ready", None, [
        ("routes", "${router.size()}"),
        ("startedAt", Times.nowIso8601())
    ])
    apiServer.serve()
    return 0
}
