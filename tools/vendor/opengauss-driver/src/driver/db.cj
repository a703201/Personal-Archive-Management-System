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

import std.collection.*
import std.convert.*
import std.database.sql.*
import std.random.{Random}
import std.sync.*
import std.time.*
import stdx.net.tls.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.interx.*
import cangjie_tpc::opengauss.pgconn.*
import cangjie_tpc::opengauss.pgconn

const DEFAULT_MASTER_ADDRESS_CACHE_INVALID_TIME = 600000

public class PGDB <: Datasource & PGDBInteface {
    var rnd = Random(UInt64(DateTime.now().toUnixTimeStamp().toMilliseconds()))
    var tlscfg = Option<TlsClientConfig>.None
    var config = Config()
    var lastGotMasterTime = DateTime.fromUnixTimeStamp(Duration.second)
    var lastMasterHost = ""
    var lastMasterPort = 0u16
    public init(config: Config) {
        this.config = config
        formatConfs()
        this.tlscfg = this.config.tlsconfig
    }
    public func setTlsConfig(tlscfg: TlsClientConfig) {
        this.tlscfg = tlscfg
    }
    public func setOption(key: String, value: String): Unit {
        match (key) {
            case "connection_timeout" => config.connTimeout = Duration.millisecond * Int64.parse(value)
            case "read_timeout" => config.readTimeout = Duration.millisecond * Int64.parse(value)
            case "write_timeout" => config.writeTimeout = Duration.millisecond * Int64.parse(value)
            case "send_buffer_size" => config.sendBufferSize = Int64.parse(value)
            case "receive_buffer_size" => config.receiveBufferSize = Int64.parse(value)
            case "unix_domain_socket" => config.udsfile = value
            case "binary_transfer" => config.binarytransfer = stringToBool(value)
            case "namedstatement" => config.namedstatement = stringToBool(value)
            case "balance" => config.balance = BalanceType.of(value)
            case "shuffle_addrs" =>
                config.shuffleaddrs = stringToBool(value)
                if (config.shuffleaddrs) {
                    // 打乱地址
                    config.addrs = shuffleAddrs(config.addrs)
                }
            case "priority_addrs" =>
                // 逗号隔开的多个地址，例如ip1:port1,ip2:port2
                var addrs = HashMap<String, String>()
                var addrarr = value.split(",")
                for (addr in addrarr) {
                    var tmpaddr = addr.trimAscii()
                    if (tmpaddr.size > 0) {
                        addrs[tmpaddr] = ""
                    }
                }
                config.priorityaddrs = addrs
            case _ => config.params[key] = value
        }
    }

    /*
     * 判断资源是否关闭
     * 返回值 Bool - 如果已经关闭返回 true，否则返回 false
     */
    public func isClosed(): Bool {
        return true
    }

    /*
     * 关闭资源
     */
    public func close(): Unit {}

    /*
     * 尝试连通数据库。如果失败会抛出异常
     */
    public func ping(): Unit {
        config.tlsconfig = tlscfg
        let (pgConn, addrindex) = pgconn.connect(config, " to ping the instance")
        config.setAddrIndex(addrindex)
        pgConn.close();
    }

    /*
     * 返回一个可用的连接
     * 返回值 Connection - 数据库连接实例
     */
    public func connect(): Connection {
        config.tlsconfig = tlscfg
        let (pgConn, addrindex) = pgconn.connect(config, " for datasource")
        config.setAddrIndex(addrindex)
        pgConn.setPgdb(this)
        return PGConnection(pgConn)
    }

    public func checkIsMaster(host: String, port: UInt16): Bool {
        checkIsMaster(host, port, " to check if the instance is master")
    }

    public func checkIsMaster(host: String, port: UInt16, info: String): Bool {
        var ret = false
        var (pgConn, index) = pgconn.connectDirect(config, host, port, info)
        try (connection = PGConnection(pgConn)) {
            try (qr = connection.query("select local_role, db_state from pg_stat_get_stream_replications()")) {                
                while (qr.next()) {
                    var role = qr.get<String>(0)
                    var state = qr.get<String>(1)

                    if ((role.toAsciiLower() == "primary") && (state.toAsciiLower() == "normal")) {
                        ret = true
                    }
                    break
                }
            }
        }
        return ret
    }

