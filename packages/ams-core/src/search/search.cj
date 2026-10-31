// ============================================================
// ams.core.search · 检索领域模型
//
// 需求：
//   FR-SRC-001 关键词全文检索
//   FR-SRC-002 结构化筛选
//   FR-SRC-003 排序
//   FR-SRC-004 游标分页
//   FR-SRC-005 盲索引等值检索
//   FR-SRC-006 敏感字段掩码
//
// [游标分页]（数据模型 §4.2 索引说明）
//   所有列表查询使用 `(updated_at, id)` 或 `(created_at, id)` 复合键做 keyset 分页，
//   避免 OFFSET 在大数据量下的性能塌陷。
//   游标 = (排序键值, id)，下一页条件为：
//     (sortKey, id) > (cursor.sortKey, cursor.id)
//
// [敏感掩码]（FR-SRC-006）
//   无「展开敏感字段」权限时，敏感字段返回掩码值而非隐藏 ——
//   让用户知道「这里有值」但看不到内容，比完全隐藏更不易引发困惑。
// ============================================================
package ams.core.search

import std.collection.*

/**
 * 排序方向。
 */
public enum SortDirection {
    | Asc
    | Desc
}

/**
 * 排序字段。
 */
public enum SortField {
    | UpdatedAt
    | CreatedAt
    | Title
    | ExpiresAt
    | Issuer
    | AttachmentCount   // FR-SRC-003：按附件数排序
}

/**
 * 排序条件。
 */
public class SortSpec {
    public let field: SortField
    public let direction: SortDirection

    public init(field: SortField, direction: SortDirection) {
        this.field = field
        this.direction = direction
    }
}

/**
 * 游标（keyset 分页位置）。
 *
 * @param sortKey 排序键的值（时间戳为毫秒，标题为字符串）
 * @param id 该位置记录的 ID
 */
public class Cursor {
    public let sortKey: String
    public let id: String

    public init(sortKey: String, id: String) {
        this.sortKey = sortKey
        this.id = id
    }

    /**
     * 编码为游标串（便于放 URL）。
     *
     * 格式：sortKey:id，冒号转义为 %3A。
     */
    public func encode(): String {
        return "${this.sortKey.replace(":", "%3A")}:${this.id}"
    }

    /**
     * 从游标串解码。格式非法返回 None。
     */
    public static func decode(s: String): ?Cursor {
        let idx = Cursor.indexOf(s, ":")
        if (idx <= 0 || idx >= s.size - 1) {
            return None
        }
        let key = s[0..idx].replace("%3A", ":")
        let id = s[(idx + 1)..s.size]
        return Some(Cursor(key, id))
    }

    /**
     * 查找子串首字节下标（-1 表示未找到）。
     *
     * 不用 String.indexOf —— 它返回 Option，与算术运算不兼容。
     */
    private static func indexOf(s: String, sub: String): Int64 {
        if (sub.isEmpty() || s.size < sub.size) {
            return -1
        }
        for (i in 0..(s.size - sub.size + 1)) {
            var matched = true
            for (j in 0..sub.size) {
                if (s[i + j] != sub[j]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                return i
            }
        }
        return -1
    }
}

/**
 * 查询条件（FR-SRC-002 结构化筛选）。
 */
public class SearchQuery {
    /** 关键词（FR-SRC-001） */
    public let keyword: String
    /** 主体 ID 列表（**服务端强制附加**，禁止由前端传参决定归属） */
    public let subjectIds: Array<String>
    /** 分类码列表（空 = 不限） */
    public let categoryCodes: Array<Int64>
    /** 状态过滤（空 = 不限） */
    public let statuses: Array<Int64>
    /** 颁发机构 */
    public let issuer: String
    /** 颁发日期起（含） */
    public let issuedFrom: String
    /** 颁发日期止（含） */
    public let issuedTo: String
    /** 失效日期起（含） */
    public let expiresFrom: String
    /** 失效日期止（含） */
    public let expiresTo: String
    /** 标签 ID 列表（空 = 不限） */
    public let tagIds: Array<String>
    /** 盲索引等值检索（FR-SRC-005）：fieldKey → 盲索引字节 */
    public let blindFilters: Array<(String, Array<Byte>)>
    /** 扩展字段等值筛选：fieldKey → 值 */
    public let extraFilters: Array<(String, String)>
    /** 排序 */
    public let sort: SortSpec
    /** 每页条数 */
    public let pageSize: Int64
    /** 游标（空 = 首页） */
    public let cursor: Cursor
    /**
     * 来源系统筛选（FR-SRC-010）。
     *
     * 0 = 手动录入；1 = CSV 导入；2 = 克隆生成；3 = OCR 识别；4 = 附件导入。
     * 0 表示「不限」之外的默认手动来源；传入 0 时不过滤（与「全部」等价）。
     */
    public let source: Int64
    /** 创建时间起（含），`YYYY-MM-DD` 或 `YYYY-MM-DD HH:MM:SS` */
    public let createdFrom: String
    /** 创建时间止（含） */
    public let createdTo: String

