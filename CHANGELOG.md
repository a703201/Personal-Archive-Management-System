# AMS · 变更日志

本文件记录 AMS 各版本的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **发布流程**：
> ```bash
> # 方式一：本地脚本（不依赖 CI runner）
> bash scripts/release.sh --version 1.0.0
>
> # 方式二：打 tag 触发 GitHub Actions
> git tag -a v1.0.0 -m "AMS 1.0.0"
> git push origin v1.0.0
> ```

---

## [1.3.0] — 2026-11-09（功能小缺口收口 + external OCR 生产化 + 架构演进阶段 3 + 安全收口）

> 本批不改动业务功能完成度口径（P0 54 / P1 34 / P2 23 不变），属能力补强 + 安全收口。
> 版本号提升至 **1.3.0**（语义化 minor：多新功能模块 + 安全加固）。

### 新增（检索 / 授权 / 上传 / 国际化 · 真实小缺口收口）
- **搜索高亮片段**（FR-SRC-001 补遗）：新增 `ams.core.search.SearchHighlighter`，按 **UTF-8 字符边界**把命中切成 `[{text,hit}]` 分段（含长文本以首命中为中心开窗 + 省略号、ASCII 大小写折叠、对齐后端「单字回退 LIKE」）。`GET /api/search` 每行返回 `highlight.title` / `highlight.issuer`；**敏感度 ≥ 2 的条目 issuer 不生成高亮**，避免通过片段反推掩码前明文。前端 `GlobalSearch.vue` 用 `v-for` + `<mark>` 渲染，**不用 v-html**（零 XSS 面）。单测 11 例。
- **分片上传 / 断点续传**（FR-ATT-001 补齐）：新增 `ChunkUploadStore`（单实例内存态 + Mutex，1 MiB 分片、50 MB 上限、24h TTL、归属绑定、非末片长度强校验、重传幂等）与 5 个端点 `POST/GET/PUT/POST/DELETE /api/attachments/upload/sessions...`。合并后的明文**原样交给 `AttachmentService.upload()`**，加密 / 去重 / 审计 / 媒体链路零回归。前端 `web/src/api/chunkedUpload.ts` 在文件 > 1 MiB 时启用，会话 ID 存 sessionStorage 支持刷新后续传；小文件仍走原单次上传。单测 9 例。
- **i18n 动态文案**：`viewsArchiveView.9fead2` 原为静态「已更新条目」，导致批量编辑提示丢失数量且 en/fr 回退中文；改为三语 `{count}` 占位符 + 新增 `batchTagged` / `uploadProgress` / `uploaded` / `api.chunkedUploadFailed` 三语词条。三语 catalog 键数保持一致。
- **核查结论（自纠正）**：`docs/10` 历史章节中「FR-ACL-009 撤销接口仍待补」「FR-ATT-001 分片上传未实现」「前端导入页模板套用 UI 待补」均为 2026-10-26 的**陈旧标注** —— 实际已由后续批次落地（`DELETE /api/grants/:id`、`DELETE /api/family/grants/:id`、`ImportView.vue` 模板 CRUD）。历史逐行标记按分层约定保留不改，现状以本文与 `docs/10` 新增章节为准。

### 新增（external PP-OCRv5 生产化）
- **DB 后处理升级**：`ocr_bridge.c` 从「8 连通域 + 轴对齐框」升级为「凸包 + 旋转卡壳最小面积外接四边形 → Unclip 边偏移求交 → 单应矩阵透视变换 + 双线性采样」，覆盖**倾斜文本**。rec 推理抽成 `run_rec_crop()` 供旋转框与轴对齐两条路径共用，避免漂移。
- **零回归开关**：`AMS_OCR_DET_QUAD=0` 回退旧轴对齐路径；`AMS_OCR_UNCLIP_RATIO`（默认 1.6）可调。
- **通道序校准**（B2）：`AMS_OCR_CHANNEL_ORDER=bgr` 可切换，默认 `rgb`（web 导出版实测灰度/彩色 RGB 正确），det 与 rec 共用同一开关；不做隐式猜测。
- **如实边界**：对凸四边形，边偏移求交与通用 Vatti 多边形等距外扩结果一致；**任意凹多边形 / 粘连文本行仍不支持**（未引入 Vatti 库）。倾斜 > 45° 与竖排文本未做方向规整。
- **方向规整（实测发现并修复）**：旋转卡壳枚举的是凸包**边**，朝向任意；初版直接做透视变换会把文本左右镜像 / 上下颠倒，B3 倾斜 12° 夹具上 QUAD=1 三个框全空、QUAD=0 反而全中。新增 `orient_quad()`（枚举 4 起点 × 2 绕序，保留「长边在 p0→p1」，取 p0→p1 最水平向右、p1→p2 最竖直向下）后修复。
- **B3 泛化实测（直连 C ABI，不走 HTTP/DB）**：`.tmp/ocr_selftest.c` + 三张夹具（倾斜 12° / 彩色浅蓝底 / 复杂排版）。
  - 倾斜 12°：QUAD=1 `档案管理系统 / 文字识别测试ABC123 / 倾斜文本12度`（**完整**）；QUAD=0 `文字识别测A123`（丢「试」「BC」）—— 旋转框路径明显更优。
  - 彩色图：rgb 与 bgr 输出一致，三行均正确；说明该 web 导出模型对通道序不敏感，默认 rgb 保持，开关留给其它导出版本。
  - 复杂排版：`UNCLIP_RATIO=1.6` 出 4 行、`1.2` 只出 3 行且第 3 行变差 → 默认 1.6 合理。末行小字号（28px）识别仍有瑕疵（`大务月250110-...`），属识别质量而非引擎失败，如实保留。
  - C 桥接已在 `ams-cj` 容器 `gcc -O2 -fPIC -shared` 实编 0 error；Linux 全量构建 `LINUX_BUILD_EXIT=0`。

### 新增（架构演进 · 阶段 3 / docs/15）
- **ams-kit 阶段 3**：纳入审计哈希链（`newAuditChain` / `auditGenesisHash`）、检索纯逻辑（`tokenizeForSearch` / `maskValue` / `highlightJson`）、导入模板纯字符串内核 `CsvColumnTemplate`（在框架层独立实现，**不 import ams.app**，保持单向分层）。单测 6 例。
- **多租户阶段 3**：迁移 `024_tenant_ops.sql`（`sys_tenant_quota` / `sys_tenant_settings` / `v_tenant_audit_summary`，侧表幂等）；`TenantOpsRepo` + `TenantOpsRoutes`（`acl:manage`，配额读写 / 配置读写 / 审计聚合）；`main.cj` 注册。配额纯逻辑单测 7 例。
- **配额边界如实标注**：本阶段配额是「运营上限声明」，**尚未在创建用户 / 条目 / 附件的写路径强制拦截** —— 未经压测不改写入语义。
- **cjpm 发布化 — 已拍板方案 A（静态库分发，不做全仓改名）**：包名点号分层（`ams.kit`）与 cjpm 扁平 `name` 不兼容，`cjpm check` 实测报错；全仓改名波及所有 import、风险高收益低，故维持 `build/*.a` 静态库形态并做成正式分发链路：
  - 新增 `scripts/package-kit.sh`：从 `ams.kit` 的 `import` 出发**实时递归推导依赖闭包**（当前 8 个包，不写死白名单），校验每个包的 `.a` / `.cjo` 齐全后打包 `lib/` + `cjo/` + `LICENSE`（缺失即拒绝出包）+ `README.md` + `VERSION` + `MANIFEST.txt`（闭包/逐文件 sha256）+ `CHECKSUMS.sha256`；版本号**唯一来源**为 `kit.cj` 的 `KIT_VERSION`，支持 `--build-dir build/linux`、`--print-closure`、`--version`。
  - 新增 `packages/ams-kit/README.md`（**发布用途**文档，随包分发）：分发形态、8 包闭包、`cjc --import-path ./cjo` 接入示例、最小示例、能力清单、Apache-2.0 与安全边界、自行打包命令。
  - 三个 `cjpm.toml` 加注释明确「仅元数据文档、不参与构建、勿跑 cjpm build/check/publish」；**不改 `name` / `version` 数值**。
  - **事实核查订正**：`docs/15` 原记三个 toml 版本为「0.1.0 / 0.1.0-alpha」，实际均为模板值 `"1.0.0"`；因不参与构建而无实际含义，已在 `docs/15` §4.1 订正。
  - **接入验证闸门 `scripts/ci/verify-kit-package.sh`**：模拟外部接入方，只用发布包里的 `.cjo` / `.a`（不引用仓库 `build/` 下任何其它产物），用 `cjc` 编译链接并运行最小程序；断言 `KIT_VERSION`、`SM3_BYTES=32`、分词 / 高亮 / 掩码 / 导入模板 / 审计链可用。**实测 `VERIFY_EXIT=0`**：8 库链接成功、`SM3_BYTES=32`、`TOKENS=5`、`HIGHLIGHT_LEN=102`、`MASK_LEN=8`、`GENESIS=32`、`TPL_HAS_TITLE=true` —— 依赖闭包完整、接口快照可消费、静态库真实可用。
  - **双平台产物实跑**：`dist/ams-kit-0.1.0-alpha-windows-x86_64.zip`（185K）与 `dist/ams-kit-0.1.0-alpha-linux-x86_64.zip`（191K）均生成成功；`--build-dir build/linux` 自动推断 `platform=linux-x86_64`。三个 `cjpm.toml` 经 Python `tomllib` 解析语法有效，`name` / `version` 数值未改动。
  - 决策记录与「何时重新评估 B/C」的触发条件见 `docs/15` §4.1 阶段 2。

### 新增（Q2 产品决策 · 用户拍板方案 A：存储可插拔骨架）

> **Q2 未关闭**：最终选型（自建 MinIO / 华为云 OBS / 本地 FS）仍待运维·甲方确认；本批落地的是 `docs/README.md` §六 Q2 表格写明的兜底方案，**不替业务方选后端**。

