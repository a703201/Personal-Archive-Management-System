# ams-kit · 通用开发框架（静态库分发）

> **发布用途文档**。开发侧约定见仓库根 `docs/`；本文随框架发布包分发，面向**接入方**。
> 架构决策记录见 `docs/15-架构演进路线-方案候选.md` §4.1。

## 1. 分发形态（方案 A，2026-11-08 已决策）

`ams-kit` 以**静态库 + Cangjie 接口快照**打包分发，随 GitHub Release 发布：

```
ams-kit-<version>-<platform>/
├── lib/       lib<包名>.a     静态库
├── cjo/       <包名>.cjo     编译单元接口快照（cjc --import-path 用）
├── LICENSE                   Apache-2.0（必须随包分发）
├── README.md                 本文
├── VERSION
├── MANIFEST.txt              依赖闭包 / 版本 / 逐文件 sha256
└── CHECKSUMS.sha256
```

**本包不是 cjpm 包，请勿执行 `cjpm build` / `cjpm check` / `cjpm publish`。**

原因：cjpm 1.2.0 要求 `cjpm.toml` 的 `name`（扁平标识符，如 `cjDemo`）与源码
`package` 声明**逐字相等**；AMS 全仓使用点号分层命名（`ams.kit`、`ams.core.search`），
两者不兼容。仓库内 `packages/ams-{kernel,crypto,kit}/cjpm.toml` **仅作元数据文档**，
不参与构建，其 `name` / `version` 字段不生效。

决策为**不做全仓包名扁平化**：那会波及所有 `import`，改动面大且回归风险高，
收益仅是一键 `cjpm install`。若将来 cjpm 支持点号包名、或框架需要独立开源分发，
再重新评估（见 `docs/15` §4.1）。

## 2. 版本口径

版本号**唯一来源**是 `packages/ams-kit/src/kit.cj` 的 `KIT_VERSION` 常量。
`scripts/package-kit.sh` 直接从源码提取，不另抄一份；发布包内 `VERSION` 即该值。

当前：`KIT_VERSION = "0.1.0-alpha"`。

> 三个 `cjpm.toml` 里的 `version = "1.0.0"` 是模板默认值，因文件不参与构建而**无实际含义**，
> 不与 `KIT_VERSION` 对齐，也不作为发布版本依据。

## 3. 依赖闭包

发包脚本从 `ams.kit` 的 `import` 出发递归扫描源码，**实时推导**闭包（不写死白名单）。
当前闭包 8 个包：

| 包 | 职责 |
| --- | --- |
| `ams.kernel.error` | AppError / 统一错误转换 |
| `ams.crypto.provider` | CryptoProvider 接口与 DigestAlgorithm 等 |
| `ams.crypto.impl` | SM3 / HMAC-SM3 / SM4 / PBKDF2 实现 |
| `ams.crypto.key` | KeyManager（DEK 包裹 / 解包） |
| `ams.crypto.blindindex` | 盲索引（HMAC-SM3 可检索加密） |
| `ams.security.audit` | 审计哈希链（computeHash / verifyChain） |
| `ams.core.search` | 中文分词 / 掩码 / 检索命中高亮分段 |
| `ams.kit` | 对外 functional facade |

框架层**不 import 任何 AMS 业务包**（`ams.app` / `ams.data` / `ams.api`），
因此可脱离档案业务独立使用。

## 4. 接入方式

### 前置

- 仓颉 SDK **cjc 1.2.0**（与 `cjc-version` 一致）与同版本 `stdx`。
- 本包只提供 AMS 侧 `.a` / `.cjo`；运行时与 stdx 由接入方自备。

### 编译 / 链接

```bash
# 接口快照目录给 cjc，静态库目录给链接器
cjc main.cj \
  --import-path ./cjo \
  --import-path "$CANGJIE_STDX" \
  -L./lib \
  -l:libams.kit.a -l:libams.security.audit.a -l:libams.core.search.a \
  -l:libams.crypto.blindindex.a -l:libams.crypto.key.a \
  -l:libams.crypto.impl.a -l:libams.crypto.provider.a \
  -l:libams.kernel.error.a \
  -o app
```

> 参数顺序与 `scripts/build.sh` 的拓扑序一致；实际链接参数请按接入方的构建系统调整。
> 可用 `bash scripts/package-kit.sh --print-closure` 查看当前闭包（仓库内执行）。

### 最小示例

```cangjie
import ams.kit.*
import ams.crypto.provider.*

main(): Int64 {
    let p = newCryptoProvider()
    let km = newKeyManager(p, "change-me-in-prod-32bytes!!".toArray())
    let bi = newBlindIndex(p)
    let chain = newAuditChain(p)
    let toks = tokenizeForSearch("档案管理系统")
    println("KIT_VERSION=${KIT_VERSION} tokens=${toks.size}")
    return 0
}
```

## 5. 对外能力

| 类别 | API |
| --- | --- |
| 密码学 | `newCryptoProvider()` / `newKeyManager(provider, kek)` / `newBlindIndex(provider)` / `KIT_VERSION` |
| 审计哈希链 | `newAuditChain(provider)` / `auditGenesisHash()` |
| 检索纯逻辑 | `tokenizeForSearch(text)` / `maskValue(value, sensitivity)` / `highlightJson(text, keyword)` |
| 导入模板内核 | `CsvColumnTemplate(header, mapping, defaults)` → `resolve(fieldKey, cells)` / `hasField(fieldKey)` |

`CsvColumnTemplate` 是**纯字符串内核**：把「CSV 表头 → 字段键」映射与默认值回落
从业务层剥离，不依赖任何档案领域类型。

## 6. 安全与许可

- 许可 **Apache-2.0**；`LICENSE` 必须随发布包分发（打包脚本会强制校验，缺失即拒绝出包）。
- 密码学能力**失败关闭**：缺密钥 / 缺加密提供者时抛错，绝不降级成弱 token 或空摘要。
- `SM4-GCM` 在 stdx 实测不可用，实际落地为 `SM4-CBC/CTR + HMAC-SM3`（Encrypt-then-MAC）；
  **SM2 未实现**（SDK 未提供），导出包签名用 HMAC-SM3 对称签名，不支持第三方公钥验签。
- 代码层面对齐国密算法 **≠ 取得商用密码产品认证**；强监管场景需另行送检。

## 7. 自行打包（仓库维护者）

```bash
bash scripts/build.sh                        # 先产出 build/*.a 与 *.cjo
bash scripts/package-kit.sh                  # Windows 产物 → dist/ams-kit-<v>-windows-x86_64.zip
bash scripts/package-kit.sh --build-dir build/linux   # Linux 产物
bash scripts/package-kit.sh --print-closure # 只看依赖闭包
```

脚本会校验闭包内每个包的 `.a` 与 `.cjo` 是否齐全，任一缺失即失败（不产出半截包）。

### 持续验收

```bash
bash scripts/ci/verify-kit-package.sh                     # 默认校验 windows-x86_64 包
bash scripts/ci/verify-kit-package.sh dist/ams-kit-0.1.0-alpha-linux-x86_64
```

该脚本模拟**外部接入方**：只拿包内 `.cjo` / `.a`，用 `cjc` 编译链接一个最小程序并运行，
断言 `KIT_VERSION`、SM3 摘要长度、分词 / 高亮 / 掩码 / 导入模板 / 审计链可用。
实测输出 `SM3_BYTES=32 / TOKENS=5 / GENESIS=32 / TPL_HAS_TITLE=true`，
证明依赖闭包完整、静态库真实可链接（不是「文件存在但链不上」）。
需本机具备仓颉 SDK 1.2.0 与 stdx。
