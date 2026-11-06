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

internal import stdx.net.tls.common.CertificateVerifyMode
internal import stdx.net.tls.TlsClientConfig
import cangjie_tpc::opengauss.url
import cangjie_tpc::opengauss.utils.*

public struct URLParser {
    let connstr: String
    public init(connstr: String) {
        this.connstr = connstr
    }
    public func parse(): Option<Config> {
        if (let Some(url) <- url.Parser.parseURI(connstr)) {
            var cfg = Config()
            let hosts = parseHost(url.authority.hostinfo)
            cfg.addrs = hosts
            if (hosts.size > 0) {
                if (hosts[0][0].size > 0) {
                    cfg.host = hosts[0][0]
                }
                if (hosts[0][1] > 0) {
                    cfg.port = hosts[0][1]
                }
            }

            var dbname = url.path.trimStart("/")
            if (dbname.size > 0) {
                cfg.database = dbname
            }
            if (url.authority.userinfo.username.size > 0) {
                cfg.user = url.authority.userinfo.username
            }

            cfg.password = url.authority.userinfo.password
            for ((k, v) in url.params) {
                if (k == "dbname") {
                    cfg.params["database"] = v
                } else {
                    cfg.params[k] = v
                }
            }
            cfg.tlsconfig = ssl(cfg.params, cfg.host)

            return cfg
        } else {
            return None
        }
    }
    func ssl(params: HashMap<String, String>, host: String): Option<TlsClientConfig> {
        let sslmode = params.get("sslmode") ?? "prefer"
        let sslrootcert = params.get("sslrootcert") ?? ""
        let sslcert = params.get("sslcert") ?? ""
        let sslkey = params.get("sslkey") ?? ""
        let sslpassword = params.get("sslpassword") ?? ""
        let sslsni = params.get("sslsni") ?? "1"
        var tlsconfig = TlsClientConfig()
        match (sslmode) {
            case "disable" =>
                tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
                return None
            case "allow" | "prefer" => tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
            case "require" => tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
            case "verify-ca" => tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
            case "verify-full" =>
                tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
            case _ => return None
        }

//        if (sslsni == "" || sslsni.startsWith("1")) {
//            tlsconfig.domain = host
//        }
        return tlsconfig
    }
    func parseHost(hostinfo: String) {
        var hosts = ArrayList<(String, UInt16)>()
        for (hp in hostinfo.split(",")) {
            let (h, _, p) = hp.partition(b':')
            let port = if (p.size > 0) {
                UInt16.tryParse(p) ?? 0
            } else {
                0u16
            }
            hosts.add((h, port))
        }
        return hosts
    }
}
