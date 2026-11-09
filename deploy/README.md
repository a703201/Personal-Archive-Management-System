# AMS 部署指南（容器化）

本目录提供 AMS 的容器化部署资料，与 `docs/09-部署与发布指南.md`（物理机发布包）互为补充。
**生产运维手册**（备份/恢复、升级回滚、监控、排障、已知生产缺口）见 [RUNBOOK.md](RUNBOOK.md)。

```
deploy/
├── RUNBOOK.md                # 生产运维手册（备份/恢复/升级/监控/缺口清单）
├── docker/
│   ├── Dockerfile            # 多阶段镜像：builder(后端) + web(前端) + runtime
│   ├── Dockerfile.cjbase     # 仓颉基础镜像（ubuntu22.04 + SDK1.2.0-beta.03 + stdx）
│   ├── Dockerfile.prebuilt   # 基于预编译产物构建运行镜像（含 web/dist，ams:1.2.1）
│   ├── Dockerfile.web        # 前端独立镜像（多阶段：node:20 构建 → nginx:1.27-alpine）
│   ├── Dockerfile.web.prebuilt # 前端独立镜像（秒级离线：把宿主 web/dist 烤入 nginx）
│   ├── Dockerfile.merge      # 把最新 web/dist 叠加进既有 ams:1.2.1（前端并入后端镜像）
│   └── nginx.conf            # 前端独立镜像的反代配置（/api → ams-server:8080 + SPA 回退）
├── compose/
│   ├── docker-compose.yml    # 单机编排：ams 应用 + openGauss 数据库（静态 IP 连库）
│   └── .env.example          # 本地开发 compose 变量模板（首次必复制；.env 不入库）
├── config/
│   ├── ams.env.example       # 运行期环境变量模板（不含密钥）
│   └── deployment.env.example # 部署配置（向导写入 deployment.env）模板
├── scripts/
│   ├── build-linux-docker.sh # 在仓颉工具链镜像内交叉编译 Linux 产物
│   ├── init-db.sh            # 宿主机侧手动跑迁移（整体跳过判断，调试用，勿代替 init 服务）
│   ├── migrate.sh            # 容器内迁移执行脚本（init 服务用，_ams_migrations 逐文件台账）
│   ├── run-app.sh            # 一键拉起统一栈（db + init + ams，含 .env 前置检测）
│   ├── backup.sh             # 逻辑备份（gs_dump + sha256 + AMS_BACKUP_KEEP 清理）
│   ├── restore.sh            # 从逻辑备份恢复（二次确认 + gsql 导入）
│   ├── backup-offsite.sh     # 异地副本（sha256 校验后 rclone/rsync/scp 复制，默认未启用）
│   ├── restore-drill.sh      # 恢复演练（独立临时容器，绝不碰生产数据，默认未启用）
│   ├── crontab.example       # cron 调度示例（备份/异地/演练，需改绝对路径，默认未启用）
│   ├── mail-spool.sh         # SMTP 投递暂存监听（镜像 CMD 后台拉起）
│   └── sms-spool.sh          # 短信网关投递监听（默认关闭，镜像 CMD 后台拉起）
├── systemd/
│   ├── ams.service           # systemd 单元「示例」（服务封装未落地）
│   ├── ams-backup.service    # 每日备份 + 异地复制 oneshot「示例」（默认未启用）
│   └── ams-backup.timer      # OnCalendar 每日 02:30 / Persistent=true「示例」（默认未启用）
└── windows/
    ├── start.cmd             # Windows 前台启动「示例」（服务封装未落地）
    └── README.md             # Windows 服务封装现状说明（NSSM/WinSW 未落地）
```

> `systemd/`、`windows/` 现已补上**示例文件**，但**服务封装尚未落地**：
> 未与发布包集成、未实机验证（见 `deploy/windows/README.md`）。
> 新增的 `backup-offsite.sh` / `restore-drill.sh` / `crontab.example` /
> `ams-backup.service` / `ams-backup.timer` 同样**只是脚本与示例，默认未启用**，
> 启用动作见 [RUNBOOK.md](RUNBOOK.md) §9「自动化启用清单」。
> 容器化路径已可用（见 §2–§4），生产运维见 [RUNBOOK.md](RUNBOOK.md)。

---

## 1. 架构约束（影响部署形态）

- **单进程、单端口**：`ams-server` 一个进程同时提供 `/api/*` 与前端 SPA
  （后端侧见 `packages/ams-api/src/server/static.cj`）。部署方只需启动
  `bin/ams-server`，**无需再装 Nginx 或另起静态服务器**。
