# AMS 生产运维手册（RUNBOOK）

> 适用：`deploy/compose/docker-compose.yml` 的**单机容器化部署**（仓颉后端 + Vue3 前端 + openGauss）。
> 物理机发布包路径见 `docs/09-部署与发布指南.md`；容器化部署说明见 `deploy/README.md`。
>
> **本文只描述当前仓库已落地的能力。** 凡是「建议」「应」而尚未在仓库中实现的，
> 均在 §8「已知生产缺口清单」中如实列出，请勿把建议做法当成已具备的功能。
> 本文所有命令均未在本次任务中实机执行（见文末「验证边界」）。

---

## 0. 常用命令速查

下文 `COMPOSE` 统一代表：

```bash
COMPOSE="docker compose -p ams -f deploy/compose/docker-compose.yml"
```

| 目的 | 命令 |
| --- | --- |
| 启动整栈 | `bash deploy/scripts/run-app.sh` |
| 查看状态 | `$COMPOSE ps` |
| 看应用日志 | `$COMPOSE logs -f ams` |
| 看迁移日志 | `$COMPOSE logs -f init` |
| 健康检查 | `curl -fsS http://127.0.0.1:8080/api/health` |
| 停止整栈 | `$COMPOSE down` |
| 备份 | `bash deploy/scripts/backup.sh` |
| 异地副本 | `bash deploy/scripts/backup-offsite.sh`（需先配后端，默认未启用） |
| 恢复 | `bash deploy/scripts/restore.sh <容器内备份路径>` |
| 恢复演练 | `bash deploy/scripts/restore-drill.sh --dry-run <备份.sql>`（独立临时容器，默认未启用） |

---

## 1. 部署前置

### 1.1 必填三变量与 SEC-001

`docker-compose.yml` 已把三个凭据改为 `${VAR:?...}` **必填变量**，缺任意一个 compose 直接拒绝启动：

| 变量 | 要求 | 生成方式（生产） |
| --- | --- | --- |
| `AMS_DB_PASSWORD` | openGauss 口令，须与既有 `ams_ogdata` 卷初始化口令一致 | 由 DBA 保管，不使用仓库默认值 |
| `AMS_TOKEN_SECRET` | 令牌签名密钥，**≥ 32 字节随机值** | `openssl rand -base64 48` |
| `AMS_KEK` | 密钥加密密钥（包裹密钥 / 盲索引派生） | `openssl rand -hex 32` |

后端新增 **SEC-001 门禁**：`AMS_ENV=production` 时，上述三项**必须显式提供且不得使用内置开发默认值**，否则进程直接拒绝启动。compose 的 `ams` 服务写的是 `AMS_ENV: "${AMS_ENV:-production}"`，即**不设置就等于 production**。

- **本地开发**：`cp deploy/compose/.env.example deploy/compose/.env`，模板中 `AMS_ENV=dev` 显式覆盖默认值，不触发 SEC-001；模板里的值均为 dev 固定值，**禁止用于生产**。
- **生产**：通过 `env_file` / Docker secrets 注入随机值，`AMS_ENV=production`（或留空走默认），绝不把 `.env` 提交到仓库（已被 `.gitignore` 屏蔽）。
- `deploy/config/ams.env.example` 是**运行期配置模板**（另一套文件），其中同样标注了生产必填项。

> ⚠️ 更换 `AMS_KEK` 会使既有用该 KEK 包裹的密钥/盲索引无法解密。生产运行中不要随意轮换，
> 轮换需配套数据重加密方案（当前仓库**没有** KEK 轮换工具，见 §8）。

### 1.2 网络与 TLS

- `ams` 容器只提供 **HTTP `:8080`**（`AMS_HTTP_HOST=0.0.0.0` / `AMS_HTTP_PORT=8080`），
  一个进程同时托管 `/api/*` 与前端 SPA，**不监听 HTTPS、不内置 TLS 证书**。
- **TLS 必须由前置反向代理终止**：`客户端 --HTTPS--> 反向代理 --HTTP--> 127.0.0.1:8080`。
  当前 compose **未内置**任何反代 / TLS 容器，需运维自行部署并配置。
- `ams-server` 已内置 SPA history 回退，反代把 `/` 整体转发即可，**不要**在反代层做 `try_files` 兜底
  （见 `docs/09` §6 排障表）。
- 容器之间：`AMS_DB_HOST` 必须是 IP 字面量 `172.28.0.10`（仓颉运行时不解析服务名 / `/etc/hosts`）。

