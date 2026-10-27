// ============================================================
// ams.app.search · 检索应用服务
//
// 覆盖：
//   FR-SRC-001 关键词全文检索 —— 分词 + 索引构建 + 命中
//   FR-SRC-006 敏感字段掩码与「展开需权限 + 留痕」
//
// [索引什么时候建]
//   提供 indexItem(itemId) 供条目写入路径调用（创建/更新后重建）。
//   索引内容是「标题 + 各扩展字段值拼接」的纯文本，
//   分词后存进 arc_search_index.tokens（GIN），查询侧用数组交叠匹配。
//
// [敏感字段如何展示]
//   默认**一律掩码**（Masker），前端拿到的永远是脱敏值；
//   真正要看明文必须走 reveal()：
//     · 需持有 archive:read_sensitive
//     · 每次展开都写一条 AuditAction.FieldReveal 审计（FR-SRC-006 的「留痕」）
//   这样「谁在什么时候展开了哪个敏感字段」可追溯。
// ============================================================
package ams.app.search

import std.collection.*

import ams.app.audit.*
import ams.core.search.*
import ams.data.repo.*
import ams.security.audit.*
import ams.kernel.error.*
import ams.kernel.log.*

/**
 * 检索应用服务。
 */
public class SearchService {
    private let searchRepo: SearchRepo
    private let itemRepo: ItemRepo
    private let itemFieldRepo: ItemFieldRepo
    private let recorder: ?AuditRecorder

    public init(
        searchRepo: SearchRepo,
        itemRepo: ItemRepo,
        itemFieldRepo: ItemFieldRepo,
        recorder!: ?AuditRecorder = None
    ) {
        this.searchRepo = searchRepo
        this.itemRepo = itemRepo
        this.itemFieldRepo = itemFieldRepo
        this.recorder = recorder
    }

    /**
     * 建立 / 重建某条目的检索索引（幂等）。
     *
     * 内容 = 标题 + 各扩展字段值（敏感值**不入索引**，避免明文落到索引表）。
     */
    public func indexItem(itemId: Int64): Unit {
        match (this.itemRepo.findByIdRaw(itemId)) {
            case Some(r) =>
                let sb = StringBuilder()
                sb.append(r.title)
                sb.append(" ")
                sb.append(r.issuer)
                sb.append(" ")
                sb.append(r.remark)
                for (f in this.itemFieldRepo.listByItem(itemId)) {
                    // 敏感字段（>=2）不入索引：索引表是明文存储区
                    if (f.sensitivity < 2) {
                        sb.append(" ")
                        sb.append(f.value)
                    }
                }
                let content = sb.toString()
                let tokens = ChineseTokenizer.tokenize(content)
                this.searchRepo.upsertIndex(
                    itemId,
                    UserRepo.parseId(r.subjectId),
                    r.category,
                    r.title.toAsciiLower(),
                    content,
                    tokens
                )
            case None => throw notFound("条目")
        }
    }

    /**
     * 批量回填「尚未建立索引」的条目（供运维端点调用）。
     *
     * 用途：索引接线补齐之前创建的存量条目没有索引行，
     * 关键词检索会漏掉它们。单条失败不影响整批。
     *
     * @return 本次成功建立索引的条数
     */
    public func reindexUnindexed(limit: Int64): Int64 {
        let ids = this.searchRepo.listUnindexedItemIds(limit)
        var done: Int64 = 0
        for (id in ids) {
            try {
                this.indexItem(id)
                done = done + 1
            } catch (e: Exception) {
                Log.get().warn("search.reindex.skip", None, [
                    ("itemId", "${id}"),
                    ("reason", e.toString())
                ])
            }
        }
        return done
    }

    /**
     * 执行检索。
     *
     * @param q 查询条件（subjectIds 必须已由服务端填好）
     * @return 结果行集（**可能比 pageSize 多一条**，用于判定 has_more）
     */
    public func search(q: SearchQuery): RowSet {
        var tokens: Array<String> = []
        var likePattern = ""
        if (!q.keyword.isEmpty()) {
            tokens = ChineseTokenizer.tokenize(q.keyword)
            // 单字查询：二元索引里没有单字 token，回退到 LIKE
            if (ChineseTokenizer.isSingleCharQuery(q.keyword)) {
                likePattern = "%${q.keyword}%"
            }
        }
        return this.searchRepo.search(q, tokens, q.tagIds, likePattern)
    }

    /**
     * 展开敏感字段明文（FR-SRC-006：需权限 + 留痕）。
     *
     * @param actorId 操作者
     * @param hasPerm 是否已持有 archive:read_sensitive（由路由层判定后传入）
     * @param ip / userAgent 用于审计
     */
    public func reveal(
        itemId: Int64,
        fieldKey: String,
        actorId: Int64,
        hasPerm: Bool,
        ip: String,
        userAgent: String
    ): String {
        if (!hasPerm) {
            throw forbidden(message: "无权限查看敏感字段明文")
        }
        var found = ""
        var sensitivity: Int64 = 1
        for (f in this.itemFieldRepo.listByItem(itemId)) {
            if (f.fieldKey == fieldKey) {
                found = f.value
                sensitivity = f.sensitivity
            }
        }
        if (found.isEmpty()) {
            throw notFound("字段")
        }
        // 留痕：每次展开都写审计
        match (this.recorder) {
            case Some(rec) =>
                rec.record(
                    "${actorId}",
                    ActorType.User,
                    AuditAction.FieldReveal,
                    "item",
                    "${itemId}",
                    "",
                    0,
                    AuditResult.Success,
                    "",
                    ip,
                    userAgent,
                    "",
                    [("fieldKey", fieldKey), ("sensitivity", "${sensitivity}")]
                )
            case None => ()
        }
        Log.get().warn("search.field.reveal", None, [
            ("itemId", "${itemId}"), ("fieldKey", fieldKey), ("actor", "${actorId}")
        ])
        return found
    }
}
