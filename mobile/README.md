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
| 条目详情 | 完整字段、编辑、删除（两段式确认，软删进回收站）、状态流转、克隆；**更多入口**：历史版本 / 附件 / 标签 / 共享链接 |
| 新建 / 编辑 | 标题、机构、日期、备注、敏感度、所属主体切换；编辑走乐观锁 `version`；新建直接落「正常」状态 |
| 搜索 | 关键词全文检索、11 类分类筛选 chip、游标加载更多、**后端 highlight 分段高亮渲染（Text + 样式，不用 Web）** |
| 通知中心 | 全部 / 仅未读筛选、单条标为已读、全部已读、重要标记、下拉刷新；已读后联动首页未读数 |
| 回收站 | `/api/items/recycle-bin` 列表、单条恢复 |
| 设置 | 账号信息、修改口令、服务器地址修改、关于、退出登录；**外观**：深色模式 / 三语（zh-CN / en / fr）/ 大字模式；**功能入口**：主体 / 标签 / 共享链接 / 模板 / 系统信息 / 家庭组 / 导入导出 |
| **主体管理** | 列表、新建、编辑（乐观锁 `version`）、软删除（返回残留条目数）；`subjects.cj` |
| **标签中心** | 标签库（列表 / 统计 / 新建 / 删除）、条目标签附加与移除、附件标签批量增删、查看条目自定义字段；`management.cj` / `fielddefs.cj` |
| **共享链接** | 列表 / 创建（有效期、失败次数、可选密码）/ 撤销；显示新链接 URL 与令牌；`share.cj` |
| **条目模板** | 列表 / 选择主体与份数 / 套用生成条目；`itemtemplates.cj` |
| **历史版本** | 版本列表（快照摘要）/ 回滚到指定版本；`items.cj` |
| **系统信息** | 健康状态、初始化 / 数据库 / 邮件、品牌、服务端多语言声明；用公开只读端点，不越权；`auth/setup/branding/i18n` |
| **家庭组** | 家庭组列表、展开成员、**共享条目只读视图**（点开看详情）；`family.cj` |
| **附件** | 列表、**单次上传小文件**（文档选择器 → 原始字节体）、**预览**（光栅图 `data:image/...;base64` 渲染 + OCR 文本）；`attachments.cj` |
| **导入导出** | 导出任务创建 / 列表 / 进度 / 下载正文 / 取消；导入任务创建（CSV）/ 列表；`export.cj` / `import.cj` |

跨页面数据刷新用 `AppStorage` 信号量 `ams_data_version` + `@Watch`（见 `common/store/DataRefresh.ets`）；写入成功后列表/首页/回收站自动重拉。

网络层 `common/api/ApiClient.ets` 统一处理：
- **长期登录**：`accessToken` 只有 30 分钟，401 时先用**一次性** `refreshToken` 调 `POST /api/auth/refresh` 换新令牌并立刻落盘，再自动重放原请求；刷新失败才清空登录态、回登录页。并发 401 共享同一个刷新 Promise。
- **持久化**：`common/store/AuthStore.ets`（登录态 / 服务器地址）、`common/store/Settings.ets`（深色 / 三语 / 大字）、`common/store/CacheStore.ets`（离线缓存）都用 `preferences` 同步 API 落盘 + `AppStorage` 运行时镜像；杀进程重开不掉。
- **离线可读**：GET 成功时写 `CacheStore`（preferences 持久化），网络失败时回退缓存；缓存键由 `common/crypto/Fingerprint.ets` 的 FNV-1a 32 生成。**离线缓存已落盘，进程重启后仍可读**。
- 统一 `{code,message,data}` 信封解包；另有原始字节上传 / 无信封下载的专用通道。
- **外观**：`common/theme/Theme.ets` 的 `C` / `F` 是共享可变令牌，`applyTheme()` 就地改写；`ams_theme_rev` 信号量触发全应用重渲染。`common/theme/I18n.ets` 提供三语文案，分类 / 状态口径与 `web/src/composables/useCatalog.ts` 一致。

**全屏沉浸**：`EntryAbility` 调 `setWindowLayoutFullScreen(true)` 并把状态栏/导航栏设为透明（图标深色），读取 `TYPE_SYSTEM` 避让区的 px 高度存 `AppStorage`；`Index` 根容器用 `'XXpx'` 字符串做 `top/bottom` padding —— 背景铺满整屏，内容避开状态栏与底部手势区。用带单位字符串而非全局 `px2vp()`（后者 API 18 起已废弃）。