- **核查结论**：`StorageBackend` 接口 / 默认 FS 驱动 / `storage_backend` 列早已存在，但 `AMS_STORAGE_BACKEND` 与 `AMS_S3_*` 只在 `docs/02` 的示例 compose 里出现（代码零命中）、S3 驱动完全没有、`main.cj` 三处硬编码 `LocalFileStorage`、写入侧把 `storage_backend` 硬编码为 `0`。
- 新增 `packages/ams-storage/src/s3.cj`：`S3StorageConfig`（配置模型 + `fromEnv` / `validate` / `objectUrl`，支持 pathStyle 与 virtual-host）、`S3Transport` 注入接口、`UnavailableS3Transport`（失败关闭）、`S3ObjectStorage`（实现 `StorageBackend`，`backendCode()=1`）。对象键消毒按 **UTF-8 字符边界**处理，中文文件名不被切碎；阻断 `..` / 反斜杠 / 控制字符。
- `storage.cj`：`StorageBackend` 加 `backendCode()`（0=fs / 1=s3）；新增 `StorageBackends.make(root, purpose, transport?)` **唯一装配点**，默认 `fs` 行为零回归。`main.cj` 附件 / 导出 / 备份三处硬编码全部收敛；隔离区恒定本地 FS（保留 FR-ATT-007 物理分离）。
- `AttachmentRepo.create()` 加具名参数 `storageBackend!: Int64 = 0`（零回归），SQL 字面量 `0` 改 `?` 并调整索引；`AttachmentService` 落库传 `this.storage.backendCode()`。
- `docker-compose.yml` 加 `minio` 服务（`profiles: ["s3"]`）+ `ams-minio-data` 卷，**默认 `up -d` 不创建容器**；MinIO 凭据用 `:-` 默认值而非 `:?`，避免未启用 profile 时 compose 插值打断默认起栈。两个 env 模板补全 `AMS_STORAGE_BACKEND` / `AMS_S3_*` 注释示例。
- 新增 `packages/ams-storage/tests/storage/s3_test.cj` **16 例**：默认 fs 零回归、未知后端 / 缺配置 / 缺传输层失败关闭、配置与 URL 组装、键消毒（穿越 / 中文 / 控制字符）、注入内存 transport 的读写往返、工厂 s3 路径。`bash scripts/test.sh ams-storage` **28 通过 / 0 失败**。
- ⚠️ **如实边界**：这是骨架，不是可用驱动。AWS SigV4 / OBS 兼容签名依赖 **HMAC-SHA256**，而 `ams.crypto.impl` 明确返回「HMAC-SHA256 暂未接入」（SHA256 摘要可用），stdx HTTP 客户端在本仓只用过服务端 API。故设 `s3` 且未注入真实 transport 会**启动即失败关闭**（`StorageFailure`），不静默回落 FS、不以明文写入；注入 transport 后骨架可读写（单测验证）。选 B/C 前必须先补 HMAC-SHA256 + SigV4 传输层。
- **验证（全绿）**：`bash scripts/build.sh` **0 error** · `bash scripts/test.sh` **469 通过 / 0 失败**（较上轮 +16 = 新 `s3_test.cj`）· `npm run build` **EXIT 0** · Linux 全量构建 **0 error**（21M）· 镜像 `ams:1.2.1` 重建 **EXIT 0** · 默认栈 `up -d --force-recreate` **EXIT 0**：容器仅 `ams-server` + `ams_opengauss`（**无 minio**）、`/api/health` **200**、`routes="200"` 不变、无存储报错 → **默认 fs 零回归**。
  - `docker compose config --services`：默认 `ams/db/init`，`--profile s3` 才多 `minio`。
  - **失败关闭实测**（独立 `docker run` 连同一网络）：① 设 `s3` 但缺配置 → `RUN_EXIT=1`，抛「S3 配置不齐备…」，栈帧 `StorageBackends::make ← main.cj:426`；② 配置齐全但未注入传输层 → `RUN_EXIT=1`，抛「Q2 方案 A 仅提供 S3 驱动骨架：SigV4 依赖的 HMAC-SHA256 尚未接入…」。两道守卫均真实生效，无静默回落。

### 新增（Q2 扩展 · 多厂商 OBS 选择 + HMAC-SHA256）

> 用户要求：适配华为云 / 阿里云 / 七牛云等多家 OBS、提供平台选择接口、保留本地选项、补 HMAC-SHA256。**最终选型仍待运维·甲方确认，Q2 未关闭**。

- **HMAC-SHA256 落地**：`ams.crypto.impl` 原对 `DigestAlgorithm.Sha256` 的 HMAC 返回「暂未接入」；现按 **RFC 2104** 用已验证可用的 stdx `SHA256` 摘要原语自行构造（不赌 SDK `HashType.SHA256` 枚举是否存在），含 `key > 64B` 先哈希的分支。`impl_test.cj` 新增 **RFC 4231 四个标准向量**（Case 1/2/6/7）+ 长度 / 空 key / 算法隔离共 7 例，`ams-crypto` **33/33 通过**。
- **多厂商注册 `providers.cj`**：`StorageProviderProfile` + 8 个平台 —— `local`（默认、唯一完全可用）、`minio`、`huawei`（华为云 OBS）、`aliyun`（阿里云 OSS）、`qiniu`（七牛 Kodo S3 兼容网关）、`tencent`（腾讯云 COS）、`aws`、`s3`（通用）。每家带 endpoint 模板、region 样例、桶命名约束、默认寻址风格、签名协议、说明与文档链接。`AMS_STORAGE_PROVIDER` 优先，旧 `AMS_STORAGE_BACKEND=fs/s3` 兼容保留；MinIO 默认 path-style、其余云默认 virtual-host，profile 真的影响 URL（单测验证）。
- **SigV4 签名计算 `sigv4.cj`**：canonical request → string-to-sign → HMAC 链派生签名密钥 → Authorization 头，基于新补的 HMAC-SHA256；header 名自动小写 + 字典序排序 + 值 trim。`sigv4_test.cj` 用 **AWS 官方 GET Object 向量**验证（`Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41`），中间值（canonical hash / string-to-sign hash / signing key hex）由独立 Python `hashlib`+`hmac` 实现交叉生成；另测 PUT 场景与「SK 不进入任何结果」。`ams-storage` **51/51 通过**。
- **平台选择接口 `storageadmin.cj`**：`GET /api/admin/storage/providers`（8 平台清单 + 当前 / 已配置 / 是否需重启 + `ready` 标记）、`GET /api/admin/storage/config`（凭据脱敏）、`PUT /api/admin/storage/config`（`cfg:manage`，写 `deployment.env`，记 `ConfigChange` 审计且 detail 不含凭据）。**存量保护**：`AttachmentRepo.countAll() > 0` 时，改变 `provider`/`endpoint`/`bucket` 一律 `Conflict` 拒绝（旧 `storage_key` 会在新后端失效 = 静默数据丢失）；仅改凭据 / region / 寻址风格允许。配置写入后**需重启生效**，响应明确 `requiresRestart`。
- **配置同步**：`main.cj` 启动时只把 `deployment.env` 里**显式存在**的存储键同步到进程环境变量（`ams-storage` 按分层不能读配置文件/DB）；文件无该键时不覆盖，保留旧变量兼容与纯 env 部署（零回归）。
- **迁移 `025_storage_provider.sql`**：`arc_attachments` 加 `storage_provider VARCHAR(32) NOT NULL DEFAULT 'local'` + 索引（DO 块幂等，同 022）；不改 `storage_backend`(0/1) 语义，存量行回填 `local`。`create()` 与服务构造注入平台 code，每行附件自述厂商。
- **安全**：`DeploymentStore.SECRET_KEYS` 增加 `S3_SECRET_KEY` / `S3_ACCESS_KEY`，`redactedJson()` 不会泄漏对象存储凭据。
- ⚠️ **如实边界**：HMAC-SHA256 与 SigV4 **签名计算真实可用、有官方向量**；七牛自有 QiniuV2 / 阿里 OSS 自有 V1（HMAC-SHA1）明确标注「未实现」，本期只走各家 S3 兼容 + SigV4。平台选择目前是 HTTP API，尚无管理页 UI。
  - （补遗）`S3Transport` 的 **HTTP 客户端已于后续批次落地**：用 `std.net`（TcpSocket）+ `stdx.net.tls`（TlsSocket）自实现 HTTP/1.1 客户端，PUT/GET/DELETE 真正发出，404 → None、其余失败关闭。选非 `local` 平台在配置完整时即构建真实传输层（不再仅因缺 transport 启动即失败关闭），连接/签名/响应失败仍一律失败关闭。详见下方「真实 S3/OBS HTTP 传输层落地」。

### 新增（Q2 扩展 · 真实 S3/OBS HTTP 传输层落地）

> 把「只能签名、不能发请求」补成「选某家 OBS 即可真实读写」。SigV4 签名计算（前批次已具备）与真实 HTTP 传输层在此汇合为完整可用的对象存储驱动。