- **运行时依赖必须随包分发**：仓颉运行时 `.so` 与 stdx 动态库 `.so`
  必须与 `ams-server` 同目录（或位于 `LD_LIBRARY_PATH`），漏发会报
  `error while loading shared libraries`。Dockerfile 已自动拷贝。
- **数据库**：openGauss（兼容 PostgreSQL 协议），默认端口 `15432`
  （源码 `main.cj` 硬编码默认值），账号 `gaussdb`、库名 `ams`。
- **受限运行时账号**：生产应通过 `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD`
  让应用以「业务表全 DML、审计表仅 SELECT/INSERT」的受限角色 `ams_app` 连接
  （见 `006_audit_restricted_role.sql` / `RUNBOOK.md` §1.3）。

---

## 2. 构建镜像

仓颉 SDK（Linux 版）需自行准备，二选一（详见 Dockerfile 顶部注释）：

**A. 自举基础镜像（推荐）**

```bash
docker build -t ams:1.2.1 \
  --build-arg BASE_IMAGE=your-registry/cangjie:1.2.0-linux \
  -f deploy/docker/Dockerfile .
```

**B. SDK 直链下载**

```bash
docker build -t ams:1.2.1 \
  --build-arg CANGJIE_SDK_URL=https://.../cangjie-1.2.0-linux.tar.gz \
  --build-arg CANGJIE_STDX_URL=https://.../cangjie-stdx-linux.tar.gz \
  -f deploy/docker/Dockerfile .
```

> ⚠️ 官方 Linux SDK 直链可能需要自举（同 Windows 侧
> `scripts/ci/publish-toolchain.sh` 思路，做成 Release 资产）。

### 2.1 前端独立镜像（可选 · nginx 托管）

若希望**前端与后端解耦**（分别扩缩、或后端在别处），可用纯前端镜像：

```bash
# 方式 A：容器内构建（需能拉取 node:20-bookworm-slim，约 1GB 基础层）
docker build -f deploy/docker/Dockerfile.web -t ams-web:local .

# 方式 B：秒级离线（直接烤入宿主已产出的 web/dist，不拉 Node、不联网）★
cd web && npm run build          # 先产出 web/dist
docker build -f deploy/docker/Dockerfile.web.prebuilt -t ams-web:local .

# 运行（默认 80，映射到宿主 8080）
docker run --rm -p 8080:80 ams-web:local
# 打开 http://localhost:8080
```

`deploy/docker/nginx.conf` 已配好：

- `location /api { proxy_pass http://ams-server:8080; }` —— 把接口反代到后端
  （前端容器与后端容器需同处 `ams-net` 用户网络，用容器名 `ams-server` 直连）；
- `location /` 做 SPA history 回退（`/archive`、`/overview` 等深链正常）；
- `/assets/` 给 `max-age=31536000, immutable`，`/index.html` 给 `no-cache`；
- 附 gzip 与 `nosniff` / `Referrer-Policy` / `X-Frame-Options` 安全响应头。

> ⚠️ 该镜像**仅托管 UI**，登录 / 注册 / 读写数据依赖后端 `ams-server`。
> 单容器形态（见 §4）不需要它；它与「合并镜像」是**两种互斥**的前端部署方式，
> 不要同时把 `ams-web`（8080）与 `ams-server`（8080）都跑在宿主 8080。

---

## 3. 首次初始化（建库 + 迁移）

> ⚠️ **前置：必须先准备 compose 变量文件**。`docker-compose.yml` 已把
> `AMS_DB_PASSWORD` / `AMS_TOKEN_SECRET` / `AMS_KEK` 改为 `${VAR:?...}`
> **必填变量**，未注入时 `docker compose` 会直接抛 `:?` 错误并拒绝启动。
> 首次部署先执行：
> ```bash
> cp deploy/compose/.env.example deploy/compose/.env
> $EDITOR deploy/compose/.env      # 生产换成随机凭据，AMS_ENV=production
> ```
> `.env` 已被 `.gitignore` 屏蔽，绝不提交；`run-app.sh` 在缺少它时会打印该指引并退出 1。
> 三个变量的本地/生产差别见 §5「凭据与 SEC-001」。

容器启动前，数据库必须已有 schema。迁移 SQL 在仓库 `db/` 目录（如
`019_*`、`006_audit_restricted_role.sql` 等）。**当前 compose 已自带 `init`
一次性服务自动跑迁移**，所以正常首次部署只需 `bash deploy/scripts/run-app.sh`
（见 §4），**无需**手工执行迁移。

