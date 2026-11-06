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

import cangjie_tpc::opengauss.utils.*

public struct DataField <: Serializable<DataField> & ToString {
    public var valLen = 0i32
    public var val = Array<Byte>()

    public mut func decode(buf: ReadOnlyBuffer): Unit {
        valLen = buf.getInt32()
        if (valLen > 0) {
            this.val = buf.get(Int64(valLen))
        }
    }

    public func encode(buf: ReadWriteBuffer) {
        buf.add(valLen)
        buf.add(val)
    }

    public func serialize(): DataModel {
        return DataModelStruct().add(field<Int32>("valLen", valLen)).add(field<String>("val", toHexString(val)))
    }

    public static func deserialize(dm: DataModel): DataField {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = DataField()
        result.valLen = Int32.deserialize(dms.get("valLen"))
        // result.val = Array<Byte>.deserialize(dms.get("val"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}

public struct DataRow <: BackendMessage & Serializable<DataRow> {
    var kind = b'D'
    var len: Int32 = 0
    var fieldNum: Int16 = 0
    public var fields = Array<DataField>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.fieldNum = buf.getInt16()
        fields = Array<DataField>(Int64(fieldNum), repeat: unsafe { zeroValue<DataField>() })
        for (i in 0..Int64(fieldNum)) {
            var filed = DataField()
            filed.decode(buf)
            this.fields[i] = filed
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(fieldNum)
        for (filed in fields) {
            filed.encode(buf)
        }
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        let t: Rune = Rune(UInt32(kind))
        return DataModelStruct()
            .add(field<Rune>("type", t))
            .add(field<Int32>("len", len))
            .add(field<Int16>("fieldNum", fieldNum))
            .add(field<String>("fields", fields.toString()))
    }

    public static func deserialize(dm: DataModel): DataRow {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = DataRow()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.fieldNum = Int16.deserialize(dms.get("fieldNum"))
        // result.fields = Array<DataField>.deserialize(dms.get("fields"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
