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

public struct ParameterDescription <: BackendMessage & Serializable<ParameterDescription> {
    var kind = b't'
    var len: Int32 = 0
    public var paramNum = 0i16
    public var paramOids = Array<Int32>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.paramNum = buf.getInt16()
        this.paramOids = Array<Int32>(Int64(paramNum), repeat: 0)
        for (i in 0..Int64(paramNum)) {
            this.paramOids[i] = buf.getInt32()
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(paramNum)
        for (i in 0..Int64(paramNum)) {
            buf.add(this.paramOids[i])
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
            .add(field<Int16>("paramNum", paramNum))
            .add(field<String>("paramOids", paramOids.toString()))
    }

    public static func deserialize(dm: DataModel): ParameterDescription {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = ParameterDescription()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.paramNum = Int16.deserialize(dms.get("paramNum"))
        // result.paramOids = Array<Int32>.deserialize(dms.get("paramOids"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
