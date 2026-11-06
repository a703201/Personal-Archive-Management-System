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

public struct SASLInitialResponse <: FrontendMessage & Serializable<SASLInitialResponse> {
    var kind = b'p'
    var len: Int32 = 0
    var name = ""
    var datalen = 0i32
    var data = Array<Byte>()

    public init() {}
    public init(name: String, data: Array<Byte>) {
        this.name = name
        this.data = data
        datalen = Int32(data.size)
    }

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.name = buf.getString()
        this.datalen = buf.getInt32()
        if (this.datalen > 0) {
            this.data = Array<Byte>(Int64(datalen), repeat: 0)
            buf.get(this.data, 0, Int64(datalen))
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(name)
        buf.add(0u8)
        buf.add(datalen)
        buf.add(data)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<String>("name", name))
            .add(field<Int32>("datalen", datalen))
            .add(field<String>("data", String.fromUtf8(data)))
    }

    public static func deserialize(dm: DataModel): SASLInitialResponse {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = SASLInitialResponse()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.name = String.deserialize(dms.get("name"))
        result.datalen = Int32.deserialize(dms.get("datalen"))
        result.data = String.deserialize(dms.get("data")).toArray()
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
