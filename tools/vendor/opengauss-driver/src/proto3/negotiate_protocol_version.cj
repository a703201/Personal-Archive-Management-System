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

public struct NegotiateProtocolVersion <: BackendMessage & Serializable<NegotiateProtocolVersion> {
    var kind = b'v'
    var len: Int32 = 0
    var minorProtoVersion: Int32 = 0
    var unknownOptNum: Int32 = 0
    var optionName: String = ""

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.minorProtoVersion = buf.getInt32()
        this.unknownOptNum = buf.getInt32()
        if (unknownOptNum > 0) {
            this.optionName = buf.getString()
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(minorProtoVersion)
        buf.add(unknownOptNum)
        buf.add(optionName)
        buf.add(0u8)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("minorProtoVersion", minorProtoVersion))
            .add(field<Int32>("unknownOptNum", unknownOptNum))
            .add(field<String>("optionName", optionName))
    }

    public static func deserialize(dm: DataModel): NegotiateProtocolVersion {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = NegotiateProtocolVersion()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.minorProtoVersion = Int32.deserialize(dms.get("minorProtoVersion"))
        result.unknownOptNum = Int32.deserialize(dms.get("unknownOptNum"))
        result.optionName = String.deserialize(dms.get("optionName"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