- **新增 `packages/ams-storage/src/http_transport.cj`**：`HttpS3Transport <: S3Transport`，基于 **`std.net`（TcpSocket / StreamingSocket）+ `stdx.net.tls`（TlsSocket）** 自实现 HTTP/1.1 客户端（http/https 均可用），不依赖对 `stdx.net.http` 的猜测。`request()` 组装请求 → SigV4 签名 → 建连（https 走 TLS 默认校验证书）→ 发送 → `readAll`（按 Content-Length / chunked / EOF 三种结束判定）→ `parseResponse`。
- **语义映射（失败关闭）**：GET 收到真实 **HTTP 404 → `None`**（对象不存在）；**200/204/206 → `Some(body)`**；其它状态码、连接失败、响应不完整一律抛 `AppError(StorageFailure)`，**绝不静默回落本地 FS 或明文写入、绝不把故障伪装成「对象不存在」**。`putObject` / `deleteObject` 也走同一守卫。
- **安全**：SK 只参与 HMAC 派生，不进日志 / 异常 / 任何非 Authorization 字段；TLS 不降级为明文。
- **`StorageBackends.make` 收敛**：非 `local` 平台且配置完整时构造 `HttpS3Transport.forConfig(cfg)`（不再仅因缺 transport 启动即失败关闭）；`s3.cj` / `providers.cj` 的历史「骨架 / 未发请求」注释同步修正，`UnavailableS3Transport` 收敛为「直接构造 `S3ObjectStorage` 不带 transport 时的失败关闭桩」。
- **`storageadmin.cj` 对齐**：`transportReady` 由硬编码 `false` 改为按平台能力计算（本地与对象存储平台均为 `true`），PUT/GET 配置接口提示改为「重启后按配置装配真实传输层、失败关闭而非静默回落」。
- **测试（两层）**：
  - `s3_transport_test.cj` **纯逻辑 11 例**（默认跑，不依赖外部）：URL 解析（http/https/默认端口/显式端口/virtual-host/中文编码）、RFC 3986 路径编码（保留 `/`、中文逐字节 `%XX`）、SigV4 `amzDate` 格式（`YYYYMMDDTHHMMSSZ` = 16 字符）、响应解析（200 取体 / 404→None / chunked 解码 / 非预期码失败关闭 / PUT 收 404 是错误不是 None）、连接被拒（`127.0.0.1:1`）失败关闭。
  - `s3_integration_test.cj` **可选端到端 1 例**：默认 `println("[SKIP]")` 跳过；设 `AMS_IT_MINIO=1` 且 `127.0.0.1:9000` 可达时真连 MinIO 做「建桶 → PUT（含中文/二进制）→ GET 原样 → GET 不存在→None → DELETE → 删桶」往返，证明签名 + HTTP + 响应解析真实可用。
  - `ams-storage` 单测 **64 通过 / 0 失败**（含集成测试跳过用例）。
  - ⚠️ **如实边界**：本会话内 Docker 镜像代理（xuanyuan.cloud）繁忙，**未能拉取 `minio/minio` 跑真实端到端往返**；该往返由 `s3_integration_test.cj` 实现并默认跳过，待镜像代理恢复后可用 `AMS_IT_MINIO=1 bash scripts/test.sh ams-storage`（或 `AMS_IT_MINIO=1 docker compose --profile s3 up -d` 起 MinIO 后）验证。其余纯逻辑用例已全绿，URL 解析 / 编码 / 响应解析 / 失败关闭语义均有覆盖。

### 安全收口（审查 🔴 修复 · 1.3.0 收口）
- **R1 · 租户配置机密泄漏面**：`TenantOpsRoutes.putSetting` 此前不接受 `isSecret`，导致经 API 写入的机密项 `is_secret` 恒为 FALSE，`listSettings` 的 SQL 掩码（`CASE WHEN is_secret THEN '***'`）对 API 写入的机密失效、明文回显。修复：`TenantOpsRepo.setSetting` 新增 `isSecret: Bool` 形参，INSERT 路径按调用方落库；UPDATE 路径保持不改 `is_secret`（避免更新值时误降级机密项）。路由解析 `isSecret` 字段（缺省 false），响应回显 `isSecret`。
- **R2 · 短信失败关闭**：`SpoolSmsProvider.send` 此前吞掉 spool 写异常仅记日志、绝不抛错，使短信投递故障对用户与运维不可见（fail-open）。修复：写失败改抛 `AppError(AppErrorKind.StorageFailure)`，交由 `Mailer.sendAlert` 以 best-effort 方式捕获并记 ERROR 日志（`sms.failed`，含原因），邮件 / 站内信不受影响 —— 故障可见、不静默降级；`SmsProvider` 接口契约改为「投递失败应抛错」。Noop/Console 后端不受影响。
- **R3 · i18n 三语覆盖收口**：补齐源码用到、但三语 catalog 与 `index.ts` 基线均缺的遗漏词条（含 10 个两段点键、4 个带 `{name}` 占位符的键如 `api.chunkedUploadFailed` / `componentsAttachmentPanel.uploaded` / `viewsArchiveView.batchTagged` / `componentsAttachmentPanel.uploadProgress`，以及 fr 缺的 `dp.today`），0 缺键、0 重复键；修正此前 catalog 生成器误插导致的漂移，zh-CN / en / fr 键集重新对齐（各约 1053–1055 键）。

---

## [1.2.1] — 2026-11-08（OCR 扩展 + 验证码加固 + 媒体水印修复 + 容器部署）

> 本批次属**工程化与交付能力**补强，不改动业务功能（FR 完成度仍为 P1 34 条 / P2 23 条）。
> 架构级两项（提炼通用框架、SaaS/微服务化）已在 `docs/15 §三` 拍板，并落地 **Phase 1**（见下方「新增（架构演进 · Phase 1）」）；Phase 2 已落地（见下方「新增（架构演进 · Phase 2 落地）」）。

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
- `docs/14-对外API规范-OpenAPI.yaml`：基于 156 个 method+path 自动提取生成的 OpenAPI 3.1 基线规范，含 Bearer 鉴权、通用错误包、按标签分组；request/response schema 暂以占位类型标记，待按后端 DTO 补全。

### 新增（信创·国家标准参考）
- `docs/13-信创与国家密码标准参考.md`：对齐国密 SM3（GB/T 32905 / GM/T 0004）、SM4（GB/T 32907 / GM/T 0002）、SM2（GB/T 32918 / GM/T 0003）标准，显式列出已实现（SM3 / HMAC-SM3 / SM4-CBC·CTR / PBKDF2-HMAC-SM3）与未实现（SM4-GCM 受 stdx 限制、SM2 未实现，导出签名用 HMAC 对称），并声明「代码对齐 ≠ 商用密码产品认证」边界。

### 新增（架构演进 · Phase 1 落地 — docs/15）

> `docs/15 §三`（2026-10-29）已拍板：通用框架 → **A 独立框架库**；SaaS 第一步 → **A 多租户单体**。本批落地两项 Phase 1。

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

### 架构演进候选方案（已拍板，见 docs/15 §三）
- `docs/15-架构演进路线-方案候选.md`：提炼通用开发框架（A 独立框架库 / B 仓内 shared / C 脚手架）与 SaaS/微服务化（A 多租户单体 / B 模块化单体 / C 完整微服务）的 A/B/C 方案与权衡；**Phase 1、Phase 2 均已落地（见上方 #87 框架发布化 / #89 跨租户回归）**。

### 修复

- **标签合并前端入口缺失（FR-TAG-003）**：后端 `POST /api/tags/:id/merge`（`mergeTag`，含「防合并到自身」校验）早已具备，但 `TagView.vue` 一直只有「改名 / 移动 / 删除」，没有合并 UI —— FR-TAG-003 此前实际只完成后端一半。现补「合并」按钮 + 目标标签下拉（排除自身与子孙，复用 `parentOptions`）+「确认合并」，与服务端环路/深度校验形成双保险。`cd web && npm run build` 类型检查 + 构建通过。

### 新增（A 方向 · 生产就绪收口）

> 本批次聚焦「生产就绪」收口：凭据安全、运维可操作性、回归覆盖与文档口径对齐。
> 以下列出工作方向，具体交付与验证结果以各文件与 CI 记录为准。

- **生产凭据门禁与 compose 必填变量**：引入 `AMS_ENV`（`dev` 默认 / `production`）；`production` 下
  `AMS_TOKEN_SECRET` / `AMS_KEK` / `AMS_DB_PASSWORD` 须由环境变量或部署配置显式提供，
  否则后端拒绝启动（SEC-001）；compose 中这三项改为必填（`:?` 语法），本地开发复制
  `deploy/compose/.env.example` 为 `.env`。
- **备份卷与运维手册**：备份卷与备份脚本，以及 `deploy/RUNBOOK.md` 运维执行手册。
- **CI 显式标注 E2E 跳过并接入更多回归**。
- **测试覆盖补齐** / **前端错误兜底** / **OpenAPI schema 补全** / **i18n 清理**。
- **文档与版本号对齐**：README / CHANGELOG / docs 索引中的工程数字、状态与版本口径。

#### 本批实际交付（2026-11-07）

- **SEC-001 凭据门禁**：`packages/ams-server/src/main.cj` 新增 `isProductionEnv()` 与启动期必填校验；
  `TOKEN_SECRET` / `KEK` / `DB_PASSWORD` 统一走 `DeploymentStore.resolve`（部署配置文件 > 环境变量 > 开发默认值）；
  compose 三个变量改 `:?` 必填并默认 `AMS_ENV=production`，新增 `deploy/compose/.env.example` 供本地开发；
  `server.boot` 版本号由硬编码 `0.1.0` 修正为 `1.2.0`，并输出 `env` 字段。
- **部署生产化**：compose 补 `ams-backups` 卷（db 与 ams 共用）、`mem_limit` / `cpus` / `json-file` 日志轮转；
  新增 `deploy/scripts/backup.sh` / `restore.sh`（gs_dump + sha256 + 二次确认恢复）、
  `deploy/RUNBOOK.md`（备份 / 恢复 / 升级回滚 / 监控 / 排障 / 已知生产缺口）、
  systemd 与 Windows 启动样例；`Dockerfile*` 版本统一到 `ams:1.2.1`。
- **CI 去假绿**：`ci.yml` 把 4 个静默跳过的 E2E 收口到 `scripts/ci/verify-e2e.sh`（7 组，含此前未接入的
  多租户隔离 / 家庭协作 / 审计链独立校验），未配 DB 时输出 `::warning::` 并在 Job Summary 标注 SKIPPED；
  新增 `scripts/ci/check-consistency.py` 静态门禁（迁移编号 / 路由前缀 / 分层方向 / i18n 死词条 /
  OpenAPI / 版本号 / compose 凭据 / workflow YAML），三个 workflow 均接入；
  `ci-linux.yml` 的占位 job 改为真实 preflight 门禁；前端 `npm test` 接入 CI。
- **测试覆盖**：新增 `ams-storage` 部署配置 12 例、`ams-api` 路由契约 4 例；前端引入 Vitest 并新增
  16 例（i18n / catalog / api client），`npm test` 纳入三件套门禁。
- **前端健壮性**：`main.ts` 新增全局 `errorHandler` 与 `unhandledrejection` 提示；
  19 条懒加载路由加 chunk 失败兜底 `LoadFailedView.vue`；新增 404 页 `NotFoundView.vue`；
  `SystemView` 五处静默 catch 改为可见提示；修 `::alt` 笔误与反引号 fallback；
  文档标题改走 `t()` 并补三语词条，切换语言后同步刷新。