### 1.3 受限数据库账号 `ams_app`

- compose 目前用 `gaussdb`（初始化/高权限用户）连接，包括 `db`、`init`、`ams` 三个服务。
- 生产应创建受限角色 **`ams_app`**（业务表全 DML、审计表仅 `SELECT/INSERT`，
  迁移脚本见 `db/migrations/006_audit_restricted_role.sql`），并通过
  `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD` 让**应用**以受限角色连接；
  迁移 `init` 服务仍需高权限账号执行 DDL。
- **如实说明**：compose 当前**没有**配置这两个变量，角色的创建与注入需运维自行完成，
  尚未在仓库中默认启用（§8）。

### 1.4 卷与资源限制

| 卷 | 用途 | 备注 |
| --- | --- | --- |
| `ams_ogdata` | openGauss 数据 | `external: true`，重建容器不丢数据 |
| `ams-config` | 部署配置 `deployment.env` | 向导写入 |
| `ams-data` | 附件 | |
| `ams-exports` | 导出文件 | |
| `ams-mail` | 邮件暂存 | |
| `ams-backups` | 备份产物（**db 与 ams 服务共用**，均挂 `/app/data-backups`） | 容器重建不丢，见 §3 |

`db` / `ams` 均已设 `mem_limit: 2g`、`cpus: 2.0`、`json-file` 日志轮转 `max-size 20m` / `max-file 5`。

---

## 2. 首次部署与初始化向导

1. **准备变量文件**（必做，否则 compose 抛 `:?` 错误）：

   ```bash
   cp deploy/compose/.env.example deploy/compose/.env
   $EDITOR deploy/compose/.env      # 生产：换成随机凭据，AMS_ENV=production
   chmod 600 deploy/compose/.env
   ```

2. **准备镜像**（二选一）：

   ```bash
   # A. 由脚本交叉编译 Linux 后端产物，再经 Dockerfile.prebuilt 构建 ams:1.3.1
   bash deploy/scripts/build-linux-docker.sh
   docker build -t ams:1.3.1 -f deploy/docker/Dockerfile.prebuilt .

   # B. 直接带 --build 启动（compose 的 ams.build 指向 Dockerfile.prebuilt）
   bash deploy/scripts/run-app.sh --build
   ```

3. **启动整栈**：

   ```bash
   bash deploy/scripts/run-app.sh
   ```

   顺序由 compose 保证：`db`（healthcheck 通过）→ `init`（`migrate.sh` 逐文件台账跑完）→ `ams`。
   `run-app.sh` 会轮询 `/api/health` 直到 HTTP 200（最多 60 次）。

4. **观察**：

   ```bash
   $COMPOSE ps
   $COMPOSE logs -f init       # 迁移是否 apply/skip/fail
   $COMPOSE logs -f ams        # 启动日志、SEC-001 是否拒绝
   curl -fsS http://127.0.0.1:8080/api/health
   ```

5. **首次访问向导**：浏览器打开 `http://<host>:8080/`，库中无管理员时自动进入 `/setup`：

   1. **数据库连接** —— 默认沿用 compose 的 `AMS_DB_*`；外部库可填 IP/端口/库名/用户/口令并「测试连接」；
   2. **创建管理员** —— 首个账号自动获 `owner` + `org_admin`，完成后向导**永久关闭**；
   3. **邮件服务**（可选）—— SMTP 供找回密码；可跳过，之后在「系统运维 → 部署配置」补充。

   配置写入持久卷 `/app/config/deployment.env`（`ams-config`），规则见 `deploy/README.md` §8：
   文件里没有的键继续读环境变量；**数据库配置保存后需 `docker compose -p ams restart ams` 才生效**。

6. **首次部署后立即做一次备份**（§3），并保存好凭据与备份文件。

---

## 3. 备份

### 3.1 执行

`backup.sh` 在 **db 容器 `ams_opengauss` 内**用 openGauss 自带 `gs_dump` 导出纯 SQL，
调用方式（`LD_LIBRARY_PATH`、conninfo 连接串）与 `deploy/scripts/migrate.sh` 一致。

```bash
set -a; source deploy/compose/.env; set +a      # 载入 AMS_DB_PASSWORD
bash deploy/scripts/backup.sh
AMS_BACKUP_KEEP=14 bash deploy/scripts/backup.sh # 自定义保留份数（默认 7）
```

