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

## [未发布] — P1 收口 + P2 启动

P1 需求逐条落地并在 `127.0.0.1:8080` 实跑验证：**34 条中 33 条实现、1 条降级交付、0 条未做**（详见 `docs/12-P1实现状态核对.md`）。
P2（23 条）累计 **23 条实现 / 0 条评估中（FR-IMP-005 已按方案 C 落地）**，台账见 `docs/13-P2实现状态核对.md`。

### 新增（家庭成员邀请 · FR-ACL-010 · 方案 B）

按 `docs/15` 的推荐结论完整落地：**主体 + 条目两级授权**（分类降级为「同主体内按分类收窄」）、**不做**邀请审批流、**3 批**推进。

- **迁移 `019_family_collaboration.sql`**：4 张新表 `fam_groups`（组）、`fam_members`（成员，含 `my_role` / `removed_at` / `removed_by`）、`fam_invites`（邀请，只落 code/token 摘要）、`fam_grants`（授权 → 组 的**侧表**）。种子权限 `family:manage` / `family:invite` 授予 `owner` 与 `curator`（规则：能建/改自己主体的人才能建组；`user` 角色在本系统不存在，曾误写导致除 `owner` 外谁都建不了组，详见下方「修复」）。
  > **为什么加侧表而不是给 `acl_grants` 加一列 `group_id`**：openGauss **不支持** `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`（实测 `ERROR: syntax error at or near "NOT EXISTS"`）。项目约定「每个迁移必须可反复执行」（`scripts/db.py exec` 与 CI 都依赖这一点），该 ALTER 无法写成幂等语句。用侧表既保住幂等，也不让核心 ACL 表承担可选能力的新列。理由写进了迁移文件头。
- **`ams.core.family`（纯逻辑，零 IO）**：`InviteCode`（32 字符表 `23456789A-HJ-NP-Z`、8 位 = 40 bit 熵、掩码取低 5 bit 而非取模以避免偏置、`normalize` 去空白/连字符/下划线并转大写、`isWellFormed` **在查库前**先拒乱输）、`InviteState`（Usable/Revoked/Expired/Exhausted/TooManyFails，判定顺序 **撤销 > 失败超限 > 过期 > 用尽**）、`InviteLimits`（默认 15 分钟 / 1 次 / 5 次失败；上限 1440 分钟 / 10 次）、`InviteSnapshot.stateAt()`（三个入口共用同一判定，避免「列表显示有效但接受时报无效」）、`FamilyRole`（未知角色**降级为 Member**；Manager 不能移除 Manager/Owner，否则被提升的人可以把管理层踢空再独吞）、`GrantScope`、`PermSubset`。
- **`ams.data.repo` 四个 Repo**：`FamGroupRepo` / `FamMemberRepo` / `FamInviteRepo` / `FamGrantRepo`。两处原子性设计：
  - `consumeOnce` 把「未撤销 + 未过期 + 次数未用尽 + 失败未超限」四个条件压进**一条 UPDATE 的 WHERE**，由行锁保证「并发 accept 10 次只成功 1 次」；
  - `bumpFail` 复用共享链接同款「自增 + 判定 + 撤销」一条语句（用更新前的值判定），避免进程在自增与撤销之间被杀而白送一次尝试。
  - 成员视角只读出口 `listSharedItems` / `countSharedItems` / `canReadItem` 共用同一个 `sharedPredicate()`，三处逐字一致（否则分页会错乱）。
- **`ams.app.family.FamilyService`**：建组（立刻写入 owner 成员行，否则组变孤儿）、创建邀请（`prov.randomBytes(24)`：前 8 字节给 code、后 16 字节给 token；**邀请不能直接产出第二个 owner**，`targetRole=owner` 降为 `manager`）、接受邀请（token 定位 → 状态有效 → code 正确 → **原子 consumeOnce** → join；已入组走**幂等分支且不消耗次数**）、公开落地页元数据（失效时 `valid=false` 且**不返回组名**）、建授权（三重校验：组内 owner/manager + 必须拥有该主体 + 被授权人必须是组成员；条目级还要校验条目确属该主体）、移除成员（级联撤销授权）。
- **`FamilyRoutes`（15 条路由）**：公开 1 条（`GET /api/family/invites/:token`）、登录即可 6 条、`family:manage` 4 条、`family:invite` 5 条。
  > **`/api/family/shared-items` 为什么不挂功能权限**：新注册账号默认无任何角色（默认拒绝是刻意设计），而 `docs/14 §3 T3` 又明确「入组不改变全局权限」。若这条只读出口也要求 `archive:read:own`，家人必须先找管理员开角色才看得到东西 —— 功能等于不可用；若为此自动写 `sys_user_roles`，就违背了 T3。故单开一条「只认 `acl_grants`、不认角色」的通道：一条多余的数据也读不到，且**不提供任何写/删/导出/分享操作**。
  > 审计 detail **只写 ID 与计数，绝不写 code/token 明文**。
- **`ItemRepo.list/count` 授权下推（B2，`docs/15` §6 标记的全局风险点）**：新增 `granteeId` 参数，把授权范围下推为 SQL 条件 `EXISTS (SELECT 1 FROM acl_grants g WHERE g.grantee_id = ? AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > CURRENT_TIMESTAMP) AND (g.item_id = arc_items.id OR (g.item_id IS NULL AND g.subject_id = arc_items.subject_id AND (g.category IS NULL OR g.category = 0 OR g.category = arc_items.category))))` —— **与 `Grant.covers()` 逐条对齐**，不允许「列表能看到、详情打不开」这类两套口径。
  - **新增独立 `subjectFilter` 形参（防绕过）**：主体筛选必须作为**独立 WHERE 条件**（`subject_id = ?`），不能靠缩窄「可访问主体集合」实现 —— 因为一旦 `granteeId > 0`，谓词里还有一条「被授权的条目」分支，缩窄主体集合只会让「自有」那半边变小，被授权分支依然全量命中，于是 `subjectId=99999999` 这类越权筛选会把别人的共享条目带出来。端到端脚本已固化此回归（`subjectFilter` 不绕过断言）。
- **`SubjectRepo.grantCustodian / revokeCustodian`**：`custodian_ids` 此前**全库只有读路径、没有写入口**，是设计文档里长期存在的空档。现补上 `array_append` / `array_remove` 两个对称写入口（均带 `owner_id` 归属校验与 `NOT (? = ANY(...))` 幂等判定）与 `listCustodianIds`。
- **审计**：`AuditAction` 新增 10 个动作码（`family.group.create/dissolve`、`family.invite.create/revoke/accept/fail`、`family.member.remove`、`family.grant.create/revoke`、`family.access.denied`），枚举成员 / `fromCode` / `code()` 三处同步。审计落痕在路由层（与 `ExportRoutes` / `SystemRoutes` 同策略），写失败只 WARN 不改业务结果。
- **前端**：新增 `/family` 页（两个顶层视图：我的家庭组 / 共享给我的；组详情为 Sheet + 成员·授权·邀请三个子页；三级粒度授权表单：整个主体 / 某分类 / 单条条目；新建邀请的 **code 与链接只显示一次**并明确提示，关闭后只能撤销重发）、公开落地页 `/invite/:token`（先展示组名与邀请人昵称供**核对**，再要求登录并输 8 位码；失效邀请渲染成正常页面的「已失效」态而不是接口报错）。导航在桌面与移动端各加「家庭协作 / 家庭」入口。能力位（canInvite/canGrant/canDissolve）**直接读后端组详情**，不在前端重新推导角色 —— 两边各写一套判断必然漂移。

