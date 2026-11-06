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
import std.sync.*
import cangjie_tpc::opengauss.utils.*

@Test
public class TestStatement {
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
            sleep(Duration.second)
            id = "testStatement ${DateTime.now()}"
            updatetime = DateTime.now()
            text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            let queryResult = statement.query()
            var count: Int32 = 0
            while (queryResult.next()) {
                id = queryResult.get<String>(0)
                updatetimeGot = queryResult.get<DateTime>(1)
                text1Got = queryResult.get<String>(2)

                println("updatetimeGot=${updatetimeGot} updatetime=${updatetime}")
                println("text1Got=${text1Got} text1=${text1}")
                if (updatetimeGot != updatetime) {
                    println(
                        "updatetimeGot.nanosecond=${updatetimeGot.nanosecond} updatetime.nanosecond=${updatetime.nanosecond}"
                    )
                    println("updatetimeGot.zone=${updatetimeGot.zone} updatetime.zone=${updatetime.zone}")
                }
                @Assert(updatetimeGot.format("yyyy-MM-dd HH:mm:ss.S") == updatetime.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text1Got == text1)
                count++
            }
            @Assert(count == 1)
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testStatementMultiQueries(): Unit {
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
            var baseid = "testStatement ${DateTime.now()}"
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            
            var statement = conn.prepareStatement(sql)
            for (i in 0..10) {
                var id = "${baseid}_${i}"
                var updatetime = DateTime.now()
                var text1 = "${id + " text1"}"

                statement.set<String>(0, id)
                statement.set<DateTime>(1, updatetime)
                statement.set<String>(2, text1)
                var updateresult = statement.update()
                @Assert(updateresult.rowCount == 1)
            }
            statement.close()

            for (i in 0..10) {
                sql = "select id, updatetime, text1 from simpletest1 where id = ?"
                statement = conn.prepareStatement(sql)
                var id = "${baseid}_${i}"
                var updatetimeGot = DateTime.UnixEpoch
                var text1Got = ""

                statement.set<String>(0, id)
                let queryResult = statement.query()
                var count: Int32 = 0
                while (queryResult.next()) {
                    id = queryResult.get<String>(0)
                    updatetimeGot = queryResult.get<DateTime>(1)
                    text1Got = queryResult.get<String>(2)

                    println("updatetimeGot=${updatetimeGot}")
                    println("text1Got=${text1Got} text1=${id + " text1"}")
                    @Assert(text1Got == "${id + " text1"}")
                    count++
                }
                @Assert(count == 1)
            }
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }
    @TestCase
    func testStatementMultiThreadQueries(): Unit {
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
            let sql1fut: Future<Unit> = spawn {
                => try {
                    var baseid = "testStatement ${DateTime.now()}"
                    sleep(Duration.second)
                    var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
                    var statement = conn.prepareStatement(sql)
                    for (i in 0..10) {
                        var id = "${baseid}_${i}"
                        var updatetime = DateTime.now()
                        var text1 = "${id + " text1"}"

                        statement.set<String>(0, id)
                        statement.set<DateTime>(1, updatetime)
                        statement.set<String>(2, text1)
                        var updateresult = statement.update()
                        @Assert(updateresult.rowCount == 1)
                    }
                    statement.close()

                    for (i in 0..10) {
                        sql = "select id, updatetime, text1 from simpletest1 where id = ?"
                        statement = conn.prepareStatement(sql)
                        var id = "${baseid}_${i}"
                        var updatetimeGot = DateTime.UnixEpoch
                        var text1Got = ""

                        statement.set<String>(0, id)
                        let queryResult = statement.query()
                        var count: Int32 = 0
                        while (queryResult.next()) {
                            id = queryResult.get<String>(0)
                            updatetimeGot = queryResult.get<DateTime>(1)
                            text1Got = queryResult.get<String>(2)

                            println("updatetimeGot=${updatetimeGot}")
                            println("text1Got=${text1Got} text1=${id + " text1"}")
                            @Assert(text1Got == "${id + " text1"}")
                            count++
                        }
                        @Assert(count == 1)
                    }
                    statement.close()
                } catch (ex: Exception) {
                    ex.printStackTrace()
                    @Assert(false)
                }
            }
            sleep(Duration.second)
            let sql2fut: Future<Unit> = spawn {
                => try {
                    var baseid = "testStatement ${DateTime.now()}"
                    var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
                    var statement = conn.prepareStatement(sql)
                    for (i in 0..10) {
                        var id = "${baseid}_${i}"
                        var updatetime = DateTime.now()
                        var text1 = "${id + " text1"}"

                        statement.set<String>(0, id)
                        statement.set<DateTime>(1, updatetime)
                        statement.set<String>(2, text1)
                        var updateresult = statement.update()
                        @Assert(updateresult.rowCount == 1)
                    }
                    statement.close()

                    for (i in 0..10) {
                        sql = "select id, updatetime, text1 from simpletest1 where id = ?"
                        statement = conn.prepareStatement(sql)
                        var id = "${baseid}_${i}"
                        var updatetimeGot = DateTime.UnixEpoch
                        var text1Got = ""

                        statement.set<String>(0, id)
                        let queryResult = statement.query()
                        var count: Int32 = 0
                        while (queryResult.next()) {
                            id = queryResult.get<String>(0)
                            updatetimeGot = queryResult.get<DateTime>(1)
                            text1Got = queryResult.get<String>(2)

                            println("updatetimeGot=${updatetimeGot}")
                            println("text1Got=${text1Got} text1=${id + " text1"}")
                            @Assert(text1Got == "${id + " text1"}")
                            count++
                        }
                        @Assert(count == 1)
                    }
                    statement.close()
                } catch (ex: Exception) {
                    ex.printStackTrace()
                    @Assert(false)
                }
            }

            sql1fut.get()
            sql2fut.get()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }
}
