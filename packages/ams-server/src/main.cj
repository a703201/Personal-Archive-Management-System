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
//     AMS_AUTH_MAX_FAILS   账号锁定阈值：连续失败次数达到即锁定（默认 5）
//     AMS_AUTH_LOCK_SECONDS  账号锁定时长（秒，默认 900）
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
import ams.app.family.*
import ams.app.importer.*
import ams.app.attachment.*
import ams.app.item.*
import ams.app.notification.*
import ams.app.scheduler.*
import ams.app.search.*
import ams.app.subject.*
import ams.crypto.impl.*
import ams.crypto.key.*
import ams.crypto.provider.*
import ams.data.db.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.authn.*
import ams.security.totp.*
import ams.security.authz.*
import ams.security.ratelimit.*
import ams.storage.*

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
    /**
     * 前端静态资源目录（空 = 不托管）。
     *
     * 前后端**同进程、同端口**部署：一个 ams-server 既提供后端接口，
     * 也提供 /（Vue SPA）。部署只需要「起一个进程 + 开一个端口」，
     * 不必再维护第二份静态服务器与反向代理配置。
     *
     * 注意：本注释里不能写 `/api/` 加星号的通配写法 —— 仓颉的块注释
     * 支持嵌套，那个星号会和斜杠组成新的注释起始符，把注释一路吞到
     * 文件末尾，报出「unclosed delimiter '{'」这种完全指错地方的错误。
     */
    public let webDir: String

    public init(
        httpHost: String,
        httpPort: Int64,
        db: DbConfig,
        tokenSecret: Array<Byte>,
        accessTtlSeconds: Int64,
        refreshTtlSeconds: Int64,
        webDir!: String = ""
    ) {
        this.httpHost = httpHost
        this.httpPort = httpPort
        this.db = db
        this.tokenSecret = tokenSecret
        this.accessTtlSeconds = accessTtlSeconds
        this.refreshTtlSeconds = refreshTtlSeconds
        this.webDir = webDir
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

        // 端口：容器部署时 openGauss 在 compose 网络内是 5432，
        // 物理机本地开发默认 15432。此前此处硬编码 15432，导致
        // AMS_DB_PORT 被静默忽略（容器内永远连不上 db:5432）。
        let dbPort = parseIntEnv(getVariable("AMS_DB_PORT") ?? "15432", 15432)
        let db = DbConfig(
            getVariable("AMS_DB_HOST") ?? "127.0.0.1",
            dbPort,
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

        // 前端产物目录：显式配置优先；未配置时由 StaticFiles 自动探测
        //（源码树 ./web/dist、发布包 ./web），探测不到则关闭静态托管。
        let webDir = getVariable("AMS_WEB_DIR") ?? ""

        return ServerConfig(host, port, db, secret, 1800, 2592000, webDir: webDir)
    }
}

