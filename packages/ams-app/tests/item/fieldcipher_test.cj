// ============================================================
// ams.app.item · 敏感字段加密回归测试
//
// 覆盖：按 (主体, 分类, 字段) 派生密钥的往返一致、跨主体隔离、
//       密文篡改必须失败关闭（EtM 验签）。
// 运行：bash scripts/test.sh ams-app
// ============================================================
package ams.app.item.test

import std.unittest.*
import std.unittest.testmacro.*

import ams.app.item.*
import ams.crypto.impl.*
import ams.crypto.provider.*
import ams.kernel.error.*

@Test
public class FieldCipherTest {
    /** 仓颉枚举不支持 ==，用 match 判定错误种类。 */
    private static func isCryptoFailure(e: AppError): Bool {
        match (e.kind) {
            case AppErrorKind.CryptoFailure => true
            case _ => false
        }
    }

    private static func kek(): Array<Byte> {
        return Array<Byte>(32, repeat: 7u8)
    }

    @TestCase
    public func roundTrip(): Unit {
        let c = FieldCipher(StdxCryptoProvider(), kek())
        let sealed = match (c.encrypt(880001, 4, "id_number", "440301199001011234")) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(_) => @Assert(false); return
        }
        // 明文不得出现在密文 hex 里
        @Assert(!sealed.contains("440301"))
        let plain = match (c.decrypt(880001, 4, "id_number", sealed)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(_) => @Assert(false); return
        }
        @Assert(plain == "440301199001011234")
    }

    @TestCase
    public func subjectScopedKey(): Unit {
        let c = FieldCipher(StdxCryptoProvider(), kek())
        let sealed = match (c.encrypt(880001, 4, "id_number", "440301199001011234")) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(_) => @Assert(false); return
        }
        match (c.decrypt(880002, 4, "id_number", sealed)) {
            case CryptoResult.Ok(_) => @Assert(false)
            case CryptoResult.Err(e) => @Assert(isCryptoFailure(e), true)
        }
    }

    @TestCase
    public func tamperedCipherFailsClosed(): Unit {
        let c = FieldCipher(StdxCryptoProvider(), kek())
        let sealed = match (c.encrypt(880001, 4, "phone", "13800138000")) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(_) => @Assert(false); return
        }
        // 改动 HMAC 最后一个 hex 字符
        let bad = sealed[0..(sealed.size - 1)] + "0"
        match (c.decrypt(880001, 4, "phone", bad)) {
            case CryptoResult.Ok(_) => @Assert(false)
            case CryptoResult.Err(e) => @Assert(isCryptoFailure(e), true)
        }
    }
}
