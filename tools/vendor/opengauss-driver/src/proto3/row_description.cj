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

public struct FieldDescription <: Serializable<FieldDescription> & ToString {
    public var name: String = ""
    public var tblOid: Int32 = 0
    public var tblAttrNum = 0i16
    public var datatypeOid = 0i32
    public var datatypeLen = 0i16
    public var typeModifier = 0i32
    public var fmtCode = 0i16

    public mut func decode(buf: ReadOnlyBuffer): Unit {
        this.name = buf.getString()
        this.tblOid = buf.getInt32()
        this.tblAttrNum = buf.getInt16()
        this.datatypeOid = buf.getInt32()
        this.datatypeLen = buf.getInt16()
        this.typeModifier = buf.getInt32()
        this.fmtCode = buf.getInt16()
    }

    public func encode(buf: ReadWriteBuffer) {
        buf.add(name)
        buf.add(0u8)
        buf.add(tblOid)
        buf.add(tblAttrNum)
        buf.add(datatypeOid)
        buf.add(datatypeLen)
        buf.add(typeModifier)
        buf.add(fmtCode)
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<String>("name", name))
            .add(field<Int32>("tblOid", tblOid))
            .add(field<Int16>("tblAttrNum", tblAttrNum))
            .add(field<Int32>("datatypeOid", datatypeOid))
            .add(field<Int16>("datatypeLen", datatypeLen))
            .add(field<Int32>("typeModifier", typeModifier))
            .add(field<Int16>("fmtCode", fmtCode))
    }

    public static func deserialize(dm: DataModel): FieldDescription {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = FieldDescription()
        result.name = String.deserialize(dms.get("name"))
        result.tblOid = Int32.deserialize(dms.get("tblOid"))
        result.tblAttrNum = Int16.deserialize(dms.get("tblAttrNum"))
        result.datatypeOid = Int32.deserialize(dms.get("datatypeOid"))
        result.datatypeLen = Int16.deserialize(dms.get("datatypeLen"))
        result.typeModifier = Int32.deserialize(dms.get("typeModifier"))
        result.fmtCode = Int16.deserialize(dms.get("fmtCode"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}

public struct RowDescription <: BackendMessage & Serializable<RowDescription> {
    var kind = b'T'
    var len: Int32 = 0
    var fieldNum: Int16 = 0
    public var fields = Array<FieldDescription>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        fieldNum = buf.getInt16()
        fields = Array<FieldDescription>(Int64(fieldNum), repeat: unsafe { zeroValue<FieldDescription>() })
        for (i in 0..Int64(fieldNum)) {
            var fieldDescription = FieldDescription()
            fieldDescription.decode(buf)
            this.fields[i] = fieldDescription
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

    public static func deserialize(dm: DataModel): RowDescription {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = RowDescription()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.fieldNum = Int16.deserialize(dms.get("fieldNum"))
        // result.fields = Array<FieldDescription>.deserialize(dms.get("fields"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