- **OpenAPI 与 i18n**：`docs/14` 的 235 处 `UntypedObject` 占位全部清除，定义 16 个核心 schema
  （176 处转 `$ref`、57 处转结构化 object），新增 `scripts/ci/check-openapi.py` 校验；
  三语 catalog 清理 `${` / 反引号 / JS 表达式死词条、键集合对齐、补 zh-CN 缺失键、修 fr 自动探测，
  47 处动态文案调用点中 44 处改造成 `{name}` + vars（3 处为授权例外）。
- **文档收口**：README 工程数字、迁移数量、路由口径与版本号对齐实测值；`docs/07` 新增 v1.2.0
  视觉重构实现说明；`docs/12` / `docs/15` 状态行回写；补录 `[1.1.0]` 段落。

### 新增（能力边界转正 · 2026-11-07 第二批）

> 本批把此前登记的「能力降级交付」逐条转正，措辞如实：已交付什么、仍不能做什么分别写明，不写未验证的 PASS 数字。媒体能力全部在 `ams-server` 进程内由纯仓颉实现，没有独立 worker / 文件队列 / 额外容器。

- **OCR（FR-ATT-013）· 纯仓颉实现**：`packages/ams-core/src/media/` —— `png.cj` 自写 PNG 解码 / 编码（剥 zlib 头尾复用 stdx 裸 deflate；编码用 stored deflate 块，自实现 CRC-32 / Adler-32）；`ocr.cj` 灰度极值中点二值化 + 水平 / 垂直投影分割 + 5×7 内置点阵字模汉明匹配，识别等宽印刷体数字 / 大写字母；`pdftext.cj` 抽取 PDF FlateDecode 内容流的 Tj / TJ 字面字符串；`media.cj` 门面（缩略图、`MediaEngine.process`、像素水印）。单测 `packages/ams-core/tests/media/media_test.cj` **12/12 PASS**，`ams-core` 全量 **150 例 / 0 失败**。
  - **边界如实写**：不支持 CJK / 手写 / 复杂排版 / 倾斜校正 / JPEG / BMP / 图像型扫描 PDF；真实扫描件字体与内置字模差异大时识别率下降；文本型 PDF 直接抽文本，不走模板 OCR。
  - **不引入任何外部进程**：全部在 `ams-server` 进程内同步完成，保持「一个进程、一个端口」。
  - `scripts/media_worker.py` 保留为**离线参考实现 / 可选外部引擎**（自带 `--selftest` 12/12），**不参与运行时主链路**，不是系统依赖。
- **缩略图（FR-ATT-012）**：服务端生成 PNG 缩略图（`GET /api/attachments/:id/thumbnail`），前端优先取用、404 回落原图 CSS 缩放。
- **像素水印（FR-ATT-008）**：服务端把访问者 / 时间 / 追踪号烧进 PNG 像素（`GET /api/attachments/:id/watermarked`）；PDF 与不支持格式仍保留「签票 + 审计 + 前端叠加」。**仍不阻止截图 / 翻拍**，转正的只是「无法烧进像素」这一条。
- **短信（FR-NTF-005）**：`SpoolSmsProvider` + `deploy/scripts/sms-spool.sh` 真实 HTTP 网关投递（照搬 MailSpool 文件队列范式），默认关闭、需运维配置 `SMS_*`；`build.sh ams-app` 0 error、`test.sh ams-app` **36/0**。
- **图形验证码（FR-AUTH-011）**：纯字符串 SVG 生成（无图像库）、5 分钟一次性 challenge，登录失败 ≥3 / 注册 / 找回口令触发；10 个仓颉单测，`test.sh ams-api` **35/0**。**边界**：SVG 文本本质可被解析 / OCR，强对抗建议换图片 / 滑块；challenge 为单实例内存态，多副本需落库或共享存储。
- **接入与开关**：迁移 `023_media.sql` 为 `arc_attachments` 增 `ocr_text / ocr_status / ocr_engine / media_error` 四列；`AMS_MEDIA_ENABLED` 与 `AMS_OCR_CONSENT` 默认 `false`，**需同时为 `true`** 才自动处理（OCR 隐私显式同意）；`POST /api/attachments/:id/media` 可手动触发，另新增 `GET /api/attachments/:id/ocr`。全量 `build.sh` **0 error**、`test.sh` **381 通过 / 0 失败**，前端 typecheck / test / build 全绿。
- **E2E**：openGauss 容器在跑，新增 `scripts/ci/bootstrap-e2e.sh` 幂等自举夹具并修复 `scripts/ci/verify-audit.sh` 的 chain_seq 漂移，7 组真跑 **失败 0 组**（第 7 组审计链独立校验为 best-effort WARN，不阻断）。**如实写出**：第 5 / 6 组因注册强制 captcha，临时通过 `/tmp` shim 指向旧 exe 绕过（未改产品代码，属待办）；E2E 会写入测试账号，可用 `scripts/cleanup-test-accounts.sql` 清理。
- **备份**：新增异地复制 / 恢复演练 / cron 与 systemd timer 脚本，默认未启用，`deploy/RUNBOOK.md` 已同步。
- **npm audit**：9 个漏洞全部需 major 升级（vitest 2→5、vue-tsc 2→3），本批未修，理由记录于此，待单独排期回归。
- **架构**：媒体能力全部进程内完成，**没有**独立 worker / 文件队列 / 额外容器，因此不触碰 `docs/15` 方案 C 结论；A/B/C 决策与阶段 3 待办不变。

### 新增（JPEG 解码与 E2E 去 shim · 2026-11-07 第三批）

- **仓颉 baseline JPEG 解码器**：`packages/ams-core/src/media/jpeg.cj`，纯仓颉进程内实现 ——
  DQT / SOF0 / DHT / SOS 段解析、Huffman 解码、反量化、**定点分离式 2D IDCT**（预计算整数余弦矩阵，
  不依赖浮点 / Math.cos）、YCbCr→RGB、4:4:4 / 4:2:2 / 4:2:0 采样。`MediaEngine.process` 对 JPEG 分流，
  使 OCR / 缩略图 / 像素水印覆盖最常见的照片格式。单测 `jpeg_test.cj` 2 例（可控最小合法 JPEG：
  8×8 平坦灰 + PNG 往返），`ams-core` **152 例 / 0 失败**。
  边界：不支持渐进式 JPEG / 12·16-bit / 算术编码 / restart interval / CMYK·YCCK / 无损 JPEG。
- **captcha shim 根治**：新增 `scripts/ci/e2e_captcha.py`（黑盒 GET 验证码 → 从 SVG 解析答案 →
  注册携带 `captchaId/captchaCode`），改造 `bootstrap-e2e.sh` / `verify-tenant.py` / `verify-family.py`；
  `verify-e2e.sh` 整块删除 sitecustomize / `ams-server.exe.old` 回退。7 组 E2E 只用**当前构建产物**
  真跑 **失败 0 组**，日志无 `.old` / fallback / 答案明文。产品代码与生产验证码校验均未改动。
- **口径更新**：README / SECURITY / `docs/10` / 配置模板中「JPEG 不支持」改为「baseline JPEG 已支持」；
  第二批记录中该边界描述以本条为准（历史记录保留不改）。

### 新增（OCR 扩展 · 验证码加固 · 依赖治理 · 2026-11-08 第四批）

- **BMP 解码器**：新增 `packages/ams-core/src/media/bmp.cj`，纯仓颉进程内实现 —— BITMAPINFOHEADER / BI_RGB / 24·32·8 位（调色板）·1-bit、自下而上与自上而下两种方向、4 字节行对齐；明确拒绝 RLE 压缩、BITFIELDS、OS/2 COREHEADER、16-bit。单测 `bmp_test.cj`，已实测通过。
- **图像型扫描 PDF 支持**：新增 `pdfimage.cj`，字节级解析 `/Subtype /Image` XObject 与内联图像（BI…ID…EI），支持无滤镜 / DCTDecode / FlateDecode 与 DeviceGray / DeviceRGB、8-bit、Predictor 1/2；逐图失败只跳过该图、不中断整份 PDF。`MediaEngine.process` 改为「PdfText 抽不到文本 → PdfImage 抽图像 → 三路 OCR」，`ocrEngine` 记为 `pdf-image+<命中引擎>`。**边界**：不支持加密 PDF、ObjStm / XRef 流、CMYK、JPEG2000、CCITT、JBIG2、图像掩码；二进制流里出现 `EI` 字面量可能误判内联图像边界。
- **CJK 印刷体 + 手写风格数字 OCR**：新增 `glyphbits.cj` / `cjk.cj` / `hand.cj` 与生成数据 `glyphdata.cj`；`scripts/gen-media-glyphs.py` 在**构建期**用 Windows GDI 字体渲染生成点阵（220 个常用汉字 × 8 字体原型、10 个手写风格数字 × 9 原型），运行时**不需要**字体 / GDI / Python / 外部进程。算法为墨迹包围盒对齐 + ±1 位移容差汉明距离 + 断笔合并分字；`MediaOcr.recognizeAutoWithEngine` **三路路由**（5×7 印刷体 → CJK → 手写），返回实际命中引擎名。跨字体验收夹具（未参与训练的粗体 / 字体）已实测通过。**诚实边界**：只覆盖字典内 220 汉字与 10 个手写风格数字，是**字体点阵**而非训练模型；真实草书、生僻字、强倾斜、复杂排版、图像型 PDF 的高精度识别仍需外部模型；阈值来自跨字体夹具，真实扫描件泛化未验证。
- **渐进式 JPEG**：`jpeg.cj` 扩展 SOF2 —— 多 scan 全图系数缓冲、光谱选择、逐次逼近、EOB run、AC refinement；三份由 Windows GDI+ 验证过的最小合法夹具做单测，baseline 路径保持不变。仍拒绝算术编码、12 / 16-bit、CMYK / YCCK、无损 JPEG、DRI / restart、跨 scan 重定义量化表、AC 交错扫描（Ns>1）。
- **验证码抗自动化加固**：`captcha.cj` 的 SVG 改为**纯 path 轮廓**（内嵌点阵字模 + 旋转 / 倾斜 + 干扰线 / 噪点），不再含 `<text>` / `aria-label` / `data-*` / 答案明文；challenge TTL、一次性、3 次尝试、单实例内存态不变。**E2E 测试通道**：仅当 `AMS_ENV` 非 production / prod **且** `AMS_E2E_CAPTCHA_HINT=true` 时，响应附加 `devHint` 字段；生产环境**恒不返回**（由 `CaptchaStore.devHintAllowed` 持有保证，SEC-001 强制 production 显式凭据）。`scripts/ci/e2e_captcha.py` 只读该字段、缺失即清晰报错、不解析 SVG、不打印答案；`verify-e2e.sh` / `bootstrap-e2e.sh` 启动自建服务时显式设 `AMS_ENV=ci` 与开关，并回归断言「不带验证码的注册必须被拒绝」。**不重新引入** sitecustomize / `.old` / fallback。
- **npm audit 9 个漏洞已修复**：`vite ^6.0.7→^7.3.7`、`@vitejs/plugin-vue ^5.2.1→^6.0.10`、`vitest ^2.1.9→^5.1.0`、`vue-tsc ^2.2.0→^3.3.14`；`npm audit` 已为 **0 vulnerabilities**；`version 1.2.0` 与 scripts 未动。`AppSheet.vue` 因 vue-tsc 3 对模板 ref 不再计入使用而报的 TS6133 已用 `root.value` 守卫修正。
- **前端技术栈**：Vue 3.5 + TypeScript + **Vite 7**（不再是 Vite 6）；README 技术栈表、环境要求与已知限制已同步，历史「9 个漏洞未修」记录保留不改。

