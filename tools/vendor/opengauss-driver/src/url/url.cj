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
package cangjie_tpc::opengauss.url

internal import std.collection.*
internal import std.convert.*
import cangjie_tpc::opengauss.utils.*

// scheme:[//authority]path;params[?query][#fragment]
public class URL <: ToString {
    public var scheme = ""
    public var authority = Authority("")
    public var path = ""
    public var params = HashMap<String, String>()
    public var rawQuery = ""
    public var fragment = ""

    func parseQuery() {
        var nvs = rawQuery.split("&")
        for (nv in nvs) {
            let (n, _, v) = nv.partition(b'=')
            if (n.size > 0) {
                params[percent_decode(n)]= percent_decode(v)
            }
        }
    }

    public func toString(): String {
        return "scheme='${scheme}', authority='${authority}', path='${path}', rawQuery='${rawQuery}', params=${params}, fragment='${fragment}'"
    }
}

// user:password@host:port,host2:port2
public struct Authority <: ToString {
    public var userinfo = UserInfo("")
    public var hostinfo: String
    public var hostname = ""
    public var port = ""
    public init(authority: String) {
        // split userinfo
        let (ui, _, hi) = authority.rpartition(b'@')
        if (ui.size > 0) {
            userinfo = UserInfo(ui)
            hostinfo = hi
        } else {
            hostinfo = authority
        }

        // split host & port info
        // check if ipv6 addr
        let (_, _, hps) = hostinfo.partition(b'[')
        if (hps.size > 0) {
            // check right ]
            var (h, _, pi) = hps.partition(b']')
            if (h.size == 0) {
                throw Exception("invalid ipv6 host ${hostinfo}")
            }
            hostname = h
            let (_, _, p) = pi.partition(b':')
            port = p
        } else {
            // not ipv6
            let (h, _, p) = hostinfo.partition(b':')
            hostname = h
            port = p
        }
    }
    public func portNumber(): UInt16 {
        if (this.port.size > 0) {
            return UInt16.tryParse(this.port) ?? 0
        }
        return 0
    }
    public func toString(): String {
        return "userinfo='${userinfo}', hostinfo='${hostinfo}', hostname='${hostname}', port='${port}'"
    }
}

public struct UserInfo <: ToString {
    public var username = ""
    public var password = ""
    public init(userinfo: String) {
        var up = userinfo.partition(b':')
        username = up[0]
        password = percent_decode(up[2])
    }
    public func toString(): String {
        return "username='${username}', password='${password}'"
    }
}
