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

public struct SSLRequest <: FrontendMessage & Serializable<SSLRequest> {
    var len: Int32 = 8
    var reqCode: Int32 = 80877103

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.reqCode = buf.getInt32()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(len)
        buf.add(reqCode)
        var arr = buf.data()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct().add(field<Int32>("len", len)).add(field<Int32>("reqCode", reqCode))
    }

    public static func deserialize(dm: DataModel): SSLRequest {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = SSLRequest()
        result.len = Int32.deserialize(dms.get("len"))
        result.reqCode = Int32.deserialize(dms.get("reqCode"))

        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
