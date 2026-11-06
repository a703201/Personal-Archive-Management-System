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

public struct Execute <: FrontendMessage & Serializable<Execute> {
    var kind = b'E'
    var len: Int32 = 0
    var portalName = ""
    var maxRowNum = 0i32

    public init() {}
    public init(portalName: String, maxRowNum: Int32) {
        this.portalName = portalName
        this.maxRowNum = maxRowNum
    }

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.portalName = buf.getString()
        this.maxRowNum = buf.getInt32()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(portalName)
        buf.add(0u8)
        buf.add(maxRowNum)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        let t: Rune = Rune(UInt32(kind))
        return DataModelStruct()
            .add(field<Rune>("type", t))
            .add(field<Int32>("len", len))
            .add(field<String>("portalName", portalName))
            .add(field<Int32>("maxRowNum", maxRowNum))
    }

    public static func deserialize(dm: DataModel): Execute {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = Execute()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.portalName = String.deserialize(dms.get("portalName"))
        result.maxRowNum = Int32.deserialize(dms.get("maxRowNum"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
