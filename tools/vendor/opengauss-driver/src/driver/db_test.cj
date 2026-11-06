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

package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.collection.*
import stdx.net.tls.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.pgconn.*

@Test
public class TestDatasource {
    @TestCase
    func testDatasource(): Unit {
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
        let ds = drv.open(url)
        let clientEncodingKey = "client_encoding"
        let clientEncoding = "GBK"
        ds.setOption(clientEncodingKey, "GBK")
        try (conn = ds.connect()) {
            let metadata = conn.getMetaData()
            @Assert(metadata.get(clientEncodingKey) == clientEncoding)
        } catch (ex: Exception) {
            // println("testDatasource exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
        try {
            let pgdboption = ds as PGDB
            match (pgdboption) {
                case Some(pgdb) =>
                    pgdb.ping()
                    pgdb.close()
                case _ => @Assert(false)
            }
        } catch (ex: Exception) {
            // println("testDatasource exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }

        // 设置tls
        var tlsconfig = TlsClientConfig()
        tlsconfig.verifyMode = CertificateVerifyMode.TrustAll
        let pgdb = (ds as PGDB).getOrThrow()
        try (conn = ds.connect()) {
        } catch (ex: Exception) {
            // println("testDatasource tlsconfig exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }

        ds.close()
        @Assert(ds.isClosed() == true)
    }

    @TestCase
    func testCheckIsMaster(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drv = DriverManager.getDriver("opengauss").getOrThrow()
        let urlparse = URLParser(url)
        let cfg = urlparse.parse().getOrThrow()
        let ds = drv.open(url)
        let pgdb = (ds as PGDB).getOrThrow()
        
        let ret = pgdb.checkIsMaster(cfg.host, cfg.port)
        if (ret) {
            // println("testCheckIsMaster: checkIsMaster failed")
            @Assert(false)
        }
        pgdb.close()
    }

    @TestCase
    func testFindMaster(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drv = DriverManager.getDriver("opengauss").getOrThrow()
        let urlparse = URLParser(url)
        let cfg = urlparse.parse().getOrThrow()
        let ds = drv.open(url)
        let pgdb = (ds as PGDB).getOrThrow()
        let cfg_tmp = cfg
        let addrs = ArrayList<(String, UInt16)>(1, {i => (cfg_tmp.host, cfg_tmp.port)})
        pgdb.findMaster(addrs)
    }
}
