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

internal import stdx.encoding.hex.*
import stdx.crypto.digest.*

public func RFC5802Algorithm(
    password: String,
    salt: String,
    token: String,
    serverSignature: String,
    serverIteration: Int64,
    method: String
): String {
    var iter = 2048
    if (serverIteration > 0) {
        iter = serverIteration
    }
    let saltBytes = fromHexString(salt) ?? []
    let k = PBKDF2.key(password.toArray(), saltBytes, iter, 32, newSHA1)
    let serverKey = HMac.digest(newSHA256, k, "Sever Key".toArray())
    let clientKey = HMac.digest(newSHA256, k, "Client Key".toArray())

    let storedKey: Array<UInt8>
    if (method == "sha256") {
        storedKey = digest(SHA256(), clientKey)
    } else if (method == "sm3") {
        storedKey = digest(SM3(), clientKey)
    } else {
        storedKey = clientKey
    }

    let tokenBytes = fromHexString(token) ?? []

    let clientSignature = HMac.digest(newSHA256, serverKey, tokenBytes)
    if (serverSignature != "" && serverSignature != toHexString(clientSignature)) {
        return ""
    }
    let hmacResult = HMac.digest(newSHA256, storedKey, tokenBytes)
    let h = clientKey.clone()
    xor(h, hmacResult)

    return toHexString(h)
}
