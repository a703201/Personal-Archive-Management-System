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

## [未发布]

### 新增
- 待补充

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

[未发布]: https://github.com/a703201/Personal-Archive-Management-System/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/a703201/Personal-Archive-Management-System/releases/tag/v0.1.0
