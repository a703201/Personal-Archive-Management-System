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

public struct CopyBothResponse <: BackendMessage & Serializable<CopyBothResponse> {
    var kind = b'W'
    var len: Int32 = 0
    var overallFmt: Int8 = 0
    var colNum: Int16 = 0
    var colFmts = Array<Int16>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.overallFmt = buf.getInt8()
        this.colNum = buf.getInt16()
        this.colFmts = Array<Int16>(Int64(colNum), repeat: 0)
        for (i in 0..Int64(this.colNum)) {
            this.colFmts[i] = buf.getInt16()
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(overallFmt)
        buf.add(colNum)
        for (fmt in colFmts) {
            buf.add(fmt)
        }
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int8>("overallFmt", overallFmt))
            .add(field<Int16>("colNum", colNum))
            .add(field<String>("colFmts", colFmts.toString()))
    }

    public static func deserialize(dm: DataModel): CopyBothResponse {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = CopyBothResponse()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.overallFmt = Int8.deserialize(dms.get("overallFmt"))
        result.colNum = Int16.deserialize(dms.get("colNum"))
        // result.colFmts = Array<Int16>.deserialize(dms.get("colFmts"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
