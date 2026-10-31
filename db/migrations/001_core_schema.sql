-- ============================================================
-- AMS · 001_core_schema.sql
-- 账号与权限域 + 档案主体域 + 附件 + 检索 + 标签 + 授权 + 审计 + 通知
--
-- 依据：docs/06-数据模型设计.md §4~§10
-- 目标库：openGauss 5.0.0（postgresql 兼容模式）
--
-- 约定：
--   - 主键统一 BIGINT，由应用层雪花 ID 生成（不用序列，避免跨库兼容问题）
--   - 通用列：created_at / created_by / updated_at / updated_by / version / deleted_at
--   - 敏感字段：value_enc（密文）+ value_bidx（盲索引）
--   - 审计表仅 INSERT（应用账号无 UPDATE/DELETE 权限，见 §10.6）
-- ============================================================

-- ------------------------------------------------------------
-- 4.1 账号与权限域
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sys_users (
    id                   BIGINT       PRIMARY KEY,
    username             VARCHAR(64)  NOT NULL,
    email                VARCHAR(256),
    email_enc            BYTEA,
    phone                VARCHAR(32),
    phone_bidx           BYTEA,
    password_hash        VARCHAR(255) NOT NULL,
    password_updated_at  TIMESTAMPTZ,
    nickname             VARCHAR(64),
    avatar_file_id       BIGINT,
    status               SMALLINT     NOT NULL DEFAULT 0,
    failed_attempts      INTEGER      NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    last_login_ip        VARCHAR(45),
    two_factor_enabled   BOOLEAN      NOT NULL DEFAULT FALSE,
    two_factor_secret_enc BYTEA,
    kdf_cost             INTEGER      NOT NULL DEFAULT 600000,
    perm_version         INTEGER      NOT NULL DEFAULT 1,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by           BIGINT,
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by           BIGINT,
    version              INTEGER      NOT NULL DEFAULT 1,
    deleted_at           TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_users_username ON sys_users(username);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_users_email    ON sys_users(email) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_users_phone    ON sys_users(phone) WHERE phone IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sys_users_status ON sys_users(status, locked_until);

CREATE TABLE IF NOT EXISTS sys_perms (
    id          BIGINT      PRIMARY KEY,
    code        VARCHAR(96) NOT NULL,
    name        VARCHAR(64) NOT NULL,
    domain      VARCHAR(32) NOT NULL,
    action      VARCHAR(32) NOT NULL,
    scope       VARCHAR(16),
    is_sensitive BOOLEAN   NOT NULL DEFAULT FALSE,
    description VARCHAR(256)
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_perms_code ON sys_perms(code);

CREATE TABLE IF NOT EXISTS sys_roles (
    id              BIGINT      PRIMARY KEY,
    code            VARCHAR(64) NOT NULL,
    name            VARCHAR(64) NOT NULL,
    is_builtin      BOOLEAN     NOT NULL DEFAULT FALSE,
    description     VARCHAR(256),
    max_data_level  SMALLINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by      BIGINT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by      BIGINT,
    version         INTEGER     NOT NULL DEFAULT 1,
    deleted_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_roles_code ON sys_roles(code) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS sys_user_roles (
    id          BIGINT      PRIMARY KEY,
    user_id     BIGINT      NOT NULL,
    role_id     BIGINT      NOT NULL,
    subject_id  BIGINT,
    granted_by  BIGINT,
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_user_roles
    ON sys_user_roles(user_id, role_id, COALESCE(subject_id, 0));
CREATE INDEX IF NOT EXISTS idx_sys_user_roles_user ON sys_user_roles(user_id);

CREATE TABLE IF NOT EXISTS sys_role_perms (
    id       BIGINT PRIMARY KEY,
    role_id  BIGINT NOT NULL,
    perm_id  BIGINT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_role_perms ON sys_role_perms(role_id, perm_id);

CREATE TABLE IF NOT EXISTS sys_sessions (
    id                 BIGINT      PRIMARY KEY,
    session_id         VARCHAR(64) NOT NULL,
    user_id            BIGINT      NOT NULL,
    refresh_token_bidx BYTEA       NOT NULL,
    refresh_prev_bidx  BYTEA,
    refresh_expires_at TIMESTAMPTZ  NOT NULL,
    device_id          VARCHAR(128),
    device_name        VARCHAR(128),
    client_ip          VARCHAR(45),
    user_agent         VARCHAR(256),
    ip_prefix          VARCHAR(64),
    last_active_at     TIMESTAMPTZ  NOT NULL,
    revoked_at         TIMESTAMPTZ,
    revoke_reason      VARCHAR(64),
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_sessions_session_id ON sys_sessions(session_id);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_sessions_refresh_bidx ON sys_sessions(refresh_token_bidx);
CREATE INDEX IF NOT EXISTS idx_sys_sessions_user ON sys_sessions(user_id, revoked_at);

CREATE TABLE IF NOT EXISTS sys_login_failures (
    id          BIGINT      PRIMARY KEY,
    user_ref    VARCHAR(128),
    client_ip   VARCHAR(45) NOT NULL,
    user_agent  VARCHAR(256),
    reason      VARCHAR(32) NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sys_login_failures_ip   ON sys_login_failures(client_ip, occurred_at);
CREATE INDEX IF NOT EXISTS idx_sys_login_failures_user ON sys_login_failures(user_ref, occurred_at);

CREATE TABLE IF NOT EXISTS sys_ip_blacklist (
    id            BIGINT      PRIMARY KEY,
    client_ip     VARCHAR(45) NOT NULL,
    reason        VARCHAR(128) NOT NULL,
    source        VARCHAR(32),
    blocked_until TIMESTAMPTZ,
    created_by    BIGINT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_ip_blacklist ON sys_ip_blacklist(client_ip, COALESCE(blocked_until, TIMESTAMPTZ 'epoch'));

-- ------------------------------------------------------------
-- 4.2 档案主体域
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS arc_subjects (
    id                BIGINT      PRIMARY KEY,
    name_enc          BYTEA       NOT NULL,
    name_bidx         BYTEA,
    alias             VARCHAR(64),
    relation          SMALLINT    NOT NULL DEFAULT 0,
    gender            SMALLINT,
    birth_date        DATE,
    is_primary        BOOLEAN     NOT NULL DEFAULT FALSE,
    owner_id          BIGINT      NOT NULL,
    custodian_ids     BIGINT[],
    status            SMALLINT    NOT NULL DEFAULT 1,
    completeness       SMALLINT   NOT NULL DEFAULT 0,
    last_accessed_at  TIMESTAMPTZ,
    summary           TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by        BIGINT,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by        BIGINT,
    version           INTEGER     NOT NULL DEFAULT 1,
    deleted_at        TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_arc_subjects_owner ON arc_subjects(owner_id, status);
CREATE INDEX IF NOT EXISTS idx_arc_subjects_name_bidx ON arc_subjects(owner_id, name_bidx);
CREATE INDEX IF NOT EXISTS idx_arc_subjects_custodian ON arc_subjects USING GIN (custodian_ids);

CREATE TABLE IF NOT EXISTS arc_items (
    id                  BIGINT       PRIMARY KEY,
    subject_id          BIGINT       NOT NULL,
    category            SMALLINT     NOT NULL,
    title               VARCHAR(256) NOT NULL,
    title_norm          VARCHAR(256),
    status              SMALLINT     NOT NULL DEFAULT 1,
    sensitivity         SMALLINT     NOT NULL DEFAULT 1,
    issued_date         DATE,
    expires_at          DATE,
    issuer              VARCHAR(128),
    identifier_no_bidx  BYTEA,
    identifier_no_enc   BYTEA,
    tags_count          INTEGER      NOT NULL DEFAULT 0,
    attachment_count    INTEGER      NOT NULL DEFAULT 0,
    source              SMALLINT     NOT NULL DEFAULT 0,
    extra               JSONB        NOT NULL DEFAULT '{}',
    remark              TEXT,
    source_ref          VARCHAR(128),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          BIGINT,
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by          BIGINT,
    version             INTEGER      NOT NULL DEFAULT 1,
    deleted_at          TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_arc_items_subject_cat ON arc_items(subject_id, category, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_arc_items_expires ON arc_items(expires_at) WHERE status = 1 AND expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_arc_items_issuer ON arc_items(issuer);
CREATE INDEX IF NOT EXISTS idx_arc_items_identifier_bidx ON arc_items(identifier_no_bidx);
-- openGauss 5.0.0 不支持 jsonb_path_ops 操作类（实测语法错误），
-- 故用表达式索引：只索引常用查询键的文本值
CREATE INDEX IF NOT EXISTS idx_arc_items_extra ON arc_items ((extra::text));
CREATE INDEX IF NOT EXISTS idx_arc_items_created ON arc_items(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_arc_items_updated ON arc_items(updated_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS arc_field_defs (
    id              BIGINT      PRIMARY KEY,
    subject_id      BIGINT,
    category        SMALLINT    NOT NULL,
    field_key       VARCHAR(64) NOT NULL,
    field_name      VARCHAR(64) NOT NULL,
    data_type       SMALLINT    NOT NULL,
    sensitivity     SMALLINT    NOT NULL DEFAULT 1,
    is_required     BOOLEAN     NOT NULL DEFAULT FALSE,
    is_searchable   BOOLEAN     NOT NULL DEFAULT FALSE,
    is_filterable   BOOLEAN     NOT NULL DEFAULT FALSE,
    is_bidx_capable BOOLEAN     NOT NULL DEFAULT FALSE,
    enum_dict_code  VARCHAR(64),
    display_order   INTEGER     NOT NULL DEFAULT 0,
    validation_rule JSONB,
    default_value   TEXT,
    is_system       BOOLEAN     NOT NULL DEFAULT FALSE,
    status          SMALLINT    NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by      BIGINT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by      BIGINT,
    version         INTEGER     NOT NULL DEFAULT 1,
    deleted_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_field_defs
    ON arc_field_defs(COALESCE(subject_id, 0), category, field_key);
CREATE INDEX IF NOT EXISTS idx_arc_field_defs_cat ON arc_field_defs(category, display_order);

CREATE TABLE IF NOT EXISTS arc_item_fields (
    id                BIGINT PRIMARY KEY,
    item_id           BIGINT NOT NULL,
    field_def_id      BIGINT NOT NULL,
    value_text        TEXT,
    value_num         NUMERIC(20,6),
    value_date        DATE,
    value_bool        BOOLEAN,
    value_json        JSONB,
    value_enc         BYTEA,
    value_bidx        BYTEA,
    numeric_value_norm NUMERIC(20,6)
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_item_fields ON arc_item_fields(item_id, field_def_id);
CREATE INDEX IF NOT EXISTS idx_arc_item_fields_def  ON arc_item_fields(field_def_id, value_bidx);
CREATE INDEX IF NOT EXISTS idx_arc_item_fields_num  ON arc_item_fields(field_def_id, numeric_value_norm);
CREATE INDEX IF NOT EXISTS idx_arc_item_fields_text ON arc_item_fields(field_def_id, value_text);

CREATE TABLE IF NOT EXISTS arc_item_history (
    id             BIGINT      PRIMARY KEY,
    item_id        BIGINT      NOT NULL,
    version_no     INTEGER     NOT NULL,
    change_type    SMALLINT    NOT NULL,
    changed_fields JSONB,
    snapshot       JSONB,
    operator_id    BIGINT,
    operated_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_item_history ON arc_item_history(item_id, version_no);
CREATE INDEX IF NOT EXISTS idx_arc_item_history_time ON arc_item_history(operated_at DESC);

-- ------------------------------------------------------------
-- 7. 附件与影像
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS arc_attachments (
    id                  BIGINT       PRIMARY KEY,
    subject_id          BIGINT       NOT NULL,
    item_id             BIGINT,
    category            SMALLINT     NOT NULL,
    title               VARCHAR(256) NOT NULL,
    current_version_id  BIGINT,
    version_count       INTEGER      NOT NULL DEFAULT 0,
    storage_key         VARCHAR(512) NOT NULL,
    storage_backend     SMALLINT     NOT NULL DEFAULT 0,
    encryption_alg      VARCHAR(16)  NOT NULL DEFAULT 'SM4-CBC',
    key_version         INTEGER      NOT NULL DEFAULT 1,
    file_size           BIGINT,
    file_ext            VARCHAR(16),
    mime_type           VARCHAR(128),
    width               INTEGER,
    height              INTEGER,
    page_count          INTEGER,
    sm3_fingerprint     BYTEA,
    dedup_key           VARCHAR(128),
    status              SMALLINT     NOT NULL DEFAULT 0,
    is_current_deleted  BOOLEAN      NOT NULL DEFAULT FALSE,
    watermark_enabled   BOOLEAN      NOT NULL DEFAULT TRUE,
    download_count      INTEGER      NOT NULL DEFAULT 0,
    last_accessed_at    TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          BIGINT,
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by          BIGINT,
    version             INTEGER      NOT NULL DEFAULT 1,
    deleted_at          TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_arc_attachments_subject ON arc_attachments(subject_id, status);
CREATE INDEX IF NOT EXISTS idx_arc_attachments_item    ON arc_attachments(item_id);
CREATE INDEX IF NOT EXISTS idx_arc_attachments_dedup   ON arc_attachments(dedup_key);

CREATE TABLE IF NOT EXISTS arc_attachment_versions (
    id              BIGINT       PRIMARY KEY,
    attachment_id   BIGINT       NOT NULL,
    version_no      INTEGER      NOT NULL,
    storage_key     VARCHAR(512) NOT NULL,
    file_size       BIGINT       NOT NULL,
    file_ext        VARCHAR(16),
    mime_type       VARCHAR(128),
    sm3_fingerprint BYTEA        NOT NULL,
    iv              BYTEA,
    is_current      BOOLEAN      NOT NULL DEFAULT FALSE,
    status          SMALLINT     NOT NULL DEFAULT 0,
    change_note     VARCHAR(256),
    uploaded_by     BIGINT       NOT NULL,
    uploaded_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_attachment_versions ON arc_attachment_versions(attachment_id, version_no);
CREATE INDEX IF NOT EXISTS idx_arc_attachment_versions_fp ON arc_attachment_versions(sm3_fingerprint);

-- ------------------------------------------------------------
-- 8. 检索与标签
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS arc_search_index (
    item_id       BIGINT      PRIMARY KEY,
    subject_id    BIGINT      NOT NULL,
    category      SMALLINT    NOT NULL,
    title_norm    VARCHAR(256),
    content       TEXT,
    tokens        TEXT[],
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_arc_search_index_subject ON arc_search_index(subject_id, category);
CREATE INDEX IF NOT EXISTS idx_arc_search_index_tokens  ON arc_search_index USING GIN (tokens);

CREATE TABLE IF NOT EXISTS arc_tags (
    id           BIGINT      PRIMARY KEY,
    owner_id     BIGINT      NOT NULL,
    name         VARCHAR(64) NOT NULL,
    name_norm    VARCHAR(64) NOT NULL,
    color        VARCHAR(16),
    category     SMALLINT,
    usage_count  INTEGER     NOT NULL DEFAULT 0,
    last_used_at TIMESTAMPTZ,
    parent_id    BIGINT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   BIGINT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by   BIGINT,
    version      INTEGER     NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_tags
    ON arc_tags(owner_id, name_norm, COALESCE(parent_id, 0));
CREATE INDEX IF NOT EXISTS idx_arc_tags_usage ON arc_tags(owner_id, usage_count DESC);

CREATE TABLE IF NOT EXISTS arc_item_tags (
    id         BIGINT      PRIMARY KEY,
    item_id    BIGINT      NOT NULL,
    tag_id     BIGINT      NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_item_tags ON arc_item_tags(item_id, tag_id);
CREATE INDEX IF NOT EXISTS idx_arc_item_tags_tag ON arc_item_tags(tag_id);

-- ------------------------------------------------------------
-- 9. 授权与分享
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS acl_grants (
    id           BIGINT      PRIMARY KEY,
    subject_id   BIGINT      NOT NULL,
    item_id      BIGINT,
    category     SMALLINT,
    grantee_id   BIGINT      NOT NULL,
    perm_codes   VARCHAR(512) NOT NULL,
    granted_by   BIGINT      NOT NULL,
    granted_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at   TIMESTAMPTZ,
    revoked_at   TIMESTAMPTZ,
    revoke_reason VARCHAR(64)
);
CREATE INDEX IF NOT EXISTS idx_acl_grants_grantee ON acl_grants(grantee_id, revoked_at, expires_at);
CREATE INDEX IF NOT EXISTS idx_acl_grants_subject  ON acl_grants(subject_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_acl_grants_item     ON acl_grants(item_id) WHERE item_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS acl_shares (
    id            BIGINT       PRIMARY KEY,
    share_token   VARCHAR(128) NOT NULL,
    subject_id    BIGINT       NOT NULL,
    item_id       BIGINT,
    category      SMALLINT,
    title         VARCHAR(256),
    password_hash VARCHAR(255),
    max_access    INTEGER,
    access_count  INTEGER      NOT NULL DEFAULT 0,
    expires_at    TIMESTAMPTZ,
    created_by    BIGINT       NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_acl_shares_token ON acl_shares(share_token);

CREATE TABLE IF NOT EXISTS acl_share_access_log (
    id         BIGINT      PRIMARY KEY,
    share_id   BIGINT      NOT NULL,
    client_ip  VARCHAR(45),
    user_agent VARCHAR(256),
    result     VARCHAR(32) NOT NULL,
    accessed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_acl_share_access_log ON acl_share_access_log(share_id, accessed_at DESC);

-- ------------------------------------------------------------
-- 10. 审计与通知
-- ------------------------------------------------------------

-- 审计表：仅 INSERT（应用账号无 UPDATE/DELETE 权限，见 §10.1 权限段）
CREATE TABLE IF NOT EXISTS aud_logs (
    id           BIGINT      PRIMARY KEY,
    chain_seq    BIGINT      NOT NULL,
    actor_id     BIGINT,
    actor_type   SMALLINT    NOT NULL DEFAULT 0,
    action       VARCHAR(64) NOT NULL,
    action_desc  VARCHAR(256),
    target_type  VARCHAR(32),
    target_id    VARCHAR(64),
    subject_id   BIGINT,
    category     SMALLINT,
    result       SMALLINT    NOT NULL DEFAULT 0,
    error_code   VARCHAR(32),
    client_ip    VARCHAR(45),
    user_agent   VARCHAR(256),
    trace_id     VARCHAR(64),
    detail       JSONB,
    prev_hash    BYTEA   NOT NULL,
    record_hash  BYTEA   NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_aud_logs_chain_seq ON aud_logs(chain_seq);
CREATE UNIQUE INDEX IF NOT EXISTS uk_aud_logs_hash      ON aud_logs(record_hash);
CREATE INDEX IF NOT EXISTS idx_aud_logs_actor         ON aud_logs(actor_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_subject       ON aud_logs(subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_action        ON aud_logs(action, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_result        ON aud_logs(result, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_time          ON aud_logs(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_trace         ON aud_logs(trace_id);

-- 链头锚定：防「整链重写」攻击 —— 每日把链头写到主库之外的位置
CREATE TABLE IF NOT EXISTS aud_chain_anchors (
    id             BIGINT      PRIMARY KEY,
    anchor_date    DATE        NOT NULL,
    chain_head_hash BYTEA  NOT NULL,
    record_count   BIGINT      NOT NULL,
    anchored_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    anchored_by    BIGINT,
    external_ref   VARCHAR(256)
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_aud_chain_anchors_date ON aud_chain_anchors(anchor_date);

CREATE TABLE IF NOT EXISTS nft_messages (
    id          BIGINT      PRIMARY KEY,
    user_id     BIGINT      NOT NULL,
    category    SMALLINT,
    title       VARCHAR(128) NOT NULL,
    body        TEXT,
    link        VARCHAR(256),
    priority    SMALLINT    NOT NULL DEFAULT 0,
    is_read     BOOLEAN     NOT NULL DEFAULT FALSE,
    read_at     TIMESTAMPTZ,
    expires_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_nft_messages_user ON nft_messages(user_id, is_read, created_at DESC);

CREATE TABLE IF NOT EXISTS job_leases (
    id          BIGINT      PRIMARY KEY,
    job_name    VARCHAR(64) NOT NULL,
    owner_id    VARCHAR(64) NOT NULL,
    lease_until TIMESTAMPTZ NOT NULL,
    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_job_leases_name ON job_leases(job_name);

CREATE TABLE IF NOT EXISTS imp_export_tasks (
    id          BIGINT      PRIMARY KEY,
    task_no     VARCHAR(64) NOT NULL,
    task_type   VARCHAR(16) NOT NULL,
    user_id     BIGINT      NOT NULL,
    subject_id  BIGINT,
    status      SMALLINT    NOT NULL DEFAULT 0,
    total_count INTEGER     NOT NULL DEFAULT 0,
    done_count  INTEGER     NOT NULL DEFAULT 0,
    failed_count INTEGER    NOT NULL DEFAULT 0,
    params      JSONB,
    result_path VARCHAR(512),
    error_msg   TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_imp_export_tasks_no ON imp_export_tasks(task_no);
CREATE INDEX IF NOT EXISTS idx_imp_export_tasks_user ON imp_export_tasks(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS imp_export_task_items (
    id         BIGINT      PRIMARY KEY,
    task_id    BIGINT      NOT NULL,
    item_id    BIGINT,
    status     SMALLINT    NOT NULL DEFAULT 0,
    error_msg  TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_imp_export_task_items ON imp_export_task_items(task_id, status);

-- ------------------------------------------------------------
-- 11. 字典
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cfg_dict_types (
    id          BIGINT      PRIMARY KEY,
    code        VARCHAR(64) NOT NULL,
    name        VARCHAR(64) NOT NULL,
    description VARCHAR(256),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  BIGINT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by  BIGINT,
    version     INTEGER     NOT NULL DEFAULT 1,
    deleted_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_cfg_dict_types_code ON cfg_dict_types(code) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS cfg_dict_items (
    id           BIGINT      PRIMARY KEY,
    dict_type_id BIGINT      NOT NULL,
    code         VARCHAR(64) NOT NULL,
    label        VARCHAR(64) NOT NULL,
    sort_order   INTEGER     NOT NULL DEFAULT 0,
    extra        JSONB,
    status       SMALLINT    NOT NULL DEFAULT 1,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   BIGINT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by   BIGINT,
    version      INTEGER     NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_cfg_dict_items
    ON cfg_dict_items(dict_type_id, code) WHERE deleted_at IS NULL;

-- ------------------------------------------------------------
-- 12. 配置项（键值型，含敏感配置的密文列）
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cfg_settings (
    id          BIGINT      PRIMARY KEY,
    scope       VARCHAR(32) NOT NULL DEFAULT 'global',
    key         VARCHAR(128) NOT NULL,
    value       TEXT,
    value_enc   BYTEA,
    value_type  VARCHAR(16) NOT NULL DEFAULT 'string',
    is_secret   BOOLEAN     NOT NULL DEFAULT FALSE,
    description VARCHAR(256),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  BIGINT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by  BIGINT,
    version     INTEGER     NOT NULL DEFAULT 1,
    deleted_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uk_cfg_settings
    ON cfg_settings(scope, key) WHERE deleted_at IS NULL;
