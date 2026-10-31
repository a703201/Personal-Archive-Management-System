// ============================================================
// ams.kernel.util · 文本工具
//
// 为什么需要本文件（实测踩坑，务必先读）：
//
//   仓颉 SDK 1.0.5（windows_x86_64_cjnative）的
//   `String.trimStart()` / `String.trimEnd()` 是**空实现** ——
//   返回原串，不删除任何字符：
//       "  abc  ".trimStart().size == 7   （不是 5）
//   编译器不报警、运行时不抛异常，属于「静默失效」。
//
//   该缺陷曾导致两处真实故障：
//     ① SimpleJson 解析 `{"k": "v"}`（冒号后带空格）时，值被解析成
//        ` "v"`（含前导空格与引号），后端报「用户名与口令不能为空」；
//     ② 审计链校验把 detail 还原成 ` "k"= "v"` 形式，与写入时
//        `k=v` 的规范化串不一致，导致**每条带 detail 的记录都被误判
//        「被篡改」**（FR-AUD-003 假阳性）。
//
//   故本项目统一使用 trimSpace()，禁止再直接调用 trimStart/trimEnd。
// ============================================================
package ams.kernel.util

import std.collection.*

/**
 * 去首尾 ASCII 空白（空格 / \t / \r / \n）。
 *
 * 为什么按**字节**而不是 rune 处理：
 *   UTF-8 多字节序列的所有后续字节都 >= 0x80，不可能等于 ASCII 空白，
 *   因此按字节裁剪不会切断字符，且比 rune 遍历更省。
 */
public func trimSpace(s: String): String {
    let b = s.toArray()
    var start = 0
    var end = b.size
    while (start < end && isWs(b[start])) {
        start = start + 1
    }
    while (end > start && isWs(b[end - 1])) {
        end = end - 1
    }
    if (start == 0 && end == b.size) {
        return s
    }
    return String.fromUtf8(b[start..end])
}

/**
 * 是否 ASCII 空白字节。
 */
public func isWs(b: Byte): Bool {
    return b == 32u8 || b == 9u8 || b == 10u8 || b == 13u8
}

/**
 * 转义为 JSON 字符串字面量内容（不含外围引号）。
 *
 * 与 [jsonFlatEntries] 严格互逆：detail 落库前必须转义，
 * 否则值里的 `"` 会让 jsonb 解析失败、控制字符会被 jsonb 改写为 \uXXXX，
 * 两者都会使审计链重算哈希与落库值不一致。
 */
public func jsonEscape(s: String): String {
    let sb = StringBuilder()
    for (r in s.runes()) {
        if (r == r'"') {
            sb.append("\\\"")
        } else if (r == r'\\') {
            sb.append("\\\\")
        } else if (r == r'\n') {
            sb.append("\\n")
        } else if (r == r'\r') {
            sb.append("\\r")
        } else if (r == r'\t') {
            sb.append("\\t")
        } else if (UInt32(r) < 0x20u32) {
            sb.append("\\u00")
            sb.append(hexDigit((UInt32(r) >> 4) & 0x0Fu32))
            sb.append(hexDigit(UInt32(r) & 0x0Fu32))
        } else {
            sb.append(r.toString())
        }
    }
    return sb.toString()
}

/**
 * 解析**扁平的** JSON 字符串对象为有序键值对。
 *
 * 只处理 `{"k":"v", ...}` 这一层（值统一按字符串处理）：
 *   - 引号内的 , 与 : 不参与切分；
 *   - 支持 \" \\ \/ \b \f \n \r \t \uXXXX（含代理对）转义；
 *   - 非字符串值（数字/布尔/null）取原始 token。
 *
 * 为什么不用 split(",")：值里出现半角逗号（文件名、备注、标题）会被截断，
 * 使规范化串与写入时不一致 —— 审计链会因此误报篡改。
 *
 * 解析失败时返回已解析出的部分（调用方不会因此崩溃）。
 */
public func jsonFlatEntries(text: String): Array<(String, String)> {
    let out = ArrayList<(String, String)>()
    let t = trimSpace(text)
    let b = t.toArray()
    if (b.size < 2 || b[0] != 123u8 || b[b.size - 1] != 125u8) {
        return out.toArray()
    }
    let end = b.size - 1
    var i: Int64 = 1
    while (i < end) {
        while (i < end && (isWs(b[i]) || b[i] == 44u8)) {
            i = i + 1
        }
        if (i >= end || b[i] != 34u8) {
            break
        }
        let keyRead = readJsonString(b, i)
        let key = keyRead[0]
        i = keyRead[1]
        while (i < end && isWs(b[i])) {
            i = i + 1
        }
        if (i < end && b[i] == 58u8) {
            i = i + 1
            while (i < end && isWs(b[i])) {
                i = i + 1
            }
        }
        var value = ""
        if (i < end && b[i] == 34u8) {
            let valRead = readJsonString(b, i)
            value = valRead[0]
            i = valRead[1]
        } else {
            let vs = i
            while (i < end && b[i] != 44u8) {
                i = i + 1
            }
            value = trimSpace(String.fromUtf8(b[vs..i]))
        }
        if (!key.isEmpty()) {
            out.add((key, value))
        }
    }
    return out.toArray()
}

