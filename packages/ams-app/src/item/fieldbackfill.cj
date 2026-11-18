// ============================================================
// ams.app.item · 历史敏感字段加密回填
//
// 一次性运维任务：把历史写入 value_text 等明文列的高敏字段
// 迁移到 value_enc（EtM 密文），并清空明文列；逐条幂等，
// 单条失败不影响其它行，返回成功/失败计数供调用方核对。
// ============================================================
package ams.app.item

import std.collection.*

import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.log.*

public class FieldBackfillService {
    private let repo: ItemFieldRepo
    private let itemRepo: ItemRepo
    private let cipher: FieldCipher

    public init(repo: ItemFieldRepo, itemRepo: ItemRepo, cipher: FieldCipher) {
        this.repo = repo
        this.itemRepo = itemRepo
        this.cipher = cipher
    }

    /** @return (已加密条数, 失败条数) */
    public func run(): (Int64, Int64) {
        var done: Int64 = 0
        var failed: Int64 = 0
        for (v in this.repo.listPlaintextSensitive()) {
            let item = match (this.itemRepo.findByIdRaw(v.itemId)) {
                case Some(r) => r
                case None =>
                    failed = failed + 1
                    continue
            }
            try {
                let sealed = match (this.cipher.encrypt(
                    RowData.toI64(item.subjectId), item.category, v.fieldKey, v.value)) {
                    case CryptoResult.Ok(hex) => hex
                    case CryptoResult.Err(e) => throw e
                }
                this.repo.saveEncrypted(v.itemId, v.fieldDefId, sealed)
                done = done + 1
            } catch (e: Exception) {
                failed = failed + 1
                Log.get().warn("field.backfill.failed", None, [
                    ("itemId", "${v.itemId}"), ("fieldDefId", "${v.fieldDefId}"),
                    ("reason", e.toString())
                ])
            }
        }
        return (done, failed)
    }
}
