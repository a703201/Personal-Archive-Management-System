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
public class TestTransaction {
    @TestCase
    func testTransactionDefault1(): Unit {
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionDefault2(): Unit {
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionDefault3(): Unit {
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionDefault4(): Unit {
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadUncommittedReadOnlyNotDeferrable1(): Unit {
        // TransactionIsoLevel.ReadUncommitted
        // TransactionAccessMode.ReadOnly
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1(exception)
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
        var atinsert = false
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var transaction = conn.createTransaction()
            transaction.isoLevel = TransactionIsoLevel.ReadUncommitted
            transaction.accessMode = TransactionAccessMode.ReadOnly
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"
            atinsert = true

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            // 因为是readonly transaction，因此插入数据应该会报错，所以如果能走到这里，那么则说明出现了问题
            @Assert(false)
        } catch (ex: Exception) {
            if (!atinsert) {
                // 如果不是insert的异常，那么则有问题
                ex.printStackTrace()
                @Assert(false)
            }
        }
    }

    @TestCase
    func testTransactionReadUncommittedReadWriteNotDeferrable1(): Unit {
        // TransactionIsoLevel.ReadUncommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadUncommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadUncommittedReadWriteNotDeferrable2(): Unit {
        // TransactionIsoLevel.ReadUncommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadUncommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadUncommittedReadWriteNotDeferrable3(): Unit {
        // TransactionIsoLevel.ReadUncommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadUncommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadUncommittedReadWriteNotDeferrable4(): Unit {
        // TransactionIsoLevel.ReadUncommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadUncommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadCommittedReadWriteNotDeferrable1(): Unit {
        // TransactionIsoLevel.ReadCommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadCommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadCommittedReadWriteNotDeferrable2(): Unit {
        // TransactionIsoLevel.ReadCommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadCommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadCommittedReadWriteNotDeferrable3(): Unit {
        // TransactionIsoLevel.ReadCommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadCommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionReadCommittedReadWriteNotDeferrable4(): Unit {
        // TransactionIsoLevel.ReadCommitted
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.ReadCommitted
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionRepeatableReadReadWriteNotDeferrable1(): Unit {
        // TransactionIsoLevel.RepeatableRead
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.RepeatableRead
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionRepeatableReadReadWriteNotDeferrable2(): Unit {
        // TransactionIsoLevel.RepeatableRead
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.RepeatableRead
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionRepeatableReadReadWriteNotDeferrable3(): Unit {
        // TransactionIsoLevel.RepeatableRead
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.RepeatableRead
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionRepeatableReadReadWriteNotDeferrable4(): Unit {
        // TransactionIsoLevel.RepeatableRead
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.NotDeferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.RepeatableRead
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.NotDeferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSnapshotReadWriteDeferrable1(): Unit {
        // TransactionIsoLevel.Snapshot
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Snapshot
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSnapshotReadWriteDeferrable2(): Unit {
        // TransactionIsoLevel.Snapshot
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Snapshot
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSnapshotReadWriteDeferrable3(): Unit {
        // TransactionIsoLevel.Snapshot
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Snapshot
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSnapshotReadWriteDeferrable4(): Unit {
        // TransactionIsoLevel.Snapshot
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Snapshot
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSerializableReadWriteDeferrable1(): Unit {
        // TransactionIsoLevel.Serializable
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> select data1(ok) -> select data2(no data) ->
        // rollback -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Serializable
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()
            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            println("==============count=${count}")
            @Assert(count == 1)
            statement.close()

            // 回滚到保存点1
            transaction.rollback(savePointName)

            // 在事务中应该可以获取到数据1
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

            // 因为rollback了保存点1，在事务中应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            // 事务rollback操作
            transaction.rollback()

            // 因为执行了rollback，因此应该不可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 因为执行了rollback，因此应该获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSerializableReadWriteDeferrable2(): Unit {
        // TransactionIsoLevel.Serializable
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> rollback savepoint1 -> commit -> select data1(ok) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Serializable
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 事务rollback操作第一个保存点
            transaction.rollback(savePointName)

            // 事务commit操作
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为中间执行了rollback保存点1，因此在事务commit后应该可以获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSerializableReadWriteDeferrable3(): Unit {
        // TransactionIsoLevel.Serializable
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> rollback savepoint1(exception) -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Serializable
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            try {
                // 事务rollback操作第一个保存点
                transaction.rollback(savePointName)
                // 因为已经删除了保存点，因此这个应该失败
                @Assert(false)
            } catch (ex: Exception) {
                // 有异常表示正常
            }

            // 事务commit操作，但是由于中间出现了错误，因此就算commit，数据也不会进入数据库
            transaction.commit()

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            updatetimeGot = DateTime.UnixEpoch
            text1Got = ""

            statement.set<String>(0, id)
            queryResult = statement.query()
            count = 0
            while (queryResult.next()) {
                // 预期是0行，不需要取值
                // id = queryResult.get<String>(0)
                // updatetimeGot = queryResult.get<DateTime>(1)
                // text1Got = queryResult.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)

            // 虽然执行了commit，但是由于中间出现了异常，因此commit实际是rollback，因此获取不到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                // 预期是0行，不需要取值
                // id2 = queryResult2.get<String>(0)
                // updatetime2Got = queryResult2.get<DateTime>(1)
                // text2Got = queryResult2.get<String>(2)

                @Assert(false)
                // count++
            }
            @Assert(count == 0)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testTransactionSerializableReadWriteDeferrable4(): Unit {
        // TransactionIsoLevel.Serializable
        // TransactionAccessMode.ReadWrite
        // TransactionDeferrableMode.Deferrable
        // 测试用例 insert data1 -> save savepoint1 -> insert data2 -> select data1(ok) ->
        // select data2(ok) -> release savepoint1 -> 
        // commit -> select data1(no data) -> select data2(no data)
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
            transaction.isoLevel = TransactionIsoLevel.Serializable
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.begin()

            // 插入第一条数据
            var sql = "insert into simpletest1(id, updatetime, text1) values(?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var id = "testTransaction ${DateTime.now()}"
            var updatetime = DateTime.now()
            var text1 = "${id + " text1"}"

            statement.set<String>(0, id)
            statement.set<DateTime>(1, updatetime)
            statement.set<String>(2, text1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)

            // 保存点
            var savePointName = "savepoint1"
            transaction.save(savePointName)

            // 插入第二条数据
            var id2 = "testTransaction2 ${DateTime.now()}"
            var updatetime2 = DateTime.now()
            var text2 = "${id2 + " text2"}"

            statement.set<String>(0, id2)
            statement.set<DateTime>(1, updatetime2)
            statement.set<String>(2, text2)
            updateresult = statement.update()
            statement.close()

            // 在事务中应该可以获取到数据1
            sql = "select id, updatetime, text1 from simpletest1 where id = ?"
            statement = conn.prepareStatement(sql)
            var updatetimeGot = DateTime.UnixEpoch
            var text1Got = ""

            statement.set<String>(0, id)
            var queryResult = statement.query()
            var count = 0
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

            // 在事务中应该可以获取到数据2
            var updatetime2Got = DateTime.UnixEpoch
            var text2Got = ""

            statement.set<String>(0, id2)
            var queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            // 删除保存点
            transaction.release(savePointName)

            // 事务commit操作，就算删除了保存点，数据也会进入数据库
            transaction.commit()

            // 因为执行了commit，因此应该可以获取到数据1
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

            // 因为执行了commit，因此在事务commit后应该可以获取到数据2
            updatetime2Got = DateTime.UnixEpoch
            text2Got = ""

            statement.set<String>(0, id2)
            queryResult2 = statement.query()
            count = 0
            while (queryResult2.next()) {
                id2 = queryResult2.get<String>(0)
                updatetime2Got = queryResult2.get<DateTime>(1)
                text2Got = queryResult2.get<String>(2)

                println("updatetime2Got=${updatetime2Got} updatetime2=${updatetime2}")
                println("text2Got=${text2Got} text2=${text2}")
                if (updatetime2Got != updatetime2) {
                    println(
                        "updatetime2Got.nanosecond=${updatetime2Got.nanosecond} updatetime2.nanosecond=${updatetime2.nanosecond}"
                    )
                    println(
                        "updatetime2Got.zone=${updatetime2Got.zone} updatetime2.zone=${updatetime2.zone}")
                }
                @Assert(updatetime2Got.format("yyyy-MM-dd HH:mm:ss.S") == updatetime2.format("yyyy-MM-dd HH:mm:ss.S"))
                @Assert(text2Got == text2)
                count++
            }
            @Assert(count == 1)
            statement.close()

            sleep(Duration.second)
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }
}