    public init(
        keyword: String,
        subjectIds: Array<String>,
        categoryCodes: Array<Int64>,
        statuses: Array<Int64>,
        issuer: String,
        issuedFrom: String,
        issuedTo: String,
        expiresFrom: String,
        expiresTo: String,
        tagIds: Array<String>,
        blindFilters: Array<(String, Array<Byte>)>,
        extraFilters: Array<(String, String)>,
        sort: SortSpec,
        pageSize: Int64,
        cursor: Cursor,
        source!: Int64 = 0,
        createdFrom!: String = "",
        createdTo!: String = ""
    ) {
        this.keyword = keyword
        this.subjectIds = subjectIds
        this.categoryCodes = categoryCodes
        this.statuses = statuses
        this.issuer = issuer
        this.issuedFrom = issuedFrom
        this.issuedTo = issuedTo
        this.expiresFrom = expiresFrom
        this.expiresTo = expiresTo
        this.tagIds = tagIds
        this.blindFilters = blindFilters
        this.extraFilters = extraFilters
        this.sort = sort
        this.pageSize = pageSize
        this.cursor = cursor
        this.source = source
        this.createdFrom = createdFrom
        this.createdTo = createdTo
    }
}

/**
 * 检索结果页。
 */
public class SearchPage {
    /** 本页结果 */
    public let items: Array<String>
    /** 下一页游标（空 = 已是最后一页） */
    public let nextCursor: Cursor
    public let total: Int64

    public init(items: Array<String>, nextCursor: Cursor, total: Int64) {
        this.items = items
        this.nextCursor = nextCursor
        this.total = total
    }
}

/**
 * 敏感字段掩码（FR-SRC-006）。
 */
public class Masker {
    /**
     * 按敏感度生成掩码值。
     *
     * - Normal    → 原值
     * - Sensitive → 保留首尾各 1 位（如 3********4）
     * - High      → 全掩码（********）
     *
     * @param value 明文
     * @param sensitivity 敏感度（1=normal 2=sensitive 3=high）
     */
    /**
     * 按敏感度生成掩码值。
     *
     * - Normal    → 原值
     * - Sensitive → 保留首尾各 1 位（如 3********4）
     * - High      → 全掩码（********）
     *
     * 【全部按「字符」而非「字节」处理】
     *   仓颉的 `String.size` 是字节数，`value[0..1]` 切出的是**单个字节**。
     *   含中文的值（签发机关「市公安局」、地址、姓名等）被逐字节切碎后拼接，
     *   会直接抛 `IllegalArgumentException: Invalid utf8 byte sequence`
     *   —— 实测 `GET /api/search` 一遇到敏感条目就 500。
     *   改用 chars() 按 UTF-8 边界切分后，掩码长度也**按字符数**计
     *   （此前 9 字节的「市公安局」会显示 9 个星号，实际只有 4 个字）。
     *
     * @param value 明文
     * @param sensitivity 敏感度（1=normal 2=sensitive 3=high）
     */
    public static func mask(value: String, sensitivity: Int64): String {
        if (sensitivity <= 1 || value.isEmpty()) {
            return value
        }
        let cs = Masker.chars(value)
        let n = cs.size
        if (sensitivity >= 3) {
            // 高敏：全掩码，保留长度信息但不泄漏内容
            return Masker.repeat("*", n)
        }
        // 敏感：保留首尾各 1 位
        if (n <= 2) {
            return Masker.repeat("*", n)
        }
        return "${cs[0]}${Masker.repeat("*", n - 2)}${cs[n - 1]}"
    }

