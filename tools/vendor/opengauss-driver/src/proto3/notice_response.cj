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

public struct NoticeResponse <: BackendMessage & Serializable<NoticeResponse> {
    var kind = b'N'
    var len: Int32 = 0
    var params = HashMap<UInt8, String>()

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)
        var leftlen: Int32 = len
        var noticeType: UInt8
        var noticeValue: String
        noticeType = buf.getByte()
        while (noticeType != 0) {
            noticeValue = buf.getString()
            buf.getPosition()
            params[noticeType] = noticeValue
            noticeType = buf.getByte()
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        for ((k, v) in params) {
            buf.add(k)
            buf.add(v)
        }
        buf.add(0u8)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        // 同 startup_message.cj：HashMap 在 stdx 1.2.0 起不再实现 Serializable，
        // 改用 toString() 输出（与上游 error_response.cj 保持一致）。
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<String>("params", params.toString()))
    }

    public static func deserialize(dm: DataModel): NoticeResponse {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = NoticeResponse()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        // 与 serialize 对称：params 以字符串形式存储，此处不再还原为 HashMap
        // （协议反序列化走 decode()，不经过本方法）。
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