// 从环境变量读取整数配置（字符串 → Int64），解析失败或缺失时回退默认值。
// 仅接受非负十进制整数；含非法字符或空串一律回退，避免把运维拼写错误当成 0。
func parseIntEnv(raw: String, default: Int64): Int64 {
    if (raw.isEmpty()) { return default }
    var n: Int64 = 0
    for (b in raw.toArray().iterator()) {
        if (b < 48 || b > 57) { return default }
        n = n * 10 + Int64(b - 48)
    }
    return n
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

    // 盲索引密钥：由 KEK 派生（与附件 DEK 包裹密钥同源），写读两侧一致（FR-SRC-005）
    let kek = (getVariable("AMS_KEK") ?? "ams-dev-kek-change-me-in-production").toArray()
    let blindIndexService = BlindIndexService(provider, kek)

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

    // ---- 档案主体（arc_subjects）----
    // 主体是「条目归属」的锚点：arc_items.subject_id 必须属于调用者的
    // 可访问主体集合，否则 createItem 返回 403。
    // 此前全仓无任何主体写入点 → 所有用户都建不了第一条档案。
    // 姓名字段（name_enc）是密文列，加解密由 SubjectService 负责。
    // subjectRepo 单独持有：权限预览（FR-ACL-013）需要「全机构主体」全集
    let subjectRepo = SubjectRepo(db)
    let subjectService = SubjectService(subjectRepo, provider, kek)

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

    // ---- 邮件出口（FR-NTF-004）----
    // 提到这里创建：自助找回（FR-AUTH-008）要用它下发验证码，
    // 而 AuthRoutes 在接口层一开始就注册。下方调度器复用同一实例。
    let configRepo = ConfigRepo(db)
    let emailRepo = EmailRepo(db)
    // ---- FR-NTF-005：短信 provider（默认 Noop，sms.enabled=true 时启用）----
    let smsProvider = makeSmsProvider(configRepo)
    let mailer = Mailer(emailRepo, configRepo, smsProvider: smsProvider)

    // ---- 自助找回口令（FR-AUTH-008）：验证码 → 一次性令牌 → 强制下线 ----
    let resetRepo = PasswordResetRepo(db)
    let passwordResetService = PasswordResetService(
        userRepo,
        resetRepo,
        hasher,
        passwordValidator,
        mailer,
        provider,
        tokenService,
        policy.iterations,
        recorder: auditRecorder
    )

    // ---- FR-AUTH-010：账号锁定策略（阈值与时长可配置，默认 5 次 / 900s）----
    let authMaxFails = parseIntEnv(getVariable("AMS_AUTH_MAX_FAILS") ?? "5", 5)
    let authLockSeconds = parseIntEnv(getVariable("AMS_AUTH_LOCK_SECONDS") ?? "900", 900)
    let authService = AuthService(
        userRepo,
        roleRepo,
        hasher,
        tokenService,
        AuthConfig(
            kdfIterations: policy.iterations,
            lockSeconds: authLockSeconds,
            maxFailedAttempts: authMaxFails
        ),
        passwordValidator,
        recorder: auditRecorder,
        totpRepo: TotpRepo(db)
    )

    // ---- 限流器：导出专属配额（按用户）与通用兜底限流（按 IP）共用一个实例 ----
    let rateLimiter = RateLimiter()

    // ---- 7. 接口层 ----
    let router = Router()
    AuthRoutes.health(router)
    // ---- 登录页定制（FR-CFG-008）：公开只读的品牌配置 ----
    // 必须在鉴权之前可用（登录页渲染时还没有令牌），故走 isPublic 路由。
    // 写入沿用 PUT /api/admin/config?scope=branding（含权限与审计）。
    BrandingRoutes(ConfigRepo(db)).register(router)
    // 通知偏好中心（FR-NTF-006 / FR-NTF-007）：用户级，按 req.subjectId 隔离。
    NotifyRoutes(ConfigRepo(db)).register(router)
    // 多语言框架（FR-CFG-009）：公开只读的语言清单出口。
    I18nRoutes().register(router)
    AuthRoutes(authService, resetService: passwordResetService).register(router)

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
    let itemFieldRepo = ItemFieldRepo(db)
    let itemVersionRepo = ItemVersionRepo(db)

    // ---- 检索执行层（FR-SRC-001~006）----
    // SearchService 复用条目与扩展字段仓库来构建索引；
    // 敏感字段展开（reveal）经 auditRecorder 留痕。
    // 【提前创建的原因】ItemRoutes 要在条目创建/更新后调用 indexItem() 重建索引，
    // 否则 arc_search_index 恒为空、关键词检索永不命中。
    let searchService = SearchService(
        SearchRepo(db),
        itemRepo,
        itemFieldRepo,
        recorder: auditRecorder
    )
    // ---- 主体接口（/api/subjects）：必须在条目接口之前就绪 ----
    // 前端建档流程是「先拉主体 → 再按主体建条目」，
    // GET /api/subjects 会为首访用户懒建「本人」主体。
    SubjectRoutes(subjectService, userRepo).register(router)

    // 注册顺序：先条目（含 /api/items/recycle-bin 与 /api/items/:id），
    // 再子资源（/api/items/:id/fields），避免通配路径抢先匹配。
    // tagRepo：供批量编辑的「批量打标」使用（FR-ARCH-013）
    ItemRoutes(
        itemRepo,
        userRepo,
        versionRepo: itemVersionRepo,
        searchService: searchService,
        tagRepo: TagRepo(db)
    ).register(router)

    // ---- 字段定义与扩展字段（FR-ARCH-003 / 004 / 005）----
    // ① 先播种 11 套内置分类字段模板：此前模板只存在于代码里（catalog.cj），
    //    未写入 arc_field_defs —— 现在启动时幂等落库（已存在则跳过）。
    let fieldDefRepo = FieldDefRepo(db)
    let seeded = FieldTemplateService(fieldDefRepo).ensureBuiltinTemplates()
    Log.get().info("startup.field.templates", None, [("seeded", "${seeded}")])
    // ② 字段定义 CRUD（ARCH-003）+ 条目扩展字段明细读写（ARCH-004）
    FieldDefRoutes(fieldDefRepo, userRepo).register(router)
    // 扩展字段值参与索引内容，保存后需重建索引；敏感字段按规则落盲索引（FR-SRC-005）
    ItemFieldRoutes(itemRepo, fieldDefRepo, itemFieldRepo, userRepo, searchService: searchService, blindIndexService: blindIndexService).register(router)

    // ---- 导出接口（FR-EXP-004 / FR-EXP-007）----
    // 配额由共享 rateLimiter 计量；导出审计经 auditRecorder 落库
    let exportService = ExportService(itemRepo, rateLimiter, recorder: auditRecorder)
    // ---- 异步导出（FR-EXP-001/002/003/006）----
    // 产物与附件分目录存放：附件是加密块（.enc），导出是明文 CSV/JSON，
    // 混在一处会让「按目录做备份/清理」的运维动作变得危险。
    let exportStorage = LocalFileStorage(getVariable("AMS_EXPORT_DIR") ?? "./data-exports")
    let exportTaskRepo = ExportTaskRepo(db)
    // 可携带导出的签名密钥（FR-EXP-003）：独立密钥优先，回落到令牌密钥
    //
    // 回落必须用 `config.tokenSecret`（已带本地开发默认值），不能重新读
    //    `AMS_TOKEN_SECRET` 环境变量 —— 后者在未显式配置时返回 None，
    //    于是这里的 `?? ""` 会得到**空串**，导致：
    //      · 导出包无法签名 / 回导验签恒失败；
    //      · 共享链接 token 派生直接报「HMAC 密钥不能为空」（FR-ACL-011）。
    //    即「本地开发一切正常、一配环境就好」的反向陷阱：本地反而全挂。
    let exportSignKey = getVariable("AMS_EXPORT_SIGN_KEY") ?? String.fromUtf8(config.tokenSecret)
    let asyncExportService = AsyncExportService(
        itemRepo,
        userRepo,
        exportTaskRepo,
        NotifyRepo(db),
        exportStorage,
        recorder: auditRecorder,
        crypto: provider,
        signKey: exportSignKey
    )
    // 上次进程遗留的 running 任务标失败（否则用户永远看到 99% 转圈）
    let staleRecovered = asyncExportService.recoverStale()
    Log.get().info("startup.export.stale_recovered", None, [("count", "${staleRecovered}")])
    ExportRoutes(
        userRepo,
        exportService,
        asyncExportService,
        exportTaskRepo,
        storage: exportStorage,
        recorder: auditRecorder
    ).register(router)

    // ---- 批量导入（FR-IMP-001/003）----
    // 与导出共用 imp_export_tasks 与产物目录：任务表已按 task_type 区分，
    // 分目录反而让「按用户清理产物」变成两处逻辑。
    // FR-IMP-005：注入 fieldDefRepo / itemFieldRepo，使导入模板带来的
    // 自定义字段能解析为 field_def 后落 arc_item_fields。
    let importTemplateRepo = ImportTemplateRepo(db)
    let importService = ImportService(
        itemRepo,
        userRepo,
        exportTaskRepo,
        NotifyRepo(db),
        exportStorage,
        recorder: auditRecorder,
        // FR-EXP-008 回导验签：签名密钥必须与导出侧一致，
        // 否则自导出包会被判为「签名不匹配」。
        crypto: provider,
        signKey: exportSignKey,
        fieldDefRepo: fieldDefRepo,
        itemFieldRepo: itemFieldRepo
    )
    ImportRoutes(
        importService,
        exportTaskRepo,
        userRepo,
        importTemplateRepo,
        storage: exportStorage
    ).register(router)

    // ---- 导入模板（FR-IMP-005）：CSV 表头 → 字段键映射，owner 隔离 ----
    ImportTemplateRoutes(importTemplateRepo).register(router)

    // ---- 条目模板（FR-ARCH-012 · 方案 C：骨架 + 字段默认值）----
    // 个人模板：owner 隔离在仓储 WHERE 里，接口只需 archive:write:own。
    ItemTemplateRoutes(
        ItemTemplateRepo(db),
        itemRepo,
        userRepo
    ).register(router)

    // ---- 共享链接（FR-ACL-011 / FR-ACL-012）----
    // 公开只读路由以 token 为凭据；token 由密钥 HMAC 派生，故需要 provider 与签名密钥。
    // 签名密钥与导出签名同源：AMS_EXPORT_SIGN_KEY 优先，回落 AMS_TOKEN_SECRET。
    ShareRoutes(
        ShareLinkRepo(db),
        itemRepo,
        userRepo,
        crypto: provider,
        signKey: exportSignKey
    ).register(router)

    // ---- 权限预览（FR-ACL-013）----
    // 只输出统计口径，不返回条目内容；acl:manage 才能访问。
    PermissionPreviewRoutes(
        roleRepo,
        userRepo,
        itemRepo,
        subjectRepo
    ).register(router)

    // ---- 检索接口（SearchService 已在条目接口之前创建）----
    // ---- 家庭成员邀请与轻量协作（FR-ACL-010 · 方案 B）----
    // 授权粒度止步于「主体 + 条目」，分类只作同主体内收窄；
    // 不做「成员申请 -> owner 审批」（docs/15 决策）。
    // family:manage / family:invite 两个权限点由迁移 019 授予 owner / user 角色。
    let familyService = FamilyService(
        FamGroupRepo(db),
        FamMemberRepo(db),
        FamInviteRepo(db),
        FamGrantRepo(db),
        subjectRepo,
        userRepo,
        itemRepo,
        crypto: provider,
        // 与共享链接/导出签名同源：密钥轮换即让全部邀请链接同时失效，
        // 这是「密钥泄露时的止血手段」，故意不单独配一套。
        signKey: exportSignKey
    )
    FamilyRoutes(familyService, auditRecorder).register(router)

    SearchRoutes(searchService, userRepo, blindIndexService: blindIndexService).register(router)

    // ---- 个人中心与概览（FR-UX-001 的后端支撑）----
    // 注入口令相关能力后，PUT /api/me 与 POST /api/me/password 才可用
    // （此前个人主页只能看不能改 —— 后端根本没有写入口）。
    MeRoutes(
        userRepo,
        itemRepo,
        NotifyRepo(db),
        hasher: hasher,
        passwordValidator: passwordValidator,
        policy: policy,
        authService: authService,
        sessions: sessions,
        kdfIterations: policy.iterations,
        attachmentRepo: AttachmentRepo(db),
        configRepo: ConfigRepo(db)
    ).register(router)

    // ---- 双因子（FR-AUTH-009）：生成密钥 / 启用 / 停用 / 查询 ----
    TwoFaRoutes(TotpRepo(db), provider).register(router)
    // TOTP 自检（RFC 6238 附录 B 向量）：算法一旦跑偏，宁可启动时就暴露，
    // 也不要等用户绑不上动态码才发现。
    Log.get().info("startup.totp.selftest", None,
                   [("ok", if (Totp.selftest()) { "true" } else { "false" })])

    // ---- 附件域（FR-ATT-001~007）----
    // KEK 由环境变量注入（生产应来自 KMS / HSM，禁止硬编码）；
    // 附件内容用 KeyManager 生成的随机 DEK 加密（SM4-CBC + HMAC-SM3），
    // DEK 本身被 KEK 包裹后落 arc_attachments.wrapped_dek（见 008 迁移）。
    let keyManager = KeyManager(provider, { keyId: String => kek })
    let storageRoot = getVariable("AMS_STORAGE_DIR") ?? "./data-attachments"
    let attachmentRepo = AttachmentRepo(db)
    let attachmentService = AttachmentService(
        attachmentRepo,
        LocalFileStorage(storageRoot),
        QuarantineStorage("./data-quarantine"),
        keyManager,
        provider,
        itemRepo: itemRepo
    )
    AttachmentRoutes(
        attachmentService,
        attachmentRepo,
        userRepo: userRepo,
        crypto: provider,
        recorder: auditRecorder
    ).register(router)

    // ---- 附件批量导入（FR-IMP-002）：ZIP → 目录名映射到条目 ----
    // 必须放在 attachmentService 之后：它是本功能的核心依赖（逐文件解密/落库）。
    // 任务表与产物目录复用导出/CSV 导入那一套（task_type=import，format=zip-attach），
    // 前端只需要一张任务列表。
    let attachmentImportService = AttachmentImportService(
        itemRepo,
        userRepo,
        exportTaskRepo,
        NotifyRepo(db),
        exportStorage,
        attachmentService,
        recorder: auditRecorder,
        crypto: provider,
        attachmentRepo: attachmentRepo
    )
    AttachmentImportRoutes(attachmentImportService, userRepo).register(router)

    // ---- 周期任务（FR-NTF-002 到期提醒 / FR-ARCH-008 回收站清理 / FR-AUD-007 告警 / FR-AUD-008 归档）----
    // 不在启动即刻执行：避免频繁重启造成重复推送。
    // 由 cron 或运维调用 POST /api/admin/tasks/run 驱动（内部有间隔闸门）。
    // FR-NTF-004 邮件：Mailer 把邮件入队 ntf_email_outbox，由 worker 出队外发。
    // （configRepo / emailRepo / mailer 已在上方安全层创建，此处复用）
    let scheduler = Scheduler(
        itemRepo,
        NotifyRepo(db),
        AuditRepo(db),
        userRepo,
        configRepo,
        mailer
    )
    AdminRoutes(scheduler, searchService: searchService).register(router)

    // ---- 系统运维（P1：FR-CFG-003/005/006/007 + FR-NTF-003）----
    // 放在附件域与调度器之后：SystemRoutes 需要 keyManager 与 scheduler。
    // 备份快照与附件隔离存放（默认 ./data-backups），避免误删与配额混淆。
    SystemRoutes(
        ConfigRepo(db),
        SystemRepo(db),
        scheduler: scheduler,
        keyManager: keyManager,
        backupStorage: LocalFileStorage(
            getVariable("AMS_BACKUP_DIR") ?? "./data-backups"
        ),
        recorder: auditRecorder,
        sessions: sessions
    ).register(router)

    // ---- 审计查询接口（FR-AUD-003/004）----
    // auditRecorder 已在上面创建（供 AuthService 记录登录/登出）
    AuditRoutes(auditRecorder).register(router)

    // 前后端同时部署：静态目录探测失败不阻断启动（只打 WARN），
    // 因为「接口可用」比「页面可用」优先 —— 排障时先能调接口。
    let webDir = StaticFiles.detect(config.webDir)
    let apiServer = ApiServer(
        config.httpHost, config.httpPort, router, staticDir: webDir)

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
                    userRepo.tenantOf(uidNum),
                    ownedSubjectIds: userRepo.listOwnedSubjectIds(uidNum)
                )
            },
            grantLoader: { uid: String => authzService.loadAuthorizer(uid).allGrants() }
        ),
        router
    ))

    log.info("server.ready", None, [
        ("routes", "${router.size()}"),
        ("webDir", if (webDir.isEmpty()) { "<disabled>" } else { webDir }),
        ("startedAt", Times.nowIso8601())
    ])
    apiServer.serve()
    return 0
}