产物（**db 容器内**路径）：

```
/app/data-backups/ams-YYYYmmdd-HHMMSS.sql          纯 SQL 转储
/app/data-backups/ams-YYYYmmdd-HHMMSS.sql.sha256   sha256 校验文件
```

脚本会打印产物路径与 `docker cp` 取回命令，并按 `AMS_BACKUP_KEEP` 清理更旧的
`ams-*.sql` 及配套 `.sha256`。口令取自 `AMS_DB_PASSWORD`，**脚本不硬编码任何口令**。

### 3.2 取回与校验

```bash
docker cp ams_opengauss:/app/data-backups/ams-20261107-120000.sql ./
docker cp ams_opengauss:/app/data-backups/ams-20261107-120000.sql.sha256 ./
sha256sum -c ams-20261107-120000.sql.sha256     # 应输出 OK
```

> [!] **持久化已落地**：compose 把同一个 `ams-backups` 命名卷同时挂到
> **db 与 ams 服务**的 `/app/data-backups`。`backup.sh` 在 db 容器内
> `gs_dump` 到该路径，产物落在命名卷里，容器重建不会丢失；
> 脚本用 `-u root` 建目录并交给 `omm`（卷首次挂载时属主为 root）。
> 但卷与数据库同机，整机故障仍会一起丢失，务必按 §3.2 `docker cp`
> 取回并异地留存；仓库提供 `deploy/scripts/backup-offsite.sh` 做「校验后再复制」
> 的异地副本（**脚本已提供，默认未启用**，需运维配置后端，见 §3.3 / §9）。

### 3.3 调度、异地副本与演练（脚本已提供，但默认未启用）

- **本地备份**：`deploy/scripts/backup.sh` 手动执行；`AMS_BACKUP_KEEP=7`（默认）清理旧备份。
- **异地副本**：`deploy/scripts/backup-offsite.sh` 先 `sha256sum -c` 校验再复制，
  后端二选一：`RCLONE_REMOTE`（rclone）或 `OFFSITE_HOST` + `OFFSITE_PATH`
  （rsync / scp）；都没设置会打印指引并**明确报错退出 1**，绝不静默成功。
  `OFFSITE_KEEP` 控制异地保留份数。**通道依赖运维配置**，仓库不预置主机 / 凭据（§8）。
- **调度样例**：`deploy/scripts/crontab.example`（每日 02:30 备份 / 03:00 异地复制 /
  每月 1 日 04:00 演练）与 `deploy/systemd/ams-backup.service` +
  `ams-backup.timer`（`OnCalendar=*-*-* 02:30:00`、`Persistent=true`、
  `EnvironmentFile=/etc/ams/ams.env`、`ExecStartPre=backup.sh`）。两者都是**示例，
  默认未启用**：需运维改绝对路径、配变量文件后
  `systemctl enable --now ams-backup.timer` 或自行 `crontab` 安装；二选一，不要同时启用。
- **恢复演练**：`deploy/scripts/restore-drill.sh` 在独立临时容器里导入并校验
  （绝不碰生产数据，`--dry-run` 只打印命令），步骤与验收见 §4.4；建议每月至少一次。
- **建议周期**：每日一次全量逻辑备份（低峰期）；关键业务期可提高频率。
- **建议保留**：`AMS_BACKUP_KEEP=7`（默认），异地另存至少一份。
- **每次必做**：`sha256sum -c` 校验；**每月至少一次恢复演练**（脚本已提供，需运维启用）。
- **备份范围（诚实结论）**：`backup.sh` / `backup-offsite.sh` 只覆盖**数据库**。
  附件 / 导出 / 配置 / 邮件分别落在 `ams-data` / `ams-exports` / `ams-config` /
  `ams-mail` 卷，**仍无卷级备份方案**，需另行对齐并保证与 DB 同一时间点（§8）。
  恢复时若这些卷与 DB 时间点不一致，会出现数据不一致。

---

## 4. 恢复

> 恢复是**破坏性操作**。`backup.sh` 的 dump 带 `--clean --if-exists`，
> 导入时会 DROP 并重建同名对象，**备份时间点之后的数据将丢失**。

### 4.1 步骤