---

## 构建

```bash
bash mobile/build_hap.sh
```

脚本用 DevEco 自带的 JBR / node / hvigor，`--no-daemon` 避免污染环境。本机 DevEco 装在
`E:/Program Files/Huawei/DevEco Studio`（脚本里为 `E:`，若换机器需同步修改）。
产物：`mobile/entry/build/default/outputs/default/entry-default-signed.hap`。

**实测**：2026-11-12 补完功能后多次 `bash build_hap.sh` → `BUILD SUCCESSFUL`（EXIT=0、**零 WARN / 零 ERROR**）；
最终签名 HAP `entry-default-signed.hap` = **1,178,654 字节（约 1.12 MB）**。

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
| 登录 | `POST /api/auth/login` | **`captchaId/captchaCode` 不是每次必填**：仅连续失败 ≥ 3 次才强制 |
| 搜索 | `GET /api/search?keyword=&category=&cursor=&size=` | 参数名是 **`keyword`**（`q` 只属于 `/api/search/suggest`）；响应 `nextCursor` 配合 `hasMore` |
| 搜索高亮 | 同上 | 每条含 `highlight:{"title":[{text,hit}],"issuer":[...]}`，`hit:true` 为命中片段；用 Text 分段渲染，勿 v-html / Web |
| 状态 | `POST /api/items/:id/status` | body `{status, version}`；状态 **0 草稿 / 1 正常 / 2 已归档 / 3 已删除** |
| 克隆 | `POST /api/items/:id/clone` | 返回 `{id, sourceId}`，新条目为草稿 |
| 通知 | `GET /api/notifications?unread=&page=&size=` | 行字段是 DB 列名（`is_read`、`created_at_ms`），`is_read` 可能是 `'t'`/`'f'`/布尔 |
| 标记已读 | `POST /api/notifications/:id/read`、`/api/notifications/read-all` | 带 `{}` 请求体 |
| 修改口令 | `POST /api/me/password` | body `{oldPassword, newPassword}`；是 **POST** 而非 `PUT /api/me` |
| 主体列表/新建 | `GET /api/subjects`、`POST /api/subjects` | 列表 `{subjects,total}`；新建 body `{name,alias?,relation?,summary?}` → `{id}` |
| 主体编辑 | `PUT /api/subjects/:id` | **`version` 必填**（乐观锁）；未传 `name` 时沿用原值 |
| 主体删除 | `DELETE /api/subjects/:id` | 返回 `{deleted,orphanItems}`，可提示回收站残留；**无需 body** |
| 标签库 | `GET /api/tags?tree=1` | **务必带 `tree=1`**：结构化 `{id,name,color,usageCount,parentId,depth,...}`；不带时返回 DB 列名（`usage_count` 等）不好解析 |
| 标签统计 | `GET /api/tags/stats` | `{total,used,unused,totalUsage,lastUsedAt}` |
| 标签增删 | `POST /api/tags`、`DELETE /api/tags/:id` | 新建 `{name,color?,category?,parentId?}` → `{id}`；删除软删 |
| 条目标签 | `POST /api/items/:id/tags` / `DELETE /api/items/:id/tags/:tagId` | 附加 body **`{tagId}` 为数字**（标签 id 是数字字符串，需 parseInt）；移除走路径参数 |
| 附件标签 | `POST /api/attachments/batch/tag` | body `{ids:[number],tagIds:[number],mode:"add"\|"remove"}` → `{changed,...}` |
| 自定义字段 | `GET /api/items/:id/fields` | 返回 `{itemId,category,fields:[{fieldKey,fieldName,value,...}]}`，敏感字段默认掩码 |
| 共享链接列表 | `GET /api/share-links?page=&size=` | `{total,items:[{id,token,itemId,revoked,expired,viewCount,...}]}` |
| 共享链接创建 | `POST /api/share-links` | body `{itemId,expiresInHours?,maxFails?,password?}`；`itemId` 为**数字**；返回 `{url:"/share/<token>",token,expiresAt}` |
| 共享链接撤销 | `DELETE /api/share-links/:id` | → `{revoked:true}`，无需 body |
| 模板列表 | `GET /api/item-templates` | `{items:[{id,name,category,title,status,sensitivity,expiresOffsetDays,...}]}` |
| 模板套用 | `POST /api/item-templates/:id/apply` | body `{subjectId:number,count:number}` → `{created,ids}`；`subjectId` 必须是**数字**且有写权限 |
| 历史版本 | `GET /api/items/:id/versions` | `{versions:[{id,version,snapshot,changedBy,changedAt}]}`；`snapshot` 是 **JSON 字符串**，需自行解析 |
| 版本回滚 | `POST /api/items/:id/versions/:vid/restore` | → `{restored,fromVersion}`；回滚本身也递增 version |
| 系统健康 | `GET /api/health` | **公开**，返回 `{status:"ok"}` |
| 系统信息 | `GET /api/setup/status`、`GET /api/branding`、`GET /api/i18n/locales` | 均为**公开只读**；`setup.status` 含 `database`/`mail` 子对象 |
| 系统看板（不用） | `GET /api/admin/health`（system.cj） | 需 **`system:admin`** 高权限，普通用户 403；移动端改用上面的公开端点，不越权 |
| 家庭组/成员 | `GET /api/family/groups`、`/api/family/groups/:id/members` | 只读、无需特殊权限；成员 `{userId,nickname,username,role,joinedAt}` |
| 共享条目 | `GET /api/family/shared-items?page=&size=`、`/api/family/shared-items/:id` | 列表 `{total,page,size,items}`；**详情返回裸条目，不是 `{item}` 包装** |
| 附件列表 | `GET /api/attachments?itemId=N` | `{attachments:[{id,title,fileSize,fileExt,mimeType,ocrText,...}]}`；`id` 是**数字** |
| 附件下载 | `GET /api/attachments/:id/download` | 返回 **`{id,size,base64}`**，正文是 base64 字符串，不是裸字节；图片可用 `data:image/<subType>;base64,...` 交给 `Image` 渲染（SVG 除外） |
| 附件单次上传 | `POST /api/attachments?fileName=&title=&category=&itemId=&subjectId=` | **元数据全在 query，正文是文件原始字节**（`Content-Type: application/octet-stream`），不是 JSON；后端仅允许 **jpg/png/pdf、≤50MB**；挂了 `itemId` 会按条目反查归属主体，`subjectId` 可留空 |
| 附件分片上传 | `/api/attachments/upload/sessions/*` | 会话 / 分片 / 合并契约复杂，移动端**暂未实现**，只做单次上传 |
| 导出任务创建 | `POST /api/export/tasks` | body `{scope:"item"\|"category"\|"full",format:"csv"\|"json",category?,keyword?,...}` → `{taskNo,status,...}` |
| 任务列表/详情 | `GET /api/export/tasks?type=&page=&size=`、`GET /api/export/tasks/:no` | **`type` 留空返回全部任务**（导入与导出共用 `imp_export_tasks` 一张表）；状态 0 待处理 / 1 运行中 / 2 成功 / 3 失败 / 4 已取消 / 5 已过期 |
| 导出下载 | `GET /api/export/tasks/:no/download` | **直接返回 CSV/JSON 正文，没有 `{code,message,data}` 信封**；不能用通用 `request()` 解包，必须单独取原始字符串 |
| 导出取消 | `POST /api/export/tasks/:no/cancel` | → 幂等取消 |
| 导入任务创建 | `POST /api/import/tasks` | JSON body `{csv:"...",subjectId?}`；CSV 表头固定 `subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark`，`#` 开头行忽略 |
| 导入任务列表 | `GET /api/import/tasks?page=&size=` | 与导出共用任务表，也可用 `GET /api/export/tasks` 一并查看 |