### 修复（媒体水印 · 版本对齐 · 部署启用 · 端到端验证）
- **媒体水印 UTF-8 崩溃**：`MediaOcr.render` / `upperByte` 此前对水印文本里任意非 ASCII 码点（如分隔符 `·` U+00B7、中文）构造单字节 `String.fromUtf8([0xB7])`，抛 `Invalid utf8 byte sequence`，导致手动 / 自动水印绘制整体失败（`ocrStatus=3`、`watermarked` 为空）。现对 ≥0x80（及负值）码点直接跳过（返回空串 → 字模 `indexOf=-1` 跳过该字），水印恢复可用；缩略图与 OCR 不受影响。
- **版本对齐（应用版本 → 1.2.1）**：`web/package.json` / `web/package-lock.json` / `packages/ams-server/src/main.cj`（`version` 启动日志）/ `deploy/compose/docker-compose.yml` 镜像 tag 统一升至 `ams:1.2.1`；部署文档（README / RUNBOOK / Dockerfile* / run-app.sh）示例 `docker build -t ams:1.2.1` 同步。Cangjie SDK / `cjc-version` / `SDK_VERSION` 的 `1.2.0` **未动**（属编译器基线，非应用版本）。
- **部署期启用媒体 / OCR**：运行期 `AMS_MEDIA_ENABLED=true` + `AMS_OCR_CONSENT=true`（隐私显式同意双开关）已在 `deploy/compose/.env` 打开并热重启 `ams-server`（镜像已验证健康、健康检查 1s、DB 池 51 连、媒体开关门禁满足）。
- **端到端验证**：新增测试账户 `e2e_ocrverify`（owner 角色，自动清理正则覆盖）用于功能验证；已完成「建主体 → 上传图片附件 → 自动 / 手动媒体处理 → 取 OCR / 缩略图 / 水印」全链路，并确认 5×7 / 220 汉字 CJK 点阵 / 手写数字三路 OCR 路由按设计工作（CJK 重文本退化为 `?` 属能力边界，非缺陷）。

## [1.2.0] — 2026-11-05（前端重构 + 首次部署向导 + 关于页）

> 本批次在前端 Apple 风格重构与容器化基础上，新增**首次部署向导**、**部署配置管理**
> 与 **SMTP 真实投递**（后端新功能），并补齐关于页与全站文案统一；
> FR 完成度仍为 P1 34 条 / P2 23 条，后端单测 338/0 不变。

### 新增（前端 Apple 风格视觉重构）

参考 Apple 设计语言对前端做了整体改版，目标是「简洁、高端、去 AI 味」：

- **`web/src/styles/theme.css`（设计令牌重构）**：配色改为 Apple 中性灰阶
 （`#f5f5f7` / `#1d1d1f`）+ Apple 系统蓝（`#0071e3`，暗色 `#0a84ff`）+ 系统级
  语义色（`#34c759`/`#ff9f0a`/`#ff3b30`）；阴影改双层 diffuse 柔影；新增
  `display`/`h1` 字号阶梯（clamp + 光学字距）、`--field-ring` 聚焦环、页面进入动效。
  保留全部既有变量名，组件零破坏。
- **三张认证页重做**（`LoginView` / `RegisterView` / `ForgotPasswordView`）：
  统一为全局 `.auth` 分屏 hero —— 左品牌大字标题 + 标语 + 要点（纯排版、单一
  强调色、无光斑），右认证卡；窄屏自动堆叠。逻辑/接口保持不变。
- **`App.vue` 外壳打磨**：品牌字标改为圆角方块「A」应用图标 + 字标，导航项
  间距/字重微调，顶栏 Apple 玻璃材质（`backdrop-filter`）承载层级。

### 新增（前端容器化部署）

- `deploy/docker/Dockerfile.web`：多阶段前端独立镜像（node:20 构建 →
  nginx:1.27-alpine 托管），含 SPA history 回退；仅托管 UI，`/api` 需后端。
- `deploy/docker/Dockerfile.web.prebuilt`：把宿主已产出的 `web/dist` 直接烤入
  `nginx:1.27-alpine`，**不拉取 Node、不联网**，构建秒级（离线 / CI 友好）。
- `deploy/docker/nginx.conf`：前端独立镜像的反代配置 —— `location /api` 反代到
  后端 `ams-server:8080`（同 `ams-net` 容器名直连），`location /` 做 SPA 回退，
  哈希资源 `max-age=31536000, immutable`，`/index.html` 不缓存，附 gzip 与安全响应头。
- `deploy/docker/Dockerfile.merge`：在既有 `ams:1.2.0`（已含后端二进制）之上叠加
  最新 `web/dist`，实现「前端并入后端镜像」—— 单镜像 / 单容器同时托管新 UI 与
  `/api/*`，刷新前端无需重新编译后端（旧 web 孤儿哈希文件无害）。
- 全栈编排 `deploy/compose/docker-compose.yml` 的 `ams` 服务默认 `8080:8080`，
  单一合并镜像同时提供 UI 与 `/api`（前端经 `Dockerfile.prebuilt` 或
  `Dockerfile.merge` 烤入 `/app/web`）。

### 修复

- **全局搜索遮罩只盖顶栏（视觉错位）**：`GlobalSearch` 的 `.mask`
  （`position: fixed; inset: 0`）被渲染在 `App.vue` 的 `.topbar` 内，而 `.topbar`
  设了 `backdrop-filter: blur()`，会为后代 `fixed` 建立**包含块**，导致遮罩只覆盖
  高约 50px 的顶栏、搜索面板错位。修复：在 `GlobalSearch.vue` 用 `<Teleport to="body">`
  把遮罩传送到 `body`，脱离含 `backdrop-filter` 的祖先，`fixed` 重新相对视口全屏。

### 增量 · 2026-11-05 二次设计调校 + 交互动效层

按 `apple.com` 当前站点实测参数做**全站完整重做**（不只是认证页），并补齐交互动画：

- **`theme.css` 重做**：卡片改为**零 box-shadow**（Apple 官网 73 个卡片实例无投影，
  层级靠 `#ffffff` 卡浮在 `#f5f5f7` 画布上的明度差）；交互元素统一 999px 胶囊、
  卡片 28px 圆角；正文 17px / `-0.022em` / 1.47，display 字阶 44–96px；
  字重阶梯收敛到 400 / 600 / 700（去掉 500）；`#0071e3` 仅给填充 CTA，
  行内链接另用 `#0066cc`；章节靠交替色带分隔而非硬边框；补齐
  `--bg-soft` / `--bg-base` 等别名，吸收组件里的硬编码 fallback 色值。
  保留全部既有变量名与类名，17 个业务视图零改动即继承新体系。
- **新增 `styles/motion.css`**（动效层，与静态视觉职责分离）：pointer-down 即时反馈、
  对称路径的路由转场、`.stagger` 交错入场、材质化弹层（blur+scale+opacity 同步）、
  导航选中指示条、顶栏滚动边缘效果、Toast/Sheet/进度条；
  全量支持 `prefers-reduced-motion`（降级为短交叉淡入，保留颜色反馈）、
  `prefers-reduced-transparency`、`prefers-contrast` 三类偏好。
- **新增 `composables/useReveal.ts`**：基于 IntersectionObserver 的 `v-reveal`
  指令（渐进增强：脚本不可用/减少动效时内容保持可见），`main.ts` 注册，
  `OverviewView` 的指标网格与两张卡片接入滚动显现。
- **`App.vue`**：两处 `RouterView` 接入 `<Transition>`；彩色 emoji（🔔/☀/☾）
  换成单色线性 SVG；顶栏按滚动状态浮现极淡边缘；品牌字标与导航按新令牌精修。
- **无障碍修复**：全仓 7 处 `::aria-label`（双冒号导致属性失效，屏幕阅读器读不到）
  已在 `App.vue` / `AttachmentPanel` / `DatePicker` / `ArchiveView` 修正为 `:aria-label`。
- **三张认证页**：补 eyebrow 标签、hero 交错入场、卡片统一浮现（移除各自 scoped
  里已失效的 `ams-enter-rise` 引用）；`GlobalSearch` 触发框改胶囊 + 线性放大镜。

> 视觉复核：无头 Chrome 以 1440×900 实截 `/login` 确认分屏、字距、胶囊按钮、
> 对勾图标与留白均正常，无重叠/截断/廉价装饰。

### 增量 · 2026-11-05 字体替换、列表显示修正与滚动性能

- **字体：MiSans 优先 + HarmonyOS Sans 兜底**。自托管 MiSans 可变字体
  （`web/public/fonts/misans/`，56 个 unicode-range 分片 / 4.6 MB，
  `font-weight: 150 700`，`font-display: swap`，离线与 Docker 可用）；
  `--font-sans` 依次为 `MiSans → MiSans VF → HarmonyOS Sans SC →
  HarmonyOS Sans → 系统字体`。`index.html` 预加载首片避免首屏字形回退闪烁。
