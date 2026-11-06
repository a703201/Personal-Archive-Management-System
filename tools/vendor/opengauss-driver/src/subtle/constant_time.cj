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
package cangjie_tpc::opengauss.subtle

public func constantTimeCompare(x: Array<Byte>, y: Array<Byte>): Int64 {
    if (x.size != y.size) {
        return 0
    }
    var v: Byte = 0
    for (i in 0..x.size) {
        v |= x[i] ^ y[i]
    }
    return constantTimeByteEq(v, 0)
}

@OverflowWrapping
public func constantTimeByteEq(x: UInt8, y: UInt8): Int64 {
    return Int64((UInt32(x ^ y) - 1) >> 31)
}
