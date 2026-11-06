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

public struct AuthenticationSASL <: AuthenticationMessage & Serializable<AuthenticationSASL> {
    var kind = b'R'
    var len: Int32 = 0
    var code = AuthCode.SASL
    public var mechanisms: Array<String> = Array<String>()

    public init() {}

    public init(kind: Rune, data: Array<Byte>) {}

    public mut func decode(data: Array<UInt8>): Unit {
        let mechanismList = ArrayList<String>()
        var buf = data
        this.code = AuthCode.of(Int32.readBigEndian(buf))
        if (0 == buf.size - 4){
            return
        }
        while (buf.size > 0) {
            if (let Some(idx) <- buf.indexOf(0u8)) {
                let mechanism = String.fromUtf8(buf[0..idx]).trimAscii()
                if (mechanism != "") {
                    mechanismList.add(mechanism)
                }
                if (buf.size == idx + 1) {
                    break
                }
                buf = buf[idx + 1..]
            } else {
                throw Exception("unterminated string")
            }
        }
        this.mechanisms = mechanismList.toArray()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(code.value())
        for (mechanism in mechanisms) {
            buf.add(mechanism)
            buf.add(0u8)
        }

        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("code", code.value()))
            .add(field<String>("mechanisms", mechanisms.toString()))
    }

    public static func deserialize(dm: DataModel): AuthenticationSASL {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = AuthenticationSASL()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.code = AuthCode.of(Int32.deserialize(dms.get("code")))
        // result.mechanisms = Array<String>.deserialize(dms.get("mechanisms"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
