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
public class TestConnection {
    @TestCase
    func testConcurrentSingleConnectionMultiStatement(): Unit {
        println("testConcurrentSingleConnectionMultiStatement--------------------------")
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
            let sql1fut: Future<Unit> = spawn {
                =>
                let sql1 = "select 'sql1', pg_sleep(2), now()"
                let statement = conn.prepareStatement(sql1)
                for (i in 0..10) {
                    println("${DateTime.now()} sql1 ${i}")
                    try (qr = statement.query()) {
                        var sql = ""
                        var sl = ""
                        var now = DateTime.UnixEpoch

                        while (qr.next()) {
                            sql = qr.get<String>(0);
                            sl = qr.get<String>(1);
                            now = qr.get<DateTime>(2);

                            println("${DateTime.now()} ${sql} ${sl} ${now}")
                        }
                        sleep(Duration.second)
                    } catch (ex: Exception) {
                        // println("sql1 exception: ${ex}")
                        // ex.printStackTrace()
                        @Assert(false)
                    }
                }
            }

            let sql2fut: Future<Unit> = spawn {
                =>
                let sql2 = "select 'sql2', now()"
                let statement = conn.prepareStatement(sql2)
                for (i in 0..10) {
                    println("${DateTime.now()} sql2 ${i}")
                    try (qr = statement.query()) {
                        var sql = ""
                        var now = DateTime.UnixEpoch
                        while (qr.next()) {
                            sql = qr.get<String>(0);
                            now = qr.get<DateTime>(1);

                            println("${DateTime.now()} ${sql} ${now}")
                        }
                    } catch (ex: Exception) {
                        // println("sql2 exception: ${ex}")
                        // ex.printStackTrace()
                        @Assert(false)
                    }
                }
            }

            sql1fut.get()
            sql2fut.get()
        } catch (ex: Exception) {
            // println("testConcurrentSingleConnectionMultiStatement exception: ${ex}")
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testConcurrentMultiConnection(): Unit {
        println("testConcurrentMultiConnection--------------------------")
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
        let sql1fut: Future<Unit> = spawn {
            => try (conn = ds.connect()) {
                let sql1 = "select 'sql1', pg_sleep(2), now()"
                let statement = conn.prepareStatement(sql1)
                for (i in 0..10) {
                    println("${DateTime.now()} sql1 ${i}")
                    try (qr = statement.query()) {
                        var sql = ""
                        var sl = ""
                        var now = DateTime.UnixEpoch
                        while (qr.next()) {
                            sql = qr.get<String>(0);
                            sl = qr.get<String>(1);
                            now = qr.get<DateTime>(2);

                            println("${DateTime.now()} ${sql} ${sl} ${now}")
                        }
                    } catch (ex: Exception) {
                        // println("sql1 exception: ${ex}")
                        // ex.printStackTrace()
                        @Assert(false)
                    }
                }
            } catch (ex: Exception) {
                // println("testConcurrentMultiConnection exception: ${ex}")
                // ex.printStackTrace()
                @Assert(false)
            }
        }

        let sql2fut: Future<Unit> = spawn {
            => try (conn = ds.connect()) {
                let sql2 = "select 'sql2', now()"
                let statement = conn.prepareStatement(sql2)
                for (i in 0..10) {
                    println("${DateTime.now()} sql2 ${i}")
                    try (qr = statement.query()) {
                        var sql = ""
                        var now = DateTime.UnixEpoch
                        while (qr.next()) {
                            sql = qr.get<String>(0);
                            now = qr.get<DateTime>(1);

                            println("${DateTime.now()} ${sql} ${now}")
                        }
                    } catch (ex: Exception) {
                        // println("sql2 exception: ${ex}")
                        // ex.printStackTrace()
                        @Assert(false)
                    }
                }
            } catch (ex: Exception) {
                // println("testConcurrentMultiConnection exception: ${ex}")
                // ex.printStackTrace()
                @Assert(false)
            }
        }

        sql1fut.get()
        sql2fut.get()
    }

    @TestCase
    func testConnection(): Unit {
        println("testConnection--------------------------")
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
            var id = "testConnection ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
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

            conn.close()
            @Assert(conn.state == ConnectionState.Closed)
        } catch (ex: Exception) {
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testConnectionTransaction(): Unit {
        println("testConnectionTransaction--------------------------")
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
            var transaction = conn.createTransaction()
            transaction.begin()
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testConnectionTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            // 在事务中应该可以获取到数据
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
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

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""
            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // Assert(count == 0)，不需要读取
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)

            transaction.begin()

            sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            statement = conn.prepareStatement(sql)
            id = "testConnectionTransaction ${DateTime.now()}"
            updatetime = DateTime.now()
            text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            // 在事务中应该可以获取到数据
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""
            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
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

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""
            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
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

            conn.close()
            @Assert(conn.state == ConnectionState.Closed)
        } catch (ex: Exception) {
            // ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testQuery(): Unit {
        println("testQuery--------------------------")
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

            let pgConnOption = conn as PGConnection
            var pgConn: PGConnection
            match (pgConnOption) {
                case Some(v) => pgConn = v
                case None =>
                    @Assert(false)
                    return
            }

            let sql1 = "select 'sql1', now()"
            let result = pgConn.query(sql1)
            if (!result.next()) {
                // println("testQuery failed")
                @Assert(false)
            }
        }
    }

    @TestCase
    func testUpdate(): Unit {
        println("testUpdate--------------------------")
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

            let pgConnOption = conn as PGConnection
            var pgConn: PGConnection
            match (pgConnOption) {
                case Some(v) => pgConn = v
                case None =>
                    @Assert(false)
                    return
            }

            var id = "testConnection ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"
            var sql = "insert into simpletest1(id, text1) values('${id}', '${text1}')"

            let result = pgConn.update(sql)
            if (1 != result.rowCount) {
                // println("testUpdate failed")
                @Assert(false)
            }
        }
    }
}
