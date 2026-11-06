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
import std.time.*
import cangjie_tpc::opengauss.utils.*

@Test
public class TestUpateResult {
    @TestCase
    func testStatement(): Unit {
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
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testStatement ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }
}
