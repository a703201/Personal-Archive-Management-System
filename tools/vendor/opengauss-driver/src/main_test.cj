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

package opengauss

import std.unittest.*
import std.unittest.testmacro.*
internal import std.collection.*
internal import std.sync.*
internal import std.time.*
internal import stdx.log.*
internal import std.database.sql.*
internal import stdx.encoding.json.*
internal import stdx.net.tls.*
import cangjie_tpc::opengauss.driver.*
import cangjie_tpc::opengauss.pgconn.*
import cangjie_tpc::opengauss.sema.*
import cangjie_tpc::opengauss.collections.*
import cangjie_tpc::opengauss.url.*
import cangjie_tpc::opengauss.sqlpool.*
import cangjie_tpc::opengauss.slog
import cangjie_tpc::opengauss.utils.*

let logger = slog.Default()

func do_insert(cn: Connection): Unit {
    var sql = "INSERT INTO some_types (created_at,updated_at,deleted_at,source) VALUES (?,?,NULL,?) RETURNING id"
    try (st = cn.prepareStatement(sql)) {
        let create_at = DateTime.now()
        let updated_at = DateTime.now()
        let source = "walawala"

        st.set<DateTime>(0, create_at)
        st.set<DateTime>(1, updated_at)
        st.set<String>(2, source)
        let ur = st.update()
        logger.info("${ur.rowCount}, ${ur.lastInsertId}")
    } catch (e: Exception) {
        logger.error("main exception do_insert e.message:${e.message}  e.printStackTrace:${e.printStackTrace()}")
    }
}

func do_query_single(cn: Connection): Unit {
    let sql = "SELECT * FROM public.some_types limit 1"
    try (st = cn.prepareStatement(sql)) {
        let qr = st.query()
        var id = 0i64
        var create_at = DateTime.UnixEpoch
        var updated_at = DateTime.UnixEpoch
        var deleted_at = DateTime.UnixEpoch
        var source = ""
        while (qr.next()) {
            id = qr.get<Int64>(0)
            create_at = qr.get<DateTime>(1)
            updated_at = qr.get<DateTime>(2)
            deleted_at = qr.get<DateTime>(3)

            logger.info(
                "${id} ${create_at} ${updated_at} ${deleted_at} "
            )
        }
        qr.close()
    } catch (e: Exception) {
        logger.error("main exception do_query_single e.message:${e.message}  e.printStackTrace:${e.printStackTrace()}")        
    }
}
func do_query1(i: Int64, db: Datasource) {
    logger.info("do_query1 ${i}")
    try {
        let cn = db.connect()
        let sql = "SELECT * FROM public.some_types WHERE id = ? ORDER BY id ASC"
        try (st = cn.prepareStatement(sql)) {
            var id = i % 8

            st.set<Int64>(0, id)
            let qr = st.query()
            var create_at = DateTime.UnixEpoch
            var updated_at = DateTime.UnixEpoch
            var deleted_at = DateTime.UnixEpoch
            var source = ""
            while (qr.next()) {
                id = qr.get<Int64>(0)
                create_at = qr.get<DateTime>(1)
                updated_at = qr.get<DateTime>(2)
                deleted_at = qr.get<DateTime>(3)

                logger.info(
                    "${id} ${create_at} ${updated_at} ${deleted_at} "
                )
            }
            qr.close()
        }
        cn.close()
    } catch (e: Exception) {
        logger.error("main exception ${e.message} e.printStackTrace:${e.printStackTrace()}")        
    } finally {}
    sleep(Duration.second * 1)
}

func test_parallel_query(db: Datasource): Unit {
    let list = ArrayList<Future<Unit>>()
    for (i in 0..40) {
        let fut = spawn {
             => do_query1(i, db)
        }
        list.add(fut)
    }
    for (fut in list) {
        fut.get()
    }
    db.close()
}
func multi_query(db: Datasource) {
    for (i in 0..40) {
        do_query1(i, db)
    }
}
@Test
func test_pg(): Unit {
    // var url = "opengauss://gorm:pass@127.0.0.1:5432/loggable?sslmode=disable"
    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drv = DriverManager.getDriver("postgres") ?? return
    let ds = drv.open(url)
    println("connect opengauss OK.")
}
@Test
func test_og(): Unit {
    logger.level = LogLevel.DEBUG
    var tlsconfig = TlsClientConfig()

    // tlsconfig.privateKeyFile = "client.key"
    // tlsconfig.certificateChainFile = "client.crt"
    registerTLSConfig("custom", tlsconfig)

    // var url = "postgres://gorm:pass@127.0.0.1:5432/loggable?sslmode=disable"
    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drv = DriverManager.getDriver("opengauss") ?? return
    let ds = drv.open(url)
    try (cn = ds.connect()) {
        do_insert(cn)
        do_query_single(cn)        
    }
    println("ping postgres OK.")
    do_query1(1, ds)    
    do_query1(2, ds)    
    do_query1(3, ds)
    multi_query(ds)
    test_parallel_query(ds)
}
