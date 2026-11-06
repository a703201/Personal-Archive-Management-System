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

internal import std.crypto.digest.*
internal import stdx.crypto.digest.{MD5, SHA256}

func authMd5(username: String, password: String, salt: Array<Byte>): String {
    // concat('md5', md5(concat(md5(concat(password, username)), random-salt)))
    var md5 = MD5()
    md5.write((password + username).toArray())
    var pu = toHexString(md5.finish())
    md5.reset()
    md5.write((pu + unsafe { String.fromUtf8Unchecked(salt) }).toArray())
    return "md5" + toHexString(md5.finish())
}

func authSha256(username: String, password: String, token: Array<Byte>, salt: Array<Byte>): String {
    let sha256 = SHA256()
    sha256.write(password.toArray())
    sha256.write(token)
    let temp_md = sha256.finish()
    sha256.reset()
    sha256.write((toHexString(temp_md) + toHexString(token)).toArray())
    sha256.write(salt)
    return "sha256" + toHexString(sha256.finish())
}

func authMd5Sha256(username: String, password: String, salt: Array<Byte>): String {
    var md5 = MD5()
    md5.write(password.toArray())
    md5.write(username.toArray())
    let temp_md = md5.finish()
    let sha256 = SHA256()
    sha256.write(toHexString(temp_md).toArray())
    sha256.write(salt)
    return "sha256" + toHexString(sha256.finish())
}
