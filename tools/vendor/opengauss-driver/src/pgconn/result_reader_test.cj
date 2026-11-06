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
import std.time.*

@Test
public class TestResultReader {
    @TestCase
    func testUpdate(): Unit {
        try
        {
            var cfg: Config = getConfig()
            let (pgconn, index) = connect(cfg, "testUpdate")

            var id = "testUpdate ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"
            let result = pgconn.simpleExec("insert into simpletest1(id, text1) values('${id}', '${text1}')")

            @Assert(result.update())
            @Assert(result.rows() == 1)
            pgconn.close()
        } catch (ex: Exception) {
            println("TestResultReader testUpdate exception: ${ex}")
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testQuery(): Unit {
        try
        {
            var cfg: Config = getConfig()
            let (pgconn, index) = connect(cfg, "testQuery")

            var id = "testQuery ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"
            let result = pgconn.simpleExec("select id, updatetime, text1 from simpletest1 limit 1")

            @Assert(result.rows() == 0)
            @Assert(result.nextRow())            
            pgconn.close()
        } catch (ex: Exception) {
            println("TestResultReader testQuery exception: ${ex}")
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testErrorSql(): Unit {
        try
        {
            var cfg: Config = getConfig()
            let (pgconn, index) = connect(cfg, "testQuery")
            var result = pgconn.simpleExec("select * from simpletest1 limit 1")
            @Assert(!result.isClosed())
            result.rowsToString()

            result = pgconn.simpleExec("select id from typetest1 limit 1")     
            @Assert(result.isClosed())  
            pgconn.close()
        } catch (ex: Exception) {

        }
    }

}