/**
 * 读一个 JSON 字符串字面量（b[from] 必须是引号）。
 *
 * 注意 必须**按字节累积**、最后一次性 fromUtf8：
 *    逐字节 `String.fromUtf8` 遇到中文（多字节序列）会立刻抛
 *    IllegalArgumentException: Invalid utf8 byte sequence。
 *
 * @return (解码后的值, 闭合引号之后的下标)；下标等于 b.size 表示到末尾。
 */
private func readJsonString(b: Array<Byte>, from: Int64): (String, Int64) {
    let out = ArrayList<Byte>()
    var i = from + 1
    while (i < b.size) {
        let c = b[i]
        if (c == 34u8) {
            return (String.fromUtf8(out.toArray()), i + 1)
        }
        if (c != 92u8) {
            out.add(c)
            i = i + 1
            continue
        }
        // 转义
        i = i + 1
        if (i >= b.size) {
            break
        }
        let e = b[i]
        if (e == 110u8) {
            out.add(10u8)
            i = i + 1
        } else if (e == 114u8) {
            out.add(13u8)
            i = i + 1
        } else if (e == 116u8) {
            out.add(9u8)
            i = i + 1
        } else if (e == 98u8) {
            out.add(8u8)
            i = i + 1
        } else if (e == 102u8) {
            out.add(12u8)
            i = i + 1
        } else if (e == 117u8) {
            // \uXXXX
            let r1 = readHex4(b, i + 1)
            var cp = r1[0]
            i = r1[1]
            // 代理对：\uD8xx\uDCxx → 补充平面码点
            if (cp >= 0xD800u32 && cp <= 0xDBFFu32 && i + 5 < b.size &&
                b[i] == 92u8 && b[i + 1] == 117u8) {
                let r2 = readHex4(b, i + 2)
                let lo = r2[0]
                if (lo >= 0xDC00u32 && lo <= 0xDFFFu32) {
                    cp = 0x10000u32 + ((cp - 0xD800u32) << 10) + (lo - 0xDC00u32)
                    i = r2[1]
                }
            }
            appendCodepoint(out, cp)
        } else {
            // \\ \" \/ 及未知转义：原样保留字符
            out.add(e)
            i = i + 1
        }
    }
    return (String.fromUtf8(out.toArray()), i)
}

/**
 * 读 4 位十六进制。
 * @return (值, 之后的下标)
 */
private func readHex4(b: Array<Byte>, from: Int64): (UInt32, Int64) {
    var v: UInt32 = 0
    var i = from
    var n = 0
    while (i < b.size && n < 4) {
        let d = hexVal(b[i])
        if (d < 0) {
            break
        }
        v = v * 16u32 + UInt32(d)
        i = i + 1
        n = n + 1
    }
    return (v, i)
}

/**
 * 十六进制字符 → 值；非十六进制返回 -1。
 */
private func hexVal(b: Byte): Int64 {
    if (b >= 48u8 && b <= 57u8) {
        return Int64(b - 48u8)
    }
    if (b >= 97u8 && b <= 102u8) {
        return Int64(b - 97u8) + 10
    }
    if (b >= 65u8 && b <= 70u8) {
        return Int64(b - 65u8) + 10
    }
    return -1
}

/**
 * 码点 → UTF-8 字节，追加到缓冲区。
 */
private func appendCodepoint(out: ArrayList<Byte>, cp: UInt32): Unit {
    if (cp < 0x80u32) {
        out.add(UInt8(cp))
    } else if (cp < 0x800u32) {
        out.add(UInt8(0xC0u32 | (cp >> 6)))
        out.add(UInt8(0x80u32 | (cp & 0x3Fu32)))
    } else if (cp < 0x10000u32) {
        out.add(UInt8(0xE0u32 | (cp >> 12)))
        out.add(UInt8(0x80u32 | ((cp >> 6) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | (cp & 0x3Fu32)))
    } else {
        out.add(UInt8(0xF0u32 | (cp >> 18)))
        out.add(UInt8(0x80u32 | ((cp >> 12) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | ((cp >> 6) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | (cp & 0x3Fu32)))
    }
}

/**
 * 十六进制半字节 → 字符。
 */
private func hexDigit(v: UInt32): String {
    if (v < 10u32) {
        return "${v}"
    }
    if (v == 10u32) {
        return "a"
    }
    if (v == 11u32) {
        return "b"
    }
    if (v == 12u32) {
        return "c"
    }
    if (v == 13u32) {
        return "d"
    }
    if (v == 14u32) {
        return "e"
    }
    return "f"
}
