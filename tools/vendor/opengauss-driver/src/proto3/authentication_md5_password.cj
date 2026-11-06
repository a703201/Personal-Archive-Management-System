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

public struct AuthenticationMD5Password <: AuthenticationMessage & Serializable<AuthenticationMD5Password> {
    var kind = b'R'
    var len: Int32 = 12
    var code = AuthCode.MD5_PASSWORD
    public var data = Array<Byte>(4, repeat: 0)

    public init() {}

    public init(kind: Rune, data: Array<Byte>) {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)
        this.code = AuthCode.of(buf.getInt32())
        buf.get(this.data, 0, 4)
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(code.value())
        buf.add(this.data)
        return buf.data()
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("code", code.value()))
            .add(field<String>("data", data.toString()))
    }

    public static func deserialize(dm: DataModel): AuthenticationMD5Password {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = AuthenticationMD5Password()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.code = AuthCode.of(Int32.deserialize(dms.get("code")))
        // result.data = Array<Byte>.deserialize(dms.get("data"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