---

## 已知边界 / 待办

- **标签「查看某条目已挂的标签」**：后端现有端点只有全局标签库、附加 / 移除，以及自定义字段值，**没有「列出单个条目已挂标签」的只读端点**。标签页因此提供全局标签库 + 统计 + 条目/附件标签编辑 + 自定义字段查看，**未用假数据伪造条目已挂标签**。
- **附件**：只做单次上传（分片会话未做）；受后端约束仅支持 jpg/png/pdf、≤50MB；光栅图（jpg/png）可在线预览，**pdf 及非图片格式只展示元信息 / OCR 文本，不伪造预览**。
- **系统运维页**使用无需高权限的公开只读端点（`/api/health` 等）；`system.cj` / `admin.cj` 的 `/api/admin/health`、`/api/admin/jobs` 等看板需 `system:admin` / `cfg:read`，普通用户会 403，**移动端不越权调用**。
- **i18n 三语**：所有页面（登录 / 首页 / 列表 / 详情 / 编辑 / 搜索 / 通知 / 回收站 / 主体 / 标签 / 共享链接 / 模板 / 系统信息 / 家庭组 / 附件 / 导入导出 / 历史版本 / 关于 / 设置）的 UI 文案已全量用 `t()` 覆盖 zh-CN / en / fr，缺失键在 `common/theme/I18n.ets` 三语字典中同步补齐（键集严格一致，EN/FR 均为真实翻译）；分类名与状态名通过 `categoryNameI18n()` / `statusNameI18n()` / `taskStatusName()` 与 `useCatalog.ts` 口径一致。后端返回的 error/message 字符串按规则原样透传、不包 `t()`；语种切换仅影响 UI 文案，不动后端数据。
- **深色 / 大字模式**：`applyTheme()` 就地改写共享令牌 + `ams_theme_rev` 触发重渲染；真机换肤效果与 `NavDestination` 安全区间距仍待实测微调。
- 验证码 SVG 由 `Web` 组件 + `WebviewController.loadData()` 渲染（关闭 JS 与 DOM Storage）。三个踩坑：① `Web({src})` 的 `src` 只接受网页地址；② `loadData` 的 `encoding` 是字符集（`"UTF-8"`），传 `"base64"` 不会解码；③ data 含 `#` 会被当内容结束符。最终做法：SVG base64 塞进 `<img src="data:image/svg+xml;base64,...">` 再 `loadData(html, 'text/html', 'UTF-8')`。
- 真机 / 模拟器联调未做：需把服务器地址改为开发机局域网 IP；文档选择器 / 原始字节上传 / 图片预览均需真机验证。
- HAP 构建已在本机验证通过，但**真机安装与端到端 API 联调仍需实测**。

