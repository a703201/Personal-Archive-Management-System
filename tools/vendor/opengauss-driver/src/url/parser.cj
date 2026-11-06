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
package cangjie_tpc::opengauss.url

internal import cangjie_tpc::opengauss.slog.*
internal import std.math.*
import cangjie_tpc::opengauss.slog

let logger = slog.Default()

// scheme:[//authority]path[?query][#fragment]
public class Parser {
    public static func parseURI(rawUrl: String): Option<URL> {
        if (rawUrl.isEmpty()) {
            return None
        }
        var url = URL()
        var remaining: String
        match (parseScheme(rawUrl)) {
            case Some(s) =>
                url.scheme = s[0]
                remaining = s[1]
            case _ => return None
        }
        if (remaining.startsWith("//")) {
            var authority = parseAuthority(remaining, start: 2)
            url.authority = Authority(authority[0])
            remaining = authority[1]
        }
        if (remaining.contains("#")) {
            let frags = remaining.split("#", 2)
            url.fragment = frags[1]
            remaining = frags[0]
        }
        if (remaining.contains("?")) {
            let qrys = remaining.split("?", 2)
            url.rawQuery = qrys[1]
            url.parseQuery()
            url.path = percent_decode(qrys[0])
        } else {
            url.path = remaining
        }
        return url
    }

    static func parseScheme(input: String): (Option<(String, String)>) {
        if (!input[0].isAsciiLetter()) {
            return None
        }
        for (i in 0..input.size) {
            let c = input[i]
            if (c.isAsciiLetter() || c.isAsciiNumber() || c == b'+' || c == b'-' || c == b'.') {}
            else if (c == b':') {
                return (input[0..i], input[i + 1..])
            } else {
                return ("", input)
            }
        }
        return ("", input)
    }

    static func parseAuthority(input: String, start!: Int64 = 0): (String, String) {
        var delim = input.size
        for (c in "/?#") {
            match (input.indexOf(c, start)) {
                case Some(wdelim) => delim = min(delim, wdelim)
                case _ => ()
            }
        }
        return (input[start..delim], input[delim..])
    }

    static func isCtl(c: Rune): Bool {
        var cv = UInt32(c)
        return cv < UInt32(r' ') || cv == 0x7F
    }
}