### 变更（部署形态：一个进程、一个端口）

此前「后端 8080 + 前端另起静态服务器」被改成**前后端同时部署、同时启动**：

- **`packages/ams-api/src/server/static.cj`**（新增）：`StaticFiles` + `StaticHandler` + `ApiPath`。三条规则：① `/api/` 前缀**永不接管**（未匹配的接口返回 JSON 404，形状与 `ApiResponse.error` 一致，否则前端 `JSON.parse` 拿到 HTML 会报极具误导性的语法错）；② SPA history 回落**仅对无扩展名路径**生效（带扩展名却缺失必须真 404，否则缺 js 会被 HTML 掩盖）；③ 拒绝 `..` / `\` / `:` / 空字节。`/assets/` 给 `public, max-age=31536000, immutable`，其余 `no-cache`；统一加 `nosniff` / `referrer-policy: no-referrer` / `x-frame-options: DENY`。目录探测顺序 `web/dist → web → ../web/dist`，可用 `AMS_WEB_DIR` 覆盖。
- **`ParamDistributor` 新增 `setFallback()`**：SPA 路由无法逐一注册，静态托管作为兜底，同时保持「精确匹配 > 参数匹配 > 最长模式优先」的既有语义不变。
- **`ApiServer.init` 新增 `staticDir` 入参**，并在 `main.cj` 读 `AMS_WEB_DIR`、`server.ready` 日志带上 `webDir`；未找到前端目录时打 `http.static.disabled`（WARN，只有接口可用）。
- **`scripts/package.sh`**：新增前端构建步骤（`npm run build`，含 `vue-tsc` 类型检查，类型漂移不允许进交付物）与 `web/` 目录落包；`config/application.env` 增 `AMS_WEB_DIR`；`start.cmd` / `start.sh` 在缺 `web/index.html` 时给出明确 WARN；`healthcheck.*` 增加第二项检查 —— **根路径必须返回前端页面**（专门发现「接口通但前端产物没带上」的半残部署）；`DEPLOY.md` 改写为「一个进程一个端口」并补路由分流表。顺带修掉一个既有缺陷：`DEPLOY.md` 的 heredoc 用了引号定界符（`<<'DEPLOYEOF'`），导致 `${VERSION}` `${PKG_NAME}` 从未被展开、标题里一直是字面量。

### 新增（P2 第三批）

- **条目模板（FR-ARCH-012 · 方案 C：条目骨架 + 字段默认值）**：新增表 `arc_item_templates`（迁移 `017`）+ `ItemTemplateRepo` + `ItemTemplateRoutes`（`GET/POST /api/item-templates`、`PUT/DELETE /:id`、`POST /:id/apply`）。模板 = 骨架（分类/标题/状态/敏感度/签发机构/备注）+ `extra` JSON 默认值 + `expires_offset_days`。两条关键取舍：① **存偏移不存绝对日期** —— 模板会长期复用，绝对日期第二次套用就批量产出「已过期」档案；② 标题序号展开抽为纯函数 `TemplatePlan`（`{n}` 占位替换、无占位且 N>1 时追加 ` (i)`，否则列表里是 N 行无法区分的同名记录），15 条单测覆盖占位/多条/零条/闰年边界/超限钳制。套用上限 50 条（再大应走 CSV 导入，那边有预检与错误报告）。所有读写以 `owner_id` 为界。前端新增 `/templates` 页：列表 + 新建/编辑（标题实时预览 + JSON 对象校验）+ 套用 + 删除。
- **共享链接（FR-ACL-011 / FR-ACL-012 · 方案 A：条目级）**：新增表 `arc_share_links`（迁移 `018`）+ `ShareLinkRepo` + `ShareRoutes`。公开入口 `GET/POST /api/share/:token`（`isPublic`），所有者 `POST/GET /api/share-links` + `DELETE /:id`。安全要点：
  - token 由**密钥 HMAC-SM3** 从「条目+用户+时间+两次雪花 ID」派生（雪花 ID 单调可推，裸用可猜邻近 token）；
  - 密码只存**加盐 HMAC-SM3 摘要**，比较走 `provider.constantTimeEquals`（定时无关，复用系统内实现而非本地重复一份）；
  - `fail_count / max_fails` 落库 → 计数跨进程、跨重启有效；**「自增 + 判定 + 撤销」合并为一条 UPDATE**（`fail_count + 1 >= max_fails` 用更新前的值），避免进程在自增与撤销之间被杀而白送一次尝试；
  - 不存在 / 已撤销 / 已过期 / 条目已删 **一律 404 同一话术**（区分原因即等于确认 token 存在）；
  - 公开响应**只含展示字段**，不含条目标识/归属主体/扩展字段/附件；`sensitivity >= 3` 连签发机构与备注都不给；其余掩码复用 `Masker.mask`，与列表页同口径（两套掩码规则是最典型的越权旁路）；
  - 缺加密提供者或签名密钥时**失败关闭**（抛错），绝不降级成「弱 token」或「带密码却存空摘要 → 静默变公开链接」。
  前端：条目详情面板内嵌「共享」区（创建 / 复制 / 撤销 / 浏览数与错误数），新增公开页 `/share/:token`（密码保护时首屏不含任何条目信息）。
- **权限预览（FR-ACL-013 · 方案 A：仅统计口径）**：`GET /api/admin/permission-preview?role=<code>[&userId=]`（权限 `acl:manage`），返回角色元数据、主体范围（`any` / `own` / `user:<id>`）、`userCount/subjectCount/visibleItemCount`、按分类分布、字段可见上限与掩码级别、权限点清单。**不返回任何条目内容** —— 预览是「验证 RBAC 配置」的工具，不是「以他人身份浏览数据」的后门。角色不含 `archive:*:any` 时默认「仅本人范围」，**不猜测他人主体集合**。前端角色卡片新增「预览」：统计卡 + 分类条形分布 + 可选用户 ID 精算。
- **家庭成员邀请 · 安全设计（FR-ACL-010）**：交付 `docs/14-家庭成员邀请设计.md`（10 项安全原则、`fam_groups/fam_members/fam_invites` 数据模型、邀请码 vs 二维码取舍、14 项威胁模型 T1–T14、10 个审计动作码、完整 API 草案、统一错误语义、F1–F4 分批计划）。当时三处待定项（§6 授权粒度、§13 R6 审批流、§14 批次范围）已在 `docs/15` 给出推荐结论，后续按该结论完整落地，详见上方「新增（家庭成员邀请 · FR-ACL-010 · 方案 B）」。
- **前端字典统一**：新增 `web/src/composables/useCatalog.ts`。分类中文名此前在 `ArchiveView` 与 `OverviewView` 各写一份且已出现漂移（分类 2 一处叫「证件信息」、另一处叫「身份证明」），现以 `docs/06 §12.3` 为唯一口径。

### 修复

- **邀请码生成把字符写成 ASCII 码（单测发现）**：`InviteCode.generate` 里 `sb.append(ALPHABET[idx])` —— 仓颉的 `String` 下标取回的是 **UTF-8 字节（`Byte`）**，不是 `Rune`，于是命中了 `StringBuilder.append(Int64)` 重载，把 `'2'`(=50) 写成字符串 `"50"`。产出变成 `"5051525354555657"` 这种 16 位数字串，`isWellFormed` 必然不过 → `createInvite` 恒抛 `Internal: 邀请码生成失败`，**功能完全不可用**。改为 `sb.append(Rune(Int32(ALPHABET[idx])))`（与同文件 `normalize` 的写法一致）。这条是靠「给定字节 → 确定字符串」的确定性单测抓出来的 —— 纯随机生成 + 人工点一遍根本发现不了。
- **`static.cj` 的 `String.indexOf` / `lastIndexOf` 返回 `Option<Int64>`**：初版直接与 `0` 比较（`if (q >= 0)`），编译报 `invalid binary operator '>=' on type 'Enum-Option<Int64>'`。改用 `match` 解包。同时 `Byte(x)` 这种「构造调用」在仓颉不成立，数值转换一律走 `UInt8(...)`。
- **块注释里的 `/api/*` 会吞掉半个文件**：`ServerConfig.webDir` 的文档注释里写了 `/api/` 加星号，而**仓颉的块注释支持嵌套** —— 那个星号与斜杠组成新的注释起始符，注释一路吞到文件末尾，报出 `unclosed delimiter '{'` 并指向 `class ServerConfig {`，完全指错地方。已在注释里写清这个坑。
- **`acceptInvite` 恒报「HMAC 密钥不能为空」（端到端发现）**：`FamInviteRepo.findByTokenHash` 的 SELECT 只取了判定状态所需字段，**漏掉 `code_hash` / `code_salt`**；`RowData.str()` 对不存在的列返回空串，于是 `hmacHex("", ...)` 直接抛 `CRYPTO_FAILURE`。诡异之处在于**公开落地页完全正常**（它不需要这两列），只有接受邀请必挂，报错信息还指向密钥配置 —— 与真实原因（少选两列）相差十万八千里。已补齐两列，并在 `FamilyService.acceptInvite` 加「数据完整性自检」：缺摘要属于内部缺陷，抛 `Internal` 而不是伪装成「邀请码错误」去扣用户仅有的 5 次机会。
- **权限种子授给了不存在的角色（迁移静默失效）**：`019` 把 `family:manage` / `family:invite` 授给 `r.code = 'user'`，而系统实际角色是 `owner / curator / family / org_admin / auditor` —— 那两条 `INSERT ... SELECT` 匹配 0 行，**不报错**，表现是「迁移成功、跑完没异常，但除 `owner` 外谁都建不了家庭组」。现改为 `owner` + `curator`（规则：能建/改自己主体的人才能建组），并加一条「除零即报错」的单语句断言防止再次静默。之所以不用 `DO $$ ... $$`：`scripts/db.py exec` 按分号切语句，PL/pgSQL 块体内的分号会被切断。
- **已用尽的邀请对成员报「邀请不存在」**：`acceptInvite` 原顺序是「token → 状态 → code → 成员」，而默认 `maxUses = 1` —— 家人第二次点同一链接时邀请刚好被他自己用尽，于是看到「邀请不存在」，明明已经在组里。已把**成员身份判定提到状态判定之前**：持 token 已具备凭据，而「你在不在这个组」对本人不是秘密；非成员仍统一 404。
- **`FamilyRole` / `AppErrorKind` 不能用 `==` 比较**：仓颉自定义枚举没有内建 `operator func ==`，`target == FamilyRole.Member` 与 `e.kind == AppErrorKind.Forbidden` 都编译不过，改成嵌套 `match`。
- **`let (_, _) = f()` 用在非 tuple 返回值上**：`revokeAllByGroup` / `memberRepo.remove` / `requireRole` 四处报 `initializer isn't a tuple to match tuple pattern`，删掉解构直接调用。
- **共享链接恒失败（配置回落拿到空密钥）**：`main.cj` 中 `exportSignKey = AMS_EXPORT_SIGN_KEY ?? AMS_TOKEN_SECRET ?? ""` 在未显式配置环境变量时得到**空串** —— 因为 `AMS_TOKEN_SECRET` 的本地默认值只落在上文的局部变量里，这里重新读环境变量拿到的是 `None`。后果是本地开发下「导出包无法签名 / 回导验签恒失败 / 共享链接报 HMAC 密钥不能为空」，且报错信息指向不明。已改为回落到 `config.tokenSecret`（已含默认值），并把空密钥的报错改为点名配置项。
- `packages/ams-data/src/repo` 新增文件缺 `std.database.sql.*` 与 `ams.data.db.*` 导入，导致 `Database` / `toDbError` 未声明（`ams.data.repo` 构建失败）。
- **新手引导盖住公开页**：`Onboarding.vue` 只判断 `localStorage` 是否看过，但它挂在 App 外壳之外 —— 于是登录页、找回口令页、以及新增的共享页（`/share/:token`，接收方根本没有账号）都会被引导层蒙住。共享页尤其致命：内容被盖住，接收方会以为链接坏了。现改为同时满足「未看过 + 已登录 + 非 `meta.public`」才展示。
- **`.kv` 键值列表在多数页面退化成默认缩进**：该样式此前只定义在 `ArchiveView` 的 `scoped` 里，`RolesView`（权限预览）与 `ProfileView` 使用 `class="kv"` 时拿不到样式，`dd` 回落到浏览器默认的 40px 左缩进并换行 —— 表现为「标签一行、值另起一行且右移」。已将 `.kv` 提升为 `styles/theme.css` 全局类（含窄屏单列适配），并删除 ArchiveView 里的局部副本。
- `scripts/build.sh`：`TARGETS` 在参数解析之前被引用（`set -u` 下报 unbound variable）；且 `TOP_ORDER` 把 `ams-data` 排在 `ams-core` 之前，导致 `ams.data.repo` 用旧 `ams.core.search.cjo` 编译、`SearchQuery` 新字段报「member not found」。已调整参数解析顺序并修正拓扑序（`ams-core` 先于 `ams-data`）。
- **分类中文名后端与前端不一致**：`ArchiveCategory.displayName()`（后端唯一出中文名的地方，导出 CSV / 详情报文都走它）沿用早期草稿的「身份证明 / 工作经历 / 资格证书」，与 `docs/06 §12.3` 的字典表（证件信息 / 职业经历 / 资质证书）不符，也与前端 `useCatalog.ts` 不符 —— 同一份档案在网页和导出文件里叫两个名字。现已把后端 `displayName()` 对齐字典表，并更新枚举成员注释与文件头说明。

### 文档与许可证（P2 第三批）

- **新增 `docs/15-家庭成员邀请方案评估.md`**：针对 FR-ACL-010 三处待定项（§6 授权粒度 / §13 R6 审批流 / §14 分批范围）各出 A/B/C 三案 + 推荐 + 成本表，结论为 **§6 采方案 B（主体 + 条目两级，分类降级为同主体内收窄）**、**§13 R6 不做（邀请本身即双人确认）**、**§14 由 4 批压缩为 3 批**。评估前先做了一次**代码现状审计**，5 条硬事实推翻了设计文档里的若干隐含假设：① `acl_grants.subject_id` 是 `NOT NULL`（分类级授权无法表达「不限主体」）；② `Grant.covers()` 连分类授权也要求主体一致（跨主体分类授权恒不命中）；③ `ItemRepo.list/count` 完全不查 `acl_grants`，FR-ACL-008 只是「详情能用、列表/检索/导出仍全量」的半成品；④ `custodian_ids` 有列有读路径但**全库无写路径**（主体级共享反而最便宜）；⑤ 列表下推要改 6 个入口，必须先收敛出统一 `AccessScope`。
- `docs/14-家庭成员邀请设计.md` 在 §6.1 字段级说明后、§13 R6 行、§14 门槛说明后、结语共 4 处加了指向 `docs/15` 的指针，避免读者按未定稿的粒度直接开工。
- **新增 `README.md`**（项目门面）：目录 / 这是什么 / 当前状态（P0 54/54、P1 33+1 降级、P2 15/23，附工程面统计：115 个 `.cj` 3.76 万行、29 个 vue-ts 1.24 万行、19 个迁移、152 条路由、272 条单测）/ 功能一览 / 技术栈与九层单向依赖图 / 安全设计要点（国密落地实况：SM3 ✅、SM4-CBC/CTR ✅、SM4-GCM ❌ 已改 EtM 等价构造、SM2 ❌ 未实现）/ 快速开始 / 常用脚本 / 目录结构 / 文档索引 01–15 / 已知限制 / 参与开发 / 许可证。
- **采用 Apache-2.0**：新增 `LICENSE`（全文与官方文本逐字一致，仅填入 `Copyright 2026 何宇翔 (a703201)`），`web/package.json` 补 `license` 字段。选 Apache-2.0 而非 MIT 的唯一决定项是**第 3 条明示专利授权**：本项目含国密实现与权限模型等可能被主张专利的部分，MIT 对此完全沉默，Apache-2.0 能让使用方获得明确的专利许可、并以第 3 条终止条款对冲专利诉讼风险。
- `docs/README.md` 索引从 01–10 补齐到 01–15，状态行由「设计阶段（尚未进入编码实现）」改为当前实现进度。
- `docs/13-P2实现状态核对.md` 的 FR-ACL-010 行补 `docs/15` 指针。
- **前端文案口径统一落地**：`OverviewView.vue`（自带一份 `CATEGORY_NAMES`）与 `ArchiveView.vue`（自带一份 `CATEGORY_DEFS`）改为统一消费 `composables/useCatalog.ts`，该文件成为分类/状态/来源/敏感度的唯一口径。

### 新增（P2 收口：安全策略 / 通知 / 导入导出 / 档案增强）

> 本轮回填 7 条 P2，含 4 条能力边界降级项；三道闸门实跑：后端 `bash scripts/build.sh ams-server` 0 error、单测 `bash scripts/test.sh` **331 通过 / 0 失败**（较上轮 +6，来自 FR-IMP-005 模板路径）、前端 `cd web && npm run build` 0 error。端到端（`verify-family.py` 三-B 并发 accept 压测 + 新接口联调）**代码就绪但本环境无法实跑** —— 沙箱拦截 WSL/openGauss，需用户在本地拉起库后复验。

- **账号锁定策略可配置（FR-AUTH-010）**：`AuthConfig` 阈值/时长原硬编码；现读取环境变量 `AMS_AUTH_MAX_FAILS`（默认 5）、`AMS_AUTH_LOCK_SECONDS`（默认 900），在 `main.cj` 装配处具名传入。`auth.cj` 的登录失败原子计数 + 渐进延时 + 锁定 + 管理员人工解锁（`POST /api/users/:id/unlock`，写审计）均已具备。
- **短信通知降级（FR-NTF-005）**：新增 `SmsProvider` 接口（`Noop` / `Console`）+ `makeSmsProvider`（按 `sms.enabled` / `sms.console` 选择，默认关）。`Mailer.sendAlert` 在邮件基础上，若 `sms.enabled` 且电话非空则补发短信。安全事件走「站内 + 邮件 + 可选短信」双/三通道；密码重置已切到 `sendAlert`。
- **附件 SM3 指纹去重（FR-IMP-004 附件侧）**：此前 CSV 侧「关键字段判重」已实现，附件指纹侧补齐 —— `AttachmentRepo.listDedupKeys(subjectId)` 一次取该主体未删除/未隔离附件的去重键集合；`AttachmentImportService` 在预检（`buildPlan`）与执行（`runTask`）两阶段均比对 `dedupKeyOf(subjectId, plain)`（SM3 指纹 + 主体前缀），命中则标记跳过，避免每个文件各查一次库。
- **附件摘要/关键词手动录入（FR-ATT-013 降级）**：`arc_attachments` 新增 `summary` / `keywords`（迁移 `020`），`PUT /api/attachments/:id` + `AttachmentService.updateMeta` + 前端附件面板「摘要」按钮（展示与编辑）。OCR 作为部署侧可选项，隐私显式同意前走人工录入。
- **缩略图降级（FR-ATT-012 降级）**：`width/height/page_count` 元数据已落库（迁移 001），服务端无图像编解码库，降级为前端按原图 CSS `object-fit: cover` 缩放生成列表缩略图（图片附件预拉取 Blob 固定 48×48 缩放）。
- **图形验证码降级（FR-AUTH-011 降级）**：无图形库，降级为「同 IP 限流（`rateLimitMiddleware` 300/分钟）+ 登录递增延时 + 失败次数阈值锁定」，与 FR-AUTH-010 合并交付。
- **导出格式（FR-EXP-005）**：已支持 JSON 包（manifest + HMAC-SM3 签名，FR-EXP-008 回导验签闭环）+ CSV 报告，形态已统一为可携带闭环。
- **并发 accept 压测就绪（`scripts/ci/verify-family.py` 三-B）**：单条使用邀请（maxUses=1）下 10 个不同账号并发兑换，断言恰好 1 人成功（200）、其余 9 人一律 404，并校验组内仅 +1 新成员 —— 验证 `consumeOnce` 的「单条 UPDATE + WHERE 行锁」原子语义。
- **导入模板管理（FR-IMP-005 · 方案 C：全量字段定义域）**：CSV 表头不固定时，用户可保存命名模板（`{CSV 表头 → 字段键}` 映射 + 系统字段默认值），导入时套用免去每次重排列位。新增表 `arc_import_templates`（迁移 `021`）+ `ImportTemplateRepo` + `ImportTemplateRoutes`（`GET/POST /api/import-templates`、`PUT/DELETE /api/import-templates/:id`，`archive:write:own`）。`ImportService.validate()` 新增「按表头映射」分支（`mapping`/`defaults` 入参，**空映射零回归**走原 `cells[i]` 固定列序）；`ImportRoutes` 透传 `templateId`（从 query 或 JSON 体加载，失败回落空映射）。自定义字段键经既有 `arc_field_defs` / `arc_item_fields`（FR-ARCH-003/004）落库，复用条目录入同一条字段定义域通道；模板仓储层全带 `owner_id` 隔离，非本人一律 404/409。6 条单测覆盖固定列序零回归、模板映射（系统+自定义）、默认值回落、主体越权、判重。前端导入页模板套用 UI 已补（#75）：下拉套用 / 删除 / **复制**（`POST` 带 `cloneFrom`，以本人既有模板为蓝本，名称默认「原名 副本」）/ **改名**（内联 PUT 只改名称）、可视化表头映射编辑器、系统字段默认值。迁移 `021` 幂等写法已复核（`CREATE TABLE/INDEX IF NOT EXISTS`，与既有 15 个迁移同款）。

### 新增（P2 第二批）

- **导出包回导（FR-EXP-008）**：`POST /api/import/bundle/precheck` 与 `/api/import/bundle`。回导侧从**原始文本**按括号配平切出 `manifest` / `items` 两段，校验 **HMAC-SM3（或 SHA-256）签名**与 `manifest.segments[].sha256` 指纹 —— 签名针对原始字节，故不重新序列化（多一个空格就对不上）。任一不匹配即拒绝，**一个字节都不落库**；验签通过后按 `source=5` 回导入库，复用导入任务表 / 进度 / 错误报告 / 取消语义。`bodyCapFor` 将该入口放宽到 64 MiB。新增 5 条单测（合法包 / 篡改 / 错密钥 / 缺签名 / 不支持算法）。
- **来源与创建时间筛选（FR-SRC-010）**：`arc_items.source` 此前恒为 0、无写入方，来源筛选无从谈起。现打通写入枚举（0 手动 / 1 CSV / 2 克隆 / 3 OCR / 4 附件 / 5 回导），`ItemRepo.list/count`、`SearchQuery`、`GET /api/items`、`GET /api/search` 均接受 `source` 与 `createdFrom/createdTo`；前端档案页工具栏新增来源下拉与创建日期区间，条目卡显示来源标签。
- **通知偏好中心与免打扰（FR-NTF-006 / FR-NTF-007）**：`GET/PUT /api/notify/prefs`（`NotifyRoutes`），按 `req.subjectId` 隔离，存于配置中心（`scope=notify`，key=`u:<userId>:<field>`），不新增表。免打扰开关 + 起止时间 + 渠道（站内信 / 邮件）+ 频率（实时 / 每日 / 每周 / 关闭）；写入按白名单字段增量 upsert。个人主页新增「通知偏好」卡片。
- **多语言框架（FR-CFG-009）**：后端 `GET /api/i18n/locales` 声明默认 `zh-CN` 与支持列表；前端**零依赖** i18n 模块（`web/src/i18n`：`locale` + 文案目录 + localStorage 持久化 + 同步 `<html lang>`），顶栏语言切换、登录页标题/副标题接入。P2 定位为「框架预留」，未做全量翻译（避免为引 `vue-i18n` 增加依赖与网络安装成本）。

### 新增（P2 第一批）

- **标签使用统计（FR-TAG-004）**：`TagRepo.stats()` 一条 SQL 出 `total/used/unused/totalUsage/lastUsedAt`，`GET /api/tags/stats`。顺带修掉口径错误：原先**摘标签**也会把 `last_used_at` 推后，导致「最近使用」被清理动作污染；现只在打标时刷新。前端标签页顶部统计卡。
- **标签层级（FR-TAG-005）**：`arc_tags.parent_id` 早有列但无维护入口。新增 `TagRepo.move()`：写库前用 `tagMoveWouldCycle()` / `tagDepthOf()` 做**环路检测**（自引用结构一旦成环，递归渲染与级联删除都会死循环）与深度上限 `TAG_MAX_DEPTH = 5`；`PUT /api/tags/:id/parent`、`GET /api/tags?tree=1`（返回 `depth` / `childCount`）。两个纯函数有 7 条单测，含「互相引用成环」的终止判定。前端新增 `/tags` 页（树形表格 + 移动/改名/删除 + 新建时选父级）。
- **自审计（FR-AUD-009）**：新增 `AuditAction.AuditQuery`（`audit.query`）；`/api/audit`、`/api/audit/verify-chain`、`/api/audit/report` 三个入口都调用 `selfAudit()` 落痕（IP / UA / requestId）。「谁看了审计」此前没有任何证据，审计链在这里是断的。`record()` 是写不是查，不递归。
- **登录页定制（FR-CFG-008）**：新增 `BrandingRoutes`，`GET /api/branding` 为**公开只读**（登录页渲染时还没有令牌），返回 `brandName/logoUrl/notice/footerText/icpNo`；写入沿用 `PUT /api/admin/config?scope=branding`（权限与审计已由配置中心覆盖），不另开写接口。前端登录页渲染 Logo / 公告 / 页脚 + 备案号，接口失败静默降级为默认值 —— 登录本身比品牌展示重要，不能因为配置接口挂了就白屏。
- **批量编辑（FR-ARCH-013）**：`POST /api/items/batch/edit`，`{ids, category?, expiresAt?, tagIds?}` 三个字段均可省略，**打补丁语义**（不传的字段不动 —— 批量场景下用缺省值覆盖未填字段一次就能毁掉几十条记录）。`ItemRepo.batchEdit()` 的 WHERE 同时带 id 列表与**可访问主体列表**，越权条目根本不会被更新，响应的 `updated` 与 `requested` 不一致即为信号；`TagRepo.attachMany()` 幂等打标（已有关系不重复计数，`usage_count` 不会虚增）。前端档案页批量栏新增改分类 / 有效期 / 加标签。

### 新增（P1 收口）

- **ZIP 批量导入附件（FR-IMP-002）**：上轮标注的「SDK 无 zip 解包」被证伪 —— `stdx.compress.zlib` 的 `WrapType.DeflateFormat` 探针实测就是 **RFC 1951 裸 deflate**（ZIP 条目正是这个格式）。手写 `zipreader.cj`（EOCD/中央目录/本地头 + store/deflate）与 `gbk.cj`（87×94 GBK 码表，由 `scripts/gen-gbk-table.py` 生成），解决中文 Windows 打包「GBK 文件名 + bit 11 未置位」这一最常见坑（UTF-8/GBK 双解码 + 可信度打分）。两阶段接口：`POST /api/import/attachments/precheck` 出映射预览（**真解一遍验 CRC**，不写库）→ `POST /api/import/attachments/tasks` 用户确认后异步落库；标题不存在自动新建条目（同标题只建一次），同名条目 ≥2 列为冲突必须手动指定（未指定直接 409 并点名目录）。安全闸门：路径穿越/绝对路径/盘符、ZIP64、加密位、deflate64/bzip2、CRC 损坏、解压炸弹（边解边计数，50 MB/文件、2000 条目）。前端新增 `/import` 页（ZIP/CSV 双 Tab、统计卡、映射预览表、冲突下拉、任务进度轮询、错误报告下载）。
- **自助找回口令（FR-AUTH-008）**：`sys_password_reset` 表 + `PasswordResetRepo` + `PasswordResetService`；`POST /api/auth/password/{forgot,verify,reset}` 三步链路（6 位验证码 10 分钟 / 5 次尝试 / 60 秒冷却 → 一次性重置令牌 15 分钟 → 改哈希并**吊销全部会话**）。验证码与令牌只存 SM3 摘要（验证码以 user_id 作盐）。前端新增 `/forgot` 三步向导。
- **双因子 TOTP（FR-AUTH-009）**：自写 `Sha1`/`Base32`/`Totp`（标准库无 SHA-1；启动跑 RFC 6238 附录 B 自检），`sys_user_totp` + `TotpRepo`（`last_step` 防重放），`/api/me/2fa{,/setup,/enable,/disable}`，登录在口令通过后、签发令牌前强制校验；个人主页新增绑定卡片，登录页按需展开动态码输入。
- **附件版本（FR-ATT-004 补齐）**：`POST /api/attachments/:id/versions` 上传新版本（复用附件 DEK、版本号自增、`att_<id>_v<n>.bin`），下载改为按 `is_current` 反查存储键 —— 之前「切换版本」只改标记、下载永远是首版。
- **版本元数据对比（FR-ATT-009）**：`GET /api/attachments/:id/versions/compare?from=&to=`，返回两侧元数据 + `diff{contentChanged,sizeDelta,ext/mime/status/noteChanged,fields[]}`。
- **附件批量操作（FR-ATT-010）**：`/api/attachments/batch/{download,tag,delete}`；自写 ZIP 写入器（store + CRC32 + UTF‑8 名标志 + 可选 ZipCrypto 口令，因 SDK 无 zip）；新表 `arc_attachment_tags` 支持附件维度打标签（幂等）；删除走软删。前端新增 `AttachmentPanel.vue`（上传/预览/版本对比/批量栏）。
- **动态水印（FR-ATT-008，降级）**：`GET /api/attachments/:id/watermark` 签发「访问者 + 服务端时间 + 8 位追踪号」并写审计，前端斜向平铺覆盖；**无法烧进像素**（SDK 无图像/PDF 渲染库）。
- **审计动作扩展**：`AuditAction.PasswordReset`（`auth.password_reset`），找回流程六类结果均落库。
- **邮件控制台投递**：配置 `mail.console=true` 时把邮件正文打进日志（等价 Django console backend），便于本地联调验证码类流程；默认关闭。
- **链校验分段模式（FR-AUD-003 补充）**：`GET /api/audit/verify-chain?mode=segment` 在段首无前驱（链头归档 / 历史断层）时，以段首自身 `prev_hash` 为锚点证明**段内**连续且未改动，响应明示 `anchored=false`、`checked=N`；默认 `strict` 行为不变。
- **审计链独立校验器**：`scripts/verify-audit-chain.py` 按同一套规范化规则用 Python 复算 SM3 并与落库 `record_hash` 比对，不依赖 `ams-server` 与被测代码（可交叉验证「tampered」是真是假），输出哈希/衔接/断层三类结论与退出码。

### 修复

- **请求体 1 MiB 以上被静默截断**：附件上传声明上限 50 MB，但 `api.http` 只做**一次** `read()`，超过 1 MiB 的部分直接丢弃，而魔数校验看的是前几个字节 —— 表现是「上传成功但文件残缺」。两层修复：① `ServerBuilder.maxRequestBodySize(64 MB)`（stdx 在传输层就返回 413 `The content too large.`，我们的读循环根本没跑到）；② 读循环改为分块累积，按路径分级限额（附件与批量导入 64 MB，其余 1 MB），超限返回 `PAYLOAD_TOO_LARGE` 而不是截断。
- **导入任务报告的失败数恒为 0（影响 FR-IMP-001 与 FR-IMP-002）**：`markSuccess()` 先把 `status` 置 2 并把 `failed_count` 清零，随后的 `updateProgress()` 因 `WHERE status = 1` 成了**空操作**。新增 `ExportTaskRepo.finish()` 用**一条** UPDATE 写全 `total/done/failed/result_path/expires_at`，两个导入器改用它。实测同一夹具由 `failed=0` 变为 `failed=2`，与报告里的 skipped 行数一致。
- **批量导入附件会静默丢文件**：`attachments.upload()` 的去重命中分支会复用已有附件行、不建新的条目归属，导入时该文件看起来「成功」却没挂到任何条目。新增 `dedup!: Bool = true` 形参，批量导入传 `false`。
- **请求体分块拼接依赖切片语义**：`ApiRequest.fromContext` 复用同一个 64 KiB 缓冲区循环读，分块用 `chunk[0..n]` 累积。若 `Array<Byte>[Range]` 返回视图而非拷贝，所有分块会指向同一段内存，拼出的请求体「长度正确、内容全错」——现场表现为「几十个条目的 ZIP 解析失败，单个小包却正常」。改为显式逐字节拷贝（`ApiRequest.copyOf`），从语义上消除该依赖。
- **预检接口残留诊断开关**：`POST /api/import/attachments/precheck?debug=1` 会把收到的字节数与指纹回显在错误消息里（早期为定位请求体损坏临时加的）。已移除；同时预检改用与提交相同的 `splitFramed`，裸 ZIP 与封帧体都能解析，避免「预检能过、确认提交报 400」的分叉。
- **导入页未拦超大包**：后端对 `/api/import/attachments` 的请求体上限是 64 MiB（`MAX_LARGE_BODY_BYTES`），但前端不校验包大小，用户要把几十 MB 的包传完才拿到 413。现在选包时即按 64 MiB 拦截并提示拆包，页内说明也标注了「单个压缩包 ≤ 64MB」。
- **导入分类范围写死 1–6**：字段模板与前端字典都是 1–11，导入却把 7–11（家庭关系/健康/资产/影像附件/自定义）判为非法。两处校验统一放宽到 1–11。
- **附件归属错挂**：`POST /api/attachments` 曾把「当前用户 ID」当 `subject_id` 落库，导致附件主体级鉴权必然失败；改为按 `itemId` 反查条目主体，主体级附件要求显式 `subjectId`。
- **附件行级越权缺口**：单条下载只校验权限码、不校验行归属；批量入口统一补上「附件主体是否在调用者可访问集合内」校验。
- **`wrapped_dek` 列缺失**：`008_attachment_dek.sql` 用的 `ADD COLUMN IF NOT EXISTS` 在 openGauss 5.0 上不生效且被静默忽略，附件上传/列表直接 `DATABASE_FAILURE`；已补列并记录该语法限制。
- **`db/migrations/015`**：`sys_password_reset` 增加 `created_ms/consumed_ms`（冷却期在 SQL 里做数值比较，避免 TIMESTAMPTZ 转换）。
- **审计哈希链大面积误报「被篡改」（FR-AUD-002/003）**：收尾自检发现 `GET /api/audit/verify-chain` 对应用自己写入的正常记录报 tampered。用「Python 独立复算 + 解析探针 + 端到端复现」三层定位，实为 4 处反查/还原缺陷：
  - `String.trimStart()/trimEnd()` 在本机仓颉 SDK 1.0.5 上是**空实现**（`"  abc  ".trimStart().size == 7`），`jsonToDetail` 因此把 `{"k": "v"}` 还原成 ` "k"= "v"`。新增 `ams.kernel.util.trimSpace()`（按字节裁剪，不切断 UTF-8），全仓替换 16 处误用；`jsonToDetail` 改为扫描式解析（值内含逗号/冒号不截断，支持 `\" \\ \n \uXXXX` 及代理对），`detailToJson` 按 JSON 规范转义。
  - `AuditAction.fromCode` 与 `code()` 有 4 个动作用词不一致（`share.create`↔`acl.share_create`、`share.access`↔`acl.share_access`、`kms.key_rotate`↔`crypto.key_rotate`、`archive.batch`↔`archive.batch_operation`），反查退化为 `unknown` 导致哈希不符；`fromCode` 改为新旧码都接受。
  - `toResult(2)` 误返回 `Success`（应为 `Denied`），全部 `result=2` 的记录误报（实测 20 条）；`toActorType(3)` 漏处理（防御性补齐）。
- **服务重启后旧令牌返回裸 500**：`MemorySessionStore.get()` 用 `HashMap[sid]` 直接读，键缺失时仓颉 `[]` **抛 `NoneValueException`**（不返回 Option），异常穿透中间件。改为先 `contains` 再取，恢复为 `401 令牌无效或已过期`。
- **带空格 JSON 解析失败**（同一 trim 根因）：`{"username": "tester"}` 曾报「用户名与口令不能为空」；现与紧凑 JSON 行为一致。

### 文档

- 新增 `db/migrations/015_password_reset.sql`、`016_attachment_tags.sql`。
- `docs/12-P1实现状态核对.md` 更新为收口状态（含每条实测证据与唯一降级项的说明），新增 §2.6.1 记录审计哈希链复核的 5 处缺陷、定位方法与验证证据；§2.7.1 记录 ZIP 批量导入的可行性探针、实现要点与 7 个夹具的验收结果；同时修正 §1 摘要与全表统计不一致（20/14 → 33/1/0）。
- 新增 `scripts/gen-gbk-table.py`：从 Python `gbk` 编解码器生成 87×94 GBK→Unicode 码表（仓颉侧 `gbk.cj`）。
- 新增 `scripts/verify-audit-chain.py`：审计链离线独立校验（不信任服务端）。

### 已知限制

- FR-ATT-008 水印为「可视覆盖 + 审计可追溯」，非像素级烧写（SDK 无图像编解码/PDF 内容流库，能力边界）。
- ZIP 批量导入的**单个压缩包 ≤ 64 MiB**、单批 ≤ 500 个文件。请求体在鉴权之前就被读入内存，故上限按路径分档放宽（附件与批量导入 64 MiB，其余 1 MiB），不做流式入库；超出需拆包分批（前端已在选包时拦截并提示）。

---

## [未发布] — 工程化与交付增强（Linux / 容器 / 对外 API / 信创）

> 本批次属**工程化与交付能力**补强，不改动业务功能（FR 完成度仍为 P1 34 条 / P2 23 条）。
> 架构级两项（提炼通用框架、SaaS/微服务化）已在 `docs/18 §三` 拍板，并落地 **Phase 1**（见下方「新增（架构演进 · Phase 1）」）；Phase 2 待办见 #87 / #89。

### 新增（Linux 构建链路）
- `scripts/build-linux.sh`：`build.sh` 的 Linux 移植（去 cygpath/`.exe`/`.dll`，运行时与 stdx 改 `linux_x86_64_cjnative`，产物 `ams-server` 无扩展名，SDK 探测 `/opt/cangjie` 或 `tools/cangjie`），驱动构建改调 `build-driver-linux.sh`。
- `scripts/build-driver-linux.sh` / `scripts/test-linux.sh`：opengauss-driver 与单元测试的 Linux 移植，使 Linux 上可跑通「构建 + 单测」双闸门。
- `.github/workflows/ci-linux.yml`：独立的 opt-in Linux CI（仅 `workflow_dispatch` 与 `ci-linux` 分支触发，不干扰现有 Windows CI），支持自托管 Linux runner 或 `CANGJIE_LINUX_SDK_URL` 下载直链。
- ⚠️ 沙箱无 Linux，脚本为 best-effort 移植，需在 Linux runner（含 Cangjie SDK 1.2.x）实测复验。

### 新增（容器化部署）
- `deploy/docker/Dockerfile`：多阶段镜像（builder 跑 `build-linux.sh` + web 阶段构建前端 SPA + runtime 仅留可执行文件与运行时/ stdx `.so`）。
- `deploy/compose/docker-compose.yml`：`ams` 应用 + `openGauss`（enmotech/opengauss:5.0.0）单机编排，含健康检查与 volume。
- `deploy/config/ams.env.example`：运行期环境变量模板（不含密钥）。
- `deploy/README.md`：构建 / 首次建库迁移 / 启动 / 生产 Checklist。

### 新增（对外 API 接入配套）
- `docs/17-对外API规范-OpenAPI.yaml`：基于 156 个 method+path 自动提取生成的 OpenAPI 3.1 基线规范，含 Bearer 鉴权、通用错误包、按标签分组；request/response schema 暂以占位类型标记，待按后端 DTO 补全。

### 新增（信创·国家标准参考）
- `docs/16-信创与国家密码标准参考.md`：对齐国密 SM3（GB/T 32905 / GM/T 0004）、SM4（GB/T 32907 / GM/T 0002）、SM2（GB/T 32918 / GM/T 0003）标准，显式列出已实现（SM3 / HMAC-SM3 / SM4-CBC·CTR / PBKDF2-HMAC-SM3）与未实现（SM4-GCM 受 stdx 限制、SM2 未实现，导出签名用 HMAC 对称），并声明「代码对齐 ≠ 商用密码产品认证」边界。

### 新增（架构演进 · Phase 1 落地 — docs/18）

> `docs/18 §三`（2026-10-29）已拍板：通用框架 → **A 独立框架库**；SaaS 第一步 → **A 多租户单体**。本批落地两项 Phase 1。

- **多租户数据层隔离（SaaS · 方案 A · Phase 1）**
  - 迁移 `022_tenant_isolation.sql`：建 `sys_tenants`（默认租户 `id=1, code='default'`）；用幂等 `DO $$` 块（`information_schema.columns` 判定）给 `sys_users` / `arc_subjects` / `arc_items` 加 `tenant_id BIGINT NOT NULL DEFAULT 1`；补 `idx_*_tenant` 索引。复验：迁移 10/0 成功，三表列/索引齐备，存量 12 subjects / 24 items / 89 users 回填 `tenant_id=1`。
  - 鉴权链路注入 `tenantId`：`UserAccess` / `AccessContext` / `ApiRequest` 新增字段；`main.cj` 与 `ams-app.authz` 经 `UserRepo.tenantOf(userId)` 推导并沿请求传递。
  - 隔离策略：**传递性隔离 + 显式 tenant_id** 混合（stdx 并发处理请求，无法用品圆线程级 ambient context）。
    - `UserRepo.listAccessibleSubjectIds` / `listOwnedSubjectIds` 内部按 `tenantOf` 推导租户并过滤 `arc_subjects.tenant_id`；item 查询多按 `subjectIds` 过滤，租户隔离**传递性**覆盖（调用方零改动）。
    - 写路径 `ItemRepo.create` / `cloneItem` 显式带 `tenant_id`（clone 复制并校验同租户）。
    - `ItemRepo.findByIdRaw` **保持租户无关**：后鉴权加载点，隔离已由 guard 的 tenant-scoped subjectIds 保证；若加 tenant_id 会破坏共享链接 / 被授权用户的 FR-ACL-008 通路。
  - 附带修复 `scripts/db.py`：原按分号原生切分语句会把 `DO $$...$$` 块拆碎（`unterminated dollar-quoted string`）；新增 `_split_statements()` 状态机（忽略美元引用串与单引号串内分号），`exec_file` 改用它，惠及后续所有含 DO 块的迁移。
  - 编译复验：强制清 `.cjo` / `.a` 缓存全量重编，受影响包 0 error，`build/ams-server.exe` 13M 产出。
- **通用框架 facade（框架 · 方案 A · Phase 1）**：新增 `ams-kit` 作为对外稳定 API 层，re-export `ams-crypto`（SM3/HMAC-SM3/SM4/PBKDF2/盲索引）与 `ams-security.authz` 纯逻辑部分；业务耦合点参数化，框架层不 import 任何 AMS 业务包；已并入 `scripts/build.sh` / `build-linux.sh` 拓扑序。Phase 2 发布化已完成（详见下方「新增（架构演进 · Phase 2 落地）」）。

### 新增（架构演进 · Phase 2 落地 — #87 框架发布化 / #89 跨租户回归）

> 2026-10-30 完成。三道闸门实跑：后端 `bash scripts/build.sh` 0 error、`bash scripts/test.sh` **338 通过 / 0 失败**（较上轮 331 +7：ams-kit 独立单测 +4、authz 跨租户断言 +3）、前端 `cd web && npm run build` EXIT 0；端到端 `scripts/ci/verify-tenant.py` 在 `ams_opengauss` 实跑 **23/23 全绿**（初跑 22/23，暴露并修复一处 owner 跨租户详情泄漏后满绿）。

- **框架发布化（#87）**
  - `packages/ams-kit/tests/kit/kit_test.cj` 新建 **4 条独立单测**（`KitFacadeTest`）：`KIT_VERSION` 非空、`SM3("abc")` 标准向量、`KeyManager` KEK ≥16 字节且 wrap/unwrap 往返、`BlindIndex` 生成 32 字节且归一化匹配/不匹配。与产品代码物理分离（测试包声明 `ams.kit.test`）。
  - `scripts/test.sh` / `scripts/test-linux.sh` 默认 `PKGS` 数组追加 `ams-kit`，纳入全量门禁。
  - 补 cjpm 包描述三件套：`packages/ams-kernel/cjpm.toml`、`packages/ams-crypto/cjpm.toml`、`packages/ams-kit/cjpm.toml`（按官方 `cjpm init` 模板：`cjc-version="1.2.0"`、`output-type="static"`、版本 `0.1.0`）。依赖链用**下划线扁平形式** `ams_kernel` / `ams_crypto` / `ams_kit`。
  - ⚠️ **发布链路阻塞（待决策）**：cjpm 1.2.0 要求 toml `name` 为**扁平标识符**且与源码 `package` 声明**逐字相等**；AMS 全仓用点号分层命名（`ams.kit`），`cjpm check` 实测报 `the package name ... is wrong, the right name should be 'ams_kit'`，改回点号又报 `'ams.kit' is wrong, the example is 'cjDemo'` —— 即 cjpm 无法解析 AMS 现有包名。当前可用产物是 `build/*.a` 静态库（经 `scripts/build.sh` 拓扑序产出）；若要走 `cjpm publish`，需把相关包改名（波及全仓 import），属破坏性决策，故仅写出 toml 作文档意图，未强行改名。待用户拍板是否启动「包名扁平化」重构。

- **跨租户隔离正确性验证（#89）**
  - 新建 `scripts/ci/verify-tenant.py`：**确定性端到端回归**（仿 `verify-family.py` 风格，端口 `18105`，自启停 server，幂等 UPSERT 第二租户 `id=2, code='tenant2'`）。覆盖：
    - curator 双向跨租户隔离（主体列表 / 条目列表 / 详情按 ID → 403·404）；
    - 正向对照（各见自己）；创建隔离（租户1 在租户2 主体下创建 → 403）；克隆隔离（克隆租户2 条目 → 非 200）；
    - **owner 跨租户详情探针**（回归目标 → 必须 403/404）；owner 同租户 `archive:read:any` 语义保留；owner 列表同样经 tenant-scoped subjectIds 隔离。
  - **发现并修复 owner 跨租户详情泄漏（安全缺口）**：初跑仅「owner 读租户2 条目详情」得 200（应拒）。根因是 `Authorizer.checkOwnership` 的**路径 0**（`if (ctx.hasPerm("archive:read:any")) return true` —— 持有 any 范围权限的角色 `owner`/`org_admin` 放弃归属约束）叠加 `ItemRepo.findByIdRaw` **租户无关**（设计如此，供 FR-ACL-008 共享链接后鉴权加载），二者叠加 ⇒ owner 可凭条目 ID 跨租户读他人详情。修复：
    - `ItemRecord` 新增 `subjectId` / `tenantId` / `category` 字段并贯穿 SELECT / `toRecord`；
    - `AuthzResource` 新增 `tenantId: Int64`（默认 0 哨兵），`checkOwnership` **最顶部**加跨租户强制：`if (resource.tenantId != 0 && resource.tenantId != ctx.tenantId) return false`（防御所有路径含路径 0）；
    - `items.cj` 的 `guardOf` 将条目 `tenant_id` 传入 guard。
  - `packages/ams-security/tests/authz/authz_test.cj` 新增 **3 条**断言（29→32）：已知租户+调用者 any → 拒绝；同租户 any → 放行；tenantId=0 哨兵跳过强制。
  - 复验：e2e 22/23→23/23、authz 32/32、全量 338/338、build 0 error、web build OK。

### 候选（待拍板，未落地）
- `docs/18-架构演进路线-方案候选.md`：提炼通用开发框架（A 独立框架库 / B 仓内 shared / C 脚手架）与 SaaS/微服务化（A 多租户单体 / B 模块化单体 / C 完整微服务）的 A/B/C 方案与权衡；**Phase 1、Phase 2 均已落地（见上方 #87 框架发布化 / #89 跨租户回归）**。

### 修复

- **标签合并前端入口缺失（FR-TAG-003）**：后端 `POST /api/tags/:id/merge`（`mergeTag`，含「防合并到自身」校验）早已具备，但 `TagView.vue` 一直只有「改名 / 移动 / 删除」，没有合并 UI —— FR-TAG-003 此前实际只完成后端一半。现补「合并」按钮 + 目标标签下拉（排除自身与子孙，复用 `parentOptions`）+「确认合并」，与服务端环路/深度校验形成双保险。`cd web && npm run build` 类型检查 + 构建通过。

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
