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

public struct Close <: FrontendMessage & Serializable<Close> {
    var kind = b'C'
    var len: Int32 = 0
    var describe = b'S'
    var name: String = ""

    public init() {}
    public init(name: String, describe: Byte) {
        this.name = name
        this.describe = describe
    }
    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.describe = buf.getByte()
        this.name = buf.getString()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(describe)
        buf.add(name)
        buf.add(0u8)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        let t: Rune = Rune(UInt32(kind))
        return DataModelStruct()
            .add(field<Rune>("type", t))
            .add(field<Int32>("len", len))
            .add(field<Byte>("describe", describe))
            .add(field<String>("name", name))
    }

    public static func deserialize(dm: DataModel): Close {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = Close()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.describe = Byte.deserialize(dms.get("describe"))
        result.name = String.deserialize(dms.get("name"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
