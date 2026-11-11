# AMS 移动端（HarmonyOS NEXT · 纯 ArkTS）

面向个人与家庭的私密数字档案库 AMS 的鸿蒙客户端。**纯 ArkTS 实现，不含仓颉 / 原生 .so 依赖**（2026-11-10 决策移除 Cangjie 双栈）。

后端为仓颉 `ams-server`（HTTP API），Web 端为 Vue 3；三者共用同一套接口与文案口径。

---

## 当前功能

| 页面 | 能力 |
| --- | --- |
| 登录 | 图形验证码（SVG 经 `WebviewController.loadData()` 渲染）、账号口令登录、**服务器地址可手动配置并持久化**；连续失败触发风控时自动刷新挑战 |
| 首页 | `/api/overview` 概览（条目总数 / 分类分布 / 未读提醒 / 最近更新）、11 类分类入口、设置入口、下拉刷新；**未读提醒卡可点进通知中心** |
| 条目列表 | 按分类查询（覆盖**全部可访问主体**，含家庭授权条目）、新建入口、下拉刷新、错误重试、共享标记 |
| 条目详情 | 完整字段（签发机构 / 日期 / 到期 / 备注 / 状态 / 敏感度）、**编辑**、**删除**（两段式确认，软删进回收站）、**状态流转**（草稿→正常→已归档，可撤回）、**克隆**（成功后跳新条目） |
| 新建 / 编辑 | 标题、机构、日期、备注、敏感度、所属主体切换；编辑走乐观锁 `version`；新建直接落「正常」状态 |
| 搜索 | 关键词全文检索、**11 类分类筛选 chip**、**游标加载更多**、结果跳详情、状态标签、错误重试 |
| 通知中心 | 全部 / 仅未读筛选、单条标为已读、全部已读、重要标记、下拉刷新；已读后联动首页未读数 |
| 回收站 | `/api/items/recycle-bin` 列表、单条**恢复** |
| 设置 | 账号信息（`/api/me`）、**修改口令**（折叠区）、服务器地址修改、关于（唯一配置入口 `ets/config/About.ets`）、退出登录 |

跨页面数据刷新用 `AppStorage` 信号量 `ams_data_version` + `@Watch`（见 `common/store/DataRefresh.ets`）；写入成功后列表/首页/回收站自动重拉。

网络层 `common/api/ApiClient.ets` 统一处理：
- **长期登录**：`accessToken` 只有 30 分钟（后端 `accessTtlSeconds=1800`），401 时先用**一次性** `refreshToken` 调 `POST /api/auth/refresh` 换新令牌并立刻落盘，再自动重放原请求；刷新失败才清空登录态、回登录页。并发 401 共享同一个刷新 Promise，避免重复刷新触发后端重放检测（会吊销该用户全部会话）。
- **持久化**：`common/store/AuthStore.ets` 用 `preferences` 同步 API（`getPreferencesSync` / `getSync` / `putSync` / `flushSync`）落盘 token / refreshToken / 登录标记 / 服务器地址，`EntryAbility.onCreate` 启动时恢复到 `AppStorage`（运行时镜像）。杀进程重开不会掉登录态。
- **离线可读**：GET 成功时把响应写入 `AppStorage` 缓存（键由 `common/crypto/Fingerprint.ets` 的 FNV-1a 32 生成），网络失败时回退缓存；
- 统一 `{code,message,data}` 信封解包。

**全屏沉浸**：`EntryAbility` 调 `setWindowLayoutFullScreen(true)` 并把状态栏/导航栏设为透明（图标深色），读取 `TYPE_SYSTEM` 避让区的 px 高度存 `AppStorage`；`Index` 根容器用 `'XXpx'` 字符串做 `top/bottom` padding —— 背景铺满整屏，内容避开状态栏与底部手势区。用带单位字符串而非全局 `px2vp()`（后者 API 18 起已废弃）。

---

## 构建

```bash
bash mobile/build_hap.sh
```

脚本用 DevEco 自带的 JBR / node / hvigor，`--no-daemon` 避免污染环境。本机 DevEco 装在
`E:/Program Files/Huawei/DevEco Studio`（脚本里为 `E:`，若换机器需同步修改）。
产物：`mobile/entry/build/default/outputs/default/entry-default-signed.hap`。

**实测**：2026-11-11 `bash build_hap.sh` → `BUILD SUCCESSFUL`（EXIT=0）。

> 签名：`bundleName` 为 `com.ams.mobile`，`signing/` 下的调试证书是借用来的
> `com.Lumio.music`，正式发布前须在 DevEco → Project Structure → Signing Configs 重新生成。
> `signing/` 与 `local.properties` 均已在 `.gitignore` 中排除。

---

## 后端接口契约（已逐条核对 `packages/ams-api/src/routes/*.cj`）

