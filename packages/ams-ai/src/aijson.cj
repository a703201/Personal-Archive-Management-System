// ============================================================
// ams.ai.aijson · 模型响应容错解析（三档降级的客户端补救）
//
// 为什么不用 ams.api.routes.SimpleJson：
//   它只取顶层字符串字段，无法解析 choices[0].message.content 这种
//   嵌套结构（见 auth.cj 注释：复杂 JSON 应用 stdx.encoding.json）。
// 为什么不用 stdx.encoding.json：
//   本模块是基础设施层，先用**自包含的嵌套提取器**保证零外部 API 风险；
//   能够对"模型常见的脏输出"（代码围栏、前后废话、尾逗号）做容错。
//
// 能力边界（如实标注）：
//   - 支持：对象取值（含嵌套路径 a.b.c）、字符串/数字/布尔/数组原始串提取
//   - 支持：去 ```json 围栏、截取首个 { 到末个 }、跳过空白
//   - 不做：完整 JSON AST / 转义还原（字符串值内的 \" 保持原样交给上层）
// ============================================================
package ams.ai

import std.collection.*

import ams.kernel.util.*

/**
 * 嵌套 JSON 提取器。所有方法解析失败返回 None，不抛异常。
 */
public class AiJson {
    private let text: String
    private let bytes: Array<Byte>

    private init(text: String) {
        this.text = text
        this.bytes = text.toArray()
    }

    /**
     * 入口：清洗模型输出（去围栏 / 截首个 JSON 对象）后构造。
     */
    public static func of(raw: String): Option<AiJson> {
        let cleaned = AiJson.clean(raw)
        if (cleaned.isEmpty()) { return None }
        let j = AiJson(cleaned)
        // 基本形态校验：必须是 { ... }
        let t = trimSpace(cleaned)
        if (!t.startsWith("{") || !t.endsWith("}")) { return None }
        return Some(j)
    }

    public func raw(): String {
        return this.text
    }

    /**
     * 取字符串字段（嵌套路径用点号，如 "choices.0.message.content"）。
     * 返回**未加外围引号、未反转义**的原始内容（调用方按需处理）。
     */
    public func str(path: String): Option<String> {
        match (this.locate(path)) {
            case Some(pos) => return AiJson.readStringValue(this.bytes, pos)
            case None => return None
        }
    }

    /**
     * 取任意值的原始 JSON 串（对象/数组/数字/布尔/字符串均可）。
     */
    public func value(path: String): Option<String> {
        match (this.locate(path)) {
            case Some(pos) =>
                let end = AiJson.skipValue(this.bytes, pos)
                if (end <= pos) { return None }
                return Some(String.fromUtf8(this.bytes[pos..end]))
            case None => return None
        }
    }

    /**
     * 专用：从 OpenAI 兼容响应里提取 choices[0].message.content。
     *
     * 不走通用路径定位，直接用字符串查找 "content" 键（生产关键路径，
     * 单一职责更可靠）：找到第一个 "content": 后的字符串值，处理转义引号。
     */
    public func messageContent(): Option<String> {
        let marker = "\"content\"".toArray()
        var pos = AiJson.indexOf(this.bytes, marker, 0)
        while (pos >= 0) {
            var i = pos + marker.size
            while (i < this.bytes.size && (isWs(this.bytes[i]) || this.bytes[i] == b':')) {
                i = i + 1
            }
            match (AiJson.readStringValue(this.bytes, i)) {
                case Some(v) => return Some(v)
                case None => ()
            }
            pos = AiJson.indexOf(this.bytes, marker, pos + 1)
        }
        return None
    }

    /**
     * 取数组字段的元素原始串列表（如 sources: [12,15]）。
     */
    public func array(path: String): Array<String> {
        let out = ArrayList<String>()
        match (this.value(path)) {
            case Some(v) =>
                let b = v.toArray()
                var i = 0
                while (i < b.size && b[i] != b'[') { i = i + 1 }
                if (i < b.size) { i = i + 1 }
                while (i < b.size) {
                    while (i < b.size && (isWs(b[i]) || b[i] == b',')) { i = i + 1 }
                    if (i >= b.size || b[i] == b']') { break }
                    let start = i
                    let end = AiJson.skipValue(b, start)
                    if (end <= start) { break }
                    out.add(String.fromUtf8(b[start..end]))
                    i = end
                }
            case None => ()
        }
        return out.toArray()
    }

