-- ============================================================
-- 027 · 进程内可变状态落库（审查报告 P1-5「多副本承诺不成立」）
--
-- 背景：
--   以下状态此前只存在于单个进程的内存里，多副本部署时各自为政：
--     · SessionStore 会话 / 已轮换刷新令牌（MemorySessionStore）
--     · 登录失败计数（LoginFailureCounter，渐进延迟 + 验证码触发）
--     · 图形验证码 challenge（CaptchaStore）
--     · 分片上传会话与分片字节（ChunkUploadStore）
--     · 周期任务闸门（Scheduler.lastRun）
--   本迁移把它们统一迁到共享 DB，使多实例行为一致。
--
-- 设计：
--   · 所有时间列统一用 BIGINT Unix 毫秒（与代码侧 Times.nowMillis() 同源），
--     避免 DB 时区/精度差异影响 TTL 判定；
--   · 主键即业务键，UPSERT 用「先查后判 + 分支插入/更新」（openGauss 无 ON CONFLICT）；
--   · 分片字节用 BYTEA（驱动 set<Array<Byte>> / get<Array<Byte>> 已验证）；
--   · 调度闸门用租约表，靠 UPDATE ... WHERE leased_until < now 原子争抢。
--
-- 幂等性：CREATE TABLE / INDEX IF NOT EXISTS（openGauss 5.0 支持）；
--   不使用 ADD COLUMN IF NOT EXISTS / ON CONFLICT。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 会话（替代 MemorySessionStore）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_runtime_sessions (
    sid            VARCHAR(128)  NOT NULL PRIMARY KEY,
    uid            VARCHAR(64)   NOT NULL,
    refresh_hash   VARCHAR(128)  NOT NULL DEFAULT '',
    revoked        BOOLEAN       NOT NULL DEFAULT FALSE,
    created_at     BIGINT        NOT NULL,
    last_active_at BIGINT        NOT NULL,
    ip             VARCHAR(64)   NOT NULL DEFAULT '',
    user_agent     VARCHAR(512)  NOT NULL DEFAULT '',
    tenant_id      VARCHAR(64)   NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_sys_runtime_sessions_uid
    ON sys_runtime_sessions (uid);
CREATE INDEX IF NOT EXISTS idx_sys_runtime_sessions_refresh_hash
    ON sys_runtime_sessions (refresh_hash);
CREATE INDEX IF NOT EXISTS idx_sys_runtime_sessions_active
    ON sys_runtime_sessions (revoked, last_active_at);

COMMENT ON TABLE sys_runtime_sessions IS '登录会话（多副本共享）。refresh_hash 为当前刷新令牌哈希，revoked 用于全局/单点登出。';
COMMENT ON COLUMN sys_runtime_sessions.tenant_id IS '租户标识（兼容多租户上下文，MONO 部署固定为空串）。';

-- 1.1) 已轮换掉的刷新令牌哈希（重放检测，替代内存 HashMap）
CREATE TABLE IF NOT EXISTS sys_used_refresh_hashes (
    hash     VARCHAR(128) NOT NULL PRIMARY KEY,
    uid      VARCHAR(64)  NOT NULL,
    used_at  BIGINT       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sys_used_refresh_uid
    ON sys_used_refresh_hashes (uid);

COMMENT ON TABLE sys_used_refresh_hashes IS '已轮换刷新令牌哈希 → uid。命中即判定重放，吊销该用户全部会话。';

-- ------------------------------------------------------------
-- 2) 登录失败计数（替代 LoginFailureCounter 内存 HashMap）
--    列名 fkey = 用户名稳定哈希（与代码 AuthService.failureKey 一致），
--    uid / ip 为可选上下文，便于运维定位暴力破解来源。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_runtime_login_failures (
    fkey     VARCHAR(128) NOT NULL PRIMARY KEY,
    uid      VARCHAR(64)  NOT NULL DEFAULT '',
    ip       VARCHAR(64)  NOT NULL DEFAULT '',
    count    BIGINT       NOT NULL DEFAULT 0,
    last_at  BIGINT       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sys_runtime_login_failures_last_at
    ON sys_runtime_login_failures (last_at);

COMMENT ON TABLE sys_runtime_login_failures IS '登录失败计数（多副本共享）：渐进延迟与验证码触发阈值的数据源。';

-- ------------------------------------------------------------
-- 3) 图形验证码 challenge（替代 CaptchaStore 内存 HashMap）
--    answer_hash = hex(SM3(challenge + answer))，绝不存答案明文。
--    ip / issued_at 同时承载「单 IP 固定窗口签发限流」，使限流也跨副本生效。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_captcha_challenges (
    challenge   VARCHAR(128) NOT NULL PRIMARY KEY,
    answer_hash VARCHAR(128) NOT NULL,
    expires_at  BIGINT       NOT NULL,
    attempts    BIGINT       NOT NULL DEFAULT 0,
    ip          VARCHAR(64)  NOT NULL DEFAULT '',
    issued_at   BIGINT       NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_sys_captcha_expires
    ON sys_captcha_challenges (expires_at);
CREATE INDEX IF NOT EXISTS idx_sys_captcha_ip_issued
    ON sys_captcha_challenges (ip, issued_at);

COMMENT ON TABLE sys_captcha_challenges IS '验证码挑战（多副本共享）。answer_hash 为 SM3 摘要，明文答案只随本次响应返回，不落库。';

-- ------------------------------------------------------------
-- 4) 分片上传会话 + 分片字节（替代 ChunkUploadStore 内存态）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_upload_sessions (
    upload_id     VARCHAR(128) NOT NULL PRIMARY KEY,
    owner_id      BIGINT       NOT NULL,
    subject_id    BIGINT       NOT NULL,
    item_id       BIGINT,
    category      BIGINT       NOT NULL DEFAULT 0,
    title         VARCHAR(512) NOT NULL DEFAULT '',
    file_name     VARCHAR(512) NOT NULL DEFAULT '',
    summary       VARCHAR(2048) NOT NULL DEFAULT '',
    keywords      VARCHAR(2048) NOT NULL DEFAULT '',
    total_size    BIGINT       NOT NULL,
    chunk_size    BIGINT       NOT NULL,
    total_chunks  BIGINT       NOT NULL,
    created_at    BIGINT       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sys_upload_owner_created
    ON sys_upload_sessions (owner_id, created_at);
CREATE INDEX IF NOT EXISTS idx_sys_upload_created
    ON sys_upload_sessions (created_at);

CREATE TABLE IF NOT EXISTS sys_upload_chunks (
    upload_id    VARCHAR(128) NOT NULL,
    chunk_index  BIGINT       NOT NULL,
    data         BYTEA        NOT NULL,
    PRIMARY KEY (upload_id, chunk_index)
);

COMMENT ON TABLE sys_upload_sessions IS '分片上传会话（多副本共享）。owner_id 是归属校验边界，created_at 用于 TTL 惰性清理。';
COMMENT ON TABLE sys_upload_chunks IS '分片字节块。重复写同一 index 幂等覆盖（先 DELETE 再 INSERT）。';

-- ------------------------------------------------------------
-- 5) 调度租约（替代 Scheduler.lastRun 内存闸门）
--    租约被持有期间 leased_until > now，其它实例 UPDATE ... WHERE
--    leased_until < now 改不动，从而保证多实例只执行一次；
--    任务失败/进程崩溃后租约超时自动释放，可由下一次触发恢复。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_scheduler_leases (
    task_key      VARCHAR(128) NOT NULL PRIMARY KEY,
    leased_until  BIGINT       NOT NULL DEFAULT 0,
    owner_id      VARCHAR(128) NOT NULL DEFAULT '',
    last_run_at   BIGINT       NOT NULL DEFAULT 0
);

COMMENT ON TABLE sys_scheduler_leases IS '周期任务租约（多副本互斥）。leased_until 为 Unix 毫秒，UPDATE ... WHERE leased_until < now 争抢。';
