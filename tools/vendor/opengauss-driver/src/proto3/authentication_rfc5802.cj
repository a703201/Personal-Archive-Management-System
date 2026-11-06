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

public struct AuthenticationRFC5802 <: AuthenticationMessage & Serializable<AuthenticationRFC5802> {
    var kind = b'R'
    var len: Int32 = -1
    var code = AuthCode.SHA256_PASSWORD
    public var pwdMethod = 0i32
    public var rnd64 = Array<Byte>(64, repeat: 0)
    public var serverSignature = Array<Byte>(64, repeat: 0)
    public var token = Array<Byte>(8, repeat: 0)
    public var iterstep = 0i32
    public var data = Array<Byte>(4, repeat: 0)

    public init() {}

    public init(kind: Rune, data: Array<Byte>) {}

    public mut func decode(data: Array<Byte>): Unit {
        var buf = ReadOnlyBuffer(data)
        this.code = AuthCode.of(buf.getInt32())
        this.pwdMethod = buf.getInt32()
        if (pwdMethod == 0 || pwdMethod == 2) {
            // if (DefaultConfig.protocolVersion == 196608) {
            //     buf.get(this.rnd64, 0, 64)
            //     buf.get(this.serverSignature, 0, 64)
            //     buf.get(this.token, 0, 8)
            // } else if (DefaultConfig.protocolVersion == 196659) {
            //     buf.get(this.rnd64, 0, 64)
            //     buf.get(this.token, 0, 8)
            //     this.iterstep = buf.getInt32()
            // }
            buf.get(this.rnd64, 0, 64)
            buf.get(this.token, 0, 8)
            this.iterstep = buf.getInt32()
        } else { // if (pwdMethod == 1) 
            buf.get(this.data, 0, 4)
        }
    }

    public func encode(): Array<Byte> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(code.value())
        buf.add(pwdMethod)
        if (pwdMethod == 0 || pwdMethod == 2) {
            buf.add(rnd64)
            buf.add(token)
            buf.add(iterstep)
        } else {
            buf.add(this.data)
        }
        return buf.data()
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("code", code.value()))
            .add(field<Int32>("pwdMethod", pwdMethod))
            .add(field<String>("rnd64", String.fromUtf8(rnd64)))
            .add(field<String>("serverSignature", String.fromUtf8(serverSignature)))
            .add(field<String>("token", String.fromUtf8(token)))
            .add(field<Int32>("iterstep", iterstep))
            .add(field<String>("data", toHexString(data)))
    }

    public static func deserialize(dm: DataModel): AuthenticationRFC5802 {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = AuthenticationRFC5802()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.code = AuthCode.of(Int32.deserialize(dms.get("code")))        
        result.data = fromHexString(String.deserialize(dms.get("data"))).getOrThrow()
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
