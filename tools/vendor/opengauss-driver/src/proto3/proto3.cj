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
package cangjie_tpc::opengauss.proto3

internal import std.binary.*
internal import std.io.*
internal import cangjie_tpc::opengauss.slog.*
internal import std.math.*
import std.sync.*
internal import stdx.serialization.serialization.*
internal import stdx.encoding.hex.*
internal import stdx.encoding.json.*
internal import cangjie_tpc::opengauss.chunkreader.*
internal import std.collection.*
internal import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.slog

let DEFAULT_BUFFER_LENGTH = 1024
let logger = slog.Default()

public enum DBType <: Equatable<DBType> & ToString {
    | OpenGauss
    | Postgres
    | Family

    public static func of(v: Int32): DBType {
        match (v) {
            case 1 => OpenGauss
            case 2 => Postgres
            case _ => Family
        }
    }

    public func value(): Int32 {
        match (this) {
            case OpenGauss => 1
            case Postgres => 2
            case Family => 0
        }
    }
    public operator func ==(rhs: DBType): Bool {
        return this.value() == rhs.value()
    }
    public operator func !=(rhs: DBType): Bool {
        return this.value() != rhs.value()
    }
    public func toString(): String {
        return value().toString()
    }
}

public interface Message <: ToString {
    mut func decode(data: Array<UInt8>): Unit
    func encode(): Array<UInt8>
}

public interface BackendMessage <: Message {
    func backend(): Unit {}
}

public interface FrontendMessage <: Message {
    func frontend(): Unit {}
}

public class Frontend {
    let inputstream: VBufferedInputStream
    let outputstream: VBufferedOutputStream
    var authCode = 0i32
    public init(r: InputStream, w: OutputStream) {
        this.inputstream = VBufferedInputStream(r)
        this.outputstream = VBufferedOutputStream(w)
    }
    public func sendMessage(msg: FrontendMessage) {
        if (logger.level.ge(LogLevel.Debug)) {
            logger.debug("send msg ${msg}")
        }
        outputstream.write(msg.encode())
    }
    public func flush() {
        outputstream.flush()
    }
    func receiveMessage(): (Byte, Array<Byte>, Int64) {
        var buflen = 128
        var buf = Array<Byte>(buflen, repeat: 0)
        inputstream.get(buf, 0, 5)
        let t = buf[0]
        let remainlen = Int64(UInt32.readBigEndian(buf[1..5])) - 4
        if (buflen < remainlen) {
            buf = Array<Byte>(remainlen, repeat: 0)
        }
        inputstream.get(buf, 0, remainlen)
        buf = buf[..remainlen]
        return (t, buf, remainlen)
    }

    public func receive(dbType: DBType): Option<BackendMessage> {
        let m = receiveMessage()
        let msg: BackendMessage
        match (m[0]) {
            case b'1' => msg = ParseComplete()
            case b'2' => msg = BindComplete()
            case b'3' => msg = CloseComplete()
            case b'A' => msg = NotificationResponse()
            case b'c' => msg = CopyDone()
            case b'C' => msg = CommandComplete()
            case b'd' => msg = CopyData()
            case b'D' => msg = DataRow()
            case b'E' => msg = ErrorResponse()
            case b'G' => msg = CopyInResponse()
            case b'H' => msg = CopyOutResponse()
            case b'I' => msg = EmptyQueryResponse()
            case b'K' => msg = BackendKeyData()
            case b'n' => msg = NoData()
            case b'N' => msg = NoticeResponse()
            case b'R' => msg = if (m[2] > 4) {
                getAuthMessage(dbType, Int32.readBigEndian(m[1][0..4]))
            } else {
                getAuthMessage(dbType, Int32.readBigEndian(m[1][0..4]))
            }
            case b's' => msg = PortalSuspended()
            case b'S' => msg = ParameterStatus()
            case b't' => msg = ParameterDescription()
            case b'T' => msg = RowDescription()
            case b'v' => msg = NegotiateProtocolVersion()
            case b'V' => msg = FunctionCallResponse()
            case b'W' => msg = CopyBothResponse()
            case b'Z' => msg = ReadyForQuery()
            case _ => throw Exception("unknown message type ${m[0]}")
        }
        msg.decode(m[1])

        // logger.debug("receive ${msg}[${buf.size + 5}]")
        return msg
    }
    func getAuthMessage(dbType: DBType, code: Int32): BackendMessage {
        authCode = code
        let msg: BackendMessage
        match (code) {
            case 0 => msg = AuthenticationOk()
            case 2 => msg = AuthenticationKerberosV5()
            case 3 => msg = AuthenticationCleartextPassword()
            case 5 => msg = AuthenticationMD5Password()
            case 6 => msg = AuthenticationSCMCredential()
            case 7 => msg = AuthenticationGSS()
            case 8 => msg = AuthenticationGSSContinue()
            case 9 => msg = AuthenticationSSPI()
            case 10 => msg = match (dbType) {
                case DBType.OpenGauss => AuthenticationRFC5802()
                case _ => AuthenticationSASL()
            }
            case 11 => msg = match (dbType) {
                case DBType.OpenGauss => AuthenticationRFC5802()
                case _ => AuthenticationSASLContinue()
            }
            case 12 => msg = AuthenticationSASLFinal()
            case _ => throw Exception("not support authentication code ${code}")
        }
        return msg
    }
}