- **修复中文边缘发虚**：`body` 的 `-webkit-font-smoothing: antialiased`
  在 Windows + Chrome 下会关闭 ClearType 子像素抗锯齿（中文笔画发灰发虚），
  改回 `auto`；同时移除 `text-rendering: optimizeLegibility`（中文下会引入
  不必要的 kern 调整）。另补 `--text-soft` 别名，消除组件里的无效变量引用。
- **档案条目行显示修正**（`ArchiveView.vue`）：`.item__main` 补
  `flex: 1 1 auto; min-width: 0`，解决标题/元信息被挤到卡片正中、与复选框和
  操作按钮不同基线；6 个元信息统一为「两枚语义胶囊 + 纯文字」，
  敏感度徽标由 `currentColor` 描边改为低饱和底 + 语义色文字；
  移除 `.item:hover` 的 `box-shadow` 过渡与 `:active` 整卡缩放
  （长列表滚动时鼠标连续掠过会触发昂贵重绘）。
- **弹窗底部裁切与滚动卡顿**（`AppSheet.vue`）：`.sheet-body` 补
  `flex: 1 1 auto; min-height: 0`，此前 flex 子项默认 `min-height:auto`
  不收缩，内容撑破 `max-height:86vh` 导致「保存」按钮被 `overflow:hidden`
  裁掉；`.sheet-head` / `.sheet-foot` 设 `flex: none`；移除面板与遮罩上的
  `backdrop-filter`（滚动时逐帧重算模糊是「钝」的主因），面板改不透明实底。
- **高帧率 / 滚动性能**（`motion.css` + `App.vue`）：细滚动条；
  长列表 `content-visibility: auto` + `contain-intrinsic-size` 跳过屏外渲染；
  滚动监听改为 `requestAnimationFrame` 合并每帧一次、仅在布尔值翻转时写 ref；
  滚动容器独立合成层。高刷（90/120/144Hz）下 CSS 过渡按时间插值，
  改动目标是消除主线程每帧重绘，而非硬改动画时长。
- **验证证据**：真实 Chrome（CDP）确认 `document.fonts.check('16px MiSans')`
  为 `true`、声明 56 个分片但首屏仅按需加载 13 个、标题计算样式为
  `MiSans / 80px`、`-webkit-font-smoothing: auto`；条目行与弹窗的 flex 修复
  用**本地模拟布局页**（`.tmp/layout-check.html`）在真实浏览器截图验证，
  非业务页真实数据验收。

### 修复 · 2026-11-05 字体锯齿/发虚（根因：GPU 合成层）

用户反馈业务页 11–12px 小字（权限点徽标、审计日志、密钥说明）仍有锯齿。
CDP 实测定位到**不是字体文件问题，而是文本被抬进 GPU 合成层**：
Chrome 在合成层上禁用 ClearType 子像素抗锯齿、改走灰度 AA。
诊断证据（`/login`，dpr=1，MiSans 已加载、smoothing=auto）：
文本元素自身带 `transform` 的有 **3** 个、祖先链带 transform/filter/backdrop-filter
的有 **12** 个，`.auth__headline` 的 computed transform 为
`matrix(1,0,0,1,0,0)` —— 入场动画 `animation-fill-mode: both` 把
`translate3d(0,0,0)` 永久保留了。

- **动画**：`motion.css` 所有入场动画 `fill-mode` 由 `both` 改为 `backwards`，
  动画结束后 transform/filter 归零；`ams-scrim-in` 去掉 `backdrop-filter` 变化，
  遮罩只做 opacity 淡入；`[data-reveal]` 去掉 `will-change`，
  `.is-visible` 的 `transform` 改为 `none`（不能写 `translate3d(0,0,0)`）。
- **弹窗**：移除 `AppSheet` 的 `.sheet-body { transform: translateZ(0) }`
  （滚动流畅已由「去 backdrop-filter + 头尾固定 + content-visibility」保证）。
- **玻璃层改实底**：`App.vue` 顶栏/侧栏、`ToastHost`、`.batchbar` 去掉
  `backdrop-filter`，改用 `--bg-surface` 实底 + 边缘线/柔影表达层级。
  保留 `<Teleport to="body">` 作为防御（未来任何祖先带 transform 仍会重演
  fixed 包含块问题）。
- **小字可读性**：14 个文件里硬编码的 `font-size: 11px` 统一提到设计下限
  `12px`；浅色 `--text-muted` 由 `#86868b`（白底约 3.5:1，低于 WCAG AA）
  加深到 `#6e6e73`（约 4.9:1）。
- **复测证据**：同一 CDP 脚本 reload 后，自身带合成层的文本元素 **3 → 0**、
  祖先链带合成层的 **12 → 0**，标题 transform `none`，MiSans 仍正常加载；
  登录页实截与 12px 三栏字体对比页（MiSans / HarmonyOS Sans SC / 雅黑）
  均未再见点阵感或发虚。
- **权衡说明**：去掉玻璃模糊会损失一点材质通透感，换取中文小字的
  ClearType 锐利度与滚动帧率；这是针对 Windows + Chrome 的显式取舍。

### 新增 · 2026-11-05 首次部署初始化与部署配置

- **删除测试账户**：清理 `tpl_probe_01` 演示账号及 161 个 E2E/压测账号
  （`scripts/cleanup-demo-data.sql`、`scripts/cleanup-test-accounts.sql`，均幂等）。
  系统表 `sys_roles`(9) / `cfg_settings`(11) / `sys_perms`(40) 与审计表完整保留；
  账号清单备份于 `.tmp/users-backup-20261105.txt`。删除 `deploy/DEMO_ACCOUNT.md`。
- **首次部署向导** `/setup`：四步（数据库 → 创建管理员 → 邮件服务 → 完成）。
  后端新增公开接口 `GET /api/setup/status`、`POST /api/setup/test-db|database|mail|test-mail|admin`；
  仅在「无管理员且未初始化」时开放，创建管理员后写 `SETUP_INITIALIZED=true` 永久关闭，
  重复调用返回 403。首个账号自动授予 `owner` + `org_admin`。
  前端路由守卫按 `/setup/status` 缓存引导，旧后端无该接口时按「已初始化」处理（零回归）。
- **部署配置体系**：新增 `ams-storage` 层的 `DeploymentStore` / `MailSpool`。
  配置落在容器持久卷 `/app/config/deployment.env`（`KEY=VALUE`，按首个 `=` 切分）；
  **文件里没有的键继续读环境变量**，`ServerConfig.load()` 合并后启动，既有部署零回归。
  管理页「系统运维 → 部署配置」通过 `GET/PUT/DELETE /api/admin/deployment/*`
  （`system:admin`）读写数据库 IP/端口/库名/用户名/口令与 SMTP 配置，
  提供测试连接、发送测试邮件、恢复环境变量默认。数据库配置保存后重启生效。
- **SMTP 真实投递**：`Mailer` 在启用邮件时额外写 `.eml` 到 `ams-mail` 卷，
  `deploy/scripts/mail-spool.sh`（随镜像分发）用 `curl smtps://` 真实投递并移出队列。
  不引入仓颉网络库/子进程 API，保持单容器部署；未启用时行为与旧版一致（只入队）。
  支持 SSL(465) / STARTTLS(587)、账号口令、发件人配置；测试邮件可在管理页触发。
- **顺带修复**：全仓 5 个视图的 `::title` 双冒号写回 `:title`（此前 AppSheet 标题 prop 失效）。
- **验证证据**：Linux 后端编译 39 包全绿；`bash scripts/test.sh` **338 例 0 失败**
  （同时内嵌 `build.sh` 成功、`error:` 计数 0、产出 `build/ams-server.exe`）；`npm run build` 0 error；
  `/api/setup/status` 返回 `initialized:false` 且口令脱敏；`test-db` 真实连库 `ok:true`；
  创建管理员→登录→`/api/admin/deployment`→重复创建 403 全链路通过（验证账号已回滚）；
  `/setup` 无头 Chrome 实截正常；容器 `ams-server` 8080 healthy。

### 修复 · 2026-11-05 健康看板「运行时长」显示源码片段

- **现象**：运行时长卡片显示字面量 `${m} 分 ${s % 60} 秒`，其余指标正常。
- **根因**：i18n 目录由 codemod 自动抽取，把 `` `${m} 分 ${s % 60} 秒` `` 这类
  **JS 模板字符串原样**当成译文写进 `catalog.zh-CN/en/fr.ts`；`t()` 是纯查表、
  不做插值，运行时直接返回词条里的源码片段。这不是后端 `uptimeMs` 的问题
  （后端 `system.cj` 输出的是裸数字 JSON）。
- **系统性排查**：三个语言包各有 47 条含 `${` 的死词条，源码 42 处动态文案调用；
  全仓交叉复核确认 42 条调用点**全部传了 fallback**，另 4 条为无引用的孤儿词条。
- **修复**：
  1. `web/src/i18n/index.ts` 的 `t()` 增加防御：词条值含 `${` 时回退到调用点
     已插值的 fallback，一次覆盖全部 42 处动态文案（toast / 确认框 / aria-label），
     静态词条与正常翻译不受影响；
  2. `viewsSystemView.b0ec90` 三语词条改为 `{m}` / `{s}` 占位符，新增
     `viewsSystemView.uptimeHours`（`{h}` / `{m}`），`SystemView.vue` 的
     `fmtUptime()` 用 `.replace()` 完成插值，并补 `Number.isFinite` 与负值保护
     （异常值显示 `—` 而非 `NaN`）；≥1 小时的分支也纳入多语。
- **验证**：用真实源码（`.vue` 提取的 `fmtUptime` 函数体 + 真实 `i18n` 模块）
  在 Node 中跑三语 × 9 组边界值：`16 分 5 秒` / `16 min 5 s`，无 `${`、无残留占位符；
  7 条同类死词条回退正确、fr 静态词条仍正确翻译；`npm run build` 0 error；
  镜像内 `SystemView` chunk 含 `uptimeHours`、旧字面量 0 处；容器 8080 healthy。
- **说明**：`t()` 防御会让 en/fr 下这 42 条动态文案回退为中文（原本显示的是坏掉的
  `${...}`，属改善）。若要三语完整翻译动态文案，需把每条词条改为命名占位符并
  逐个改造调用点，作为独立一轮处理。

