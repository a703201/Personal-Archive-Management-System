// ============================================================
// ams.kit · 通用开发框架对外稳定 API 层（Phase 1：functional facade）
//
// 设计目标（见 docs/18 4.1）：把与业务无关的密码学能力收敛到一个入口，
// 使其它项目以最小认知成本使用 AMS 的密码学实现。
//
// 实现说明（Cangjie 1.2.0 约束）：
//   本语言不支持跨包 `public import` 整包，也不支持 `public type = 其他包类型`
//   的跨包类型别名（编译器报 "undeclared type name"）。因此 ams.kit 采用
//   **functional facade**：提供工厂函数与版本常量，底层类型（CryptoProvider /
//   KeyManager / BlindIndex 等）仍由 ams.crypto 暴露——ams.crypto 本身即
//   是那个「可独立发布的框架库」。ams.kit 负责统一入口与后续扩展点。
//
// 约束：框架层严禁 import 任何 AMS 业务包（ams.app / ams.data / ams.api）。
//
// 【Phase 3（docs/15 §4.1）】再纳入三块与业务解耦的纯能力：
//   ① 审计哈希链 —— ams.security.audit 的 AuditService（只依赖 CryptoProvider）；
//   ② 检索纯逻辑 —— ams.core.search 的分词 / 掩码 / 高亮分段；
//   ③ 导入模板框架 —— 表头映射的**纯字符串内核**在 kit 内独立实现，
//      不 import ams.app.importer（那是业务包），从而保持框架层洁净。
//   三者都只依赖 ams.core / ams.security / ams.crypto，符合单向分层。
// ============================================================
package ams.kit

import std.collection.*

import ams.crypto.provider.*
import ams.crypto.impl.*
import ams.crypto.key.*
import ams.crypto.blindindex.*
import ams.security.audit.*
import ams.core.search.*

// 框架版本（与 CHANGELOG 对齐；独立发版后由 cjpm 版本号接管）
public let KIT_VERSION: String = "0.1.0-alpha"

// 构造密码学提供者（SM3 / HMAC-SM3 / SM4-CBC·CTR / PBKDF2-HMAC-SM3）。
// 返回接口类型，调用方以 ams.crypto 的 CryptoProvider 形态使用。
public func newCryptoProvider(): CryptoProvider {
    return StdxCryptoProvider()
}

// 构造密钥管理器。kek 为密钥加密密钥（字节数组），对任意 keyId 均返回同一 kek
// （与 ams-server main.cj 的构造方式一致：单一 KEK 派生盲索引 / 包裹密钥）。
public func newKeyManager(provider: CryptoProvider, kek: Array<Byte>): KeyManager {
    return KeyManager(provider, { keyId: String => kek })
}

// 构造盲索引服务（基于 HMAC-SM3 的可检索加密）。
public func newBlindIndex(provider: CryptoProvider): BlindIndex {
    return BlindIndex(provider)
}

// ============================================================
// Phase 3 · ① 审计哈希链
// ============================================================

/** 构造审计哈希链服务（computeHash / buildRecord / verifyChain 全可用）。 */
public func newAuditChain(provider: CryptoProvider): AuditService {
    return AuditService(provider)
}

/** 创世记录的 prev_hash（32 字节全 0）。 */
public func auditGenesisHash(): Array<Byte> {
    return AuditService.genesisHash()
}

// ============================================================
// Phase 3 · ② 检索纯逻辑
// ============================================================

/** 中文二元切分（bigram），中英混合；供检索索引构建复用。 */
public func tokenizeForSearch(text: String): Array<String> {
    return ChineseTokenizer.tokenize(text)
}

/** 按敏感度掩码（按 UTF-8 字符计，不切碎中文）。 */
public func maskValue(value: String, sensitivity: Int64): String {
    return Masker.mask(value, sensitivity)
}

/**
 * 检索命中高亮分段 JSON（前端按段渲染 <mark>，不用 v-html）。
 * 形如 [{"text":"清华","hit":false},{"text":"硕士","hit":true}]
 */
public func highlightJson(text: String, keyword: String): String {
    return SearchHighlighter.toJson(text, keyword)
}

// ============================================================
// Phase 3 · ③ 导入模板框架（纯字符串内核）
//
// 与 ams.app.importer.ImportService 的 mapping 语义一致：
//   mapping = 「CSV 表头 → 字段键」；defaults = 「字段键 → 默认值」。
// 抽到框架层后，任何项目都能按表头名取列，不必绑定 AMS 的条目模型。
// ============================================================
public class CsvColumnTemplate {
    private let fieldToIndex: HashMap<String, Int64>
    private let defaults: HashMap<String, String>

    /**
     * @param header   CSV 首行切分后的表头数组
     * @param mapping  CSV 表头 → 字段键；未列出的表头列一律忽略
     * @param defaults 字段键 → 默认值（缺列 / 空单元格时回落）
     */
    public init(header: Array<String>, mapping: HashMap<String, String>,
                defaults: HashMap<String, String>) {
        this.fieldToIndex = HashMap<String, Int64>()
        this.defaults = HashMap<String, String>()
        var i: Int64 = 0
        while (i < header.size) {
            match (mapping.get(header[i])) {
                case Some(key) =>
                    if (!key.isEmpty()) {
                        // 同名表头以**首次出现**为准，避免后列覆盖前列
                        match (this.fieldToIndex.get(key)) {
                            case Some(_) => ()
                            case None => this.fieldToIndex[key] = i
                        }
                    }
                case None => ()
            }
            i = i + 1
        }
        for ((k, v) in defaults) {
            this.defaults[k] = v
        }
    }

    /** 取某字段在当前行的值：缺列 / 越界 / 空串时回落默认值。 */
    public func resolve(fieldKey: String, cells: Array<String>): String {
        match (this.fieldToIndex.get(fieldKey)) {
            case Some(idx) =>
                if (idx >= 0 && idx < cells.size && !cells[idx].isEmpty()) {
                    return cells[idx]
                }
            case None => ()
        }
        match (this.defaults.get(fieldKey)) {
            case Some(v) => return v
            case None => return ""
        }
    }

    /** 是否已映射到该字段（供调用方判断模板覆盖率）。 */
    public func hasField(fieldKey: String): Bool {
        return this.fieldToIndex.contains(fieldKey)
    }
}
