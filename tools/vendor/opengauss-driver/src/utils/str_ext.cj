/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 */
package cangjie_tpc::opengauss.utils

import std.time.*
import std.collection.*

public interface StringExtention {
    func partition(c: Byte): (String, Byte, String)
    func rpartition(c: Byte): (String, Byte, String)
}

extend String <: StringExtention {
    public func partition(c: Byte): (String, Byte, String) {
        match (this.indexOf(c)) {
            case Some(i) => return (this[0..i], c, if (i < this.size - 1) {
                    this[i + 1..this.size]
                } else {
                    ""
                })
            case _ => return ("", c, "")
        }
    }
    public func rpartition(c: Byte): (String, Byte, String) {
        match (this.lastIndexOf(c)) {
            case Some(i) => return (this[0..i], c, if (i < this.size - 1) {
                    this[i + 1..this.size]
                } else {
                    ""
                })
            case _ => return ("", c, "")
        }
    }
}

public func formatTS(ts: String): (String, Option<DateTime>) {
    var tmpts = match (ts.indexOf("-")) {
        case Some(v) => ts
        case _ => DateTime.now().format("yyyy-MM-dd") + " " + ts.trimAscii()
    }
    let tsit = tmpts.iterator()
    let sb = ReadWriteBuffer(256)
    let nanosb = ReadWriteBuffer(64)
    var state = 0
    var hasnano = false
    var hastz = false
    while (true) {
        let c = tsit.next() ?? break
        match {
            case c == b'.' =>
                sb.add(c)
                state = 1
            case c >= b'0' && c <= b'9' => if (state == 1) {
                nanosb.add(c)
                hasnano = true
            } else {
                sb.add(c)
            }
            case _ =>
                if (state == 1) {
                    var nano = unsafe { String.fromUtf8Unchecked(nanosb.data()) }
                    nano = nano.padEnd(6, padding: "0")
                    sb.add(nano.toArray())
                    state = 0
                    nanosb.reset()
                    hastz = true
                }
                sb.add(c)
        }
    }
    if (nanosb.size > 0) {
        var nano = unsafe { String.fromUtf8Unchecked(nanosb.data()) }
        nano = nano.padEnd(6, padding: "0")
        sb.add(nano.toArray())
    }
    try {
        var timestr = unsafe { String.fromUtf8Unchecked(sb.data()) }
        if (sb.size > 20) {
            // 可能有微秒或时区
            if (hasnano) {
                // 有微秒
                if (hastz) {
                    // 有时区
                    return (timestr, DateTime.parse(timestr, "yyyy-MM-dd HH:mm:ss.SSO"))
                } else {
                    // 无时区
                    return (timestr, DateTime.parse(timestr, "yyyy-MM-dd HH:mm:ss.SS"))
                }
            } else {
                // 无微秒
                return (timestr, DateTime.parse(timestr, "yyyy-MM-dd HH:mm:ssO"))
            }
        } else {
            // 没有毫秒/纳秒或时区
            return (timestr, DateTime.parse(timestr, "yyyy-MM-dd HH:mm:ss"))
        }
    } catch (ex: Exception) {
        // 解析时区异常
    }
    return (unsafe { String.fromUtf8Unchecked(sb.data()) }, Option<DateTime>.None)
}

public func stringToBool(str: String): Bool {
    var lowerStr = str.toAsciiLower().trimAscii()
    match (lowerStr) {
        case "1" => return true
        case "true" => return true
        case _ => return false
    }
}

public func getFirstWord(str: String): String {
    var ret = ""
    var firstIndex = getFirstNotSpaceIndex(str, 0i64)
    if ((firstIndex >= str.size) || (firstIndex < 0)) {
        return ""
    }
    var endIndex = getFirstSpaceIndex(str, firstIndex)
    if (endIndex < 0) {
        ret = str[firstIndex..]
    } else {
        ret = str[firstIndex..endIndex]
    }
    return ret
}

public func getFirstNotSpaceIndex(str: String, startIndex: Int64): Int64 {
    var ret = startIndex
    if (ret >= str.size) {
        return -1
    }
    while ((str[ret] == b' ') || (str[ret] == b'\t') || (str[ret] == b'\n') || (str[ret] == b'\r')) {
        ret++
        if (ret >= str.size) {
            ret = -1
            break;
        }
    }
    return ret
}

public func getFirstSpaceIndex(str: String, startIndex: Int64): Int64 {
    var ret = startIndex
    if (ret >= str.size) {
        return -1
    }
    while ((str[ret] != b' ') && (str[ret] != b'\t') && (str[ret] != b'\n') && (str[ret] != b'\r')) {
        ret++
        if (ret >= str.size) {
            ret = -1
            break;
        }
    }
    return ret
}