| 用途 | 接口 | 易踩的坑 |
| --- | --- | --- |
| 列表 | `GET /api/items?category=&page=&size=` | `subjectId` **可选**，不传即返回全部可访问主体；旧版硬传 `subjects[0].id` 会漏数据 |
| 详情 | `GET /api/items/:id` | 返回 **`{"item":{...}}` 包装**，不是裸条目 |
| 创建 | `POST /api/items` | `subjectId` 必填，且必须是调用者可访问主体 |
| 更新 | `PUT /api/items/:id` | `version` **必填**（乐观锁），缺失直接 400 |
| 删除 | `DELETE /api/items/:id` | **必须带 JSON body** `{"version":n}`；后端 `body(req)` 解析空串会报「请求体不是合法的 JSON 对象」 |
| 恢复 | `POST /api/items/:id/restore` | 无需 body |
| 回收站 | `GET /api/items/recycle-bin` | 返回 `{items,total}` |
| 概览 | `GET /api/overview` | `recent[].id` 是**数字**，不是字符串 |
| 账号 | `GET /api/me` | `id` 是数字；邮箱/手机为掩码值 |
| 注销 | `POST /api/auth/logout` | 无需 body |
| 验证码 | `GET /api/auth/captcha?old=<旧 captchaId>` | 刷新时**必须带 `old`** 让后端作废旧挑战；响应只含 `captchaId/svg/expiresAt`，无答案 |
| 登录 | `POST /api/auth/login` | **`captchaId/captchaCode` 不是每次必填**：后端仅在该账号连续登录失败 ≥ 3 次（`AuthConfig.captchaTriggerFailures`）时才 `enforceCaptcha`，未触发时完全忽略这两个字段（FR-AUTH-011 零回归友好）。与 Web 端同范式 |
| 搜索 | `GET /api/search?keyword=&category=&cursor=&size=` | **参数名是 `keyword`**；`q` 只属于 `/api/search/suggest`，传 `q` 会让主搜索过滤完全失效（恒返回全部条目）。响应字段是 **`nextCursor`**（不是 `cursor`），配合 `hasMore` 翻页 |
| 状态 | `POST /api/items/:id/status` | body `{status, version}`；`arc_items.status` 权威口径为 **0 草稿 / 1 正常 / 2 已归档 / 3 已删除**（`docs/06`）。旧版移动端误用「有效/临期/已过期」，已订正 |
| 克隆 | `POST /api/items/:id/clone` | 返回 `{id, sourceId}`，新条目为草稿 |
| 通知 | `GET /api/notifications?unread=&page=&size=` | 行字段是 DB 列名（`is_read`、`created_at_ms`），`is_read` 可能是 `'t'`/`'f'`/布尔，需兼容判定 |
| 标记已读 | `POST /api/notifications/:id/read`、`/api/notifications/read-all` | 带 `{}` 请求体 |
| 修改口令 | `POST /api/me/password` | body `{oldPassword, newPassword}`（注意是 **POST**，不是 `PUT /api/me` 改资料） |

---

## 已知边界 / 待办

- 仅覆盖核心档案闭环；**附件上传/预览/水印、导入导出、标签、共享链接、模板、家庭组、系统运维**等仍只在 Web 端可用。
- 验证码 SVG 由 `Web` 组件 + `WebviewController.loadData()` 渲染（关闭 JS 与 DOM Storage）。三个踩坑：① `Web({src})` 的 `src` 只接受网页地址，不能直接塞 HTML 字符串；② **`loadData` 的 `encoding` 在本机 SDK 里是字符集（`"UTF-8"`），传 `"base64"` 不会解码，整段 base64 会被当纯文本显示**；③ `loadData` 的 data 含 `#` 会被当成内容结束符，而后端 SVG 颜色值含大量 `#`。最终做法：**SVG 单独 base64 塞进 `<img src="data:image/svg+xml;base64,...">`**，外层 HTML 不含任何 `#`，再 `loadData(html, 'text/html', 'UTF-8')`。另注：SDK `image.d.ts:464` 明确「Image 组件不支持加载 SVG 的 Base64 字符串」，所以不能用 `Image` 组件替代 Web。
- 离线缓存仍是 `AppStorage` 内存态，**进程重启后失效**（只有登录态与服务器地址做了 `preferences` 持久化）。
- 全屏沉浸下，`NavDestination` 子页面的系统标题栏若出现额外下沉（框架自身也避让安全区时），需按真机截图再微调间距。
- 真机 / 模拟器联调未做：需把服务器地址改为开发机局域网 IP。
- 未做深色模式、多语言（i18n）、无障碍字号与大字模式。
- HAP 构建已在本机验证通过，但**真机安装与端到端 API 联调仍需实测**。

---

## 目录

```
entry/src/main/ets/
├── entryability/EntryAbility.ets
├── pages/          Index / Login / Home / Items / ItemDetail / ItemEdit / Search / Settings / RecycleBin
├── common/
│   ├── api/ApiClient.ets        # 网络层与全部接口数据结构
│   ├── models/Models.ets        # 领域模型 + 11 类分类口径
│   ├── store/AuthStore.ets      # 登录态与服务器地址
│   ├── store/DataRefresh.ets    # 跨页刷新信号
│   ├── crypto/Fingerprint.ets   # 纯 ArkTS FNV-1a 32（离线缓存键）
│   ├── utils/Format.ets         # 状态/敏感度/时间格式化
│   ├── utils/Logger.ets         # 统一日志封装（hilog）
│   └── theme/Theme.ets          # 设计令牌（Apple 式克制）
└── config/About.ets             # 关于信息唯一配置入口
```

文案口径遵循项目统一约定（口令 / 密码 / 用户名 / 搜索 / 暂无 X / 保存 / 返回登录）；分类中文名与 `docs/06 §12.3`、Web 端 `useCatalog.ts` 一致。