    /**
     * 生成指定长度的掩码串。
     */
    private static func repeat(ch: String, n: Int64): String {
        if (n <= 0) {
            return ""
        }
        var sb = StringBuilder()
        for (i in 0..n) {
            sb.append(ch)
        }
        return sb.toString()
    }

    /**
     * 身份证号的专用掩码（保留前 4 后 2 —— 对齐 FR-SRC-006）。
     *
     * 例：18 位 → "1101**********34"（前 4 位省+市 + 后 2 位校验位，
     * 中间 12 位打码；共暴露 6/18 位，比行业惯用的前 6 后 4 更克制）。
     */
    public static func maskIdCard(value: String): String {
        let cs = Masker.chars(value)
        let n = cs.size
        if (n < 6) {
            return Masker.repeat("*", n)
        }
        var sb = StringBuilder()
        for (i in 0..4) {
            sb.append(cs[i])
        }
        sb.append(Masker.repeat("*", n - 6))
        sb.append(cs[n - 2])
        sb.append(cs[n - 1])
        return sb.toString()
    }

    /**
     * 手机号的专用掩码（保留前 3 后 4）。
     */
    public static func maskPhone(value: String): String {
        let cs = Masker.chars(value)
        let n = cs.size
        if (n < 7) {
            return Masker.repeat("*", n)
        }
        var sb = StringBuilder()
        for (i in 0..3) {
            sb.append(cs[i])
        }
        sb.append(Masker.repeat("*", n - 7))
        for (i in n - 4..n) {
            sb.append(cs[i])
        }
        return sb.toString()
    }

    /**
     * 按 UTF-8 字符边界切分为单字数组。
     *
     * 与分词器的 toChars 同思路：首字节高位决定字符占几字节，
     * 保证后续任何切片都落在字符边界上。
     */
    private static func chars(s: String): Array<String> {
        let out = ArrayList<String>()
        var i: Int64 = 0
        while (i < s.size) {
            let len = Masker.utf8Len(s[i])
            if (len <= 0) {
                // 非法首字节（理论上不会出现）：跳过，避免死循环
                i = i + 1
            } else if (i + len > s.size) {
                out.add(s[i..s.size])
                i = s.size
            } else {
                out.add(s[i..(i + len)])
                i = i + len
            }
        }
        return out.toArray()
    }

