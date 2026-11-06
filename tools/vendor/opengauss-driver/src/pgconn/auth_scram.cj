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

internal import std.convert.*
internal import std.io.*
import stdx.crypto.crypto.{SecureRandom}
import stdx.crypto.digest.{SHA256, SHA1}
internal import stdx.encoding.base64.*
internal import stdx.serialization.serialization.*
internal import stdx.encoding.json.*
import cangjie_tpc::opengauss.subtle.*
import cangjie_tpc::opengauss.utils.*
internal import cangjie_tpc::opengauss.slog.*
class scramClient <: Serializable<scramClient> {
    let mechanisms: Array<String>
    let password: Array<Byte>
    var clientNonce = Array<Byte>()
    var clientFirstMessageBare = Array<Byte>()
    var serverFirstMessage: Array<Byte> = []
    var clientAndServerNonce: Array<Byte> = []
    var salt: Array<Byte> = []
    var iterations = 0
    var saltedPassword: Array<Byte> = []
    var authMessage: Array<Byte> = []
    var user: String
    init(mechanisms: Array<String>, password: String, user: String) {
        this.mechanisms = mechanisms
        this.password = password.toArray()
        this.user = user
        let nonceLen = 16
        let buf = Array<Byte>(nonceLen + encodedLen(nonceLen), repeat: 0)
        let rand = SecureRandom()
        buf[0..nonceLen] = rand.nextBytes(Int32(nonceLen))
        clientNonce = buf[nonceLen..]
        let b64 = toBase64String(buf[0..nonceLen])
        clientNonce[..] = b64.toArray()
    }
    func encodedLen(n: Int64): Int64 {
        return (n + 2) / 3 * 4 // minimum # 4-char quanta, 3 bytes each
    }
    func clientFirstMessage(): Array<Byte> {
        let clientNonceStr = "n=${user},r=${String.fromUtf8(clientNonce)}"
        clientFirstMessageBare = clientNonceStr.toArray()
        return "n,,${clientNonceStr}".toArray()
    }
    func clientFinalMessage(): String {
        let clientFinalMessageWithoutProof = "c=biws,r=${String.fromUtf8(clientAndServerNonce)}"
        saltedPassword = PBKDF2.key(password, salt, iterations, 32, newSHA256)
        let authMsgAL = ArrayList<Byte>(clientFirstMessageBare)
        authMsgAL.add(b',')
        authMsgAL.add(all:serverFirstMessage)
        authMsgAL.add(b',')
        authMsgAL.add(all:clientFinalMessageWithoutProof.toArray())
        authMessage = authMsgAL.toArray()
        let clientProof = computeClientProof(saltedPassword, authMessage)
        return "${clientFinalMessageWithoutProof},p=${String.fromUtf8(clientProof)}"
    }
    func recvContinueMsg(data: Array<Byte>): Unit {
        this.serverFirstMessage = data
        var buf = data
        if (buf[0..2] != "r=".toArray()) {
            throw SqlException(
                "invalid SCRAM server-first-message[${toHexString(buf)}] received from server: did not include r=")
        }
        buf = buf[2..]
        if (let Some(idx) <- buf.indexOf(b',')) {
            clientAndServerNonce = buf[0..idx]
            buf = buf[idx + 1..]
        } else {
            return
        }
        if (buf[0..2] != "s=".toArray()) {
            throw SqlException(
                "invalid SCRAM server-first-message[${toHexString(buf)}] received from server: did not include s=")
        }
        buf = buf[2..]
        if (let Some(idx) <- buf.indexOf(b',')) {
            let saltStr = buf[0..idx]
            buf = buf[idx + 1..]
            salt = fromBase64String(String.fromUtf8(saltStr)) ?? []
        } else {
            return
        }
        if (buf[0..2] != "i=".toArray()) {
            throw SqlException(
                "invalid SCRAM server-first-message[${toHexString(buf)}] received from server: did not include i=")
        }
        buf = buf[2..]
        let iterationsStr = buf
        match (Int64.tryParse(String.fromUtf8(iterationsStr))) {
            case None => throw SqlException("invalid SCRAM iteration count received from server")
            case Some(i) =>
                iterations = i
                if (i <= 0) {
                    throw SqlException("invalid SCRAM iteration count(${i}) received from server")
                }
        }
        if (clientAndServerNonce.size <= clientNonce.size) {
            throw SqlException("invalid SCRAM nonce: did not include server nonce")
        }
        if (clientAndServerNonce[0..clientNonce.size] != clientNonce) {
            throw SqlException(
                "invalid SCRAM nonce(${clientAndServerNonce[0..clientNonce.size]}): did not start with client nonce(${clientNonce})"
            )
        }
    }
    func recvFinalMsg(data: Array<Byte>) {
        if (!startWith(data, "v=".toArray())) {
            throw SqlException("invalid SCRAM server-final-message received from server")
        }
        let serverSignature = data[2..]
        if (constantTimeCompare(serverSignature, computeServerSignature(saltedPassword, authMessage)) != 1) {
            throw SqlException("invalid SCRAM ServerSignature received from server")
        }
    }
    func computeClientProof(saltedPassword: Array<Byte>, authMessage: Array<Byte>) {
        let clientKey = HMac.digest(newSHA256, saltedPassword, "Client Key".toArray())
        let storedKey = digest(SHA256(), clientKey)
        let clientSignature = HMac.digest(newSHA256, storedKey, authMessage)
        let clientProof = Array<Byte>(clientSignature.size, repeat: 0)
        for (i in 0..clientSignature.size) {
            clientProof[i] = clientKey[i] ^ clientSignature[i]
        }
        let buf = Array<Byte>(encodedLen(clientProof.size), repeat: 0)
        let b64 = toBase64String(clientProof)
        buf[..] = b64.toArray()
        return buf
    }
    func computeServerSignature(saltedPassword: Array<Byte>, authMessage: Array<Byte>): Array<Byte> {
        let serverKey = HMac.digest(newSHA256, saltedPassword, "Server Key".toArray())
        let serverSignature = HMac.digest(newSHA256, serverKey, authMessage)
        let buf = Array<Byte>(encodedLen(serverSignature.size), repeat: 0)
        let b64 = toBase64String(serverSignature)
        buf[..] = b64.toArray()
        return buf
    }
    public func serialize(): DataModel {
        return DataModelStruct().add(field<String>("mechanisms", mechanisms.toString())).add(
            field<String>("password", String.fromUtf8(password))).add(
            field<String>("clientNonce", String.fromUtf8(clientNonce))).add(
            field<String>("clientFirstMessageBare", String.fromUtf8(clientFirstMessageBare))).add(
            field<String>("serverFirstMessage", String.fromUtf8(serverFirstMessage))).add(
            field<String>("clientAndServerNonce", String.fromUtf8(clientAndServerNonce))).add(
            field<String>("salt", toHexString(salt))).add(field<Int64>("iterations", iterations)).add(
            field<String>("saltedPassword", toHexString(saltedPassword))).add(
            field<String>("authMessage", String.fromUtf8(authMessage)))
    }
    public static func deserialize(dm: DataModel): scramClient {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = scramClient([], "", "")
        return result
    }
    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}

func newSHA256(): SHA256 {
    SHA256()
}

func newSHA1(): SHA1 {
    SHA1()
}