---

## 目录

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   # 启动时恢复登录态/设置/缓存并刷新主题
├── pages/
│   ├── Index / Login / Home / Items / ItemDetail / ItemEdit / Search / Settings
│   ├── RecycleBin / Notifications          # 既有页面
│   ├── SubjectsPage / TagsPage / ShareLinksPage / TemplatesPage / ItemVersionsPage
│   ├── SystemPage / FamilyPage / AttachmentsPage / TasksPage   # 新增页面
├── common/
│   ├── api/ApiClient.ets          # 网络层与全部接口数据结构 / 方法（含字节上传与无信封下载）
│   ├── models/Models.ets          # 领域模型 + 11 类分类口径 + 搜索高亮片段
│   ├── store/AuthStore.ets        # 登录态与服务器地址（preferences）
│   ├── store/CacheStore.ets       # GET 离线缓存（preferences 持久化）
│   ├── store/Settings.ets         # 深色 / 三语 / 大字（preferences + 主题信号量）
│   ├── store/DataRefresh.ets      # 跨页刷新信号
│   ├── crypto/Fingerprint.ets     # 纯 ArkTS FNV-1a 32（离线缓存键）
│   ├── utils/Format.ets           # 状态 / 敏感度 / 时间格式化
│   ├── utils/Logger.ets           # 统一日志封装（hilog）
│   ├── theme/Theme.ets            # 设计令牌 + applyTheme（深色 / 大字）
│   └── theme/I18n.ets             # 三语文案 + 分类/状态名口径
└── config/About.ets               # 关于信息唯一配置入口
```

文案口径遵循项目统一约定（口令 / 密码 / 用户名 / 搜索 / 暂无 X / 保存 / 返回登录）；分类中文名与 `docs/06 §12.3`、Web 端 `useCatalog.ts` 一致。

---

## 硬性技术约束（ArkTS，违反会编译失败）

- `build()` / `@Builder` 体**首条语句不能是 const/let**，要改行内调用。
- `@Component` / `@CustomDialog` 上的**普通 get 访问器会被丢弃**，一律用普通方法；方法名不能用 `create`（保留字）。
- 类型标注**禁 `any` / `unknown`**；`catch (err)` 不标注可以，但形参标注不行。
- 禁裸 `console.*`，统一用 `common/utils/Logger.ets`。
- `CustomDialogController` / `DialogAlignment` / `NavPathStack` / `NavDestination` 是全局环境声明，不要从 `@kit.ArkUI` import；`@kit.*` 聚合 Kit 只有具名导出，禁默认导入。
- 组件里所有 `setTimeout` / `setInterval` 必须存句柄并在 `aboutToDisappear` 清理。
- `preferences.get()` 等可能抛异常的调用要包 try/catch；调用可能抛异常的函数（如 `http.request` / `JSON.parse`）要有 `catch` 分支。
- `getContext()` 已废弃，改用 `this.getUIContext().getHostContext()`。
- 不在静态方法用 `this`；不用对象字面量类型注解。
