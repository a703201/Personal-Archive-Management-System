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
package cangjie_tpc::opengauss.pgconn

import std.math
import std.binary.*

// PBKDF2 password salt algorithm
public class PBKDF2 {
    public static func key(password: Array<Byte>, salt: Array<Byte>, iter: Int64, keyLen: Int64, h: () -> Digest): Array<Byte> {
        let prf = HMac(h, password)
        let hashLen = prf.size
        let numBlocks = (keyLen + hashLen - 1) / hashLen
        let blockBytesArray = Array<Byte>(4, repeat: 0)
        let dk = Array<Byte>(numBlocks * hashLen, repeat: 0)
        var ndk = 0
        var U = Array<Byte>(hashLen, repeat: 0)
        for (block in 1..=numBlocks) {
            prf.reset()
            prf.write(salt)
            UInt32(block).writeBigEndian(blockBytesArray)
            prf.write(blockBytesArray)
            ndk += copy(dk[ndk..], prf.finish())
            let T = dk[(ndk - hashLen)..ndk]
            copy(U, T)
            for (n in 2..=iter) {
                prf.reset()
                prf.write(U)
                U = U[0..0]
                U = prf.finish()
                for (x in 0..U.size) {
                    T[x] ^= U[x]
                }
            }
        }
        return dk[0..keyLen]
    }
}

// copy src to dst, use the min size of (dst, src)
public func copy<T>(dst: Array<T>, src: Array<T>): Int64 {
    let copyLen = min(dst.size, src.size)
    src.copyTo(dst, 0, 0, copyLen)
    return copyLen
}

// xor src to dst
public func xor(dst: Array<Byte>, src: Array<Byte>) {
    let size = min(dst.size, src.size)
    for (i in 0..size) {
        dst[i] ^= src[i]
    }
}
