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
internal import stdx.log.*
internal import std.database.sql.*
internal import std.unittest.*
import std.time.*
import std.unittest.testmacro.*
import cangjie_tpc::opengauss.sqlpool.*
import cangjie_tpc::opengauss.slog
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.pgconn.*
import cangjie_tpc::opengauss.url.*

@Test
public class TestDriver {
    let logger = slog.Default()
    func query(i: Int64, db: Datasource) {
        try (conn = db.connect()) {
            let sql = "select id, updatetime, text1 from simpletest1 limit 1"
            let stmt = conn.prepareStatement(sql)

            try (q = stmt.query()) {
                var id = ""
                while (q.next()) {
                    id = q.get<String>(0)

                    println("i:${i} id:${id}")
                }
            }
        }
        sleep(Duration.microsecond * 1000)
    }

    @TestCase
    func testquery(): Unit {
        // var url = "postgres://gorm:pass@localhost:5432/loggable?sslmode=disable"
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drv = DriverManager.getDriver("opengauss") ?? return
        let db = drv.open(url)
        let p = db
        let list = ArrayList<Future<Unit>>()
        for (i in 0..40) {
            let fut = spawn {
                 => query(i, db)
            }
            list.add(fut)
        }
        for (fut in list) {
            fut.get()
        }
        db.close()
    }

    @TestCase
    func testDriver(): Unit {
        try {
            loadDefaultEnv()
            var url = getEnvString("connectionString")
            let drvopt = DriverManager.getDriver("opengauss")
            var drv: Driver
            match (drvopt) {
                case Some(v) => drv = v
                case None =>
                    @Assert(false)
                    return
            }
            @Assert(drv.name == "opengauss")
            @Assert(drv.version != "")
            @Assert(drv.preferredPooling == true)
            let ds = drv.open(url, ("client_encoding", "GBK"), ("TimeZone", "UTC"))
            let conn = ds.connect()
            let metaData = conn.getMetaData();
            @Assert(metaData.get("client_encoding") == "GBK")
            @Assert(metaData.get("TimeZone") == "UTC")
        } catch (ex: Exception) {
            // println("testDriver exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testPostgresDriver(): Unit {
        try {
            loadDefaultEnv()
            let drvopt = DriverManager.getDriver("postgres")
            var drv: Driver
            match (drvopt) {
                case Some(v) => drv = v
                case None =>
                    @Assert(false)
                    return
            }
            @Assert(drv.name == "opengauss")
            @Assert(drv.version != "")
            @Assert(drv.preferredPooling == true)
        } catch (ex: Exception) {
            // println("testPostgresDriver exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testChinamobiledbDriver(): Unit {
        try {
            loadDefaultEnv()
            let drvopt = DriverManager.getDriver("chinamobiledb")
            var drv: Driver
            match (drvopt) {
                case Some(v) => drv = v
                case None =>
                    @Assert(false)
                    return
            }
            @Assert(drv.name == "opengauss")
            @Assert(drv.version != "")
            @Assert(drv.preferredPooling == true)
        } catch (ex: Exception) {
            // println("testPostgresDriver exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSetOption(): Unit {
        var config = Config()
        var db = PGDB(config)

        let v = "10"
        db.setOption("connection_timeout", v)
        @Assert(Duration.millisecond * Int64.parse(v) == db.config.connTimeout.getOrThrow())
        db.setOption("read_timeout", v)
        @Assert(Duration.millisecond * Int64.parse(v) == db.config.readTimeout.getOrThrow())
        db.setOption("write_timeout", v)
        @Assert(Duration.millisecond * Int64.parse(v) == db.config.writeTimeout.getOrThrow())
        db.setOption("send_buffer_size", v)
        @Assert(Int64.parse(v) == db.config.sendBufferSize.getOrThrow())
        db.setOption("receive_buffer_size", v)
        @Assert(Int64.parse(v) == db.config.receiveBufferSize.getOrThrow())
        db.setOption("binary_transfer", "true")
        @Assert(db.config.binarytransfer)
        db.setOption("namedstatement", "true")
        @Assert(db.config.namedstatement)
        db.setOption("balance", "leastconn")
        @Assert(BalanceType.LEASTCONN.value() == db.config.balance.value())
        db.setOption("priority_addrs", "192.168.1.10,192.168.1.11")
        @Assert(db.config.priorityaddrs.size == 2)
        db.setOption("shuffle_addrs", "true")
        @Assert(db.config.shuffleaddrs)
        db.setOption("test", "1")
        @Assert("1" == db.config.params["test"])
    }

    @TestCase
    func testfindMaster(): Unit {
        try
        {
            loadDefaultEnv()
            let ignoreAddrs = ArrayList<(String, UInt16)>(2)
            var connstr = getEnvString("connectionString")
            let drv = DriverManager.getDriver("opengauss") ?? return
            let db = drv.open(connstr)
            let pg_db = (db as PGDB).getOrThrow()
            
            if (let Some(url) <- Parser.parseURI(connstr)) {
                let port = UInt16.tryParse(url.authority.port) ?? 0
                let addr = (url.authority.hostname, port)
                pg_db.config.addrs.add(addr)
                pg_db.config.addrs.add(addr)

                pg_db.findMaster(ignoreAddrs)  // 因为本地只启动了一个节点，没有创建主备，所以find会失败(因为需要role为"primary")
                @Assert(false)
            }        
        } catch (ex: Exception) {
        }
    }
}