### 新增 · 2026-11-05 关于页面与全站文案统一

- **独立「关于」页** `/about`：集中呈现项目简介、版本号、发布日期、许可证、
  技术栈、作者信息与相关链接；入口在侧栏底部「其他」分组及移动端顶栏
  （顺带补齐移动端缺失的「标签」入口）。
- **可配置字段与占位**：新增 `web/src/config/about.ts` 作为唯一内容入口。
  简介 / 标语 / 发布日期 / 作者姓名 / 身份 / 邮箱 / 技术栈 / 全部外链均在此配置。
  **未提供的信息留空字符串**，页面统一显示「待补充」「待配置」；
  未配置的外链渲染为不可点击的占位项（不产生死链），填入后自动切换为可跳转。
- **已接入跳转**：GitCode、GitHub 仓库主页与爱发电
  `https://ifdian.net/a/a703201`，均带 `target="_blank" rel="noopener noreferrer"`；
  另留「项目文档」「反馈与建议」两个待配置入口。
- **版本号单一事实来源**：`web/package.json` 与 `package-lock.json` 统一为 `1.2.0`
  （原 1.0.0 / 0.2.0 三处漂移，与 `CHANGELOG [1.2.0]` 对齐），关于页直接读取 `pkg.version`。
- **全站文案润色**（源码 fallback 与三语目录同步，共 96 处精确替换，逐条断言命中）：
  - 术语分工：用户登录凭据统一「口令」（登录 / 注册 / 找回 / 修改 / 重置），
    技术凭据保留「密码」（数据库、SMTP、共享链接访问密码），密钥材料仍称「密钥」；
  - 账号标识统一「用户名」；检索动作统一「搜索」；空态统一「暂无 X」；
  - 软删除在 `ArchiveView` 的标题 / 确认句 / 按钮统一「移入回收站」；
    `RolesView` / `TemplateView` / `UsersView` 的真删除按钮保持不变（避免误伤）；
  - 表单主动作统一「保存」，去掉「+ 新建 X」的加号前缀，
    进行态改为「注册中 / 重置中 / 保存中 / 导入中 / 应用中…」，返回入口统一「返回登录」；
  - 修正含糊与矛盾：敏感配置掩码两处口径统一、去掉模板里泄漏的 `**` 与反引号、
    「错误过多」→「邀请码输错次数过多」、「主体ID」→「主体 ID」、
    「第一条记录」→「第一条档案」、登录/注册失败兜底提示补上对象；
  - 清理注释里假的 `t()` 调用及其污染词条「懒得展示」。
- **补三语文案**：关于页 17 个界面键 + 3 个导航键，zh-CN / en / fr 全部补齐。
- **验证**：`npm run build` 0 error；CDP 实截 `/about`（4 卡片 / 3 个真实外链 /
  2 个占位项 / 侧栏入口 / v1.2.0）与登录页（确认「口令」术语）；
  真实 `t()` 源码验证三语 19 键全命中；Docker 单容器 8080 healthy。

### 调整 · 2026-11-05 作者信息精简

- 按用户确认移除「署名与账号」「身份」两个字段：`AboutConfig.author` 接口、配置值、
  页面两行 `dt/dd`、`hasPending` 判断与 zh/en/fr 三语词条一并清理，全仓 grep 无残留。
- 作者改为 **何宇翔**，联系邮箱改为 **Lumio_a7032@qq.com**，均落在 `web/src/config/about.ts`。
- 占位说明同步改为「未配置的地址显示「待配置」，留空的字段显示「待补充」……」，
  避免页面上已无「待补充」却仍提示该词。
- **验证**：`npm run build` 0 error；CDP 实截作者卡仅剩两行、姓名与邮箱完整无截断；
  三语 17 键全命中；`Dockerfile.merge` 重建 + compose 重启，容器 8080 healthy。

### 文档

- 本文件新增 `[1.2.0]` 条目与上述若干增量段落。
- `deploy/README.md`：目录树补充 `Dockerfile.web` / `Dockerfile.web.prebuilt` /
  `Dockerfile.merge` / `nginx.conf`，新增「§2.1 前端独立镜像」「§4.4 前端并入后端
  镜像」与 nginx 反代说明。
- `docs/09-部署与发布指南.md`：新增「§6.1 可选 · 独立 nginx 前端容器」说明反向代理
  `/api` 到后端的多容器形态。
- `README.md`：当前状态补充「前端已重做为 Apple 风格」说明。
- ⚠️ **历史待办（2026-11-07 已收口）**：`docs/07-视觉与交互设计规范.md` 为改版前的设计基线，本次视觉重构
  未回写该文档；如需对外一致，应安排一次 `docs/07` 与实现的对齐刷新。

### 工程化 · 发布流程（二进制 Release + CHANGELOG 作为说明）

> 发布形态决策：本批次曾于 2026-11-05 把 `release.yml` 改为「源码包上传」，后于
> 2026-11-06 按需求改回「**推送 tag → 自动编译后端 → 发布二进制程序 Release**」，
> 并使 Release 说明直接取自更新日志（CHANGELOG）。

- **`.github/workflows/release.yml`（tag 触发，二进制发布）**：
  - 触发：`push` 形如 `v*` 的 tag，或手动 `workflow_dispatch`。
  - 流程：`setup-toolchain.sh` 准备仓颉 SDK → `build.sh` 编译后端 → `test.sh` 单测
    → `package.sh` 打包 `ams-release-<v>-windows-x86_64.zip` → `verify-package.sh`
    校验可独立运行 → 上传到 GitHub Release（复用 / 新建 Release）。
  - **Release 说明（notes）**：自动从 `CHANGELOG.md` 提取 `[<v>]` 对应版本段落。
  - runner：`windows-latest`（GitHub 托管）+ 仓库变量 `CANGJIE_TOOLCHAIN_TAG` /
    `CANGJIE_SDK_URL` 提供工具链；若用已装 SDK 的自托管 Windows runner，改 `runs-on` 即可
    （`setup-toolchain.sh` 检测到已装会跳过下载）。
- **`.github/workflows/ci.yml` 末尾两步**：恢复「打包校验 / 校验发布包可独立运行」
  （`scripts/package.sh` + `scripts/ci/verify-package.sh`），与发布形态一致；
  顶部流程注释同步改回「打包校验」。
- 因 workflow 恢复二进制形态，与 `docs/09`、`README` 发布章节及 `scripts/release.sh` /
  `package.sh` / `verify-package.sh` 的二进制描述重新一致；此前「待同步」提醒作废。

### 工程化 · CI 工具链修复（修复发布流水线编译失败）

> 推送 `v1.2.0` 后 `release.yml` 的「构建」步骤失败（opt.exe 报
> `0xC0000135` DLL not found），根因有二，均已修复：

- **stdx 路径双重拼接**：`setup-toolchain.sh` 输出的 `CANGJIE_STDX` 已含
  `/dynamic/stdx`，而 `build.sh` 又拼接一次，导致 `.../dynamic/stdx/dynamic/stdx`
  目录无效（warning 且 stdx DLL 复制为空）。改为 `setup-toolchain.sh` 输出
  **根目录**（`.../windows_x86_64_cjnative`），与 `build.sh` 契约一致。
- **MinGW 运行库缺失 + PATH 未注入**：仓颉 SDK 的 `third_party/llvm/bin/`（opt.exe 所在）
  缺 `libgcc_s_seh-1.dll`，且 CI runner 的 PATH 不含 SDK 目录，故 opt.exe 加载失败。
  - `setup-toolchain.sh`：MinGW DLL 补齐从「仅 SDK 根 bin」扩展为「SDK 下
    **所有 bin 目录**」（含 `third_party/llvm/bin`），并把 `${SDK_HOME}/bin` 与
    `${SDK_HOME}/third_party/llvm/bin` 追加到 `GITHUB_PATH`。
  - `publish-toolchain.sh`：打包前同样把 MinGW DLL 补齐到 SDK 源目录下所有 bin 目录，
    使工具链 Release 资产自带完整运行时。

---

## [1.1.0] — 2026-11-03（前端 Apple 风格改版 + 前端容器化部署）

> 该版本对应 git tag `v1.1.0`（2026-11-03）。发布时未在本文件单独记录，现于 2026-11-07
> 依据 git 事实补录：本地无 `v1.0.0` tag，对比基线取 v1.0.0 对应的 merge commit `ba43705`；
> `git log ba43705..v1.1.0 --oneline` 得 `0289025`（feat）+ `5fc6368`（merge），
> `git show --stat v1.1.0` 计 15 个文件变更、987 insertions / 726 deletions，均为前端与部署侧。

- **前端 Apple 风格改版**：`web/src/styles/theme.css` 设计令牌重构为 Apple 中性灰阶 / 系统蓝；
  登录 / 注册 / 找回口令三页重做为分屏 hero；`web/src/App.vue` 外壳打磨。
- **前端容器化部署**：新增 `deploy/docker/Dockerfile.web`、`Dockerfile.web.prebuilt`、
  `nginx.conf`（`/api` 反代后端 + SPA 回退）、`Dockerfile.merge`（前端并入后端镜像）；
  同步更新 `deploy/README.md`、`deploy/compose/docker-compose.yml`、`docs/09`、`README.md`。
- **修复**：`GlobalSearch` 遮罩只盖顶栏 —— 用 `<Teleport to="body">` 脱离 `.topbar` 的
  `backdrop-filter` 包含块。
- 该版本无后端功能改动。上述视觉重构与容器化在 `[1.2.0]` 段落另有更细的增量记录
  （二次调校、动效层、字体替换、部署向导等）；本段仅补录 `v1.1.0` 相对 `v1.0.0` 的增量。

---

## [1.0.0] — 2026-10-31（首个正式版）

P1 需求逐条落地并在 `127.0.0.1:8080` 实跑验证：**34 条中 33 条实现、1 条降级交付、0 条未做**（详见 `docs/10-实现状态核对.md`）。
P2（23 条）累计 **23 条实现 / 0 条评估中（FR-IMP-005 已按方案 C 落地）**，台账见 `docs/10-实现状态核对.md`。

### 新增（家庭成员邀请 · FR-ACL-010 · 方案 B）

