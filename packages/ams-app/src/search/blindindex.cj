// ============================================================
// ams.app.search.blindindex · 盲索引服务
//
// 用途（FR-SRC-005 盲索引等值检索）：
//   为「敏感字段精确匹配」提供可复现的盲索引。写入侧在落库时算出盲索引写入
//   arc_item_fields.value_bidx（BYTEA）；查询侧用同样的规则算出盲索引，
//   交由检索执行层做 `value_bidx = decode(?, 'hex')` 等值匹配。
//
// 【密钥来源】
//   盲索引密钥由 KEK（环境变量 AMS_KEK，与附件 DEK 包裹密钥同源）派生，
//   固定 salt + 固定迭代，写读两侧用同一把密钥即可复现。
//
// 【为什么是全局一把、而非 per-subject】
//   本期采用「改动最小」方案（D4 决策）：全局盲索引密钥即可支撑精确匹配。
//   安全章 §4.3.3 建议的 per-subject 派生（跨主体不可关联）作为后续加固项，
//   彼时只需把 deriveKey 的 salt 改为 subjectId 并据此在查询侧按主体分别派生即可，
//   不改变上层调用形态。
//
// 【归一化规则映射】
//   id_number / id_card / 含 id、card 的字段键 → IdCardV1（去空白+大写）
//   phone / mobile → PhoneV1（去分隔符）
//   其余 → GenericV1（去首尾空白+小写）
//   规则与 ams.crypto.blindindex 保持一致；规则一经发布不可更改（历史数据依赖）。
// ============================================================
package ams.app.search

import std.collection.*

import ams.crypto.blindindex.*
import ams.crypto.provider.*

/**
 * 盲索引服务：派生密钥 + 按字段键算盲索引。
 */
public class BlindIndexService {
    private let provider: CryptoProvider
    private let blindKey: Array<Byte>

    public init(provider: CryptoProvider, kek: Array<Byte>) {
        this.provider = provider
        // 固定 salt + 迭代，确保写读两侧派生出同一把密钥
        let salt = "ams-blind-index-v1".toArray()
        match (provider.deriveKey(kek, salt, 1000, 32)) {
            case CryptoResult.Ok(k) => this.blindKey = k
            case CryptoResult.Err(e) => throw e
        }
    }

    /**
     * 计算某字段值的盲索引。
     *
     * @param fieldKey 字段键（arc_field_defs.field_key），用于选择归一化规则
     * @param value    明文值
     * @return 32 字节 SM3 摘要（与 value_bidx 列同形）
     */
    public func bidx(fieldKey: String, value: String): Array<Byte> {
        let rule = BlindIndexService.ruleOf(fieldKey)
        let normalized = BlindIndex.normalize(value, rule)
        match (this.provider.hmac(this.blindKey, normalized.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(b) => return b
            case CryptoResult.Err(e) => throw e
        }
    }

    /**
     * 字段键 → 归一化规则。
     */
    private static func ruleOf(fieldKey: String): NormalizeRule {
        let k = fieldKey.toAsciiLower()
        if (k.contains("id") || k.contains("card")) {
            return NormalizeRule.IdCardV1
        }
        if (k.contains("phone") || k.contains("mobile")) {
            return NormalizeRule.PhoneV1
        }
        return NormalizeRule.GenericV1
    }
}
