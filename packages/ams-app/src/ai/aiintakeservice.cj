// ============================================================
// ams.app.ai · 录入辅助聚合门面
//
// 把「附件读取（解密）→ AI 识别 → 字段候选」串成一次用例，
// 供 api 层一条路由调用；api 层不直接接触 AttachmentRepo / FieldDefRepo。
//
// 【隐私】只在内存中取明文送模型，不落盘、不缓存；失败不暴露异常堆栈。
// ============================================================
package ams.app.ai

import ams.ai.*
import ams.app.attachment.*
import ams.data.repo.*
import ams.kernel.util.*

/**
 * 录入辅助聚合服务。
 */
public class AiIntakeService {
    private let recognize: AiRecognizeService
    private let attachments: AttachmentService
    private let attachmentRepo: AttachmentRepo
    private let fieldDefRepo: FieldDefRepo

    public init(
        recognize: AiRecognizeService,
        attachments: AttachmentService,
        attachmentRepo: AttachmentRepo,
        fieldDefRepo: FieldDefRepo
    ) {
        this.recognize = recognize
        this.attachments = attachments
        this.attachmentRepo = attachmentRepo
        this.fieldDefRepo = fieldDefRepo
    }

    /**
     * 解析附件为字段候选（V5）。
     *
     * 返回 RecognizeOutcome；reason 非空时为友好失败原因码，前端按 §5.6.6 呈现。
     */
    public func parseAttachment(userId: String, attachmentId: Int64): RecognizeOutcome {
        let rec = match (this.attachmentRepo.findById(attachmentId)) {
            case Some(r) => r
            case None => return RecognizeOutcome([], "skipped", "not_found")
        }

        // 只支持图片 / PDF（§5.6.2）；其余格式给友好原因码
        let ext = AiIntakeService.lower(rec.fileExt)
        if (ext != "jpg" && ext != "jpeg" && ext != "png" && ext != "pdf") {
            return RecognizeOutcome([], "skipped", "unsupported_format")
        }

        let plain = match (AiIntakeService.safeDownload(this.attachments, attachmentId)) {
            case Some(bytes) => bytes
            case None => return RecognizeOutcome([], "failed", "read_failed")
        }
        if (plain.isEmpty()) {
            return RecognizeOutcome([], "failed", "empty_file")
        }

        // 内置 OCR 文本只作提示（ocrHint），不是最终答案（§4.2）
        let hint = if (rec.ocrStatus == 2) { rec.ocrText } else { "" }
        let category = if (rec.category > 0) { rec.category } else { 1 }

        return this.recognize.recognize(userId, category, rec.subjectId, plain, hint)
    }

    private static func safeDownload(svc: AttachmentService, id: Int64): Option<Array<Byte>> {
        try {
            return Some(svc.download(id))
        } catch (_: Exception) {
            return None
        }
    }

    private static func lower(s: String): String {
        let b = s.toArray()
        let out = Array<Byte>(b.size, repeat: 0u8)
        for (i in 0..b.size) {
            var c = b[i]
            if (c >= 65u8 && c <= 90u8) { c = c + 32u8 }
            out[i] = c
        }
        return String.fromUtf8(out)
    }
}
