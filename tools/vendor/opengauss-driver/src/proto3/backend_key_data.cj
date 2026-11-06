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

public struct BackendKeyData <: BackendMessage & Serializable<BackendKeyData> {
    var kind = b'K'
    var len: Int32 = 12
    public var processID: Int32 = 0
    public var secretkey: Int32 = 0

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.processID = buf.getInt32()
        this.secretkey = buf.getInt32()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(processID)
        buf.add(secretkey)
        return buf.data()
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("processID", processID))
            .add(field<Int32>("secretkey", secretkey))
    }

    public static func deserialize(dm: DataModel): BackendKeyData {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = BackendKeyData()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.processID = Int32.deserialize(dms.get("processID"))
        result.secretkey = Int32.deserialize(dms.get("secretkey"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
