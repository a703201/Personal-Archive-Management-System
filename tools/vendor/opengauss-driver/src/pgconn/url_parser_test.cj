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

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*



@Test
public class TestUrlParser {
    @TestCase
    func testUrlParser(): Unit {

        var url = "opengauss://bes:password@192.168.1.123:5432/bes?sslmode=disable"
        var urlparse = URLParser(url)
        if (let Some(cfg) <- urlparse.parse()) {
            println("cfg.host:${cfg.host}")
            @Assert(cfg.host == "192.168.1.123")
            println("cfg.port:${cfg.port}")
            @Assert(cfg.port == 5432u16)
            println("cfg.database:${cfg.database}")
            @Assert(cfg.database == "bes")
            println("cfg.user:${cfg.user}")
            @Assert(cfg.user == "bes")
            println("cfg.password:${cfg.password}")
            @Assert(cfg.password == "password")

            println("cfg.addrs.size:${cfg.addrs.size}")
            @Assert(cfg.addrs.size == 1)
            var (ip, port) = cfg.addrs[0]
            println("ip:${ip}")
            @Assert(ip == "192.168.1.123")
            println("port:${port}")
            @Assert(port == 5432u16)
        } else {
            println("testUrlParser parse failed! url: ${url}")
            @Assert(false)
        }

        url = "opengauss://bes:password@192.168.0.10:5432,192.168.0.11:5432,192.168.0.12:5432/bes"
        urlparse = URLParser(url)
        if (let Some(cfg) <- urlparse.parse()) {
            println("cfg.host:${cfg.host}")
            @Assert(cfg.host == "192.168.0.10")
            println("cfg.port:${cfg.port}")
            @Assert(cfg.port == 5432u16)
            println("cfg.database:${cfg.database}")
            @Assert(cfg.database == "bes")
            println("cfg.user:${cfg.user}")
            @Assert(cfg.user == "bes")
            println("cfg.password:${cfg.password}")
            @Assert(cfg.password == "password")

            println("cfg.addrs.size:${cfg.addrs.size}")
            @Assert(cfg.addrs.size == 3)
            var (ip, port) = cfg.addrs[0]
            println("ip:${ip}")
            @Assert(ip == "192.168.0.10")
            println("port:${port}")
            @Assert(port == 5432u16)

            (ip, port) = cfg.addrs[1]
            println("ip:${ip}")
            @Assert(ip == "192.168.0.11")
            println("port:${port}")
            @Assert(port == 5432u16)

            (ip, port) = cfg.addrs[2]
            println("ip:${ip}")
            @Assert(ip == "192.168.0.12")
            println("port:${port}")
            @Assert(port == 5432u16)
        } else {
            println("testUrlParser parse failed! url: ${url}")
            @Assert(false)
        }

        url = "opengauss://bes:password@192.168.0.10:5432/bes?sslmode=disable&balance=leastconn&shuffle_addrs=true&priority_addrs=192.168.0.11:5432,192.168.0.12:5432"
        try
        {
            let cfg = getConfig(url)

            println("cfg.host:${cfg.host}")
            @Assert(cfg.host == "192.168.0.10")
            println("cfg.port:${cfg.port}")
            @Assert(cfg.port == 5432u16)
            println("cfg.database:${cfg.database}")
            @Assert(cfg.database == "bes")
            println("cfg.user:${cfg.user}")
            @Assert(cfg.user == "bes")
            println("cfg.password:${cfg.password}")
            @Assert(cfg.password == "password")
            println("cfg.shuffleaddrs:${cfg.shuffleaddrs}")
            @Assert(cfg.shuffleaddrs)
            println("cfg.balance.value():${cfg.balance.value()}")
            @Assert(cfg.balance.value() == BalanceType.LEASTCONN.value())

            println("cfg.addrs.size:${cfg.addrs.size}")
            @Assert(cfg.addrs.size == 1)
            var (ip, port) = cfg.addrs[0]
            println("ip:${ip}")
            @Assert(ip == "192.168.0.10")
            println("port:${port}")
            @Assert(port == 5432u16)       

            println("cfg.priorityaddrs.size:${cfg.priorityaddrs.size}")
            @Assert(cfg.priorityaddrs.size == 2)
            @Assert(cfg.priorityaddrs.contains("192.168.0.11:5432"))
            @Assert(cfg.priorityaddrs.contains("192.168.0.12:5432"))
        } catch (ex: Exception) {
            println("TestUrlParser exception: ${ex}")
            ex.printStackTrace()
            @Assert(false)
        }

        url = "opengauss://bes:password@192.168.1.100:5432/bes?sslmode=prefer&connection_timeout=5000&read_timeout=10000&write_timeout=10000"
        try
        {
            let cfg = getConfig(url)

            println("cfg.host:${cfg.host}")
            @Assert(cfg.host == "192.168.1.100")
            println("cfg.port:${cfg.port}")
            @Assert(cfg.port == 5432u16)
            println("cfg.database:${cfg.database}")
            @Assert(cfg.database == "bes")
            println("cfg.user:${cfg.user}")
            @Assert(cfg.user == "bes")
            println("cfg.password:${cfg.password}")
            @Assert(cfg.password == "password")
            // println("cfg.sslmode:${cfg.sslmode}")
            // @Assert(cfg.sslmode == "prefer")
            println("cfg.connTimeout:${cfg.connTimeout}")
            @Assert(cfg.connTimeout == Duration.millisecond * 5000)
            println("cfg.readTimeout:${cfg.readTimeout}")
            @Assert(cfg.readTimeout == Duration.millisecond * 10000)
            println("cfg.writeTimeout:${cfg.writeTimeout}")
            @Assert(cfg.writeTimeout == Duration.millisecond * 10000)

            println("cfg.addrs.size:${cfg.addrs.size}")
            @Assert(cfg.addrs.size == 1)
            var (ip, port) = cfg.addrs[0]
            @Assert(ip == "192.168.1.100")
            @Assert(port == 5432u16)
        } catch (ex: Exception) {
            println("TestUrlParser exception: ${ex}")
            ex.printStackTrace()
            @Assert(false)
        }
    }
}