手工方式（仅调试 / 分步部署）示例：

```bash
# 等 db 健康后，把迁移跑进容器内的 openGauss
docker compose -p ams -f deploy/compose/docker-compose.yml up -d db
# 用宿主机的 psql 或 scripts/db.py 连到 127.0.0.1:15432 执行迁移
python scripts/db.py exec db/000_init.sql
python scripts/db.py exec db/001_...   # 依次执行其余迁移
```

> ⚠️ **不要**把「`init-db.sh` 检测到 `sys_users` 即跳过」当成迁移模型：
> compose 的 `init` 服务跑的是 `migrate.sh`，它按**逐文件台账
> `_ams_migrations`** 登记每个已成功执行的迁移，新增迁移会在下次起栈
> 自动补跑（历史教训见 `migrate.sh` 头注释：旧的整体跳过逻辑曾漏掉
> 020/021 等增量迁移）。`deploy/scripts/init-db.sh` 是宿主机侧手动工具，
> 仍用「`sys_users` 存在即整体跳过」的短路判断，**不会补跑新增迁移**，
> 仅用于调试，不能替代 `init` 服务。

---

## 4. 启动（统一栈：单个分组）

AMS 采用**单一 compose 栈**，把数据库 / 迁移 / 应用三类容器归到同一个
项目（默认 `ams`）下。在容器管理界面（Portainer 等）里表现为**一个
`ams` 分组**，内含：

| 容器 | 角色 | 对应 ReturnGuard |
|---|---|---|
| `ams_opengauss` | openGauss 数据库（数据卷 `ams_ogdata`） | `rg_opengaus` |
| `ams_db_init`   | 一次性迁移任务（跑完即退出，`restart: "no"`） | `rg_realdb_init` |
| `ams-server`    | 应用服务（同时提供 `/api/*` + SPA） | `rg_app` |

> 这与 ReturnGuard 的 `returnguard` 分组（rg_opengaus / rg_realdb_init /
> rg_app）结构一致——不再是分散的两个平级独立容器。

### 4.1 推荐：一键拉起整个栈

```bash
# 前提：已复制 .env（见 §3），且已用 build-linux-docker.sh 产出 build/linux/ 与 web/dist/
bash deploy/scripts/run-app.sh
#   或显式带项目名：
#   docker compose -p ams -f deploy/compose/docker-compose.yml up -d
# 访问 http://localhost:8080   健康检查 http://localhost:8080/api/health
```

`run-app.sh` 会：检查 `deploy/compose/.env`（缺失则打印复制指引并退出 1）
→ 移除旧的独立容器（数据卷 `ams_ogdata` 保留）→ 清理旧 `ams-net`
→ `docker compose -p ams up -d` 拉起 db + init + ams → 轮询 `/api/health`
直到 200。`ams` 服务通过 `depends_on: init: service_completed_successfully`
等迁移跑完再起；`init` 通过 `depends_on: db: service_healthy` 等库就绪。

### 4.2 分步 / 调试

```bash
# 只起库（宿主 15432 可连）
docker compose -p ams -f deploy/compose/docker-compose.yml up -d db
# 手动触发迁移（宿主机侧，调试用；正常部署由 init 服务自动完成）
bash deploy/scripts/init-db.sh
# 再起应用
docker compose -p ams -f deploy/compose/docker-compose.yml up -d ams
# 看迁移任务日志（对应 rg_realdb_init）
docker compose -p ams -f deploy/compose/docker-compose.yml logs init
# 停止整个分组
docker compose -p ams -f deploy/compose/docker-compose.yml down
```

> ⚠️ **连库必须静态 IP**：`db` 在自定义网络 `ams-net`（`172.28.0.0/16`）上
> 固定为 `172.28.0.10`，`init` 与 `ams` 的 `AMS_DB_HOST=172.28.0.10` 必须
> 是 IP 字面量（见 §4.3 坑位①）。不要改回服务名 `db`。

### 4.3 部署陷阱（仓颉 / Git Bash 专属，务必知悉）

**① 仓颉运行时只认 IP 字面量，不解析服务名 / hosts**
Cangjie 的网络层在解析主机名时，**忽略 Docker 内置 DNS（127.0.0.11）**，
**也忽略 `/etc/hosts`**（实测 `--add-host` 仍失败），只接受 IP 字面量。
因此应用 / 迁移容器**不能用服务名连库**（compose 的 `db` 不行），必须
把 `AMS_DB_HOST` 指向 DB 在共享网络上的**静态 IP**。这是本栈采用「静态
IP 172.28.0.10」的硬性原因。

