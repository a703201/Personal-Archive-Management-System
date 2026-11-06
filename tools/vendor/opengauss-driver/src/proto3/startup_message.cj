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

let DriverSetting = HashSet<String>(
    [
        "host",
        "port",
        "password",
        "sslmode",
        "sslcert",
        "sslkey",
        "sslrootcert",
        "sslpassword",
        "sslsni",
        "fallback_application_name",
        "connect_timeout",
        "connection_timeout",
        "disable_prepared_binary_result",
        "binary_parameters",
        "shuffle_addrs",
        "balance",
        "binary_transfer",
        "namedstatement",
        "priority_addrs",
        "read_timeout",
        "write_timeout",
        "send_buffer_size",
        "receive_buffer_size",
        "unix_domain_socket"
    ]
)

public struct StartupMessage <: FrontendMessage & Serializable<StartupMessage> {
    var len: Int32 = 0
    var protocolVersion: Int32 = 196608
    var parameters = HashMap<String, String>()

    public init() {}

    public init(protocolVersion: Int32, parameters: HashMap<String, String>) {
        this.protocolVersion = protocolVersion
        for ((k, v) in parameters) {
            this.parameters[k] = v
        }
    }

    public func addParam(name: String, value: String) {
        parameters[name] = value
    }

    public func removeParam(name: String) {
        parameters.remove(name)
    }

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)
        // this.len = buf.getInt32()
        var protocolVersion = buf.getInt32()
        if (protocolVersion != this.protocolVersion) {
            throw Exception(
                "Bad startup message version number. Expected ${this.protocolVersion}, got ${protocolVersion}, remaining ${buf.remaining()}")
        }
        if (1 == buf.remaining()) { // 为空的情况
            return
        }
        while (true) {
            var k = buf.getString()
            var v = buf.getString()
            parameters[k] = v
            if (buf.remaining() == 1) {
                var term = buf.getByte()
                if (term != 0) {
                    throw Exception("Bad startup message last byte. Expected 0, got ${term}")
                }
                break
            }
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(len)
        buf.add(protocolVersion)
        for ((k, v) in parameters) {
            if (DriverSetting.contains(k)) {
                continue
            }
            buf.add(k)
            buf.add(0u8)
            buf.add(v)
            buf.add(0u8)
        }
        buf.add(0u8)
        var arr = buf.data()
        arr[0..4] = UInt32(arr.size).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        // 注意：parameters 是 HashMap<String,String>，
        // 而 stdx 1.2.0 起 HashMap **不再实现** Serializable 接口，
        // 用 field<HashMap<...>> 会在运行期抛
        // "extensionData is nullptr, itf: ...Serializable<HashMap<String,String>>"。
        // 上游 error_response.cj 已用 params.toString() 规避同一问题，此处保持一致。
        // serialize() 仅服务于调试用的 toString()，不影响协议编码（encode() 独立实现）。
        return DataModelStruct()
            .add(field<Int32>("len", len))
            .add(field<Int32>("protocolVersion", protocolVersion))
            .add(field<String>("parameters", parameters.toString()))
    }

    public static func deserialize(dm: DataModel): StartupMessage {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var sm = StartupMessage()
        var protocolVersion = Int32.deserialize(dms.get("protocolVersion"))
        if (protocolVersion != sm.protocolVersion) {
            throw Exception(
                "Bad startup message version number. Expected ${sm.protocolVersion}, got ${protocolVersion}")
        }
        // 与 serialize 对称：parameters 以字符串形式存储，此处不再还原为 HashMap
        // （协议反序列化走 decode()，不经过本方法）。
        return sm
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