```bash
# 0) 停止应用写入，避免恢复期间继续写库；并先给「当前库」留一份退路
$COMPOSE stop ams
set -a; source deploy/compose/.env; set +a
bash deploy/scripts/backup.sh

# 1) 备份文件放到 db 容器内（参数是「容器内路径」）
docker cp ./ams-20261107-120000.sql ams_opengauss:/app/data-backups/
docker cp ./ams-20261107-120000.sql.sha256 ams_opengauss:/app/data-backups/

# 2) 恢复：脚本会先校验 sha256、再要求输入 RESTORE 二次确认
bash deploy/scripts/restore.sh /app/data-backups/ams-20261107-120000.sql

# 3) 恢复后校验（见 4.3），然后拉起应用
$COMPOSE up -d ams
```

`restore.sh` 用容器内 `gsql -v ON_ERROR_STOP=1 -f` 导入；
未输入精确的 `RESTORE` 一律取消，sha256 校验失败也会中止。

### 4.2 RTO / RPO（建议目标，未经演练验证）

| 指标 | 建议目标 | 依据与限制 |
| --- | --- | --- |
| **RPO** | 默认 ≤ **24 h**（每日全量备份）；关键业务期建议 ≤ **1 h** | 当前只有定时全量逻辑备份，**无增量备份 / 连续归档 / WAL 归档**；要达到 1h 需提高备份频率并自行实现，仓库未落地 |
| **RTO** | ≤ **2 h** | 单机 `gsql -f` 逻辑恢复 + 校验；实际耗时取决于 dump 体积，**未实测**；演练脚本已提供但默认未启用（§4.4） |

> 以上为**规划建议值**，不是已验证的 SLA。请通过恢复演练实测后再对外承诺。

### 4.3 恢复后校验项

1. **迁移台账**：`_ams_migrations` 行数/文件清单与发布版本一致
   （`gsql -c "SELECT name, applied_at FROM _ams_migrations ORDER BY applied_at;"`）；
   台账与数据同在 dump 中，会一并恢复。
2. **健康检查**：`curl -fsS http://127.0.0.1:8080/api/health` 返回
   `{"code":"OK",...,"data":{"status":"ok"}}`。
3. **业务抽样**：登录、档案列表/详情、附件下载、家庭成员邀请、审计链连续性。
4. **配套卷**：确认 `ams-data`（附件）、`ams-config`（`deployment.env`）与恢复时间点匹配，
   否则需单独对齐（当前无自动化，见 §8）。
5. **日志**：`$COMPOSE logs -f ams` 无 `server.db.unavailable` / SEC-001 拒绝等错误。

### 4.4 恢复演练（绝不碰生产数据）

`deploy/scripts/restore-drill.sh` 在**独立临时容器**（镜像
`enmotech/opengauss:5.0.0`、随机容器名 `ams_restore_drill_<ts>`、独立网络、
`--rm`）里拉起全新 openGauss 实例，导入指定备份并跑只读校验 SQL；
**不连接、不挂载、不写入任何生产容器 / 卷 / 网络**，临时实例口令为
独立随机值，绝不复用 `AMS_DB_PASSWORD`。脚本**默认未启用**，也未实机验证。

```bash
# 1) 先只打印将执行的命令（不创建任何资源、不碰生产数据）
bash deploy/scripts/restore-drill.sh --dry-run ./ams-20261107-120000.sql
# 2) 确认命令无误后实跑（带超时；结束无论成败都清理临时容器 / 网络）
bash deploy/scripts/restore-drill.sh ./ams-20261107-120000.sql
```

演练脚本执行的校验 SQL（与 §4.3 的人工校验互补）：

- `SELECT count(*) FROM information_schema.tables WHERE table_schema='public';`
- `SELECT count(*) FROM sys_users;`
- 关键表存在检查（`sys_users`、`_ams_migrations` 等，可用 `DRILL_KEY_TABLES` 配置）。

**验收标准（脚本据此给出 PASS / FAIL）**：

1. 导入 `gsql -v ON_ERROR_STOP=1 -f` 成功（失败即 FAIL）；
2. `public` 表数量 > 0 且为数字；
3. `sys_users` 可查询（返回数字行数，表不存在即 FAIL）；
4. 每个关键表在 `information_schema.tables` 中命中；
5. 临时容器 / 网络在成功或失败后均已清理（`docker ps -a` 无 `ams_restore_drill_*`）。

> 演练只验证**数据库逻辑备份可导入**；附件 / 配置卷未参与，
> 也不代表整机恢复。RTO/RPO 需据演练实测后回填 §4.2。

---

## 5. 版本升级与回滚

### 5.1 升级（停机顺序）