**② Git Bash / MSYS 会把 `-e AMS_WEB_DIR=/app/web` 翻成 Windows 路径**
在 Git Bash 里直接 `docker run -e AMS_WEB_DIR=/app/web` 时，MSYS 会把
`/app/web` 翻译成 `D:/.../PortableGit/app/web`，导致容器内静态托管根指向
不存在的路径、SPA 全部 404。解法：命令前加 `MSYS_NO_PATHCONV=1`。
（注：compose 文件里的 `AMS_WEB_DIR: /app/web` 不在命令行，不受此影响；
`run-app.sh` 走 compose 也不触发。）

**③ openGauss 的 MOT 引擎需要提权，否则无限重启**
MOT（内存优化表引擎）启动时调用 `mbind` 做 NUMA 绑核，需要
`CAP_SYS_NICE` / `SYS_RESOURCE` 等能力；容器默认能力集下会报
`mbind: Operation not permitted` → 恢复管理器初始化失败 → 服务器退出 →
`restart: unless-stopped` 触发无限重启（容器日志看不到明显 FATAL，真正的
错误只在 `pg_log/*.log` 里：`[MOT] mbind: Operation not permitted`）。
解法：给 `db` 服务加 `privileged: true`（compose 已加并注释）。仅在本地
开发 / 演示库这样用；生产应改关 MOT，或用 `--cap-add` 收紧到
`SYS_NICE,IPC_LOCK,SYS_RESOURCE` 而非整容器提权（见 `RUNBOOK.md` §8）。

**④ `Dockerfile.prebuilt` 的 `AMS_DB_HOST=db` 不能脱离 compose 单跑**
`Dockerfile.prebuilt` 里 `ENV AMS_DB_HOST=db` 只是占位默认值：
单独 `docker run ams:1.2.1` 时既没有名为 `db` 的主机可解析，仓颉运行时
又不解析服务名 / `/etc/hosts`（见坑位①），必然连不上库。compose 已给
`ams` 服务显式注入 `AMS_DB_HOST=172.28.0.10` 覆盖它；若确要单跑镜像，
必须 `-e AMS_DB_HOST=<DB 的 IP 字面量>` 并自行保证网络可达，
同时补齐三个必填凭据（见 §5）。

### 4.4 前端并入后端镜像（刷新 UI 不重编后端）

若你已有一个 `ams:1.2.1` 镜像（含后端二进制），只是想把它里面的前端换成
最新重做后的 UI，**无需重新编译仓颉后端**，用 `Dockerfile.merge` 叠加即可：

```bash
cd web && npm run build                       # 先产出 web/dist
docker build -f deploy/docker/Dockerfile.merge -t ams:1.2.1 .
# 重建并重启（compose 的 ams 服务默认 8080:8080，单容器同时提供 UI + /api）
docker compose -p ams -f deploy/compose/docker-compose.yml up -d --no-build ams
```

`Dockerfile.merge` 以既有 `ams:1.2.1` 为基底，仅 `COPY web/dist/ /app/web/`，
因此**不会引入后端回归**；旧 web 的孤儿哈希文件无害（浏览器只会请求新产物）。
**后端 / 依赖变更不能用它**，必须先经 `build-linux-docker.sh` 重编、
再用 `Dockerfile.prebuilt` 重建镜像（见 `RUNBOOK.md` §5）。

> 这与「§2.1 前端独立镜像」是两种互斥方案：要么单容器合并镜像（推荐，
> 一个进程一个端口），要么 nginx 前端容器 + 后端容器（多容器、需反代）。
> 全栈 `docker compose up` 默认走前者。

### 4.5 可选 S3 profile（Q2 预留，**默认不启用**）

Q2（附件存储最终用自建 MinIO / 华为云 OBS / 本地 FS）仍待运维·甲方确认。
本仓已按方案 A 落地**可插拔骨架**，默认仍是本地 FS：

```bash
# 默认起栈：只有 ams + ams_opengauss（+ 一次性 init），行为与改造前一致
docker compose -p ams -f deploy/compose/docker-compose.yml up -d

# 只预置对象存储拓扑时（网络 / 卷 / MinIO 容器），显式开 profile
docker compose -p ams -f deploy/compose/docker-compose.yml --profile s3 up -d
```

