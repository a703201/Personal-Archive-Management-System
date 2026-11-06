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
package cangjie_tpc::opengauss.driver

internal import std.collection.*
internal import cangjie_tpc::opengauss.slog.*
internal import std.net.*
internal import std.database.sql.*
internal import std.sync.*
import std.time.*
internal import stdx.net.tls.*
internal import cangjie_tpc::opengauss.pgconn.*
internal import cangjie_tpc::opengauss.proto3.*
internal import cangjie_tpc::opengauss.sqlpool.*
import cangjie_tpc::opengauss.slog

let logger = slog.Default()
let tlsConfigMux = Mutex()
let tlsConfigRegistry = HashMap<String, TlsClientConfig>()
let reservedKey = HashSet<String>(
    [
        "disable",
        "allow",
        "prefer",
        "require",
        "verify-ca",
        "verify-full"
    ]
)

public func registerTLSConfig(key: String, config: TlsClientConfig) {
    let lowerKey = key.toAsciiLower()
    let (value, valid) = readBool(lowerKey)
    if (valid || reservedKey.contains(lowerKey)) {
        throw SqlException("key '${key}' is reserved")
    }
    synchronized(tlsConfigMux) {
        tlsConfigRegistry[key] = config
    }
}

public func deregisterTLSConfig(key: String) {
    synchronized(tlsConfigMux) {
        tlsConfigRegistry.remove(key)
    }
}

func getTlsConfigClone(key: String) {
    synchronized(tlsConfigMux) {
        return tlsConfigRegistry.get(key)
    }
}

func readBool(input: String) {
    match (input) {
        case "1" | "TRUE" => return (true, true)
        case "0" | "FALSE" => return (false, true)
        case _ => return (false, false)
    }
}

let _ = {
    =>
    DriverManager.register("postgres", PGDriver("postgres"))
    DriverManager.register("opengauss", PGDriver("opengauss"))
    DriverManager.register("chinamobiledb", PGDriver("chinamobiledb"))
}()

let drivername = "opengauss"
let driverversion = "0.1.2"
let driverstarttime = DateTime.now()

public class PGDriver <: Driver {
    init() {
        DriverManager.register("postgres", PGDriver("postgres"))
        DriverManager.register("opengauss", PGDriver("opengauss"))
        DriverManager.register("chinamobiledb", PGDriver("chinamobiledb"))
    }
    private var scheme = "postgres"
    public init(scheme: String) {
        this.scheme = scheme.toAsciiLower()
    }
    public prop name: String {
        get() {
            return drivername
        }
    }
    public prop version: String {
        get() {
            return driverversion
        }
    }
    public prop preferredPooling: Bool {
        get() {
            return true
        }
    }
    public func open(connstr: String, opts: Array<(String, String)>): Datasource {
        logger.debug("in PGDriver.openDb ${connstr}")
        let urlparse = URLParser(connstr)
        if (let Some(cfg) <- urlparse.parse()) {
            logger.debug("${cfg}")
            var config = cfg
            if (this.scheme == "postgres") {
                config.scheme = DBType.Postgres
            } else {
                config.scheme = DBType.OpenGauss
            }

            let sslmode = cfg.params.get("sslmode") ?? "prefer"
            config.sslmode = sslmode
            if (let Some(t) <- getTlsConfigClone(sslmode)) {
                config.tlsconfig = t
            }
            for ((k, v) in opts) {
                config.params[k] = v
            }
            return PGDB(config)
        }
        throw SqlException("failed to parse as URL ${connstr}")
    }
    public func getDriverStartTime(): DateTime {
        return driverstarttime
    }
}
