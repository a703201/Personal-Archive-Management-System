// ============================================================
// ams.crypto.blindindex · 盲索引
//
// 用途（安全章 §5.2）：
//   敏感字段（如身份证号、手机号）落库前加密，但加密后无法做等值检索。
//   盲索引方案：同时存一列「归一化值 + 派生密钥」的 HMAC-SM3，
//   检索时用同样规则算出盲索引去等值匹配，命中后再解密比对明文。
//
// 规约：
//   - 归一化规则必须稳定且可版本化（规则变了会导致历史数据检索不到）
//   - 派生密钥必须与数据密钥分离（不同的 keyId）
//   - 盲索引本身泄露「相同值相同索引」，故只用于等值检索，不用于范围检索
// ============================================================
package ams.crypto.blindindex

import std.collection.*

import ams.crypto.provider.*

/**
 * 归一化规则版本。
 *
 * 新增规则时**必须**递增版本号，并保留旧版本以支持历史数据检索。
 */
public enum NormalizeRule {
    /** v1：身份证号 —— 去空格、转大写 */
    | IdCardV1
    /** v1：手机号 —— 去空格、去分隔符 */
    | PhoneV1
    /** v1：通用 —— 去首尾空白并转小写 */
    | GenericV1
}

/**
 * 盲索引生成器。
 */
public class BlindIndex {
    private let provider: CryptoProvider

    public init(provider: CryptoProvider) {
        this.provider = provider
    }

    /**
     * 生成盲索引。
     *
     * @param derivedKey 派生密钥（由数据密钥派生的专用子密钥）
     * @param value 原始值
     * @param rule 归一化规则
     * @return 32 字节盲索引（SM3 摘要长度）
     */
    public func generate(
        derivedKey: Array<Byte>,
        value: String,
        rule: NormalizeRule
    ): CryptoResult<Array<Byte>> {
        let normalized = BlindIndex.normalize(value, rule)
        return this.provider.hmac(derivedKey, normalized.toArray(), DigestAlgorithm.Sm3)
    }

    /**
     * 校验：先算盲索引匹配，再解密比对明文。
     *
     * 之所以要两步：盲索引命中只说明「归一化后相同」，
     * 仍需解密后的明文精确比对，防止因归一化规则过粗导致误判。
     *
     * @param derivedKey 派生密钥
     * @param candidate 候选明文
     * @param expectedPlain 解密后的期望明文
     * @param rule 归一化规则
     */
    public func matches(
        derivedKey: Array<Byte>,
        candidate: String,
        expectedPlain: String,
        rule: NormalizeRule
    ): Bool {
        let normalized = BlindIndex.normalize(candidate, rule)
        let index = match (this.provider.hmac(derivedKey, normalized.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => return false
        }
        // 期望明文也走同样的归一化
        let expectedNorm = BlindIndex.normalize(expectedPlain, rule)
        return expectedNorm == normalized
    }

    /**
     * 归一化。
     *
     * 规则一经发布不可更改（否则历史盲索引失效），
     * 变更必须新增版本并双写过渡。
     */
    public static func normalize(value: String, rule: NormalizeRule): String {
        // 注意：仓颉的 match 分支是**表达式**（不是语句块），
        // 故多语句逻辑必须抽成独立方法。
        match (rule) {
            case NormalizeRule.IdCardV1 => BlindIndex.normalizeIdCard(value)
            case NormalizeRule.PhoneV1 => BlindIndex.normalizePhone(value)
            case NormalizeRule.GenericV1 => BlindIndex.normalizeGeneric(value)
        }
    }

    /**
     * 身份证号归一化：去所有空白 + 转大写。
     */
    private static func normalizeIdCard(value: String): String {
        return BlindIndex.removeWhitespace(value).toAsciiUpper()
    }

    /**
     * 手机号归一化：只保留数字与字母。
     */
    private static func normalizePhone(value: String): String {
        return BlindIndex.removeSeparators(value)
    }

    /**
     * 通用归一化：去首尾空白 + 转小写。
     */
    private static func normalizeGeneric(value: String): String {
        return value.trimAscii().toAsciiLower()
    }

    /**
     * 去掉所有空白字符（含全角空格）。
     *
     * 【为什么按字节而不是按 `s[i..i+1]` 拼接】
     *   仓颉的 `String.size` 是**字节数**，`s[i..i+1]` 切出的是**单个字节**。
     *   中文等多字节字符被逐字节切碎后拼回，会产生非法 UTF-8 序列，
     *   `StringBuilder.toString()` 直接抛：
     *     IllegalArgumentException: Invalid utf8 byte sequence
     *   实测：盲索引对「居民身份证」这类含中文的值必崩 →
     *     PUT /api/items/:id/fields 返回 INTERNAL_ERROR。
     *   故这里在字节层面过滤，再整体 fromUtf8，保证切分点永远落在字符边界上
     *   （空白字符的字节值 0x20/0x09/0x0A/0x0D 与 U+3000 的 E3 80 80
     *    在 UTF-8 中不会与其它字符的首字节混淆）。
     */
    private static func removeWhitespace(s: String): String {
        let src = s.toArray()
        let out = ArrayList<Byte>()
        var i: Int64 = 0
        while (i < src.size) {
            let b = src[i]
            if (b == 32 || b == 9 || b == 10 || b == 13) {
                i = i + 1
                continue
            }
            // 全角空格 U+3000 = E3 80 80
            if (b == 0xE3 && i + 2 < src.size && src[i + 1] == 0x80 && src[i + 2] == 0x80) {
                i = i + 3
                continue
            }
            out.add(b)
            i = i + 1
        }
        return String.fromUtf8(out.toArray())
    }

    /**
     * 去掉分隔符：- + ( ) 空格 等。
     *
     * 只保留 ASCII 数字与字母 —— 结果天然是合法 UTF-8。
     */
    private static func removeSeparators(s: String): String {
        let out = ArrayList<Byte>()
        for (b in s.toArray()) {
            let isDigit = b >= 48 && b <= 57
            let isUpper = b >= 65 && b <= 90
            let isLower = b >= 97 && b <= 122
            if (isDigit || isUpper || isLower) {
                out.add(b)
            }
        }
        return String.fromUtf8(out.toArray())
    }
}
