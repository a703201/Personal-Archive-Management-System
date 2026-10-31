# AMS · 个人档案管理系统

> Personal Archive Management System —— 面向个人与家庭的私密数字档案管理平台。
> 后端 **仓颉（Cangjie）**，前端 **Vue 3 + TypeScript**，数据底座 **openGauss**，密码学底座 **国密 SM3 / SM4**。

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Backend](https://img.shields.io/badge/backend-Cangjie-1f6feb)](./packages)
[![Frontend](https://img.shields.io/badge/frontend-Vue%203%20%2B%20TS-42b883)](./web)
[![Database](https://img.shields.io/badge/database-openGauss-orange)](./db/migrations)
[![Tests](https://img.shields.io/badge/tests-272%20passed-brightgreen)](./scripts/test.sh)

---

## 目录

- [这是什么](#这是什么)
- [当前状态](#当前状态)
- [功能一览](#功能一览)
- [技术栈与架构](#技术栈与架构)
- [安全设计要点](#安全设计要点)
- [快速开始](#快速开始)
- [常用脚本](#常用脚本)
- [目录结构](#目录结构)
- [文档](#文档)
- [已知限制](#已知限制)
- [许可证](#许可证)

---

## 这是什么

AMS 把一个人的**证件、学历、职业、资质、资产、健康、家庭关系、影像附件**等档案集中收拢，解决三个具体问题：

1. **散** —— 证件在相册、扫描件在网盘、证书在邮箱、体检报告在某个 App 里。AMS 按 **11 类分类模板 + 内置字段**统一归档，支持全文检索、标签、版本追溯。
2. **险** —— 云笔记类工具默认把明文放在别人服务器上。AMS 对敏感字段做**字段级 SM4 加密**、证件号走**盲索引**（可等值查询但服务端不可逆推）、附件逐块加密、预览叠加**动态水印**，并保证**密钥不经服务端明文落库**。
3. **难共享** —— 给家人看一张房产证，不该等于把整个档案库开放。AMS 提供**条目级共享链接**（可选密码 + 失败上限 + 有效期）与**家庭组协作**（已落地 · FR-ACL-010 · 方案 B，见 [docs/12](./docs/12-家庭成员邀请.md)（设计章节）/ 取舍见同文档（方案评估章节）），而不是"要么全给、要么不给"。

设计取向是 **本地优先、最小暴露、失败关闭**：宁可让某个功能拒绝服务，也不降级到不安全状态。

---

## 当前状态

需求按 P0 / P1 / P2 三批推进，判定口径是「领域模型 + 数据层 + HTTP 接口 + 权限校验齐全，可端到端使用」。

| 批次 | 规模 | 已实现 | 降级交付 | 未开始 | 台账 |
| --- | --- | --- | --- | --- | --- |
| **P0/P1/P2** 需求落地 | 111 | **110（99%）** | 5（附件水印 / 缩略图 / OCR / 短信 / 图形验证码，均已降级交付） | 0 | [docs/10](./docs/10-实现状态核对.md) |

工程面实测数据（本机验证，非估算）：

| 指标 | 数值 |
| --- | --- |
| 后端源码 | 115 个 `.cj`，约 3.76 万行（含测试） |
| 前端源码 | 29 个 `.vue` / `.ts`，约 1.24 万行 |
| 数据库迁移 | 19 个 SQL 文件 |
| HTTP 路由 | 152 条（启动日志 `server.ready` 打印） |
| 单元测试 | **272 passed / 0 failed** |

> 门禁：`bash scripts/build.sh` → 0 error、`npm run build` → 0 error、`bash scripts/test.sh` → 0 fail。
> 三者未同时通过不算完成。

---

## 功能一览

### 档案核心

- **11 类分类模板**（个人基本信息 / 证件信息 / 教育经历 / 职业经历 / 资质证书 / 联系方式 / 家庭关系 / 健康信息 / 资产信息 / 影像附件 / 自定义），每类预置字段定义（如证件类的证件号、签发机关、有效期）
- 条目 CRUD、状态流转（草稿 → 正常 → 已归档）、**乐观锁**、软删除与回收站
- **条目模板**（骨架 + 字段默认值 + 有效期偏移），支持 `{n}` 序号占位批量套用
- 标签（含层级与环路检测）、批量编辑、条目克隆

### 检索

- 关键字检索 + 12 种筛选维度（分类 / 状态 / 签发日期 / 失效日期 / 标签 / 来源 / 创建时间区间 …）
- **盲索引**：证件号、手机号等敏感字段可等值查询，但服务端不持有明文
- 保存视图、搜索历史、游标分页

### 附件

- 逐块加密存储、版本管理（新版本复用 DEK）、版本元数据对比
- **ZIP 批量导入**（自研 ZIP 读取器：store + deflate、CRC32 校验、GBK/UTF-8 文件名双解码、路径穿越与解压炸弹防护）
- 批量下载（自研 ZIP 写入器）/ 打标签 / 删除
- 预览**动态水印**（访问者 + 服务端时间 + 追踪号，落审计）

### 导入导出

- CSV / ZIP 两阶段导入：**预检不落库** → 用户确认 → 异步执行，带进度、错误报告、取消
- 导入去重（同主体 + 同标题）
- 同步导出 CSV/JSON；异步导出任务（断点续做、崩溃恢复、配额限流）
- **可携带导出包**（manifest + 分段 SHA-256 + HMAC-SM3 签名），支持验签回导；签名针对**原始字节**，篡改一个空格都过不了

### 身份与权限

- 口令 **PBKDF2-HMAC-SM3** 迭代派生；会话管理（设备列表 / 踢出）
- **TOTP 双因子**（自写 SHA-1/Base32/TOTP，启动跑 RFC 6238 附录 B 自检）
- 三级 RBAC（角色 → 权限点 → 数据级别上限）+ 主体级 / 条目级临时授权
- **权限预览**（按角色统计可见条目数与分类分布，不返回任何条目内容）
- 自助找回口令（验证码 → 一次性令牌 → 改密并吊销全部会话）

### 共享与协作

- **条目级共享链接**：不可预测 token（密钥 HMAC 派生）、可选访问密码、失败次数上限（超限即单向失效）、有效期；公开页只输出展示字段，高敏条目连签发机关都不给
- **家庭组协作（FR-ACL-010）**：建组 → 生成一次性邀请码（8 位 / 40 bit 熵 / 默认 15 分钟 / 1 次）→ 家人输码入组 → 按「整个主体 / 某分类 / 单条条目」三级授权，**默认只读**。成员角色与全局 RBAC 完全隔离，入组不产生任何系统角色；移除成员或解散组会级联撤销全部授权。设计见 [docs/12](./docs/12-家庭成员邀请.md)（设计章节），取舍见同文档（方案评估章节）

### 运维与合规

- **全链路审计哈希链**（每条记录含前序哈希，可校验链完整性）
- 审计自审计（谁看了审计本身也留痕）、留存策略、导出报告
- 数据级别 L1–L4 分级、敏感字段清单、导出四层管控
- 多语言框架（zh-CN / en）、免打扰与通知偏好、登录页品牌定制

---

## 技术栈与架构

| 层 | 选型 | 说明 |
| --- | --- | --- |
| 后端语言 | **仓颉 Cangjie**（SDK 1.0.5） | 静态编译、原生二进制；子包粒度手写构建脚本（`cjpm` 在本机 Windows 触发堆损坏，故本机构建走 `scripts/build.sh`，CI 用 `cjpm`） |
| 密码学扩展 | **stdx 1.0.5.1** | 提供 SM3 / SM4；`bash scripts/verify-stdx.sh` 可一键复现 14 项国标向量校验 |
| 数据库 | **openGauss** | 通过自编译的 `tpc` 驱动接入（`tools/vendor/opengauss-driver`） |
| 前端 | **Vue 3.5 + TypeScript + Vite 6** | 零 UI 框架依赖，手写设计系统（深浅色、四档响应式断点、Apple 质感动效） |
| 状态管理 | 组合式 API + `AppStorage` 式信号 | 不引入 Pinia，规模未到需要 |
| 测试 | 仓颉 `std.unittest` | 272 个用例，按包分层 |

### 分层依赖（严格单向，`scripts/build.sh` 按拓扑序编译）

```
ams-kernel   ← 错误 / 日志 / 时间 / ID / 指标 / 工具
    ↑
ams-crypto   ← 加密提供者接口 + SM3/SM4 实现 + 密钥管理
    ↑
ams-storage  ← 文件存储抽象（本地 / 分块）
    ↑
ams-core     ← 领域模型：条目 / 分类目录 / 状态机 / 检索 / 附件
    ↑
ams-data     ← 仓储层：openGauss 驱动封装 + 各表 Repo
    ↑
ams-security ← 认证 / 授权 / 审计链 / 限流 / TOTP
    ↑
ams-app      ← 应用服务：编排领域与仓储
    ↑
ams-api      ← HTTP 路由 / 中间件 / 响应信封
    ↑
ams-server   ← 入口：装配依赖、启动
```

约束：**`ams.app` 不得 import `ams.api`**（应用层不感知 HTTP），编译期由目录分层与构建顺序保证。

---

## 安全设计要点

### 国密落地情况（实测，不吹不掩）

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| SM3 摘要 / HMAC-SM3 | ✅ 可用 | 与国标标准向量**逐字节一致**（`SM3("abc")` = `66c7f0f4…8f4ba8e0`） |
| SM4 加密 | ✅ CBC / CTR | 密文与国标测试向量一致 |
| SM4-**GCM** | ❌ 不可用 | stdx 实测报 `create tag error`（OpenSSL 本身支持），故改用 **EtM 组合：CBC 加密 + HMAC-SM3 认证** |
| SM2 非对称 | ❌ 未落地 | SDK 无实现；导出包签名改用 **HMAC-SM3**（共享密钥），非公钥签名 |

这三条不是"以后再说"，是已在 [docs/08](./docs/08-SM4方案变更说明.md) 与 [docs/03 §4.0](./docs/03-安全设计专章.md) 留有实测记录的既定方案。

### 三条铁律

1. **失败关闭（Fail-closed）** —— 安全组件异常时拒绝服务，绝不降级。例：密钥不可用 → 拒绝写入敏感字段，**不**退化成明文存储；共享链接缺加密提供者 → 创建失败，**不**发一个可预测 token。
2. **默认拒绝（Default Deny）** —— 先判"是否禁止"，再判"是否允许"。
3. **最小必要（Least Privilege）** —— 只采集、只授权达成目的所需的最小数据与范围。

### 几个横切实现

- **敏感字段不明文落库**：字段级 SM4 加密 + 盲索引（HMAC-SM3 派生）支撑等值查询
- **定时无关比较**：所有摘要比较走 `constantTimeEquals`，不按字节提前返回
- **统一错误语义**：越权 / 不存在常合并为同一响应，避免把"资源存在"变成探测信号
- **审计哈希链**：每条审计记录带前序哈希，`GET /api/audit/verify-chain` 可自证未被篡改

---

## 快速开始

### 环境要求

| 依赖 | 版本 / 说明 |
| --- | --- |
| 仓颉 SDK | 1.0.5，`CANGJIE_HOME` 指向安装目录（或放 `tools/cangjie/`） |
| stdx | 1.0.5.1，`bash scripts/install-stdx.sh` 安装，`bash scripts/verify-stdx.sh` 校验 |
| openGauss | 一个可连实例（本地开发常用容器，默认端口 `15432`） |
| Node.js | ≥ 20（前端 Vite 6 / vue-tsc） |
| 平台 | 本机已验证 Windows + Git Bash；CI 覆盖 Linux |

### 1. 装载环境

```bash
source scripts/envsetup.sh          # 设置 CANGJIE_HOME / CANGJIE_STDX / PATH
bash   scripts/install-stdx.sh      # 首次：安装 stdx
bash   scripts/verify-stdx.sh       # 验证 14 项国标向量
```

### 2. 初始化数据库

```bash
# 逐个执行迁移（001 ~ 019，顺序不可打乱；均幂等，可重复执行）
for f in db/migrations/*.sql; do python scripts/db.py exec "$f"; done

# 核对表是否齐全
python scripts/db.py tables
```

`scripts/db.py` 通过 `docker exec` 调用容器内 `gsql`，因此需要一个名为 `ams_opengauss` 的运行中容器；
若使用外部数据库，直接用 `gsql -f` 或任何 PG 兼容客户端执行同样文件即可。

### 3. 构建后端

```bash
bash scripts/build.sh               # 首次会自动编译 opengauss 驱动，约 2~4 分钟
```

关键环境变量（完整清单见 [docs/09 §4.3](./docs/09-部署与发布指南.md)）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `AMS_HTTP_HOST` / `AMS_HTTP_PORT` | `127.0.0.1` / `8080` | 监听地址与端口（前端与接口共用） |
| `AMS_WEB_DIR` | `web` | 前端静态目录；生产包内即为 `web/` |
| `AMS_TOKEN_SECRET` | 本地开发默认值 | 令牌签名密钥，**生产必填**，≥ 32 字节 |
| `AMS_EXPORT_SIGN_KEY` | 回落 `AMS_TOKEN_SECRET` | 导出包签名密钥 |
| `AMS_DB_HOST` / `AMS_DB_NAME` / `AMS_DB_USER` / `AMS_DB_PASSWORD` | `127.0.0.1` / `ams` / `gaussdb` / 开发默认 | 数据库连接 |
| `AMS_DB_APP_USER` / `AMS_DB_APP_PASSWORD` | 空 | 指定后以**受限角色**连接（业务表 DML、审计表仅 SELECT/INSERT） |
| `AMS_LOG_LEVEL` | `info` | 日志级别 |

启动成功日志形如：

```json
{"action":"server.ready","routes":"152","startedAt":"…","webDir":"web"}
```

### 4. 生产模式：一个进程、一个端口 ★

**部署只有一步** —— `ams-server` 同时提供 `/api/*` 与前端 SPA：

```bash
cd web && npm run build && cd ..       # 产出 web/dist
./build/ams-server.exe                 # 打开 http://127.0.0.1:8080/ 就是完整应用
```

不需要 Nginx，不需要另起静态服务器，也不存在跨域配置。
服务端按前缀分流（实现见 `packages/ams-api/src/server/static.cj`）：

| 请求 | 处理 |
| --- | --- |
| `/api/...` | 后端接口。未匹配的接口返回 **JSON 404**，不会回落到 HTML |
| `/assets/...` | 前端资源，长缓存（`immutable`） |
| `/`、`/archive` 等无扩展名路径 | 回落 `index.html`，交给前端路由 |
| `/x.js` 之类带扩展名但文件不存在 | 真正的 404（否则缺失 JS 会被 HTML 掩盖成语法错误） |

发布包由 `bash scripts/package.sh` 生成，目录形如
`bin/` + `web/` + `config/` + `scripts/`，解压后 `scripts/start.cmd`（或 `start.sh`）
一条命令启动，`scripts/healthcheck.*` 会同时校验接口与前端页面。

### 5. 开发模式：前后端分别启动

开发期才需要两个进程（热更新）：

```bash
# 终端 1：后端
./build/ams-server.exe                # 127.0.0.1:8080

# 终端 2：前端
cd web && npm install && npm run dev  # http://127.0.0.1:5173
```

Vite dev server 把 `/api` 代理到 `8080`（见 `web/vite.config.ts`），
所以前端代码里永远只写同源 `/api`，不需要区分环境。

### 6. 首次使用

1. 打开 `http://127.0.0.1:5173`（开发）或 `http://127.0.0.1:8080`（生产）→ 注册账号
2. 进入「档案」页，系统会自动为你创建「本人」主体
3. 新建档案 → 选分类 → 填字段 → 上传附件
4. 需要给家人看单条档案：详情面板底部「共享链接」→ 创建（可设密码与有效期）
5. 需要让家人长期看到一批档案：「家庭协作」→ 建组 → 生成邀请 → 对方输码入组 → 逐级授权

> 新注册账号默认**没有角色**，需要管理员在「用户管理」中分配（`owner` 角色包含 29 项个人权限）。
> 这是刻意的：默认拒绝。

### 7. 演示数据（可选）

本地库里保留了一份可直接演示的数据集，无需重新造数据：

| 项 | 内容 |
| --- | --- |
| 演示账号 | `tpl_probe_01`（已授 `owner` + `org_admin`，可覆盖普通用户与管理员两侧界面） |
| 档案条目 | 4 条：`身份证-1/2/3`（分类 2 证件信息，模板批量套用产出）、`体检报告`（分类 8 健康信息，敏感度 **3 高敏**） |
| 共享链接 | 若干条，其中 1 条已被失败次数上限**单向撤销**、1 条挂在敏感度为 3 的条目上 —— 正好用来演示「超限失效」与「高敏条目的公开页不放签发机关」 |

> 共享链接有效期按设计是短的（默认 7 天、上限 365 天），放过期后公开页统一返回 404（不区分过期/撤销/不存在）。
> 演示前若链接已过期，在条目详情面板的「共享」区重新创建一条即可，不需要清库。

---

## 常用脚本

| 脚本 | 作用 |
| --- | --- |
| `scripts/envsetup.sh` | 装载仓颉环境变量（`source` 使用） |
| `scripts/build.sh` | 子包粒度增量构建；`--clean` 全量重建；可指定顶层包如 `bash scripts/build.sh ams-core` |
| `scripts/test.sh` | 全量单元测试；可指定包如 `bash scripts/test.sh ams-api`；`--verbose` 看编译输出 |
| `scripts/build-driver.sh` | 编译 openGauss 仓颉驱动（`build.sh` 缺产物时自动触发） |
| `scripts/verify-stdx.sh` | 国密能力 14 项向量校验 |
| `scripts/db.py` | 数据库辅助：`exec <sql文件>` / `sql -s "<SQL>"` / `tables` / `count <表>` |
| `scripts/gen-gbk-table.py` | 生成 GBK 码表（ZIP 中文文件名解码用） |
| `scripts/verify-audit-chain.py` | 审计哈希链外部校验 |
| `scripts/ci/verify-family.py` | 家庭协作端到端验收（90 项断言：邀请闭环 + 失效语义 + 可见性 + 主体级授权与列表下推 + 条目级授权隔离 + 同端口静态托管）。自带启停服务，`AMS_VERIFY_PORT` 可换端口 |
| `scripts/release.sh` | 打包发布产物 |
| `scripts/package.sh` | 生成交付包（含前端构建 → `web/` 落包） |
| `scripts/ci/*` | CI 用：工具链准备、发布包可运行性校验 |

---

## 目录结构

```
Archive_manager/
├── packages/                 # 仓颉后端，11 个顶层包（分层见上文）
│   ├── ams-kernel/           # 错误 / 日志 / 时间 / ID / 指标 / 工具
│   ├── ams-crypto/           # 加密提供者 + SM3/SM4 + 密钥管理
│   ├── ams-storage/          # 文件存储抽象
│   ├── ams-core/             # 领域模型（条目 / 分类 / 状态机 / 检索 / 附件 / 模板）
│   ├── ams-data/             # openGauss 驱动封装 + 各表 Repo
│   ├── ams-security/         # 认证 / 授权 / 审计链 / 限流 / TOTP
│   ├── ams-app/              # 应用服务编排
│   ├── ams-api/              # HTTP 路由 / 中间件
│   ├── ams-server/           # 入口装配
│   └── ams-native/           # C++ 侧（预留，当前为空）
├── web/                      # Vue 3 前端（src/views 页面、src/components 组件、src/composables 复用逻辑；dist/ 由 npm run build 产出并被后端直接托管）
├── db/migrations/            # 19 个 SQL 迁移（001 ~ 019）
├── docs/                     # 15 份设计/台账文档（另含 docs/README.md 索引）
├── scripts/                  # 构建、测试、部署、验收脚本
├── deploy/                   # systemd / docker / windows 部署模板
├── tools/vendor/             # opengauss-driver（自编译依赖）
├── .github/workflows/        # ci.yml / release.yml
├── CHANGELOG.md
├── LICENSE
└── README.md
```

> 构建产物（`build/`）、运行期数据（`data-attachments/` 等）与本地缓存（`.tmp/`、`.cache/`）不入库。

---

## 文档

| 编号 | 文档 | 回答什么问题 |
| --- | --- | --- |
| — | [docs/README.md](./docs/README.md) | 文档集总导航与关键设计决策 Top 12 |
| 01 | [产品需求文档](./docs/01-PRD-产品需求文档.md) | 做什么？给谁做？做到什么程度算完成？ |
| 02 | [架构设计说明](./docs/02-架构设计说明.md) | 系统怎么搭？语言怎么分工？多架构怎么交付？ |
| 03 | [安全设计专章](./docs/03-安全设计专章.md) | 威胁是什么？怎么防？国密怎么落？审计怎么查？ |
| 04 | [开发规范](./docs/04-开发规范.md) | 代码怎么写？怎么提交？测试覆盖到什么程度？ |
| 05 | [开发排期与里程碑](./docs/05-开发排期与里程碑.md) | 分几期做？每期交付什么？风险在哪？ |
| 06 | [数据模型设计](./docs/06-数据模型设计.md) | 表怎么建？字段怎么定？分类模板与字典怎么管？ |
| 07 | [视觉与交互设计规范](./docs/07-视觉与交互设计规范.md) | 界面长什么样？动效怎么动？深浅色如何切换？ |
| 08 | [SM4 方案变更说明](./docs/08-SM4方案变更说明.md) | 为什么不用 GCM？EtM 怎么构造？密钥如何分离？ |
| 09 | [部署与发布指南](./docs/09-部署与发布指南.md) | 怎么打包？怎么部署？环境变量有哪些？ |
| 10 | [实现状态核对（P0/P1/P2）](./docs/10-实现状态核对.md) | 各优先级需求落地情况与证据（P0 54 / P1 34 / P2 23） |
| 11 | [前端技术栈选型分析](./docs/11-前端技术栈选型分析.md) | 为什么是 Vue 3？备选方案为何被否？ |
| 12 | [家庭成员邀请（设计 + 方案评估）](./docs/12-家庭成员邀请.md) | 家庭协作安全设计（10 原则 / 14 威胁 / API 草案）与授权粒度·审批流·分批取舍（含推荐结论） |
| 13 | [信创与国家密码标准参考](./docs/13-信创与国家密码标准参考.md) | 国密 GM/T·GB/T 对齐、已落地/未实现能力、信创适配现状 |
| 14 | [对外 API 规范（OpenAPI）](./docs/14-对外API规范-OpenAPI.yaml) | 156 个接口的 OpenAPI 3.1 基线规范（schema 待补全） |
| 15 | [架构演进路线（方案候选）](./docs/15-架构演进路线-方案候选.md) | 提炼通用框架 / SaaS·微服务化的 A/B/C 候选方案（待拍板） |

变更记录见 [CHANGELOG.md](./CHANGELOG.md)。

> **部署与运维**：物理机发布包见 `docs/09`；容器化（`Dockerfile` + `docker-compose` + `deploy/README.md`）与 Linux 构建链路（`scripts/build-linux.sh` 等）已就绪，详见 `deploy/` 目录。

---

## 已知限制

诚实列出，避免误用：

| 限制 | 原因 | 影响 |
| --- | --- | --- |
| **SM2 未实现** | SDK 无非对称国密实现 | 导出包签名用 HMAC-SM3（对称共享密钥），不是公钥签名，无法做到"验签方不持有签名密钥" |
| **SM4-GCM 不可用**，改用 CBC + HMAC-SM3 | stdx 实测 `create tag error` | 已是 EtM（先加密后认证）的正确构造，但非 AEAD，随机数管理需更小心 |
| **附件水印无法烧进像素** | SDK 无图像 / PDF 渲染库 | 只在预览层叠加，无法阻止截图或另存原图 |
| **缩略图、全文 OCR 未实现** | 同上（无图像编解码 / OCR 引擎） | 大图预览耗流量；扫描件不可检索 |
| **短信通知未接入** | 无短信网关 | 仅站内信 + 邮件 |
| **C++ 侧（ams-native）为空** | 当前性能不构成瓶颈 | 纯仓颉实现；C++ 通道留作后续优化 |
| **本机构建不走 `cjpm`** | `cjpm 1.0.5` 在本机 Windows 触发堆损坏（`0xC0000374`） | 本地用 `scripts/build.sh`，CI 仍用 `cjpm`；两条路径都需保持通过 |
| **家庭协作只读** | docs/12 §1.3 非目标：本期不做写协作 | 家庭成员可查看被授权条目，不能编辑 / 导出 / 再分享；无邀请审批流（组内有邀请权的人即可直接拉人） |
| **P2 已全部落地（23/23）** | 见 [docs/10（P2）](./docs/10-实现状态核对.md) | 23/23 已实现或降级交付；缩略图 / OCR / 短信 / 图形验证码 4 项能力边界项均已降级交付（详见 docs/10 §4（P2））；FR-IMP-005（导入模板管理）已按方案 C（全量字段定义域）落地（详见 docs/10 §6（P2）） |

---

## 参与开发

1. 读 [docs/04-开发规范](./docs/04-开发规范.md)（命名、注释、错误处理、提交规范）
2. 改动前先跑一次三件套，确认基线是绿的：
   ```bash
   bash scripts/build.sh && bash scripts/test.sh && (cd web && npm run build)
   ```
3. 提交前必须三件套仍然全绿；新增能力需配单元测试
4. 分支：`main` 为稳定线，`develop` 为集成分支，功能分支从 `develop` 切出

---

## 许可证

本项目采用 **Apache License 2.0**，全文见 [LICENSE](./LICENSE)。

```
Copyright 2026 何宇翔 (a703201)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```

选择 Apache-2.0 而非 MIT 的原因：它显式授予**专利许可**（第 3 条）并要求保留归属声明，对可能涉及密码学与工程实现的代码更稳妥；同时它允许商业使用与闭源衍生，不强制开源下游。
