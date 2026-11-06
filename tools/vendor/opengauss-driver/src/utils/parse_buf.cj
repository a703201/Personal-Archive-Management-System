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

import std.binary.*

public struct ParseBuf {
    let data: Array<Byte>
    var pos = 0
    let cap: Int64

    public init(data: Array<Byte>) {
        this.data = data
        this.cap = data.size
    }

    public mut func eat(n: Int64): Unit {
        pos += n
    }

    public mut func parse<T>(): T where T <: BigEndianOrder<T> & SizeOfExt<T> {
        let v = T.readBigEndian(data[pos..])
        pos += v.sizeOf()
        return v
    }

    public mut func parse(n: Int64): Array<Byte> {
        let v = data[pos..pos + n]
        pos += n
        return v
    }

    public mut func parseEOFStr(): String {
        let len = this.cap - this.pos
        // pos += len
        return String.fromUtf8(parse(Int64(len)))
    }

    public func remaining(): Int64 {
        return cap - pos
    }
}