    /**
     * 定位路径对应的值起始下标。
     */
    /**
     * 定位 path 对应值的起始下标。
     *
     * 实现策略（务实，如实标注边界）：取 path 的**最后一段**作为 key，
     * 在整个 JSON 文本中做「带引号 + 后随冒号」的精确匹配。
     * 模型响应（choices[0].message.content / usage.prompt_tokens / answer 等）
     * 的叶子 key 在单次响应里基本唯一，故够用；**不保证**同名 key 出现在
     * 多个数组元素时取到正确的那一个（本期不涉及）。
     * 需要严格路径语义时，上层应按元素拆分后分别对子对象调用 AiJson.of。
     */
    private func locate(path: String): Option<Int64> {
        let parts = path.split(".")
        if (parts.isEmpty()) { return None }
        let leaf = parts[parts.size - 1]
        let key = ("\"" + leaf + "\"").toArray()
        let keyPos = match (AiJson.findKey(this.bytes, 0, key)) {
            case Some(p) => p
            case None => return None
        }
        var i = keyPos + key.size
        while (i < this.bytes.size && (isWs(this.bytes[i]) || this.bytes[i] == b':')) {
            i = i + 1
        }
        return Some(i)
    }

    private static func isDigits(s: String): Bool {
        let b = s.toArray()
        if (b.isEmpty()) { return false }
        for (c in b) {
            if (c < 48u8 || c > 57u8) { return false }
        }
        return true
    }

    private static func toInt(s: String): Int64 {
        let b = s.toArray()
        var v: Int64 = 0
        for (c in b) { v = v * 10 + Int64(c - 48u8) }
        return v
    }

    /**
     * 从 from 起找键名 key（必须在引号内且后跟冒号），返回键名起始下标。
     */
    private static func findKey(b: Array<Byte>, from: Int64, key: Array<Byte>): Option<Int64> {
        var i = from
        var inString = false
        var escaped = false
        while (i < b.size) {
            let c = b[i]
            if (inString) {
                if (escaped) {
                    escaped = false
                } else if (c == b'\\') {
                    escaped = true
                } else if (c == b'"') {
                    inString = false
                }
                i = i + 1
                continue
            }
            if (c == b'"') {
                // 可能是键名：比较后续字节
                if (AiJson.matchAt(b, i, key)) {
                    var j = i + key.size
                    while (j < b.size && isWs(b[j])) { j = j + 1 }
                    if (j < b.size && b[j] == b':') { return Some(i) }
                }
                inString = true
            }
            // 不在遇到 } / ] 时提前返回：外层对象的后续 key 可能排在数组之后
            // （如 {"sources":[...],"answer":"ok"} 里的 answer）。
            // key 精确匹配且要求后随冒号，跨元素误匹配风险低。
            i = i + 1
        }
        return None
    }

    private static func matchAt(b: Array<Byte>, at: Int64, key: Array<Byte>): Bool {
        if (at + key.size > b.size) { return false }
        for (i in 0..key.size) {
            if (b[at + i] != key[i]) { return false }
        }
        return true
    }

    /**
     * 读字符串值：期望 pos 指向 '"'，返回引号内内容（保留转义序列）。
     */
    /**
     * 读 JSON 字符串值并**反转义**。
     *
     * 关键：模型把 JSON 作为 content 字符串返回时，内层 JSON 的引号/换行
     * 是转义形式（\" 与 \\n）。旧实现直接 fromUtf8 原始字节、不反转义，
     * 导致下游再解析 content 时 findKey("fields") 错位 → value 返回 None
     * （V 域字段识别恒为 0 的根因，2026-11-17）。
     * 按字节累积、一次性 fromUtf8，中文多字节安全。
     */
    private static func readStringValue(b: Array<Byte>, pos: Int64): Option<String> {
        var i = pos
        while (i < b.size && isWs(b[i])) { i = i + 1 }
        if (i >= b.size || b[i] != b'"') { return None }
        i = i + 1
        var out = ArrayList<Byte>()
        while (i < b.size) {
            let c = b[i]
            if (c == b'"') {
                return Some(String.fromUtf8(out.toArray()))
            }
            if (c == b'\\' && i + 1 < b.size) {
                let nx = b[i + 1]
                if (nx == b'n') {
                    out.add(10u8); i = i + 2; continue
                } else if (nx == b'r') {
                    out.add(13u8); i = i + 2; continue
                } else if (nx == b't') {
                    out.add(9u8); i = i + 2; continue
                } else if (nx == b'b') {
                    out.add(8u8); i = i + 2; continue
                } else if (nx == b'f') {
                    out.add(12u8); i = i + 2; continue
                } else if (nx == b'"' || nx == b'\\' || nx == b'/') {
                    out.add(nx); i = i + 2; continue
                } else if (nx == b'u' && i + 5 < b.size) {
                    // \uXXXX：仅处理 BMP ASCII 范围（模型内容里的中文通常是裸 UTF-8，
                    // 不走此分支）。非 ASCII 码点用 Rune 生成后按 UTF-8 追加。
                    let h = AiJson.hex4(b, i + 2)
                    if (h >= 0) {
                        if (h < 128) {
                            out.add(UInt8(h))
                        } else {
                            let rs = Rune(h).toString().toArray()
                            for (rb in rs) { out.add(rb) }
                        }
                        i = i + 6
                        continue
                    }
                }
            }
            out.add(c)
            i = i + 1
        }
        return None
    }

