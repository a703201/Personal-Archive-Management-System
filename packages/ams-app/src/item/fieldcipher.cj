// ============================================================
// ams.app.item.fieldcipher · 敏感字段值加密（S-1）
//
// 高敏字段（sensitivity >= 2）的值不再写入 value_text / value_num 等明文列：
//   · DEK = HMAC-SM3(KEK, "ams-field-v1|subject|category|fieldKey") 前 16 字节
//     —— 按主体 / 分类 / 字段隔离，避免跨主体密文可关联；
//   · 密文格式复用 AttachmentCipher（SM4-CBC + HMAC-SM3，Encrypt-then-MAC），
//     随机 IV + 完整性校验，验签失败一律失败关闭；
//   · 等值检索仍走 value_bidx 盲索引，解码后的明文只在受控读取路径出现。
// ============================================================
package ams.app.item

import stdx.encoding.hex.*

import ams.core.attachment.*
import ams.crypto.provider.*
import ams.kernel.error.*

public class FieldCipher {
    private let provider: CryptoProvider
    private let kek: Array<Byte>
    private let cipher: AttachmentCipher

    public init(provider: CryptoProvider, kek: Array<Byte>) {
        this.provider = provider
        this.kek = kek
        this.cipher = AttachmentCipher(provider)
    }

    /** 按 (主体, 分类, 字段) 派生 16 字节 DEK。 */
    private func dek(subjectId: Int64, category: Int64, fieldKey: String): CryptoResult<Array<Byte>> {
        let ctx = "ams-field-v1|${subjectId}|${category}|${fieldKey}".toArray()
        let mac = match (this.provider.hmac(this.kek, ctx, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(m) => m
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        if (mac.size < 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "字段密钥派生长度不足"))
        }
        return CryptoResult.Ok(mac[0..16])
    }

    /** 加密为 hex 字符串，供 ItemFieldRepo.saveEncrypted 写入 BYTEA。 */
    public func encrypt(
        subjectId: Int64, category: Int64, fieldKey: String, plain: String
    ): CryptoResult<String> {
        let key = match (this.dek(subjectId, category, fieldKey)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let sealed = match (this.cipher.encrypt(plain.toArray(), key)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        return CryptoResult.Ok(toHexString(sealed))
    }

    /** 解密 hex 密文；密文损坏 / 验签失败一律失败关闭，不返回空串。 */
    public func decrypt(
        subjectId: Int64, category: Int64, fieldKey: String, encHex: String
    ): CryptoResult<String> {
        let sealed = match (fromHexString(encHex)) {
            case Some(b) => b
            case None => return CryptoResult.Err(
                AppError(AppErrorKind.CryptoFailure, "字段密文不是合法 hex"))
        }
        let key = match (this.dek(subjectId, category, fieldKey)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let plain = match (this.cipher.decrypt(sealed, key)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        return CryptoResult.Ok(String.fromUtf8(plain))
    }
}
