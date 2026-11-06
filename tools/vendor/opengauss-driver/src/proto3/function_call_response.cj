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

public struct FunctionCallResponse <: BackendMessage & Serializable<FunctionCallResponse> {
    var kind = b'V'
    var len: Int32 = 0
    var resultLen: Int32 = 0
    var result = Array<Byte>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.resultLen = buf.getInt32()
        if (this.resultLen > 0) {
            this.result = Array<Byte>(Int64(resultLen), repeat: 0)
            buf.get(this.result, 0, Int64(resultLen))
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(resultLen)
        buf.add(result)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("resultLen", resultLen))
            .add(field<String>("result", result.toString()))
    }

    public static func deserialize(dm: DataModel): FunctionCallResponse {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = FunctionCallResponse()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.resultLen = Int32.deserialize(dms.get("resultLen"))
        // result.result = Array<Byte>.deserialize(dms.get("result"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
