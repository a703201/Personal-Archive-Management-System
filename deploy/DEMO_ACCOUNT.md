# AMS 演示（测试）账号

> 本文件记录 AMS 部署用于演示 / 冒烟测试的账号凭据。
> 该账号仅用于本地与演示环境，**生产环境务必删除或改密**。

## 账号

| 项 | 值 |
|---|---|
| 用户名 | `tpl_probe_01` |
| 口令 | `aqlE67mDdzp3ZspA` |
| uid | `374002040935940096` |
| 角色 | `owner` (800001) + `org_admin` (800004) |
| 状态 | 正常启用 |
| 演示数据 | 4 条档案条目 + 5 条共享链接（含 1 条已撤销、1 条高敏） |

## 登录方式

- 登录接口：`POST /api/auth/login`
- 请求体：`{"username": "tpl_probe_01", "password": "aqlE67mDdzp3ZspA"}`
- 成功后返回 `token`，后续请求在 `Authorization: Bearer <token>` 携带。

## 口令算法（与后端一致）

- 格式：`$sm3-pbkdf2$v1$<iterations>$<salt_b64>$<dk_b64>`
- 派生：`DK = PBKDF2-HMAC-SM3(password, salt, iterations=600000, dkLen=32)`
- 本账号口令于 2026-10-30 由运维脚本按上述算法重置，哈希已直接写回 `sys_users.password_hash`。

## 安全提示

- 该账号拥有 `owner` + `org_admin` 权限，可管理所有主体与条目、ACL。
- 演示结束后请通过 `UPDATE sys_users SET password_hash=NULL ...` 或改密接口处理，避免凭据泄露。