    public func findMaster(ignoreAddrs: ArrayList<(String, UInt16)>): (String, UInt16) {
        if (config.addrs.size == 0) {
            // 如果没有配置服务地址列表，那么返回配置中的host和port，目前这种情况不检查是否是master数据库
            return (config.host, config.port)
        } else if (config.addrs.size == 1) {
            // 如果服务地址列表只有一个，那么直接返回列表中的地址，目前这种情况不检查是否是master数据库
            return (config.addrs[0][0], config.addrs[0][1])
        }
        let exsbMutex = Mutex()
        let exsb = StringBuilder(256)
        let sb = StringBuilder(256)
        let futlist = ArrayList<Future<?(String, UInt16)>>()
        // 每个地址启动一个线程去获取master状态
        for (addr in config.addrs) {
            if (isIgnoreAddr(ignoreAddrs, addr)) {
                continue
            }
            futlist.add(
                spawn {
                    =>
                    try {
                        if (checkIsMaster(addr[0], addr[1], " to find a master instance")) {
                            logger.debug("found master instance ${addr[0]}:${addr[1]}")
                            return addr
                        }
                    } catch (ex: Exception) {
                        synchronized(exsbMutex) {
                            exsb.append("${addr[0]}:${addr[1]} error: ${ex.toString()}\n")
                        }
                    }
                    return Option<(String, UInt16)>.None
                })
        }
        var foundMaster = false
        while (!foundMaster) {
            sleep(Duration.millisecond * 10)
            var allthreadend = true
            // 没有找到master，看看线程是否执行完毕
            for (fut in futlist) {
                try {
                    match (fut.tryGet()) {
                        // 线程结束
                        case Some(v) => match (v) {
                            case Some(masterAddr) =>
                                // 找到了master
                                foundMaster = true
                                return masterAddr
                            case _ =>
                                // 不是master
                                ()
                        }
                        // 线程未结束
                        case _ => allthreadend = false
                    }
                } catch (ex: Exception) {
                    // 有异常的话，当做线程结束处理
                }
            }
            if (allthreadend) {
                // 所有线程都结束
                break
            }
        }
        for (addr in config.addrs) {
            sb.append("${addr[0]}:${addr[1]} ")
        }
        throw SqlException(
            "cannot find the master database instance in the addrs ${sb.toString()}.\n${exsb.toString()}")
    }

    private func isIgnoreAddr(ignoreAddrs: ArrayList<(String, UInt16)>, addr: (String, UInt16)): Bool {
        var ret = false
        for (ignoreAddr in ignoreAddrs) {
            if ((ignoreAddr[0] == addr[0]) && (ignoreAddr[1] == addr[1])) {
                ret = true
                break
            }
        }
        return ret
    }

    private func formatConfs() {
        var params = config.params
        config.params = HashMap<String, String>()
        for ((k, v) in params) {
            setOption(k, v)
        }
        addDefaultConfs()
    }

    private func addDefaultConfs() {
        if (!config.params.contains("client_encoding")) {
            // TODO 暂时没有找到获取当前字符集的函数，因此使用UTF-8来代替默认值
            config.params["client_encoding"] = "UTF-8"
        }

        if (!config.params.contains("DateStyle")) {
            config.params["DateStyle"] = "ISO"
        }

        if (!config.params.contains("TimeZone")) {
            // TODO 目前这个获取不到合适的值，因此暂时用东8区来代替默认值
            // config.params.put("TimeZone", TimeZone.Local.id)
            //config.params.put("TimeZone", "GMT+8")
            config.params["TimeZone"] = "Asia/Shanghai"
        }

        if (!config.params.contains("extra_float_digits")) {
            config.params["extra_float_digits"] = "2"
        }
    }

    private func shuffleAddrs(addrs: ArrayList<(String, UInt16)>): ArrayList<(String, UInt16)> {
        // 打乱传入的地址串
        var ret = ArrayList<(String, UInt16)>()
        for (addr in addrs) {
            if (ret.size == 0) {
                ret.add(addr)
            } else {
                ret.add(addr, at: Int64(rnd.nextUInt32()) % (ret.size + 1))
            }
        }
        return ret
    }
}
