/**
 * Copyright 2024 Beijing Baolande Software Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Runtime Library Exception to the Apache 2.0 License:
 *
 * As an exception, if you use this Software to compile your source code and
 * portions of this Software are embedded into the binary product as a result,
 * you may redistribute such product without providing attribution as would
 * otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
 */

package cangjie_tpc::opengauss.pgconn

import std.random.{Random}
import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.time.*
import std.sync.*
import std.net.*
import std.collection.*
import stdx.net.tls.*
import cangjie_tpc::opengauss.utils.*
internal import cangjie_tpc::opengauss.proto3.*

func addDefaultConfs(config: Config) {
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

func shuffleAddrs(addrs: ArrayList<(String, UInt16)>): ArrayList<(String, UInt16)> {
    // 打乱传入的地址串
    var rnd = Random(UInt64(DateTime.now().toUnixTimeStamp().toMilliseconds()))
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

func getConfig(connstr: String): Config {
    let urlparse = URLParser(connstr)
    if (let Some(cfg) <- urlparse.parse()) {
        var config = cfg
        config.scheme = DBType.OpenGauss
        
        var params = config.params
        config.params = HashMap<String, String>()
        for ((key, value) in params) {
             match (key) {
                case "connection_timeout" => config.connTimeout = Duration.millisecond * Int64.parse(value)
                case "read_timeout" => config.readTimeout = Duration.millisecond * Int64.parse(value)
                case "write_timeout" => config.writeTimeout = Duration.millisecond * Int64.parse(value)
                case "send_buffer_size" => config.sendBufferSize = Int64.parse(value)
                case "receive_buffer_size" => config.receiveBufferSize = Int64.parse(value)
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

        addDefaultConfs(config)
        return config
    }
    throw SqlException("getConfig failed!")
}

func getConfig(): Config {
    loadDefaultEnv()
    var url = getEnvString("connectionString")
    return getConfig(url)
}

@Test
public class TestPGConn {
    @TestCase
    func testStartTls(): Unit {
        var cfg: Config = getConfig()

        // CertificateVerifyMode.Default
        try
        {
            var tlscfg = TlsClientConfig()
            tlscfg.verifyMode = CertificateVerifyMode.Default
            var socket = TcpSocket(cfg.host, cfg.port)
            setSocketOps(socket, cfg, cfg.host, cfg.port)
            socket.connect(timeout: cfg.connTimeout)
            startTls(socket, tlscfg)
        } catch (ex: Exception) {
            // println("testStartTls exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
        

        // CertificateVerifyMode.TrustAll
        try
        {
            var tlscfg = TlsClientConfig()
            tlscfg.verifyMode = CertificateVerifyMode.TrustAll
            var socket = TcpSocket(cfg.host, cfg.port)
            setSocketOps(socket, cfg, cfg.host, cfg.port)
            socket.connect(timeout: cfg.connTimeout)
            startTls(socket, tlscfg)
        } catch (ex: Exception) {
            // println("testStartTls exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }        
    }

    @TestCase
    func testConnect(): Unit {
        // func connect(config: Config, info: String): (PgConn, Int32)

        try
        {
            var cfg: Config = getConfig()
            connect(cfg, "testConnect")
        } catch (ex: Exception) {
            // println("testConnect exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testConnectDirect(): Unit {

        try
        {
            var cfg: Config = getConfig()
            connectDirect(cfg, cfg.host, cfg.port, "testConnectDirect")
        } catch (ex: Exception) {
            // println("testConnectDirect exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testConnect2(): Unit {
        // func connect(connId: Int64, config: Config, host: String, port: UInt16, index: Int32, info: String): (PgConn, Int32)
    
        var cfg: Config = getConfig()

        try
        {
            connect(1, cfg, cfg.host, cfg.port, 2, "testConnect2")
        } catch (ex: Exception) {
            // println("testConnect2 exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSetSocketOps(): Unit {
        var cfg: Config = getConfig()

        var socket = TcpSocket(cfg.host, cfg.port)
        let readTimeout = Duration.millisecond * 100
        let writeTimeout = Duration.millisecond *200
        let sendBufferSize = 4096
        let receiveBufferSize = 2048
        cfg.readTimeout = readTimeout
        cfg.writeTimeout = writeTimeout
        cfg.sendBufferSize = sendBufferSize
        cfg.receiveBufferSize = receiveBufferSize
        setSocketOps(socket, cfg, cfg.host, cfg.port)

        @Assert(socket.readTimeout == readTimeout)
        @Assert(socket.writeTimeout == writeTimeout)
        // println("socket.sendBufferSize:${socket.sendBufferSize} sendBufferSize:${sendBufferSize}")
        // @Assert(socket.sendBufferSize == sendBufferSize)
        // println("socket.receiveBufferSize:${socket.receiveBufferSize} receiveBufferSize:${receiveBufferSize}")
        // @Assert(socket.receiveBufferSize == receiveBufferSize)
    }

    @TestCase
    func testConnect3(): Unit {
        // func connect(config: Config, selectedhost: String, selectedport: UInt16, info: String): StreamingSocket

        var cfg: Config = getConfig()

        try
        {
            let stream_conn = connect(cfg, cfg.host, cfg.port, "testConnect3")
            let pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
            pgConn.startup()
            @Assert(!pgConn.isClosed())
            @Assert(0 < pgConn.toString().size)
            pgConn.asyncClose()
        } catch (ex: Exception) {
            // println("testConnect3 exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }        
    }

    @TestCase
    func testConnect4(): Unit {
        // func connect(config: Config, selectedhost: String, selectedport: UInt16, info: String): StreamingSocket

        var cfg: Config = getConfig()

        try
        {
            let stream_conn = connect(cfg, cfg.host, cfg.port, "testConnect3")
            let pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
            pgConn.startup()
            @Assert(!pgConn.isClosed())

            pgConn.addNotice(NoticeResponse())
            @Assert(1 == pgConn.getAllNotices(NoticeResponse()).size)
            @Assert(0 < pgConn.genStmtName().size)

            pgConn.closeStmt("test")
        } catch (ex: Exception) {
            @Assert(false)
        }        
    }

    @TestCase
    func testExecParams(): Unit {
        var cfg: Config = getConfig()

        try
        {
            let stream_conn = connect(cfg, cfg.host, cfg.port, "testConnect3")
            let pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
            pgConn.startup()

            let result = pgConn.execParams("select id, updatetime, text1 from simpletest1 limit 1", 
                Array<BindParameter>(0, {i: Int64 => BindParameter()}), Array<Int32>(0, {i: Int64 => 0}))
            @Assert(!pgConn.isClosed())
        } catch (ex: Exception) {
            @Assert(false)
        }        
    }

    @TestCase
    func testGetServerAddr(): Unit {
        var interceptorAddrs = HashMap<String, String>()
        var config = Config()
        config.addrs.add(("192.168.1.5", 5432))
        config.addrs.add(("192.168.1.6", 5432))
        config.addrs.add(("192.168.1.7", 5432))

        var ignoreAddrs = HashMap<String, String>()
        ignoreAddrs.add("192.168.1.6:5432", "")

        config.priorityaddrs.add("192.168.1.6:5432", "")
        config.priorityaddrs.add("192.168.1.7:5432", "")        

        // 获取优先级高的服务
        var (ret_ip, ret_port, _, _) = getServerAddr(config, ignoreAddrs, interceptorAddrs)
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)

        // ROUNDROBIN
        config.priorityaddrs.clear()
        ignoreAddrs.clear()
        config.balance = ROUNDROBIN
        (ret_ip, ret_port, _, _) = getServerAddr(config, ignoreAddrs, interceptorAddrs)
        @Assert(ret_ip == "192.168.1.5")
        @Assert(ret_port == 5432)

        // LEASTCONN
        config.balance = LEASTCONN
        ConnManager.instance().add("192.168.1.5", 5432)
        ConnManager.instance().add("192.168.1.6", 5432)
        (ret_ip, ret_port, _, _) = getServerAddr(config, ignoreAddrs, interceptorAddrs)
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)
    }

    @TestCase
    func testgetNextServerAddr(): Unit {
        ConnManager.instance().connIndex.swap(0)

        var config = Config()
        config.addrs.add(("192.168.1.5", 5432))
        config.addrs.add(("192.168.1.6", 5432))
        config.addrs.add(("192.168.1.7", 5432))

        var ignoreAddrs = HashMap<String, String>()
        ignoreAddrs.add("192.168.1.6:5432", "")        

        var (ret_ip, ret_port, index, _) = getNextServerAddr(config, ignoreAddrs)
        println("1 ret_ip:${ret_ip} expect:192.168.1.5")
        @Assert(ret_ip == "192.168.1.5")
        @Assert(ret_port == 5432)

        (ret_ip, ret_port, index, _) = getNextServerAddr(config, ignoreAddrs)
        println("2 ret_ip:${ret_ip} expect:192.168.1.7")
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)

        (ret_ip, ret_port, index, _) = getNextServerAddr(config, ignoreAddrs)
        println("3 ret_ip:${ret_ip} expect:192.168.1.7 index:${index}")
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)
    }

    @TestCase
    func testGetLeastConnServerAddr(): Unit {
        ConnManager.instance().add("192.168.1.5", 5432)

        var config = Config()
        config.addrs.add(("192.168.1.5", 5432))
        config.addrs.add(("192.168.1.6", 5432))
        config.addrs.add(("192.168.1.7", 5432))

        var ignoreAddrs = HashMap<String, String>()
        ignoreAddrs.add("192.168.1.6:5432", "")

        let (ret_ip, ret_port, _, _) = getLeastConnServerAddr(config, ignoreAddrs)
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)
    }

    @TestCase
    func testGetPriorityAddr(): Unit {
        var config = Config()
        config.addrs.add(("192.168.1.5", 5432))
        config.addrs.add(("192.168.1.6", 5432))
        config.addrs.add(("192.168.1.7", 5432))

        config.priorityaddrs.add("192.168.1.6:5432", "")
        config.priorityaddrs.add("192.168.1.7:5432", "")        

        var ignoreAddrs = HashMap<String, String>()
        ignoreAddrs.add("192.168.1.6:5432", "")

        let (ret_ip, ret_port, _, _) = getPriorityAddr(config, ignoreAddrs).getOrThrow()
        @Assert(ret_ip == "192.168.1.7")
        @Assert(ret_port == 5432)
    }

    @TestCase
    func testSimpleExec(): Unit {
        var cfg: Config = getConfig()

        var stream_conn = connect(cfg, cfg.host, cfg.port, "testSimpleExec")
        let pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        pgConn.startup()
        let resultReader = pgConn.simpleExec("select 'testSimpleExec'")
        @Assert(resultReader.nextRow())
    }

    @TestCase
    func testExec(): Unit {
        var cfg: Config = getConfig()

        var stream_conn = connect(cfg, cfg.host, cfg.port, "testExec")
        let pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        pgConn.startup()
        
        try {
            pgConn.exec("select 'testExec'")
        } catch (e: SqlException) {
            // println("testExec exception: ${e}")
            // e.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testLock(): Unit {
        var cfg: Config = getConfig()

        var stream_conn = connect(cfg, cfg.host, cfg.port, "testLock")
        var pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)

        // 同一连接内重复上锁应该失败
        pgConn.lock("")
        try {
            let ret = pgConn.lock("")
            match (ret) {
                case Some(v) => @Assert(true)
                case None => 
                    println("1 testLock failed! ")
                    @Assert(false)
            }            
        } catch (e: SqlException) {}

        // 如果是同一个statement重复上锁，目前按照与锁一次相同的方式处理
        pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        pgConn.lock("statement1")
        try {
            let ret = pgConn.lock("statement1")
            match (ret) {
                case Some(v) => 
                    println("2 testLock failed! ")
                    @Assert(false)
                case _ => @Assert(true)
            }   
        } catch (ex: SqlException) {
            // println("2 testLock exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }

        // 如果是不同statement重复上锁，应该失败
        pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        pgConn.lock("statement1")
        try {
            let ret = pgConn.lock("statement2")
            match (ret) {
                case Some(v) => @Assert(true)
                case None => 
                    println("3 testLock failed! ")
                    @Assert(false)
            }
        } catch (e: SqlException) {}
    }
    
    @TestCase
    func testUnLock(): Unit {
        var cfg: Config = getConfig()

        var stream_conn = connect(cfg, cfg.host, cfg.port, "testUnLock")
        var pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)

        // 同一连接内，可以上锁、解锁、上锁
        try {
            pgConn.lock("")
            pgConn.unlock("")
            pgConn.lock("")
        } catch (ex: SqlException) {
            // println("testUnLock exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }

        // 同一个statement, 可以上锁、解锁、上锁
        pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        try {
            pgConn.lock("statement1")
            pgConn.unlock("statement1")
            pgConn.lock("statement1")
        } catch (ex: SqlException) {
            // println("testUnLock exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }

        // 不同statement，解锁应该失败
        pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
        try {
            pgConn.lock("statement1")
            pgConn.unlock("statement2")

            // println("testUnLock failed!")
            @Assert(false)
        } catch (e: SqlException) {}
    }

    @TestCase
    func testResetToMasterConnection(): Unit {
        try {
            var cfg: Config = getConfig()

            var stream_conn = connect(cfg, cfg.host, cfg.port, "testUnLock")
            var pgConn = PgConn(1, cfg, stream_conn, cfg.host, cfg.port, 2)
            let ignoreAddrs = ArrayList<(String, UInt16)>(1)

            pgConn.curPort = 0u16
            pgConn.resetToMasterConnection(ignoreAddrs)
        } catch (e: SqlException) {
            @Assert(false)
        }        
    }
}
