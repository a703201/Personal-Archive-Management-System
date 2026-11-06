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

class Backend {
    let cr: ChunkReader
    let w: OutputStream
    let buf = Array<Byte>(DEFAULT_BUFFER_LENGTH, repeat: 0)
    var authCode = 0i32
    public init(r: InputStream, w: OutputStream) {
        this.cr = ChunkReader(r)
        this.w = w
    }
    func receiveMessage(): Option<(Byte, Array<Byte>)> {
        var buf: Array<Byte>
        var obuf = cr.read(5)
        match (obuf) {
            case Some(v) => buf = v
            case None => return None
        }

        let t = buf[0]
        let remainlen = Int64(Int32.readBigEndian(buf[1..])) - 4

        obuf = cr.read(remainlen)
        match (obuf) {
            case Some(v) => buf = v
            case None => return None
        }
        return (t, buf)
    }
    public func receive(): Option<FrontendMessage> {
        let m = receiveMessage()
        match (m) {
            case Some((t, buf)) =>
                let msg: FrontendMessage
                match (t) {
                    case b'B' => msg = Bind()
                    case b'C' => msg = Close()
                    case b'D' => msg = Describe()
                    case b'E' => msg = Execute()
                    case b'F' => msg = FunctionCall()
                    case b'f' => msg = CopyFail()
                    case b'd' => msg = CopyData()
                    case b'c' => msg = CopyDone()
                    case b'H' => msg = Flush()
                    case b'P' => msg = Parse()
                    case b'p' => match (AuthCode.of(authCode)) {
                        case SASL => msg = SASLInitialResponse()
                        case SASL_CONTINUE => msg = SASLResponse()
                        case SASL_FINAL => msg = SASLResponse()
                        case GSS | GSS_CONTINUE => msg = GSSResponse()
                        case CLEARTEXT_PASSWORD | MD5_PASSWORD => msg = PasswordMessage()
                        case _ => msg = PasswordMessage()
                    }

                    case b'Q' => msg = Query()
                    case b'S' => msg = Sync()
                    case b'X' => msg = Terminate()
                    case _ => throw Exception("unknown message type ${t}")
                }
                if (logger.level.ge(LogLevel.Debug)) {
                    logger.debug("backend receive ${msg}")
                }
                msg.decode(buf)
                return msg
            case None => return None
        }
    }
}