    /**
     * 按 UTF-8 首字节判定该字符占几字节。
     */
    private static func utf8Len(b: Byte): Int64 {
        if (b < 0x80u8) {
            return 1
        }
        if (b >= 0xC0u8 && b < 0xE0u8) {
            return 2
        }
        if (b >= 0xE0u8 && b < 0xF0u8) {
            return 3
        }
        if (b >= 0xF0u8 && b < 0xF8u8) {
            return 4
        }
        return 0
    }
}

/**
 * 检索参数构造器。
 *
 * 关键安全约束（FR-ACL-006）：
 *   `subjectIds` 由**服务端**根据授权上下文填充，
 *   前端传入的主体范围**不生效**。
 */
public class SearchQueryBuilder {
    private var keyword: String = ""
    private var subjectIds: Array<String> = Array<String>()
    private var categoryCodes: Array<Int64> = Array<Int64>()
    private var statuses: Array<Int64> = Array<Int64>()
    private var issuer: String = ""
    private var issuedFrom: String = ""
    private var issuedTo: String = ""
    private var expiresFrom: String = ""
    private var expiresTo: String = ""
    private var tagIds: Array<String> = Array<String>()
    private var blindFilters: ArrayList<(String, Array<Byte>)> = ArrayList<(String, Array<Byte>)>()
    private var extraFilters: ArrayList<(String, String)> = ArrayList<(String, String)>()
    private var sortField: SortField = SortField.UpdatedAt
    private var sortDirection: SortDirection = SortDirection.Desc
    private var pageSize: Int64 = 20
    private var cursor: Cursor = Cursor("", "")
    private var source: Int64 = 0
    private var createdFrom: String = ""
    private var createdTo: String = ""

    public init() {
    }

    public func keyword_(kw: String): SearchQueryBuilder {
        this.keyword = kw
        return this
    }

    /**
     * 设置主体范围（**只能由服务端调用**）。
     */
    public func subjectScope(ids: Array<String>): SearchQueryBuilder {
        this.subjectIds = ids
        return this
    }

    public func category(codes: Array<Int64>): SearchQueryBuilder {
        this.categoryCodes = codes
        return this
    }

    public func status(codes: Array<Int64>): SearchQueryBuilder {
        this.statuses = codes
        return this
    }

    public func issuer_(v: String): SearchQueryBuilder {
        this.issuer = v
        return this
    }

    public func issuedRange(from: String, to: String): SearchQueryBuilder {
        this.issuedFrom = from
        this.issuedTo = to
        return this
    }

    public func expiresRange(from: String, to: String): SearchQueryBuilder {
        this.expiresFrom = from
        this.expiresTo = to
        return this
    }

    /**
     * 来源系统筛选（FR-SRC-010）。
     *
     * @param v 0=手动 1=CSV导入 2=克隆 3=OCR 4=附件导入；0 表示不过滤
     */
    public func source_(v: Int64): SearchQueryBuilder {
        this.source = v
        return this
    }

    /**
     * 创建时间范围（FR-SRC-010）。
     */
    public func createdRange(from: String, to: String): SearchQueryBuilder {
        this.createdFrom = from
        this.createdTo = to
        return this
    }

    public func tags(ids: Array<String>): SearchQueryBuilder {
        this.tagIds = ids
        return this
    }

    /**
     * 盲索引等值筛选（FR-SRC-005）。
     */
    public func blindFilter(fieldKey: String, bidx: Array<Byte>): SearchQueryBuilder {
        this.blindFilters.add((fieldKey, bidx))
        return this
    }

    public func extraFilter(fieldKey: String, value: String): SearchQueryBuilder {
        this.extraFilters.add((fieldKey, value))
        return this
    }

    public func sortBy(field: SortField, direction: SortDirection): SearchQueryBuilder {
        this.sortField = field
        this.sortDirection = direction
        return this
    }

    public func pageSize_(n: Int64): SearchQueryBuilder {
        this.pageSize = n
        return this
    }

    public func cursor_(c: Cursor): SearchQueryBuilder {
        this.cursor = c
        return this
    }

    /**
     * 构造最终查询。
     */
    public func build(): SearchQuery {
        return SearchQuery(
            this.keyword, this.subjectIds, this.categoryCodes, this.statuses,
            this.issuer, this.issuedFrom, this.issuedTo,
            this.expiresFrom, this.expiresTo, this.tagIds,
            this.blindFilters.toArray(), this.extraFilters.toArray(),
            SortSpec(this.sortField, this.sortDirection),
            this.pageSize, this.cursor,
            source: this.source, createdFrom: this.createdFrom, createdTo: this.createdTo)
    }
}
