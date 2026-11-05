# AMS 部署指南（容器化）

本目录提供 AMS 的容器化部署资料，与 `docs/09-部署与发布指南.md`（物理机发布包）互为补充。

```
deploy/
├── docker/
│   ├── Dockerfile            # 多阶段镜像：builder(后端) + web(前端) + runtime
│   ├── Dockerfile.cjbase     # 仓颉基础镜像（ubuntu22.04 + SDK1.2.0-beta.03 + stdx）
│   └── Dockerfile.prebuilt   # 基于预编译产物构建运行镜像（含 web/dist，ams:1.0.0）
│   ├── Dockerfile.web        # 前端独立镜像（多阶段：node:20 构建 → nginx:1.27-alpine）
│   ├── Dockerfile.web.prebuilt # 前端独立镜像（秒级离线：把宿主 web/dist 烤入 nginx）
│   ├── Dockerfile.merge      # 把最新 web/dist 叠加进既有 ams:1.0.0（前端并入后端镜像）
│   └── nginx.conf            # 前端独立镜像的反代配置（/api → ams-server:8080 + SPA 回退）
├── compose/
│   └── docker-compose.yml    # 单机编排：ams 应用 + openGauss 数据库（静态 IP 连库）
├── config/
│   └── ams.env.example       # 运行期环境变量模板（不含密钥）
├── scripts/
│   ├── build-linux-docker.sh # 在仓颉工具链镜像内交叉编译 Linux 产物
│   ├── init-db.sh            # 宿主机侧手动跑迁移（幂等，默认连 ams_opengauss）
│   ├── migrate.sh            # 容器内迁移执行脚本（init 服务用，对应 rg_realdb_init）
│   └── run-app.sh            # 一键拉起统一栈（db + init + ams，归到 ams 分组）
├── systemd/                  # （预留）systemd 单元文件目录
└── windows/                  # （预留）Windows 服务封装目录
```

> 注：`systemd/`、`windows/` 子目录当前为空，等待后续补充物理机
> systemd / Windows Service 封装；容器化路径已可用（见 §2–§4）。

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
  让应用以「业务表全 DML、审计表仅 SELECT/INSERT」的受限角色连接
  （见 `006_audit_restricted_role.sql`）。

---

## 2. 构建镜像

仓颉 SDK（Linux 版）需自行准备，二选一（详见 Dockerfile 顶部注释）：

**A. 自举基础镜像（推荐）**

```bash
docker build -t ams:1.0.0 \
  --build-arg BASE_IMAGE=your-registry/cangjie:1.2.0-linux \
  -f deploy/docker/Dockerfile .
```

**B. SDK 直链下载**

```bash
docker build -t ams:1.0.0 \
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

容器启动前，数据库必须已有 schema。迁移 SQL 在仓库 `db/` 目录（如
`019_*`、`006_audit_restricted_role.sql` 等），通过 `python scripts/db.py`
执行。一次性初始化示例：

```bash
# 等 db 健康后，把迁移跑进容器内的 openGauss
docker compose -f deploy/compose/docker-compose.yml up -d db
# 用宿主机的 psql 或 scripts/db.py 连到 127.0.0.1:15432 执行迁移
python scripts/db.py exec db/000_init.sql
python scripts/db.py exec db/001_...   # 依次执行其余迁移
```

> 后续可改用 `deploy/scripts/init-db.sh`（已就绪，幂等：检测到 `sys_users`
> 已存在即跳过）一次性跑完迁移：
> ```bash
> docker compose -f deploy/compose/docker-compose.yml up -d db
> bash deploy/scripts/init-db.sh
> ```

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
# 前提：已用 build-linux-docker.sh 产出 build/linux/ 与 web/dist/
bash deploy/scripts/run-app.sh
#   或显式带项目名：
#   docker compose -p ams -f deploy/compose/docker-compose.yml up -d
# 访问 http://localhost:8080   健康检查 http://localhost:8080/api/health
```

`run-app.sh` 会：移除旧的独立容器（数据卷 `ams_ogdata` 保留）→ 清理旧
`ams-net` → `docker compose -p ams up -d` 拉起 db + init + ams → 轮询
`/api/health` 直到 200。`ams` 服务通过 `depends_on: init:
service_completed_successfully` 等迁移跑完再起；`init` 通过
`depends_on: db: service_healthy` 等库就绪。

### 4.2 分步 / 调试

```bash
# 只起库（宿主 15432 可连）
docker compose -p ams -f deploy/compose/docker-compose.yml up -d db
# 手动触发迁移（宿主机侧，幂等）
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
`SYS_NICE,IPC_LOCK,SYS_RESOURCE` 而非整容器提权。

### 4.4 前端并入后端镜像（刷新 UI 不重编后端）

若你已有一个 `ams:1.0.0` 镜像（含后端二进制），只是想把它里面的前端换成
最新重做后的 UI，**无需重新编译仓颉后端**，用 `Dockerfile.merge` 叠加即可：

```bash
cd web && npm run build                       # 先产出 web/dist
docker build -f deploy/docker/Dockerfile.merge -t ams:1.0.0 .
# 重建并重启（compose 的 ams 服务默认 8080:8080，单容器同时提供 UI + /api）
docker compose -p ams -f deploy/compose/docker-compose.yml up -d --no-build ams
```

`Dockerfile.merge` 以既有 `ams:1.0.0` 为基底，仅 `COPY web/dist/ /app/web/`，
因此**不会引入后端回归**；旧 web 的孤儿哈希文件无害（浏览器只会请求新产物）。

> 这与「§2.1 前端独立镜像」是两种互斥方案：要么单容器合并镜像（推荐，
> 一个进程一个端口），要么 nginx 前端容器 + 后端容器（多容器、需反代）。
> 全栈 `docker compose up` 默认走前者。

---

## 5. 生产 Checklist

- [ ] `AMS_TOKEN_SECRET` 改为 ≥32 字节随机值
- [ ] `AMS_KEK` 改为随机值
- [ ] 配置 `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD` 受限角色
- [ ] 不要在 compose / 镜像里硬编码口令，改用 `env_file` 或 Docker secrets
- [ ] 反向代理（如需 HTTPS）置于容器前，终止 TLS 后转发 `:8080`
- [ ] 持久卷：`ams_ogdata`（数据库，external，演示数据不丢）、`ams-config`（配置）、`ams-data`（附件）、`ams-exports`（导出）已声明，确认备份策略
- [ ] 镜像来源可信（自举基础镜像建议打 digest 锁版本）

---

## 6. 与物理机发布包的关系

`scripts/package.sh` 产出 `ams-release-<ver>-linux-x86_64/`（含 `bin/`
`web/` `config/` `scripts/` `docs/` `LICENSE`）。容器镜像本质是「把发布包
塞进最小 Ubuntu 运行时 + 预置运行时 .so」。二者可二选一：

- **容器**：适合编排、弹性、隔离部署（本目录）。
- **物理机 / systemd**：适合裸金属或内网无容器环境（见 `docs/09` 与
  未来补充的 `deploy/systemd/`）。

---

## 7. 首次部署初始化与部署配置

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
