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
package cangjie_tpc::opengauss.pgconn

internal import std.collection.*
internal import std.time.*
import stdx.net.tls.*
import cangjie_tpc::opengauss.proto3.*

public struct Config <: ToString {
    public var scheme = DBType.Postgres
    public var addrs = ArrayList<(String, UInt16)>()
    public var host = "127.0.0.1"
    public var port = 5432u16
    public var database = "postgres"
    public var user = "postgres"
    public var password = ""
    public var udsfile = ""
    // 默认连接超时设置为3分钟
    public var connTimeout: Option<Duration> = Duration.minute * 3
    public var readTimeout = Option<Duration>.None
    public var writeTimeout = Option<Duration>.None
    public var sendBufferSize = Option<Int64>.None
    public var receiveBufferSize = Option<Int64>.None
    public var tlsconfig: Option<TlsClientConfig> = None
    public var sslmode = ""
    public var balance = BalanceType.LEASTCONN
    public var addrindex = 0i32
    public var shuffleaddrs = false
    public var binarytransfer = false
    public var namedstatement = false
    // 优先连接的地址
    public var priorityaddrs = HashMap<String, String>()
    public var params = HashMap<String, String>()
    public mut func setAddrIndex(index: Int32) {
        addrindex = index
    }

    // 因为配置项很多，==和!=后续有需要再说
    // public operator func ==(rhs: Config): Bool {
    //     match ((tlsconfig, rhs.tlsconfig)) {
    //         case (Some(lt), Some(rt)) => match ((lt.clientCertificate, rt.clientCertificate)) {
    //             case (Some(lca), Some(rca)) => if (lca[0] != rca[0]) {
    //                 return false
    //             }
    //             // refEq(lca[1], rca[1])
    //             case (None, None) => ()
    //             case _ => return false
    //         }
    //         case (None, None) => ()
    //         case _ => return false
    //     }
    //     return scheme == rhs.scheme && host == rhs.host && port == rhs.port && database == rhs.database && user == rhs.
    //         user && password == rhs.password && connTimeout == rhs.connTimeout && params == rhs.params
    // }

    // public operator func !=(rhs: Config): Bool {
    //     return !(this == rhs)
    // }

    public func toString(): String {
        return "host='${host}', port='${port}', database='${database}', user='${user}', password='${password}', sslmode='${sslmode}', params='${params}'"
    }
}
