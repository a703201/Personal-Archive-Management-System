# AMS · 变更日志

本文件记录 AMS 各版本的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **发布流程**：
> ```bash
> # 方式一：本地脚本（不依赖 CI runner）
> bash scripts/release.sh --version 0.2.0
>
> # 方式二：打 tag 触发 GitHub Actions
> git tag -a v0.2.0 -m "AMS 0.2.0"
> git push origin v0.2.0
> ```

---

## [0.2.0] — 2026-10-27

P0 需求全量落地（54 已实现 / 0 部分 / 0 未实现），并以单元测试套件全绿（214 通过 / 0 失败）收口。

### 新增

- **检索索引自动构建（FR-SRC-001）**：条目创建/更新与扩展字段保存成功后自动 `indexItem`；新增 `SearchRepo.listUnindexedItemIds` + `SearchService.reindexUnindexed`，并暴露运维端点 `POST /api/admin/search/reindex?limit=`（默认 500 / 上限 5000）用于存量回填。
- **盲索引等值检索（FR-SRC-005 / D4 决策落地）**：新增 `BlindIndexService`（由 KEK 派生全局盲索引密钥，按字段键选归一化规则 + HMAC-SM3）；写入侧落 `value_bidx`，查询侧 `GET /api/search?fkey=&fval=` 路由接通。部分掩码匹配经决策降级为「不实现」。
- **单元测试套件扩充**：`ams-api` 测试包补充至 21 个用例；全量套件 **214 用例通过 / 0 失败**。

### 修复

- **附件数维护（FR-SRC-003）**：新增 `ItemRepo.bumpAttachmentCount`（原子 `UPDATE ... + ?`），`AttachmentService` 上传落库成功后 +1；检索按附件数排序/展示恢复正确。
- **敏感字段掩码位数对齐（FR-SRC-006 / D2）**：`Masker.maskIdCard` 由「前 6 后 4」改为「前 4 后 2」，并接线到扩展字段展示路径（`GET /api/items/:id/fields` 无 `archive:read_sensitive` 权限时敏感字段默认走掩码）。
- **单元测试套件红态修复**：修掉 2 个长期预存编译错误（`api_test.cj` 误用本版本编译器不支持的 `===` 引用相等、以及 `AuthContext.accessLoader` 返回类型错误），并同步 `search_test.cj` 的掩码断言；修复前该包整包编译失败、21 个用例从未执行。

### 文档

- 新增 `docs/10-P0实现状态核对.md`：逐条以代码为准核对 54 条 P0（结论 54/0/0），记录接线审计（§7.11）、D2/D4 落地（§7.12）、测试套件红态发现与修复（§7.13）。
- `docs/08-SM4方案变更说明.md`：SM4-GCM → SM4-CBC+HMAC-SM3 论证（待产品签字，D3）。

### 已知限制

- 仅交付 Windows x86_64；Linux / ARM64 需在对应平台构建（架构文档 §7.2）。
- 前端（`web/`）尚未完全实现。
- 会话存储当前为内存实现，重启后需重新登录（生产需接 DB）。
- 真实端到端运行时验证（连 openGauss 跑盲索引 round-trip、GIN 分词命中、附件加解密、存量 `reindex` 回填）尚未执行。

---

## [0.1.0] — 2026-10-26

首个可运行版本。后端骨架 + 数据访问层 + HTTP 接口层 + 认证接口。

### 新增

**工具链**
- 仓颉 SDK 升级到 **1.2.0 STS**，stdx 升级到 **1.2.0.1**
- `scripts/install-sdk.sh` / `install-stdx.sh` / `install-driver.sh`：工具链安装
- `scripts/build.sh` / `test.sh`：cjc 逐包构建与测试（`cjpm` 在 Windows 上崩溃）
- `scripts/build-driver.sh` / `patch-driver.py`：opengauss-driver 编译与本地适配补丁
- `scripts/db.py`：openGauss 操作封装

**数据访问层（ams-data）**
- `Database` 句柄、连接池、错误映射（`AppError`）
- `UserRepo` / `RoleRepo` / `TagRepo` / `NotifyRepo` / `ConfigRepo`
- `RowData` / `RowSet` 行数据抽象（领域映射留在 ams-app，保持分层）
- 全部 SQL 参数化；标签按 `owner_id` 隔离；敏感配置脱敏
- 集成测试 7 个（真实连 openGauss，含安全约束验证）

**安全（ams-security）**
- 认证：PBKDF2-HMAC-SM3 口令哈希、访问令牌签发/校验、刷新令牌旋转与重放检测
- 授权：38 个权限点种子、`AccessContext`、own/any 作用域判定
- 审计：审计日志写入与查询

**HTTP 接口层（ams-api）**
- `ApiRequest` / `ApiResponse` / `Router`：统一请求响应与路由（含 `:param` 占位）
- 中间件链：请求 ID → 访问日志 → 鉴权 → 业务处理
- `ParamDistributor`：自研分发器，补上 stdx 内置分发器**不支持参数化路径**的缺口
- 统一响应格式：`{"code","message","data","requestId"}`
- 接口：登录 / 刷新 / 登出 / 全局登出 / 健康检查，以及用户、角色、权限、标签、通知、字典 22 个管理接口
- 单元测试 21 个

**应用层（ams-app）**
- `AuthService`：登录（含渐进延迟 + 失败锁定）、刷新、登出、全局登出

**领域核心（ams-core）**
- 档案条目、附件、检索：状态机、附件加密存储、搜索

**可执行程序**
- `ams-server.exe`：可运行的 HTTP 服务（29 条路由）
- `scripts/package.sh`：打包交付物（bin/config/scripts/docs + CHECKSUMS.sha256）
- `scripts/release.sh`：发布到 GitHub Release
- `.github/workflows/ci.yml` / `release.yml`：CI 与发布流水线

### 安全

- **SM4 方案**：因 stdx 的 SM4-GCM 不可用（1.0.5.1 与 1.2.0.1 均实测失败），
  改用 **SM4-CBC + HMAC-SM3 的 Encrypt-then-MAC** 组合。
  完整论证见 [docs/08-SM4方案变更说明](docs/08-SM4方案变更说明.md)
- **密钥分离修复**：密钥包裹原先用同一把 KEK 同时加密与认证，
  改为从 KEK 派生独立的加密子密钥与认证子密钥（`alg=2`），
  包裹结果自描述算法标识，旧数据仍可解开
- 口令、令牌、密钥材料一律不进日志与审计；数据库错误细节只进日志不进响应

### 已知限制

- 仅交付 Windows x86_64；Linux / ARM64 需在对应平台构建（架构文档 §7.2 的交叉编译路径）
- 前端（`web/`）尚未实现
- 会话存储当前为内存实现，重启后需重新登录（生产需接 DB）

[0.2.0]: https://github.com/a703201/Personal-Archive-Management-System/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/a703201/Personal-Archive-Management-System/releases/tag/v0.1.0
