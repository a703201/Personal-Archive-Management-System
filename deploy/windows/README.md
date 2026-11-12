# AMS · Windows 部署样例（未落地）

本目录放的是 Windows 物理机部署的**示例文件**，**不是**现成可用的服务封装。
容器化部署仍是本仓库主路径，见 `deploy/README.md` 与 `deploy/RUNBOOK.md`。

## 现状（如实）

- `start.cmd`：前台启动脚本示例，演示从 `config\ams.env` 逐行加载 `KEY=VALUE`
  并启动 `bin\ams-server.exe`；**未**与 `scripts/package.sh` 的发布包集成，**未**实机验证。
- **Windows 服务封装尚未落地**：仓库没有 NSSM / WinSW 的安装脚本、XML 配置或
  service wrapper，也没有开机自启、崩溃重启、服务账户、日志轮转的现成方案。
- 发布包结构与运行时 DLL 齐备性要求见 `docs/09-部署与发布指南.md` §2。

## 参考做法（需自行实施，仓库未提供这些文件）

`docs/09` §4.1 给出的 NSSM 示例：

```powershell
nssm install AMS "E:\ams\bin\ams-server.exe"
nssm set AMS AppEnvironmentExtra AMS_TOKEN_SECRET=xxx AMS_DB_PASSWORD=yyy AMS_KEK=zzz
nssm set AMS AppDirectory E:\ams
nssm set AMS AppStdout E:\ams\logs\ams.out.log
nssm set AMS AppStderr E:\ams\logs\ams.err.log
nssm start AMS
```

或 WinSW：把 `winsw.exe` 与同名 `AMS.xml`（`<env>` 中写凭据）放到发布包目录，
再执行 `AMS.exe install` / `AMS.exe start`。

> 以上只是方向。**请勿**把密钥写进受版本控制的文件或示例 XML；
> 服务账户与环境变量文件应设为仅本机管理员可读。

## 凭据（SEC-001）

- 生产必填 `AMS_DB_PASSWORD` / `AMS_TOKEN_SECRET` / `AMS_KEK`，并置
  `AMS_ENV=production`（后端会拒绝内置开发默认值），见 `deploy/RUNBOOK.md` §1.1。
- `start.cmd` 目前只校验了 `AMS_TOKEN_SECRET` 一项，另两项请自行补齐校验。
- 本地开发可用 `AMS_ENV=dev`，但只限本机、禁止用于生产。

## 待办

- [ ] 与发布包集成（把 `start.cmd` 放进 `scripts/package.sh` 产物的 `scripts/`）
- [ ] 落地 NSSM / WinSW 服务封装（安装、卸载、日志、重启策略）
- [ ] 服务化后的健康检查与日志轮转
- [ ] 实机验证（Windows 运行时 DLL 齐备性，见 `docs/09` §2 / §6）