    /** 解析 4 位十六进制；失败返回 -1。 */
    private static func hex4(b: Array<Byte>, pos: Int64): Int64 {
        var v: Int64 = 0
        for (k in 0..4) {
            let c = b[pos + k]
            let d = AiJson.hexDigit(c)
            if (d < 0) { return -1 }
            v = v * 16 + d
        }
        return v
    }

    private static func hexDigit(c: Byte): Int64 {
        if (c >= 48u8 && c <= 57u8) { return Int64(c - 48u8) }
        if (c >= 97u8 && c <= 102u8) { return Int64(c - 87u8) }
        if (c >= 65u8 && c <= 70u8) { return Int64(c - 55u8) }
        return -1
    }

    /**
     * 跳过一个 JSON 值，返回结束后的下标。
     */
    private static func skipValue(b: Array<Byte>, pos: Int64): Int64 {
        var i = pos
        while (i < b.size && isWs(b[i])) { i = i + 1 }
        if (i >= b.size) { return i }
        let c = b[i]
        if (c == b'"') {
            i = i + 1
            var escaped = false
            while (i < b.size) {
                let x = b[i]
                if (escaped) {
                    escaped = false
                } else if (x == b'\\') {
                    escaped = true
                } else if (x == b'"') {
                    return i + 1
                }
                i = i + 1
            }
            return i
        }
        if (c == b'{' || c == b'[') {
            let close: Byte = if (c == b'{') { b'}' } else { b']' }
            var depth = 0
            var inString = false
            var escaped = false
            while (i < b.size) {
                let x = b[i]
                if (inString) {
                    if (escaped) {
                        escaped = false
                    } else if (x == b'\\') {
                        escaped = true
                    } else if (x == b'"') {
                        inString = false
                    }
                } else {
                    if (x == b'"') {
                        inString = true
                    } else if (x == b'{' || x == b'[') {
                        depth = depth + 1
                    } else if (x == b'}' || x == b']') {
                        depth = depth - 1
                        if (depth == 0 && x == close) { return i + 1 }
                    }
                }
                i = i + 1
            }
            return i
        }
        // 数字 / true / false / null：读到分隔符
        while (i < b.size && !isWs(b[i]) && b[i] != b',' && b[i] != b'}' && b[i] != b']') {
            i = i + 1
        }
        return i
    }

    /**
     * 清洗：去 ```json 围栏，截取首个 { 到末个 }。
     */
    private static func clean(raw: String): String {
        var t = trimSpace(raw)
        var b = t.toArray()
        if (t.startsWith("```")) {
            let nl = AiJson.indexOfByte(b, 10u8, 0)
            match (nl) {
                case Some(p) => t = trimSpace(String.fromUtf8(b[p + 1..b.size]))
                case None => ()
            }
            b = t.toArray()
            if (t.endsWith("```") && b.size >= 3) {
                t = trimSpace(String.fromUtf8(b[0..b.size - 3]))
                b = t.toArray()
            }
        }
        let first = AiJson.indexOfByte(b, 123u8, 0)       // {
        let last = AiJson.lastIndexOfByte(b, 125u8)      // }
        match (first) {
            case Some(f) =>
                match (last) {
                    case Some(l) =>
                        if (l < f) { return "" }
                        return trimSpace(String.fromUtf8(b[f..l + 1]))
                    case None => return ""
                }
            case None => return ""
        }
    }

    private static func indexOf(b: Array<Byte>, needle: Array<Byte>, from: Int64): Int64 {
        var i = from
        while (i + needle.size <= b.size) {
            var ok = true
            for (j in 0..needle.size) {
                if (b[i + j] != needle[j]) { ok = false; break }
            }
            if (ok) { return i }
            i = i + 1
        }
        return -1
    }

    private static func indexOfByte(b: Array<Byte>, target: Byte, from: Int64): Option<Int64> {
        var i = from
        while (i < b.size) {
            if (b[i] == target) { return Some(i) }
            i = i + 1
        }
        return None
    }

    private static func lastIndexOfByte(b: Array<Byte>, target: Byte): Option<Int64> {
        var i = b.size - 1
        while (i >= 0) {
            if (b[i] == target) { return Some(i) }
            i = i - 1
        }
        return None
    }
}
