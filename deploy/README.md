# AMS 部署指南（容器化）

本目录提供 AMS 的容器化部署资料，与 `docs/09-部署与发布指南.md`（物理机发布包）互为补充。

```
deploy/
├── docker/
│   └── Dockerfile            # 多阶段镜像：builder(后端) + web(前端) + runtime
├── compose/
│   └── docker-compose.yml    # 单机编排：ams 应用 + openGauss 数据库
├── config/
│   └── ams.env.example       # 运行期环境变量模板（不含密钥）
├── scripts/                  # （预留）启停 / 健康检查脚本目录
├── systemd/                  # （预留）systemd 单元文件目录
└── windows/                  # （预留）Windows 服务封装目录
```

> 注：`scripts/`、`systemd/`、`windows/` 子目录当前为空，等待后续补充
> 物理机 systemd / Windows Service 封装；容器化路径已可用。

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
docker build -t ams:0.1.0 \
  --build-arg BASE_IMAGE=your-registry/cangjie:1.2.0-linux \
  -f deploy/docker/Dockerfile .
```

**B. SDK 直链下载**

```bash
docker build -t ams:0.1.0 \
  --build-arg CANGJIE_SDK_URL=https://.../cangjie-1.2.0-linux.tar.gz \
  --build-arg CANGJIE_STDX_URL=https://.../cangjie-stdx-linux.tar.gz \
  -f deploy/docker/Dockerfile .
```

> ⚠️ 官方 Linux SDK 直链可能需要自举（同 Windows 侧
> `scripts/ci/publish-toolchain.sh` 思路，做成 Release 资产）。

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

> 后续可抽成 `deploy/scripts/init-db.sh`（当前目录为空，待补）。

---

## 4. 启动

```bash
docker compose -f deploy/compose/docker-compose.yml up -d
# 访问 http://localhost:8080
# 健康检查：http://localhost:8080/api/health
```

`ams` 服务通过 `depends_on: condition: service_healthy` 等待数据库就绪；
自身也配置了容器健康检查（`/api/health`）。

---

## 5. 生产 Checklist

- [ ] `AMS_TOKEN_SECRET` 改为 ≥32 字节随机值
- [ ] `AMS_KEK` 改为随机值
- [ ] 配置 `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD` 受限角色
- [ ] 不要在 compose / 镜像里硬编码口令，改用 `env_file` 或 Docker secrets
- [ ] 反向代理（如需 HTTPS）置于容器前，终止 TLS 后转发 `:8080`
- [ ] 持久卷：`ams-db-data`（数据库）、`ams-config`（配置）已声明，确认备份策略
- [ ] 镜像来源可信（自举基础镜像建议打 digest 锁版本）

---

## 6. 与物理机发布包的关系

`scripts/package.sh` 产出 `ams-release-<ver>-linux-x86_64/`（含 `bin/`
`web/` `config/` `scripts/` `docs/` `LICENSE`）。容器镜像本质是「把发布包
塞进最小 Ubuntu 运行时 + 预置运行时 .so」。二者可二选一：

- **容器**：适合编排、弹性、隔离部署（本目录）。
- **物理机 / systemd**：适合裸金属或内网无容器环境（见 `docs/09` 与
  未来补充的 `deploy/systemd/`）。
