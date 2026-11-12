# 安全政策 · AMS

## 报告漏洞

本项目是个人 / 家庭自托管的私密档案系统，**请勿在公开 Issue 里贴出可复现的漏洞细节**。
请通过以下任一方式私下报告：

- GitHub 私有漏洞报告（仓库 Security → Report a vulnerability）
- 邮件联系维护者（见 `README.md` 许可证署名与 `web/src/config/about.ts` 中的联系邮箱）

请附带：影响版本、复现步骤、 PoC（脱敏）、影响面评估。维护者确认后会与你沟通修复与披露时间。

## 支持范围

| 版本 | 安全修复 |
| --- | --- |
| `1.3.x`（当前稳定线） | 支持 |
| `1.2.x` / `1.1.x` / `1.0.x` | 仅高危漏洞，建议升级到 1.3.x |
| `0.x` | 不支持 |

## 部署方必须知道的三件事

1. **生产必须设置 `AMS_ENV=production` 并显式提供 `AMS_TOKEN_SECRET` / `AMS_KEK` / `AMS_DB_PASSWORD`**。
   缺省时后端会拒绝启动（SEC-001）；本地开发的默认值仅适用于 `dev`，绝不可用于生产。
   详见 `deploy/RUNBOOK.md` 与 `deploy/config/ams.env.example`。
2. **容器本身只提供 HTTP `:8080`**，TLS 由前置反向代理终止；数据库端口 `15432` 默认暴露到宿主机，
   生产应收紧网络边界。
3. **更换 `AMS_KEK` 会使既有被包裹密钥与盲索引无法解密**，需配套数据重加密方案（当前仓库没有轮换工具）。

## 已知能力边界（不是缺陷，勿依赖）

| 边界 | 说明 |
| --- | --- |
| SM2 未实现 | SDK 无非对称国密；导出包签名使用 HMAC-SM3（对称共享密钥），**无法做到验签方不持有签名密钥** |
| SM4-GCM 不可用 | stdx 实测 `create tag error`，实际落地为 SM4-CBC/CTR + HMAC-SM3（Encrypt-then-MAC） |
| 像素水印已烧写，仍不阻止截图 / 翻拍 | 服务端把访问者 / 时间 / 追踪号烧进 PNG 像素（`GET /api/attachments/:id/watermarked`），但截图 / 翻拍发生在像素之外；PDF 与不支持格式保留签票 + 审计 + 前端叠加 |
| 缩略图 / OCR / 短信 / 图形验证码边界 | 缩略图与像素水印支持 PNG / BMP / baseline + 渐进式 JPEG（纯仓颉 `bmp.cj` / `jpeg.cj`）；三路 OCR（5×7 印刷体 → CJK 220 字点阵字典 → 10 个手写风格数字，`MediaOcr.recognizeAutoWithEngine` 返回实际引擎），文本型 PDF 抽文本、图像型扫描 PDF 经 `pdfimage.cj` 抽图像流后走 OCR；剩余边界：CJK 仅字典内 220 字且为字体点阵、手写仅 10 个近似手写数字，真实草书 / 生僻字 / 强倾斜 / 复杂排版 / 加密 PDF / CMYK / JPEG2000 / CCITT / JBIG2 / 图像掩码不支持，高精度识别仍需外部模型；短信默认关闭需运维配置 `SMS_*`；图形验证码 SVG 已 path 化轮廓（无 `<text>` / 答案明文），但字符轮廓仍可被专用 OCR 解析，challenge TTL / 一次性 / 3 次尝试 / 单实例内存态 |
| 短信网关投递失败的可见性 | `SpoolSmsProvider.send()` 只在**写 `.job` 失败**时向 `ams-server` 抛错（失败关闭）；网关投递由独立的 `sms-spool.sh` 进程异步完成，**后端无法同步感知投递结果**。投递失败时 `.job` 移入 `failed/` 并写 `*.reason`（只含 HTTP 码/时间，不含凭据、手机号、正文）+ 输出 `[sms-spool] ERROR`；告警须监控该日志或目录。网关 URL 强制 `https://`（凭据随 JSON 明文发送），loopback http 仅允许本机网关，非合规配置脚本 FATAL 退出而非静默发请求 |
| 商用密码产品认证 | **未进行**；代码层面对齐国密算法 ≠ 取得认证 / 完成密评 |

完整论证见 `docs/03-安全设计专章.md`、`docs/08-SM4方案变更说明.md`、
`docs/13-信创与国家密码标准参考.md`。

> **OCR 隐私（FR-ATT-013 · 2026-11-07 补记）**：需**显式隐私同意** —— `AMS_MEDIA_ENABLED` 与 `AMS_OCR_CONSENT` 默认均为 `false`，须同时为 `true` 才自动处理，也可由 `POST /api/attachments/:id/media` 手动触发。附件明文**只在 `ams-server` 进程内内存解码 / 识别**，不落临时文件、不引入外部进程或 worker；`scripts/media_worker.py` 仅为离线参考实现，不参与运行时主链路；CJK / 手写字模（`glyphdata.cj`）为**构建期**由 `scripts/gen-media-glyphs.py` 用 Windows GDI 字体渲染生成的静态点阵数据，运行时不读取系统字体、不需要字体 / GDI / Python / 外部进程。

> **验证码 devHint E2E 测试通道（FR-AUTH-011 · 2026-11-08 补记）**：图形验证码 SVG 已改为**纯 path 轮廓**（内嵌点阵字模 + 旋转 / 倾斜 + 干扰线 / 噪点），不再含 `<text>` / `aria-label` / `data-*` / 答案明文；challenge TTL、一次性、3 次尝试、单实例内存态不变。仅当 **`AMS_ENV` 非 `production` / `prod` 且 `AMS_E2E_CAPTCHA_HINT=true`** 时，验证码响应才附加 `devHint` 字段；**生产环境恒不返回**（由 `CaptchaStore.devHintAllowed` 持有保证，SEC-001 强制 production 显式凭据）。`scripts/ci/e2e_captcha.py` 只读该字段、缺失即清晰报错、不解析 SVG、不打印答案；`verify-e2e.sh` / `bootstrap-e2e.sh` 启动自建服务时显式设 `AMS_ENV=ci` 与开关，并回归断言「不带验证码的注册必须被拒绝」；不重新引入 sitecustomize / `.old` / fallback。**诚实结论：path 化轮廓只去除文本可解析性，不等于抗专用 OCR** —— 字符轮廓仍可被针对性 OCR / 轮廓还原解析，强对抗场景仍建议换图片 / 滑块或引入更高强度挑战。

## 设计原则

失败关闭（安全组件异常时拒绝服务，绝不降级）、默认拒绝（先判禁止再判允许）、
最小必要（只采集与授权达成目的所需的最小范围）。审计哈希链可用
`GET /api/audit/verify-chain` 自证，并用 `scripts/verify-audit-chain.py` 独立复算交叉比对。