> ⚠️ **`--profile s3` 只起 MinIO 容器，不代表对象存储已可用**。
> 本批已补 HMAC-SHA256（RFC 4231 验证）与 **SigV4 签名计算**（AWS 官方
> GET Object 向量验证），但 `S3Transport`（HTTP 客户端）仍未接入。
> 选择非 `local` 平台会让应用**启动即失败关闭**（`StorageFailure`），
> 不会静默回落 FS、更不会明文写入。
>
> **平台选择接口**（`cfg:read` / `cfg:manage`，配置写 `deployment.env`，重启生效）：
> `GET /api/admin/storage/providers`（8 个可选平台：local / minio / huawei /
> aliyun / qiniu / tencent / aws / s3）、`GET /api/admin/storage/config`（凭据脱敏）、
> `PUT /api/admin/storage/config`。库内已有附件时，改变 provider / endpoint /
> bucket 会被 **Conflict 拒绝**（旧 `storage_key` 会在新后端失效）。
>
> 生产启用对象存储前还需补：真实 HTTP 客户端 → 桶策略（禁公共读）→
> 端到端上传下载验证。隔离区（FR-ATT-007）恒定本地 FS。完整配置位见
> `deploy/config/ams.env.example` 的 Q2 段与 `docs/README.md` §六。

---

## 5. 凭据与 SEC-001

compose 把三个凭据改为 `${VAR:?...}` 必填变量；后端另有 **SEC-001 门禁**：
`AMS_ENV=production` 时三项必须显式提供、且不得使用内置开发默认值，
否则进程直接拒绝启动。`AMS_ENV` 在 compose 里的默认值就是 `production`
（`AMS_ENV: "${AMS_ENV:-production}"`），**不设置即视为生产**。

| 变量 | 要求 | 生产生成方式 |
| --- | --- | --- |
| `AMS_DB_PASSWORD` | openGauss 口令，须与 `ams_ogdata` 卷初始化口令一致 | 由 DBA 保管，不使用仓库默认值 |
| `AMS_TOKEN_SECRET` | 令牌签名密钥，**≥ 32 字节随机值** | `openssl rand -base64 48` |
| `AMS_KEK` | 密钥加密密钥（包裹密钥 / 盲索引派生） | `openssl rand -hex 32` |

| | 本地开发 | 生产 |
| --- | --- | --- |
| 变量来源 | `cp deploy/compose/.env.example deploy/compose/.env`，模板为固定 dev 值 | `env_file` / Docker secrets 注入随机值；`.env` 绝不入库 |
| `AMS_ENV` | `dev`（模板显式覆盖 compose 默认值，跳过 SEC-001） | `production`（或留空走默认） |
| 三凭据 | 模板里的 dev 固定值，**仅本机可用** | 必须替换为随机值，SEC-001 会拒绝开发默认值 |
| TLS | 无 | 由前置反向代理终止（容器本身只 HTTP `:8080`） |

> ⚠️ 更换 `AMS_KEK` 会使既有加密数据无法解密；生产不要随意轮换，
> 当前仓库没有 KEK 轮换工具（见 `RUNBOOK.md` §8）。
> 完整要求见 [RUNBOOK.md](RUNBOOK.md) §1.1 与 §8。

---

## 6. 生产 Checklist