1. **先备份**（§3），确认 `.sha256` 校验通过。
2. **停应用写入**：`$COMPOSE stop ams`（`db` 保持运行，`init` 为一次性任务）。
3. **按变更类型选构建路径（关键）**：

   | 变更 | 构建方式 | 原因 |
   | --- | --- | --- |
   | **仅前端** | `cd web && npm run build` → `docker build -f deploy/docker/Dockerfile.merge -t ams:1.3.1 .` → `$COMPOSE up -d --no-build ams` | `Dockerfile.merge` 以既有 `ams:1.3.1` 为基底，**只 `COPY web/dist/ /app/web/`**，不换后端二进制，不引入后端回归 |
   | **后端 / 依赖 / 配置** | `bash deploy/scripts/build-linux-docker.sh` → `docker build -f deploy/docker/Dockerfile.prebuilt -t ams:1.3.1 .` → `$COMPOSE up -d --no-build ams` | 仓颉不支持交叉编译，**必须**先经 `build-linux-docker.sh` 在工具链镜像内重编出 Linux 产物，再经 `Dockerfile.prebuilt` 重建镜像 |

   > ⚠️ **绝不能**用 `Dockerfile.merge` 发布后端变更：它 `FROM ams:1.3.1` 只叠加前端，
   > 后端二进制仍是旧的。`Dockerfile.prebuilt` 里的 `FROM ubuntu:22.04` 会重新
   > `COPY build/linux/` 与 `web/dist/`，是后端变更的唯一正确入口。

4. **迁移**：`$COMPOSE up -d` 时 `init` 服务按 `_ams_migrations` **逐文件台账**自动补跑新增迁移
   （见 5.3）；用 `$COMPOSE logs init` 确认 `fail=0`。
5. **校验**：`/api/health` + 业务抽样 + `$COMPOSE ps` 状态 healthy。

### 5.2 回滚

- **镜像回滚**：保留上一版镜像并打 tag，`docker tag <上一版镜像> ams:1.3.1` 后
  `$COMPOSE up -d --no-build ams`；前端回滚即重新 `Dockerfile.merge` 上一版 `web/dist`。
  > 仓库**没有**版本化镜像仓库 / 回滚脚本，需自行保留上一版镜像或 digest（§8）。
- **数据库回滚**：`_ams_migrations` **只增不减**，仓库**没有**自动 down 迁移。
  若升级后的迁移不兼容，只能按 §4 用**升级前的备份**整库恢复——
  这会丢失升级后写入的数据，务必在升级前备份。
- **回滚顺序**：停 `ams` → 恢复 DB / 换镜像 → 起 `ams` → 校验（§4.3）。

### 5.3 迁移台账 `_ams_migrations`

- 表结构：`name TEXT PRIMARY KEY`, `applied_at TIMESTAMPTZ NOT NULL DEFAULT now()`。
- `deploy/scripts/migrate.sh` 对 `db/migrations/*.sql` 逐个执行，**只有成功才登记**；
  下次起栈自动补齐新增迁移。这是可演进部署的正确模型，
  **不再是**「检测到 `sys_users` 就整体跳过」（那会漏掉增量迁移，历史教训见 migrate.sh 头注释）。
- 查询：`gsql -c "SELECT name, applied_at FROM _ams_migrations ORDER BY applied_at;"`
- `migrate.sh --force` 会忽略台账全部重跑（危险，仅用于排障）；
  **不要**手工删台账行来「重跑」，非幂等 DDL 会重复执行报错。
- 宿主机侧 `deploy/scripts/init-db.sh` 仍采用「`sys_users` 存在即跳过」的整体判断，
  **仅作调试工具**，不能替代 compose 的 `init` 服务。

---

## 6. 监控与健康检查

**已具备：**

| 项 | 现状 |
| --- | --- |
| `GET /api/health` | `ams-server` 内置就绪接口，正常返回 `{"code":"OK","message":"success","data":{"status":"ok"},"requestId":"..."}` |
| `ams` healthcheck | `curl -fSs http://127.0.0.1:8080/api/health`，`interval 30s / timeout 5s / retries 3 / start_period 30s` |
| `db` healthcheck | `/usr/local/opengauss/bin/gs_ctl query -D ... \| grep -q 'db_state.*Normal'`，`interval 15s / timeout 5s / retries 20 / start_period 60s` |
| 启动依赖 | `depends_on`：`init` 等 `db: service_healthy`，`ams` 等 `init: service_completed_successfully` |
| 重启策略 | `db` / `ams`：`restart: unless-stopped` |
| 日志轮转 | `json-file`，`max-size 20m`、`max-file 5`（`db` 与 `ams`） |
| 资源上限 | `mem_limit 2g`、`cpus 2.0`（`db` 与 `ams`） |

