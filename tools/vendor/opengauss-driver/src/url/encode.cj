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

internal import stdx.encoding.url.UrlSyntaxException

let percent_bytes = """
%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F
%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F
%20%21%22%23%24%25%26%27%28%29%2A%2B%2C%2D%2E%2F
%30%31%32%33%34%35%36%37%38%39%3A%3B%3C%3D%3E%3F
%40%41%42%43%44%45%46%47%48%49%4A%4B%4C%4D%4E%4F
%50%51%52%53%54%55%56%57%58%59%5A%5B%5C%5D%5E%5F
%60%61%62%63%64%65%66%67%68%69%6A%6B%6C%6D%6E%6F
%70%71%72%73%74%75%76%77%78%79%7A%7B%7C%7D%7E%7F
%80%81%82%83%84%85%86%87%88%89%8A%8B%8C%8D%8E%8F
%90%91%92%93%94%95%96%97%98%99%9A%9B%9C%9D%9E%9F
%A0%A1%A2%A3%A4%A5%A6%A7%A8%A9%AA%AB%AC%AD%AE%AF
%B0%B1%B2%B3%B4%B5%B6%B7%B8%B9%BA%BB%BC%BD%BE%BF
%C0%C1%C2%C3%C4%C5%C6%C7%C8%C9%CA%CB%CC%CD%CE%CF
%D0%D1%D2%D3%D4%D5%D6%D7%D8%D9%DA%DB%DC%DD%DE%DF
%E0%E1%E2%E3%E4%E5%E6%E7%E8%E9%EA%EB%EC%ED%EE%EF
%F0%F1%F2%F3%F4%F5%F6%F7%F8%F9%FA%FB%FC%FD%FE%FF
"""

func percent_encode(b: Byte): String {
    let idx = Int64(b * 3)
    return percent_bytes[idx..idx + 3]
}

func percent_decode(str: String, q!: Bool = false): String {
    let sb = StringBuilder()
    let it = str.iterator()
    let buffer = ArrayList<Byte>()
    var escape = false
    var i = 0
    while (true) {
        var c = it.next() ?? break
        match (c) {
            case b'%' => if (str.size >= i + 2) {
                let c1 = it.next() ?? b' '
                let c2 = it.next() ?? b' '
                if (!isHex(c1) || !isHex(c2)) {
                    throw UrlSyntaxException(str, "invalid URL escape")
                } else {
                    if (!escape) {
                        buffer.clear()
                    }
                    escape = true
                    buffer.add(hexToDec(c1) << 4 | hexToDec(c2))
                }
            } else {
                throw UrlSyntaxException(str, "invalid URL escape")
            }
            case b'+' where q =>
                if (escape) {
                    sb.appendFromUtf8(unsafe { buffer.getRawArray()[0..buffer.size] })
                }
                sb.append(' ')
                escape = false
            case _ =>
                if (escape) {
                    sb.appendFromUtf8(unsafe { buffer.getRawArray()[0..buffer.size] })
                }
                sb.appendFromUtf8(c)
                escape = false
        }
        i++
    }
    if (escape) {
        sb.appendFromUtf8(unsafe { buffer.getRawArray()[0..buffer.size] })
    }
    return sb.toString()
}
func isHex(c: Byte): Bool {
    match {
        case b'0' <= c && c <= b'9' => return true
        case b'a' <= c && c <= b'f' => return true
        case b'A' <= c && c <= b'F' => return true
        case _ => return false
    }
}
func hexToDec(b: Byte): Byte {
    match {
        case b'0' <= b && b <= b'9' => return b - b'0'
        case b'a' <= b && b <= b'f' => return b - b'a' + 10
        case b'A' <= b && b <= b'F' => return b - b'A' + 10
        case _ => 0
    }
}