- [ ] 已执行 `cp deploy/compose/.env.example deploy/compose/.env` 并填入三个必填变量（§5）
- [ ] `AMS_TOKEN_SECRET` 改为 ≥32 字节随机值
- [ ] `AMS_KEK` 改为随机值
- [ ] `AMS_ENV=production`（或留空走默认），确认不会因开发默认值被 SEC-001 拒绝启动
- [ ] 配置 `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD` 受限角色 `ams_app`（见 §1）
- [ ] 不要在 compose / 镜像里硬编码口令，改用 `env_file` 或 Docker secrets；`.env` 不入库
- [ ] 反向代理置于容器前终止 TLS 后转发 `:8080`（容器本身只提供 HTTP）
- [ ] 限制 `15432` 端口暴露、收紧 `db` 的 `privileged: true`（见 [RUNBOOK.md](RUNBOOK.md) §8）
- [ ] 持久卷 `ams_ogdata`（external）、`ams-config`、`ams-data`、`ams-exports`、`ams-mail`、`ams-backups` 已声明；**确认备份策略**：用 `deploy/scripts/backup.sh` 定期导出并按 [RUNBOOK.md](RUNBOOK.md) §3 校验，恢复步骤与演练见 §4
- [ ] 配置异地后端（`RCLONE_REMOTE` 或 `OFFSITE_HOST` + `OFFSITE_PATH`）并启用 `deploy/scripts/backup-offsite.sh`（校验通过才复制、未配置即报错退出；默认未启用）
- [ ] 二选一启用调度：`deploy/scripts/crontab.example` 或 `deploy/systemd/ams-backup.service` + `ams-backup.timer`（`systemctl enable --now ams-backup.timer`）；改绝对路径、配 `/etc/ams/ams.env`、示例拷到 Linux 前先 `dos2unix`（[RUNBOOK.md](RUNBOOK.md) §9）
- [ ] 每月用 `deploy/scripts/restore-drill.sh --dry-run <备份.sql>` 核对命令后实跑恢复演练，按 [RUNBOOK.md](RUNBOOK.md) §4.4 验收标准留存 PASS/FAIL 结论
- [ ] 为备份 / 异地复制失败配置外部告警（仓库无告警通道，见 [RUNBOOK.md](RUNBOOK.md) §6 / §8）
- [ ] 镜像来源可信（自举基础镜像建议打 digest 锁版本），保留上一版镜像以便回滚（[RUNBOOK.md](RUNBOOK.md) §5）
- [ ] 对照 [RUNBOOK.md](RUNBOOK.md) §8「已知生产缺口清单」逐项评估（无 TLS、无告警通道、商密认证未进行等）

---

## 7. 与物理机发布包的关系

`scripts/package.sh` 产出 `ams-release-<ver>-linux-x86_64/`（含 `bin/`
`web/` `config/` `scripts/` `docs/` `LICENSE`）。容器镜像本质是「把发布包
塞进最小 Ubuntu 运行时 + 预置运行时 .so」。二者可二选一：

- **容器**：适合编排、弹性、隔离部署（本目录）。
- **物理机 / systemd**：适合裸金属或内网无容器环境（见 `docs/09`；
  `deploy/systemd/ams.service` 为示例 unit，`deploy/systemd/ams-backup.service` /
  `ams-backup.timer` 为备份调度示例（默认未启用），`deploy/windows/README.md`
  说明 Windows 服务封装尚未落地，均未实机验证）。

---

## 8. 首次部署初始化与部署配置

全新部署（库中无管理员）首次访问会自动进入 `/setup` 向导：

1. **数据库连接** —— 默认与项目同服务器，沿用 compose 的 `AMS_DB_*`；
   需要外部数据库时在向导里填连接 IP / 端口 / 库名 / 用户名 / 口令，可先「测试连接」。
2. **创建管理员** —— 账号名称、昵称、密码、邮箱或手机号；首个账号自动获得
   `owner` + `org_admin`，完成后向导永久关闭。
3. **邮件服务** —— 可选，配置 SMTP 供找回密码发送验证码；可跳过，之后在
   「系统运维 → 部署配置」补充。

配置写入持久卷 `/app/config/deployment.env`（`ams-config` 卷）。规则：

- 格式 `KEY=VALUE`，按**第一个 `=`** 切分（口令可含 `=`），值不可含换行；
- **文件里没有的键继续读环境变量**，因此升级已有部署行为不变；
- 数据库配置保存后**需重启 `ams-server` 才生效**（`docker compose -p ams restart ams`）；
- 邮件参数随每封 `.eml` 传递，下一封信即生效；投递循环由镜像 CMD 后台拉起，
  未启用 `MAIL_ENABLED=true` 时不产生任何网络请求。

管理接口（均需 `system:admin`）：

| 接口 | 作用 |
| --- | --- |
| `GET /api/admin/deployment` | 读取当前生效的数据库/邮件配置（口令脱敏） |
| `PUT /api/admin/deployment/database` | 保存数据库配置 |
| `DELETE /api/admin/deployment/database` | 清除文件覆盖，恢复环境变量默认 |
| `PUT /api/admin/deployment/mail` | 保存 SMTP 配置 |
| `POST /api/admin/deployment/test-db` | 测试数据库连接 |
| `POST /api/admin/deployment/test-mail` | 发送测试邮件 |

模板见 `deploy/config/deployment.env.example`。
初始化接口 `GET/POST /api/setup/*` 为公开接口，但完成后自动关闭。

> 历史演示/测试账号已清理；清理脚本 `scripts/cleanup-demo-data.sql` 与
> `scripts/cleanup-test-accounts.sql` 幂等，可重复执行。