按 `docs/12（方案评估）` 的推荐结论完整落地：**主体 + 条目两级授权**（分类降级为「同主体内按分类收窄」）、**不做**邀请审批流、**3 批**推进。

- **迁移 `019_family_collaboration.sql`**：4 张新表 `fam_groups`（组）、`fam_members`（成员，含 `my_role` / `removed_at` / `removed_by`）、`fam_invites`（邀请，只落 code/token 摘要）、`fam_grants`（授权 → 组 的**侧表**）。种子权限 `family:manage` / `family:invite` 授予 `owner` 与 `curator`（规则：能建/改自己主体的人才能建组；`user` 角色在本系统不存在，曾误写导致除 `owner` 外谁都建不了组，详见下方「修复」）。
  > **为什么加侧表而不是给 `acl_grants` 加一列 `group_id`**：openGauss **不支持** `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`（实测 `ERROR: syntax error at or near "NOT EXISTS"`）。项目约定「每个迁移必须可反复执行」（`scripts/db.py exec` 与 CI 都依赖这一点），该 ALTER 无法写成幂等语句。用侧表既保住幂等，也不让核心 ACL 表承担可选能力的新列。理由写进了迁移文件头。
- **`ams.core.family`（纯逻辑，零 IO）**：`InviteCode`（32 字符表 `23456789A-HJ-NP-Z`、8 位 = 40 bit 熵、掩码取低 5 bit 而非取模以避免偏置、`normalize` 去空白/连字符/下划线并转大写、`isWellFormed` **在查库前**先拒乱输）、`InviteState`（Usable/Revoked/Expired/Exhausted/TooManyFails，判定顺序 **撤销 > 失败超限 > 过期 > 用尽**）、`InviteLimits`（默认 15 分钟 / 1 次 / 5 次失败；上限 1440 分钟 / 10 次）、`InviteSnapshot.stateAt()`（三个入口共用同一判定，避免「列表显示有效但接受时报无效」）、`FamilyRole`（未知角色**降级为 Member**；Manager 不能移除 Manager/Owner，否则被提升的人可以把管理层踢空再独吞）、`GrantScope`、`PermSubset`。
- **`ams.data.repo` 四个 Repo**：`FamGroupRepo` / `FamMemberRepo` / `FamInviteRepo` / `FamGrantRepo`。两处原子性设计：
  - `consumeOnce` 把「未撤销 + 未过期 + 次数未用尽 + 失败未超限」四个条件压进**一条 UPDATE 的 WHERE**，由行锁保证「并发 accept 10 次只成功 1 次」；
  - `bumpFail` 复用共享链接同款「自增 + 判定 + 撤销」一条语句（用更新前的值判定），避免进程在自增与撤销之间被杀而白送一次尝试。
  - 成员视角只读出口 `listSharedItems` / `countSharedItems` / `canReadItem` 共用同一个 `sharedPredicate()`，三处逐字一致（否则分页会错乱）。
- **`ams.app.family.FamilyService`**：建组（立刻写入 owner 成员行，否则组变孤儿）、创建邀请（`prov.randomBytes(24)`：前 8 字节给 code、后 16 字节给 token；**邀请不能直接产出第二个 owner**，`targetRole=owner` 降为 `manager`）、接受邀请（token 定位 → 状态有效 → code 正确 → **原子 consumeOnce** → join；已入组走**幂等分支且不消耗次数**）、公开落地页元数据（失效时 `valid=false` 且**不返回组名**）、建授权（三重校验：组内 owner/manager + 必须拥有该主体 + 被授权人必须是组成员；条目级还要校验条目确属该主体）、移除成员（级联撤销授权）。
- **`FamilyRoutes`（15 条路由）**：公开 1 条（`GET /api/family/invites/:token`）、登录即可 6 条、`family:manage` 4 条、`family:invite` 5 条。
  > **`/api/family/shared-items` 为什么不挂功能权限**：新注册账号默认无任何角色（默认拒绝是刻意设计），而 `docs/12 §3 T3` 又明确「入组不改变全局权限」。若这条只读出口也要求 `archive:read:own`，家人必须先找管理员开角色才看得到东西 —— 功能等于不可用；若为此自动写 `sys_user_roles`，就违背了 T3。故单开一条「只认 `acl_grants`、不认角色」的通道：一条多余的数据也读不到，且**不提供任何写/删/导出/分享操作**。
  > 审计 detail **只写 ID 与计数，绝不写 code/token 明文**。
- **`ItemRepo.list/count` 授权下推（B2，`docs/12（方案评估）` §6 标记的全局风险点）**：新增 `granteeId` 参数，把授权范围下推为 SQL 条件 `EXISTS (SELECT 1 FROM acl_grants g WHERE g.grantee_id = ? AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > CURRENT_TIMESTAMP) AND (g.item_id = arc_items.id OR (g.item_id IS NULL AND g.subject_id = arc_items.subject_id AND (g.category IS NULL OR g.category = 0 OR g.category = arc_items.category))))` —— **与 `Grant.covers()` 逐条对齐**，不允许「列表能看到、详情打不开」这类两套口径。
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
- **家庭成员邀请 · 安全设计（FR-ACL-010）**：交付 `docs/12-家庭成员邀请.md（设计章节）`（10 项安全原则、`fam_groups/fam_members/fam_invites` 数据模型、邀请码 vs 二维码取舍、14 项威胁模型 T1–T14、10 个审计动作码、完整 API 草案、统一错误语义、F1–F4 分批计划）。当时三处待定项（§6 授权粒度、§13 R6 审批流、§14 批次范围）已在 `docs/12（方案评估）` 给出推荐结论，后续按该结论完整落地，详见上方「新增（家庭成员邀请 · FR-ACL-010 · 方案 B）」。
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

- **新增 `docs/12（方案评估）`**：针对 FR-ACL-010 三处待定项（§6 授权粒度 / §13 R6 审批流 / §14 分批范围）各出 A/B/C 三案 + 推荐 + 成本表，结论为 **§6 采方案 B（主体 + 条目两级，分类降级为同主体内收窄）**、**§13 R6 不做（邀请本身即双人确认）**、**§14 由 4 批压缩为 3 批**。评估前先做了一次**代码现状审计**，5 条硬事实推翻了设计文档里的若干隐含假设：① `acl_grants.subject_id` 是 `NOT NULL`（分类级授权无法表达「不限主体」）；② `Grant.covers()` 连分类授权也要求主体一致（跨主体分类授权恒不命中）；③ `ItemRepo.list/count` 完全不查 `acl_grants`，FR-ACL-008 只是「详情能用、列表/检索/导出仍全量」的半成品；④ `custodian_ids` 有列有读路径但**全库无写路径**（主体级共享反而最便宜）；⑤ 列表下推要改 6 个入口，必须先收敛出统一 `AccessScope`。
- `docs/12-家庭成员邀请.md（设计章节）` 在 §6.1 字段级说明后、§13 R6 行、§14 门槛说明后、结语共 4 处加了指向 `docs/12（方案评估）` 的指针，避免读者按未定稿的粒度直接开工。
- **新增 `README.md`**（项目门面）：目录 / 这是什么 / 当前状态（P0 54/54、P1 33+1 降级、P2 15/23，附工程面统计：115 个 `.cj` 3.76 万行、29 个 vue-ts 1.24 万行、19 个迁移、152 条路由、272 条单测）/ 功能一览 / 技术栈与九层单向依赖图 / 安全设计要点（国密落地实况：SM3 ✅、SM4-CBC/CTR ✅、SM4-GCM ❌ 已改 EtM 等价构造、SM2 ❌ 未实现）/ 快速开始 / 常用脚本 / 目录结构 / 文档索引 01–15 / 已知限制 / 参与开发 / 许可证。
- **采用 Apache-2.0**：新增 `LICENSE`（全文与官方文本逐字一致，仅填入 `Copyright 2026 何宇翔 (a703201)`），`web/package.json` 补 `license` 字段。选 Apache-2.0 而非 MIT 的唯一决定项是**第 3 条明示专利授权**：本项目含国密实现与权限模型等可能被主张专利的部分，MIT 对此完全沉默，Apache-2.0 能让使用方获得明确的专利许可、并以第 3 条终止条款对冲专利诉讼风险。
- `docs/README.md` 索引从 01–10 补齐到 01–15，状态行由「设计阶段（尚未进入编码实现）」改为当前实现进度。
- `docs/10-实现状态核对.md` 的 FR-ACL-010 行补 `docs/12（方案评估）` 指针。
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
- `docs/10-实现状态核对.md` 更新为收口状态（含每条实测证据与唯一降级项的说明），新增 §2.6.1 记录审计哈希链复核的 5 处缺陷、定位方法与验证证据；§2.7.1 记录 ZIP 批量导入的可行性探针、实现要点与 7 个夹具的验收结果；同时修正 §1 摘要与全表统计不一致（20/14 → 33/1/0）。
- 新增 `scripts/gen-gbk-table.py`：从 Python `gbk` 编解码器生成 87×94 GBK→Unicode 码表（仓颉侧 `gbk.cj`）。
- 新增 `scripts/verify-audit-chain.py`：审计链离线独立校验（不信任服务端）。

### 已知限制

- FR-ATT-008 水印为「可视覆盖 + 审计可追溯」，非像素级烧写（SDK 无图像编解码/PDF 内容流库，能力边界）。
- ZIP 批量导入的**单个压缩包 ≤ 64 MiB**、单批 ≤ 500 个文件。请求体在鉴权之前就被读入内存，故上限按路径分档放宽（附件与批量导入 64 MiB，其余 1 MiB），不做流式入库；超出需拆包分批（前端已在选包时拦截并提示）。

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

- 新增 `docs/10-实现状态核对.md`：逐条以代码为准核对 54 条 P0（结论 54/0/0），记录接线审计（§7.11）、D2/D4 落地（§7.12）、测试套件红态发现与修复（§7.13）。
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


[1.2.0]: https://github.com/a703201/Personal-Archive-Management-System/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/a703201/Personal-Archive-Management-System/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/a703201/Personal-Archive-Management-System/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/a703201/Personal-Archive-Management-System/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/a703201/Personal-Archive-Management-System/releases/tag/v0.1.0
