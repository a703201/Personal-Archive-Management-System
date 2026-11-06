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
internal import std.crypto.digest.Digest

public class HMac <: Digest {
    var ipadDigest: Digest
    var opadDigest: Digest
    var ipad: Array<Byte>
    var opad: Array<Byte>

      public prop algorithm: String{
        get() {
            "HMac"
        }
    }

    public init(h: () -> Digest, key: Array<Byte>) {
        ipadDigest = h()
        opadDigest = h()
        let blocksize = ipadDigest.blockSize
        ipad = Array<Byte>(blocksize, repeat: 0)
        opad = Array<Byte>(blocksize, repeat: 0)
        var tempKey = key
        if (key.size > blockSize) {
            opadDigest.write(key)
            tempKey = opadDigest.finish()
        }
        tempKey.copyTo(ipad, 0, 0, tempKey.size)
        tempKey.copyTo(opad, 0, 0, tempKey.size)
        for (i in 0..ipad.size) {
            ipad[i] ^= 0x36
        }
        for (i in 0..opad.size) {
            opad[i] ^= 0x5c
        }
        ipadDigest.write(ipad)
    }

    public prop size: Int64 {
        get() {
            return opadDigest.size
        }
    }
    public prop blockSize: Int64 {
        get() {
            return ipadDigest.blockSize
        }
    }
    public func reset(): Unit {
        ipadDigest.reset()
        ipadDigest.write(ipad)
    }
    public func write(buffer: Array<Byte>): Unit {
        ipadDigest.write(buffer)
    }
    public func finish(to!:Array<Byte>): Unit {
        let inn = ipadDigest.finish()
        opadDigest.reset()
        opadDigest.write(opad)
        opadDigest.write(inn)
        let buf= opadDigest.finish()
        buf.copyTo(to)
    }
    public func finish(): Array<Byte> {
        let inn = ipadDigest.finish()
        opadDigest.reset()
        opadDigest.write(opad)
        opadDigest.write(inn)
        return opadDigest.finish()
    }
    public static func digest(h: () -> Digest, key: Array<Byte>, salt: Array<Byte>): Array<Byte> {
        var hmac = HMac(h, key)
        hmac.write(salt)
        return hmac.finish()
    }
}