**如实标注：当前缺少的能力（未落地）**

- **没有** Prometheus exporter / `/metrics` 端点、没有 Grafana 面板；
- **没有** Alertmanager、邮件 / webhook / 短信等**任何告警通道**；
- **没有**外部可用性探针、SLA 统计、日志集中收集 / 检索；
- **没有**自动扩缩容、自愈（除 `restart: unless-stopped`）与备份任务**失败告警**
  （调度样例见 §9，默认未启用）；
- `docker stats` / `$COMPOSE ps` 的 healthy 状态目前是唯一的运行态观测手段。

> [建议，未落地] 由外部监控系统轮询 `/api/health` 与容器 healthy 状态并配置告警；
> 采集 `json-file` 日志到集中日志平台；为备份任务加失败告警。

---

## 7. 日志与排障

### 7.1 日志

```bash
$COMPOSE logs -f ams        # 应用（启动、SEC-001、http.static.*、请求错误）
$COMPOSE logs -f db         # openGauss 启动日志
$COMPOSE logs -f init       # 迁移 apply / skip / fail 明细
docker logs --tail 200 ams-server
```

`db` 与 `ams` 均用 `json-file` 驱动、`20m × 5` 轮转（单容器约 100 MB 上限），
原始文件在 Docker 数据目录的 containers/*-json.log。**注意**：日志只在容器内，
无集中收集；容器被删除日志即丢失。

openGauss 的 MOT 相关致命错误（如 `mbind: Operation not permitted`）通常**不在** `docker logs` 里，
而在数据卷的 `pg_log/*.log` 中，排查无限重启时要看那里。

### 7.2 常见故障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| compose 启动即报 `required variable AMS_DB_PASSWORD is missing` 之类 `:?` 错误 | 没有 `deploy/compose/.env`，也未从环境注入三变量 | `cp deploy/compose/.env.example deploy/compose/.env` 并按需修改；`run-app.sh` 会提前给出该指引并退出 1 |
| `ams` 起不来，日志提示凭据/SEC-001 | `AMS_ENV=production`（默认）下三凭据缺失或仍是内置开发默认值 | 换成随机值并显式注入；本地开发才用 `AMS_ENV=dev` |
| `init` 失败，`ams` 一直不启动 | db 未健康 / 口令错 / 迁移 SQL 报错 | `$COMPOSE logs init`；核对 `AMS_DB_PASSWORD` 与 `ams_ogdata` 卷初始化口令；查 `_ams_migrations` |
| `/api/health` 200，但页面 404 / 白屏 | `web/dist` 未打进镜像或 `AMS_WEB_DIR` 指错 | 重建镜像；看启动日志是否 `http.static.disabled`；见 `docs/09` §6 |
| 应用连不上库 | 仓颉只认 IP 字面量；或单跑镜像用了默认 `AMS_DB_HOST=db` | 必须 `AMS_DB_HOST=172.28.0.10`；`Dockerfile.prebuilt` 的 `ENV AMS_DB_HOST=db` 只是占位，脱离 compose 单跑解析不了，用 `-e` 覆盖 |
| `db` 无限重启、日志无明显 FATAL | MOT 引擎 `mbind` 需要能力 | compose 已用 `privileged: true`；查 `pg_log/*.log`；生产应关 MOT 或收紧 capability（§8） |
| 备份/恢复报权限错误 | db 容器以 `omm` 运行，容器内无可写目录 | `backup.sh` 已用 `-u root` 建目录并 `chown omm:`；确认 `/app/data-backups` 可写 |
| `restore.sh` 导入报「对象已存在」 | dump 不含 DROP | 用 `backup.sh` 产物（带 `--clean --if-exists`）；不要导入来历不明的纯数据 dump |
| `sha256sum -c` 失败 | 文件被改动 / 传输损坏 | 中止恢复，重新取回备份；`restore.sh` 校验失败会自动中止 |
| 反代后刷新子页面 404 | 反代自行做了 `try_files` 兜底 | 把 `/` 整体转发给 `ams-server`（其内置 history 回退） |
| `Invalid username/password (28P01)` | 口令被 percent-encode | 原样填入，不做 `%XX` 编码（见 `docs/09` §3.1） |

---

## 8. 已知生产缺口清单（如实；含已提供脚本但未默认启用的项）

| # | 缺口 | 现状 | 建议 |
| --- | --- | --- | --- |
| 1 | **`db` 服务 `privileged: true`** | 为 openGauss MOT 的 `mbind` NUMA 绑核整容器提权 | 生产关闭 MOT，或改用 `--cap-add SYS_NICE,IPC_LOCK,SYS_RESOURCE` 收紧，去掉整容器提权 |
| 2 | **`15432:5432` 端口暴露到宿主机** | 为方便 `scripts/db.py` 连容器库而映射 | 生产仅绑定内网地址或从 compose 移除该映射 |
| 3 | **无 TLS** | 容器仅 HTTP `:8080`，TLS 完全依赖前置反向代理；compose 未内置反代/证书 | 部署前置反代终止 TLS；反代到容器之间建议置于隔离网络 |
| 4 | **无告警通道** | 无 Prometheus / Alertmanager / 邮件 / webhook 告警；仅 Docker healthcheck + `restart` | 外部探针 + 告警平台；备份失败也要告警 |
| 5 | **商密产品认证未进行** | SM4 方案在算法层面已实现（见 `docs/08`），但**未做商用密码产品认证 / 密评 / 等保测评** | 有合规要求的场景需另行送检与选型认证产品 |
| 6 | **异地副本：已提供脚本，默认未启用** | `backup-offsite.sh` 已实现「先 `sha256sum -c` 校验再复制」+ `OFFSITE_KEEP`；但**异地通道依赖运维配置**（`RCLONE_REMOTE` 或 `OFFSITE_HOST`/`OFFSITE_PATH`），未配置即报错退出；仓库不预置任何主机 / 凭据 | 按 §9 启用清单配置后端，并人工核对远端确实收到文件 |
| 7 | **调度 / 演练：已提供脚本与样例，默认未启用** | `crontab.example`、`ams-backup.service`/`.timer` 与 `restore-drill.sh` 已提供；但均为示例，需运维改绝对路径、配 `EnvironmentFile` 后 `systemctl enable --now ams-backup.timer`；**未实机验证** | 按 §9 启用清单启用，配置失败告警，每月演练（§4.4） |
| 8 | **备份仅覆盖数据库（诚实结论）** | `backup.sh` / `backup-offsite.sh` 只导出数据库；附件 / 导出 / 配置 / 邮件卷**仍无卷级备份方案**，需另行对齐并保证与 DB 同一时间点；时间点不一致会产生数据不一致 | 增加卷快照 / 文件级备份，纳入 §9 启用清单 |
| 9 | **受限账号 `ams_app` 未默认启用** | compose 三服务均用 `gaussdb` | 建角色并注入 `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD`（§1.3） |
| 10 | **systemd / Windows 服务封装仅为样例** | `deploy/systemd/ams.service`、`deploy/windows/start.cmd` 是示例文件，未与发布包集成、未验证；Windows 服务封装（NSSM / WinSW）**尚未落地** | 参考 `docs/09` §4.1 / §4.2 自行封装并验证 |
| 11 | **无自动 down 迁移 / 回滚工具** | `_ams_migrations` 只增不减，DB 回滚只能整库恢复（§5.2） | 制定人工回滚预案，升级前强制备份 |
| 12 | **单点部署** | 单 `db` + 单 `ams`，无高可用、无读写分离、无异地灾备 | 按 `docs/15` 架构演进路线评估 |

---

## 9. 自动化启用清单（脚本已提供，默认未启用）

> 本节列出**必须由运维执行**的动作。仓库只提供脚本与示例单元，
> 不自动启用任何调度、不预置任何异地通道凭据，这些脚本也**未经实机验证**。

| # | 动作 | 涉及文件 | 说明 |
| --- | --- | --- | --- |
| 1 | 准备变量文件 `/etc/ams/ams.env`（`chmod 600`） | `deploy/config/ams.env.example` | 填 `AMS_DB_PASSWORD` 等；以及异地后端变量（`RCLONE_REMOTE` 或 `OFFSITE_HOST` + `OFFSITE_PATH`、`OFFSITE_KEEP`）；systemd `EnvironmentFile` 为纯 `KEY=VALUE`，不写 `export` / 引号 |
| 2 | 配置 rclone 或 ssh 通道 | 运维侧 `rclone.conf` / `ssh config` / agent | 脚本不硬编码任何主机 / 账号 / 口令；首次人工核对远端确实收到文件 |
| 3 | 替换示例里的绝对路径 | `crontab.example`、`ams-backup.service`、`ams-backup.timer` | 把 `/ABS/REPO`、`/etc/ams/ams.env`、日志目录换成实际值 |
| 4 | 示例拷到 Linux 前转 LF | 上述 3 个示例 | 仓库工作区为 CRLF，先 `dos2unix`；两个 `.sh` 已按 `.gitattributes` 用 LF |
| 5 | 二选一启用调度 | `crontab.example` 或 `ams-backup.timer` | `sudo systemctl daemon-reload && sudo systemctl enable --now ams-backup.timer`，或 `crontab` 安装；**不要同时启用** |
| 6 | 配置备份失败告警 | 运维侧监控平台 | 仓库无告警通道（§6 / §8）；备份 / 异地复制失败需外部告警 |
| 7 | 每月执行恢复演练并留存结论 | `restore-drill.sh` | 先 `--dry-run` 核对命令，再实跑；验收标准见 §4.4；据实测回填 §4.2 的 RTO/RPO |
| 8 | 补齐卷级备份 | 运维侧 | 附件 / 配置 / 导出 / 邮件卷仍无方案，需与 DB 时间点对齐（§8 第 8 项） |

启用后请人工验证一次完整链路：`backup.sh` → `backup-offsite.sh`（远端可见）
→ `restore-drill.sh`（PASS），并把实测 RTO/RPO 回填 §4.2。
**未实机验证的点**：rclone / rsync / scp 在具体后端上的行为、`OFFSITE_KEEP`
的远端清理、systemd timer 的实际触发、演练临时 openGauss 实例的初始化与
`gsql -f` 导入，均需运维在目标环境验证后再作为运维承诺。

---

## 10. 相关文件

| 文件 | 作用 |
| --- | --- |
| `deploy/compose/docker-compose.yml` | 单机编排（本手册主体对象，**主代理维护**） |
| `deploy/compose/.env.example` | 本地开发 compose 变量模板（可入库）；实际 `.env` 不入库 |
| `deploy/config/ams.env.example` | 运行期配置模板（另一套文件） |
| `deploy/scripts/run-app.sh` | 一键启动整栈，含 `.env` 前置检测 |
| `deploy/scripts/build-linux-docker.sh` | 交叉编译 Linux 后端产物 |
| `deploy/scripts/migrate.sh` | 容器内迁移执行（`_ams_migrations` 逐文件台账） |
| `deploy/scripts/init-db.sh` | 宿主机侧手动迁移（调试工具，非 init 服务替代） |
| `deploy/scripts/backup.sh` / `restore.sh` | 逻辑备份 / 恢复 |
| `deploy/scripts/backup-offsite.sh` | 校验后异地副本（rclone / rsync / scp，默认未启用） |
| `deploy/scripts/restore-drill.sh` | 独立临时容器恢复演练（默认未启用） |
| `deploy/scripts/crontab.example` | cron 调度示例（默认未启用） |
| `deploy/systemd/ams-backup.service` / `ams-backup.timer` | 每日 02:30 systemd 调度示例（默认未启用） |
| `deploy/docker/Dockerfile.prebuilt` | 后端变更后的运行镜像构建入口 |
| `deploy/docker/Dockerfile.merge` | 仅前端变更的叠加镜像 |
| `deploy/README.md` | 容器化部署指南 |
| `docs/09-部署与发布指南.md` | 物理机发布包 / systemd / NSSM 参考 |

---

## 验证边界

本次任务**未运行** `docker`、未执行构建、未连接数据库、未实机验证 `gs_dump` / `gsql`
的 `-c` / `--clean --if-exists` 等参数在 openGauss 5.0 上的行为；
也未实机验证 `backup-offsite.sh` 的异地复制、`restore-drill.sh` 的临时实例
导入、`crontab.example` / `ams-backup.timer` 的实际触发；
仅完成了新增 `.sh` 脚本的 `bash -n` 静态语法检查与 LF 行尾检查。
所有 RTO/RPO 数值、备份周期与「建议」项均为规划值，
且上述自动化脚本**默认未启用**，需按 §9 启用后通过实机演练确认，
再作为运维承诺。
