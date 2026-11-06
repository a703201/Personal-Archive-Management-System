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
public class TestRows {
    @TestCase
    func testRows(): Unit {
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
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testConnection ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            statement.close()

            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""
            statement.set<String>(0, id)
            let queryResult = statement.query()
            var count: Int32 = 0
            let rowsOption = queryResult as Rows
            match (rowsOption) {
                case Some(rows) =>
                    println("name, typeName, displaySize, length, scale, nullable")
                    for (columnInfo in rows.columnInfos) {
                        if (columnInfo.name == "id") {
                            @Assert(columnInfo.typeName == "SqlVarchar")
                            @Assert(columnInfo.scale == 0)
                            @Assert(columnInfo.nullable == true)
                        } else if (columnInfo.name == "updatetime") {
                            @Assert(columnInfo.typeName == "SqlTimestamp")
                            @Assert(columnInfo.length == 8)
                            @Assert(columnInfo.scale == 0)
                            @Assert(columnInfo.nullable == true)
                        } else if (columnInfo.name == "text1") {
                            @Assert(columnInfo.typeName == "SqlVarchar")
                            @Assert(columnInfo.scale == 0)
                            @Assert(columnInfo.nullable == true)
                        }
                    }
                    while (rows.next()) {
                        id = rows.get<String>(0)
                        updatetimeGot = rows.get<DateTime>(1)
                        text1Got = rows.get<String>(2)

                        @Assert(updatetimeGot.format("yyyy-MM-dd HH:mm:ss.S") == updatetime.format("yyyy-MM-dd HH:mm:ss.S"))
                        @Assert(text1Got == text1)
                        count++
                    }
                    @Assert(rows.isClosed())
                case _ => @Assert(false)
            }
            @Assert(count == 1)
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testGetException(): Unit {
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

        // 测试get时index out of bounds:
        try (conn = ds.connect()) {
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testConnection ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            statement.close()

            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""
            statement.set<String>(0, id)
            let queryResult = statement.query()
            while (queryResult.next()) {
                id = queryResult.get<String>(3)
            }

            @Assert(false)
        } catch (ex: Exception) {
            
        }

        // 测试get时类型不匹配
        try (conn = ds.connect()) {
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testConnection ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            statement.close()

            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""
            statement.set<String>(0, id)
            let queryResult = statement.query()
            while (queryResult.next()) {
                queryResult.get<Duration>(0)
            }

            @Assert(false)
        } catch (ex: Exception) {}
    }

    @TestCase
    func testInt8(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        var drv = DriverManager.getDriver("opengauss") ?? return
        var ds = drv.open(url)
        try (conn = ds.connect()) {
            var sql = "insert into typetest1(char1, tinyint1) values(?, ?)"
            var statement = conn.prepareStatement(sql)
            var char1 = "testInt8 ${DateTime.now()}"
            statement.set<String>(0, char1)
            statement.set<Int8>(1, 1)
            var updateresult = statement.update()
            statement.close()

            sql = "select tinyint1, smallint1, date1 from typetest1 where char1 = ?"
            statement = conn.prepareStatement(sql)
            statement.set<String>(0, char1)
            let queryResult = statement.query()
            while (queryResult.next()) {
                queryResult.get<Int8>(0)
                queryResult.get<Int16>(0)
                queryResult.get<Int32>(0)
                queryResult.get<Int64>(0)
                queryResult.get<String>(0)
                queryResult.get<InputStream>(0)
                queryResult.get<Array<Byte>>(0)
                queryResult.get<Bool>(0)
                queryResult.get<Float32>(0)
                queryResult.get<Float64>(0)

                queryResult.getOrNull<Bool>(1)
                queryResult.getOrNull<Array<Byte>>(1)
                queryResult.getOrNull<InputStream>(1)
                queryResult.getOrNull<Int8>(1)
                queryResult.getOrNull<Int16>(1)
                queryResult.getOrNull<Int32>(1)
                queryResult.getOrNull<Int64>(1)
                queryResult.getOrNull<String>(1)
                queryResult.getOrNull<Float32>(1)
                queryResult.getOrNull<Float64>(1)
                queryResult.getOrNull<DateTime>(1)
                queryResult.getOrNull<Duration>(1)
            }
            statement.close()

            sql = "delete from typetest1 where char1 = ?"
            statement = conn.prepareStatement(sql)
            statement.set<String>(0, char1)
            let res = statement.update()
        }

    }

}
