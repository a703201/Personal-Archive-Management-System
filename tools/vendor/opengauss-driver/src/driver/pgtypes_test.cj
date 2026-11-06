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
import std.io.*
import std.time.*
import std.convert.*
import cangjie_tpc::opengauss.utils.*

@Test
public class TestTypes {
    @TestCase
    func testSqlChar(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var char1 = "c1"
            var varchar1 = "c2"
            var clob1 = "c3"
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "cgc4".toArray()
            var boolean1 = "true"
            var tinyint1 = "5"
            var smallint1 = "6"
            var integer1 = "7"
            var bigint1 = "8"
            var real1 = "9"
            var double1 = "10"
            var date1 = "2020-01-01"
            var time1 = "20:01:01"
            var timetz1 = "20:01:02+08"
            var timestamp1 = "2020-01-05 01:10:11"
            var interval1 = "1000"

            statement.set<String>(0, char1)
            statement.set<String>(1, varchar1)
            statement.set<String>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<String>(4, boolean1)
            statement.set<String>(5, tinyint1)
            statement.set<String>(6, smallint1)
            statement.set<String>(7, integer1)
            statement.set<String>(8, bigint1)
            statement.set<String>(9, real1)
            statement.set<String>(10, double1)
            statement.set<String>(11, date1)
            statement.set<String>(12, time1)
            statement.set<String>(13, timetz1)
            statement.set<String>(14, timestamp1)
            statement.set<String>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var char1Got = ""
            var varchar1Got = ""
            var clob1Got = ""
            var blob1Got = ""
            var boolean1Got = ""
            var tinyint1Got = ""
            var smallint1Got = ""
            var integer1Got = ""
            var bigint1Got = ""
            var real1Got = ""
            var double1Got = ""
            var date1Got = ""
            var time1Got = ""
            var timetz1Got = ""
            var timestamp1Got = ""
            var interval1Got = ""

            statement.set<String>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<String>(0)
                varchar1Got = queryResult.get<String>(1)
                clob1Got = queryResult.get<String>(2)
                blob1Got = queryResult.get<String>(3)
                boolean1Got = queryResult.get<String>(4)
                tinyint1Got = queryResult.get<String>(5)
                smallint1Got = queryResult.get<String>(6)
                integer1Got = queryResult.get<String>(7)
                bigint1Got = queryResult.get<String>(8)
                real1Got = queryResult.get<String>(9)
                double1Got = queryResult.get<String>(10)
                date1Got = queryResult.get<String>(11)
                time1Got = queryResult.get<String>(12)
                timetz1Got = queryResult.get<String>(13)
                timestamp1Got = queryResult.get<String>(14)
                interval1Got = queryResult.get<String>(15)

                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                @Assert(varchar1Got.toString() == varchar1.toString())
                @Assert(clob1Got.toString() == clob1.toString())
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                @Assert(smallint1Got.toString() == smallint1.toString())
                @Assert(integer1Got.toString() == integer1.toString())
                @Assert(bigint1Got.toString() == bigint1.toString())
                @Assert(real1Got.toString() == real1.toString())
                @Assert(double1Got.toString() == double1.toString())
                var date1GotTime = DateTime.parse(date1Got, "yyyy-MM-dd HH:mm:ss")
                var date1Time = DateTime.parse(date1 + " 00:00:00", "yyyy-MM-dd HH:mm:ss")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                var time1GotTime = DateTime.parse("1970-01-01 " + time1Got, "yyyy-MM-dd HH:mm:ss")
                var time1Time = DateTime.parse("1970-01-01 " + time1, "yyyy-MM-dd HH:mm:ss")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                var timetz1GotTime = DateTime.parse("1970-01-01 " + timetz1Got, "yyyy-MM-dd HH:mm:ssO")
                var timetz1Time = DateTime.parse("1970-01-01 " + timetz1, "yyyy-MM-dd HH:mm:ssO")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                @Assert(timestamp1Got.toString() == timestamp1.toString())
                @Assert(interval1Got.toString() == interval1.toString() + " days")
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<String>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableChar(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var char1 = "nullablec1"
            var varchar1 = "nullablec2"
            var clob1 = "nullablec3"
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "nullablecgc4".toArray()
            var boolean1 = "true"
            var tinyint1 = "5"
            var smallint1 = "6"
            var integer1 = "7"
            var bigint1 = "8"
            var real1 = "9"
            var double1 = "10"
            var date1 = "2020-01-01"
            var time1 = "20:01:01"
            var timetz1 = "20:01:02+08"
            var timestamp1 = "2020-01-05 01:10:11"
            var interval1 = "1000"

            statement.set<String>(0, char1)
            statement.set<String>(1, varchar1)
            statement.set<String>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<String>(4, boolean1)
            statement.set<String>(5, tinyint1)
            statement.set<String>(6, smallint1)
            statement.set<String>(7, integer1)
            statement.set<String>(8, bigint1)
            statement.set<String>(9, real1)
            statement.set<String>(10, double1)
            statement.set<String>(11, date1)
            statement.set<String>(12, time1)
            statement.set<String>(13, timetz1)
            statement.set<String>(14, timestamp1)
            statement.set<String>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var char1Got = ""
            var varchar1Got = ""
            var clob1Got = ""
            var blob1Got = ""
            var boolean1Got = ""
            var tinyint1Got = ""
            var smallint1Got = ""
            var integer1Got = ""
            var bigint1Got = ""
            var real1Got = ""
            var double1Got = ""
            var date1Got = ""
            var time1Got = ""
            var timetz1Got = ""
            var timestamp1Got = ""
            var interval1Got = ""

            statement.set<String>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<String>(0)
                varchar1Got = queryResult.get<String>(1)
                clob1Got = queryResult.get<String>(2)
                blob1Got = queryResult.get<String>(3)
                boolean1Got = queryResult.get<String>(4)
                tinyint1Got = queryResult.get<String>(5)
                smallint1Got = queryResult.get<String>(6)
                integer1Got = queryResult.get<String>(7)
                bigint1Got = queryResult.get<String>(8)
                real1Got = queryResult.get<String>(9)
                double1Got = queryResult.get<String>(10)
                date1Got = queryResult.get<String>(11)
                time1Got = queryResult.get<String>(12)
                timetz1Got = queryResult.get<String>(13)
                timestamp1Got = queryResult.get<String>(14)
                interval1Got = queryResult.get<String>(15)

                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                @Assert(getString(varchar1Got) == getString(varchar1))
                @Assert(getString(clob1Got) == getString(clob1))
                @Assert(getString(blob1Got) == bytesToString(blob1))
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                @Assert(getString(smallint1Got) == getString(smallint1))
                @Assert(getString(integer1Got) == getString(integer1))
                @Assert(getString(bigint1Got) == getString(bigint1))
                @Assert(getString(real1Got) == getString(real1))
                @Assert(getString(double1Got) == getString(double1))
                var date1GotTime = DateTime.parse(getString(date1Got), "yyyy-MM-dd HH:mm:ss")
                var date1Time = DateTime.parse(getString(date1) + " 00:00:00", "yyyy-MM-dd HH:mm:ss")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                var time1GotTime = DateTime.parse("1970-01-01 " + getString(time1Got), "yyyy-MM-dd HH:mm:ss")
                var time1Time = DateTime.parse("1970-01-01 " + getString(time1), "yyyy-MM-dd HH:mm:ss")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                var timetz1GotTime = DateTime.parse("1970-01-01 " + getString(timetz1Got), "yyyy-MM-dd HH:mm:ssO")
                var timetz1Time = DateTime.parse("1970-01-01 " + getString(timetz1), "yyyy-MM-dd HH:mm:ssO")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                @Assert(getString(timestamp1Got) == getString(timestamp1))
                @Assert(getString(interval1Got) == getString(interval1) + " days")
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<String>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlVarchar(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var char1 = "vc1"
            var varchar1 = "vc2"
            var clob1 = "vc3"
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "vcgc4".toArray()
            var boolean1 = "false"
            var tinyint1 = "15"
            var smallint1 = "16"
            var integer1 = "17"
            var bigint1 = "18"
            var real1 = "19"
            var double1 = "20"
            var date1 = "2021-01-01"
            var time1 = "21:01:01"
            var timetz1 = "21:01:02+08"
            var timestamp1 = "2021-01-05 01:10:11"
            var interval1 = "2000"

            statement.set<String>(0, char1)
            statement.set<String>(1, varchar1)
            statement.set<String>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<String>(4, boolean1)
            statement.set<String>(5, tinyint1)
            statement.set<String>(6, smallint1)
            statement.set<String>(7, integer1)
            statement.set<String>(8, bigint1)
            statement.set<String>(9, real1)
            statement.set<String>(10, double1)
            statement.set<String>(11, date1)
            statement.set<String>(12, time1)
            statement.set<String>(13, timetz1)
            statement.set<String>(14, timestamp1)
            statement.set<String>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var char1Got = ""
            var varchar1Got = ""
            var clob1Got = ""
            var blob1Got = ""
            var boolean1Got = ""
            var tinyint1Got = ""
            var smallint1Got = ""
            var integer1Got = ""
            var bigint1Got = ""
            var real1Got = ""
            var double1Got = ""
            var date1Got = ""
            var time1Got = ""
            var timetz1Got = ""
            var timestamp1Got = ""
            var interval1Got = ""

            statement.set<String>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<String>(0)
                varchar1Got = queryResult.get<String>(1)
                clob1Got = queryResult.get<String>(2)
                blob1Got = queryResult.get<String>(3)
                boolean1Got = queryResult.get<String>(4)
                tinyint1Got = queryResult.get<String>(5)
                smallint1Got = queryResult.get<String>(6)
                integer1Got = queryResult.get<String>(7)
                bigint1Got = queryResult.get<String>(8)
                real1Got = queryResult.get<String>(9)
                double1Got = queryResult.get<String>(10)
                date1Got = queryResult.get<String>(11)
                time1Got = queryResult.get<String>(12)
                timetz1Got = queryResult.get<String>(13)
                timestamp1Got = queryResult.get<String>(14)
                interval1Got = queryResult.get<String>(15)

                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                @Assert(varchar1Got.toString() == varchar1.toString())
                @Assert(clob1Got.toString() == clob1.toString())
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                @Assert(smallint1Got.toString() == smallint1.toString())
                @Assert(integer1Got.toString() == integer1.toString())
                @Assert(bigint1Got.toString() == bigint1.toString())
                @Assert(real1Got.toString() == real1.toString())
                @Assert(double1Got.toString() == double1.toString())
                var date1GotTime = DateTime.parse(date1Got, "yyyy-MM-dd HH:mm:ss")
                var date1Time = DateTime.parse(date1 + " 00:00:00", "yyyy-MM-dd HH:mm:ss")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                var time1GotTime = DateTime.parse("1970-01-01 " + time1Got, "yyyy-MM-dd HH:mm:ss")
                var time1Time = DateTime.parse("1970-01-01 " + time1, "yyyy-MM-dd HH:mm:ss")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                var timetz1GotTime = DateTime.parse("1970-01-01 " + timetz1Got, "yyyy-MM-dd HH:mm:ssO")
                var timetz1Time = DateTime.parse("1970-01-01 " + timetz1, "yyyy-MM-dd HH:mm:ssO")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                @Assert(timestamp1Got.toString() == timestamp1.toString())
                @Assert(interval1Got.toString() == interval1.toString() + " days")
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<String>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableVarchar(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var char1 = "nullablevc1"
            var varchar1 = "nullablevc2"
            var clob1 = "nullablevc3"
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "nullablevcgc4".toArray()
            var boolean1 = "false"
            var tinyint1 = "15"
            var smallint1 = "16"
            var integer1 = "17"
            var bigint1 = "18"
            var real1 = "19"
            var double1 = "20"
            var date1 = "2021-01-01"
            var time1 = "21:01:01"
            var timetz1 = "21:01:02+08"
            var timestamp1 = "2021-01-05 01:10:11"
            var interval1 = "2000"

            statement.set<String>(0, char1)
            statement.set<String>(1, varchar1)
            statement.set<String>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<String>(4, boolean1)
            statement.set<String>(5, tinyint1)
            statement.set<String>(6, smallint1)
            statement.set<String>(7, integer1)
            statement.set<String>(8, bigint1)
            statement.set<String>(9, real1)
            statement.set<String>(10, double1)
            statement.set<String>(11, date1)
            statement.set<String>(12, time1)
            statement.set<String>(13, timetz1)
            statement.set<String>(14, timestamp1)
            statement.set<String>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var char1Got = ""
            var varchar1Got = ""
            var clob1Got = ""
            var blob1Got = ""
            var boolean1Got = ""
            var tinyint1Got = ""
            var smallint1Got = ""
            var integer1Got = ""
            var bigint1Got = ""
            var real1Got = ""
            var double1Got = ""
            var date1Got = ""
            var time1Got = ""
            var timetz1Got = ""
            var timestamp1Got = ""
            var interval1Got = ""

            statement.set<String>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<String>(0)
                varchar1Got = queryResult.get<String>(1)
                clob1Got = queryResult.get<String>(2)
                blob1Got = queryResult.get<String>(3)
                boolean1Got = queryResult.get<String>(4)
                tinyint1Got = queryResult.get<String>(5)
                smallint1Got = queryResult.get<String>(6)
                integer1Got = queryResult.get<String>(7)
                bigint1Got = queryResult.get<String>(8)
                real1Got = queryResult.get<String>(9)
                double1Got = queryResult.get<String>(10)
                date1Got = queryResult.get<String>(11)
                time1Got = queryResult.get<String>(12)
                timetz1Got = queryResult.get<String>(13)
                timestamp1Got = queryResult.get<String>(14)
                interval1Got = queryResult.get<String>(15)

                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                @Assert(getString(varchar1Got) == getString(varchar1))
                @Assert(getString(clob1Got) == getString(clob1))
                @Assert(getString(blob1Got) == bytesToString(blob1))
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                @Assert(getString(smallint1Got) == getString(smallint1))
                @Assert(getString(integer1Got) == getString(integer1))
                @Assert(getString(bigint1Got) == getString(bigint1))
                @Assert(getString(real1Got) == getString(real1))
                @Assert(getString(double1Got) == getString(double1))
                var date1GotTime = DateTime.parse(getString(date1Got), "yyyy-MM-dd HH:mm:ss")
                var date1Time = DateTime.parse(getString(date1) + " 00:00:00", "yyyy-MM-dd HH:mm:ss")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                var time1GotTime = DateTime.parse("1970-01-01 " + getString(time1Got), "yyyy-MM-dd HH:mm:ss")
                var time1Time = DateTime.parse("1970-01-01 " + getString(time1), "yyyy-MM-dd HH:mm:ss")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                var timetz1GotTime = DateTime.parse("1970-01-01 " + getString(timetz1Got), "yyyy-MM-dd HH:mm:ssO")
                var timetz1Time = DateTime.parse("1970-01-01 " + getString(timetz1), "yyyy-MM-dd HH:mm:ssO")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                @Assert(getString(timestamp1Got) == getString(timestamp1))
                @Assert(getString(interval1Got) == getString(interval1) + " days")
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<String>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlClob(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "clob1"
            var char1bas = ByteBuffer()
            char1bas.write(char1value.toArray())
            var char1 = char1bas
            let varchar1value = "clob2"
            var varchar1bas = ByteBuffer()
            varchar1bas.write(varchar1value.toArray())
            var varchar1 = varchar1bas
            var varchar1querybas = ByteBuffer()
            varchar1querybas.write(varchar1value.toArray())
            var varchar1query = varchar1querybas
            var clob1value = "clob3"
            var clob1bas = ByteBuffer()
            clob1bas.write(clob1value.toArray())
            var clob1 = clob1bas
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "clobgc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1bas = ByteBuffer()
            boolean1bas.write(boolean1value.toArray())
            var boolean1 = boolean1bas
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas
            var real1value = 19.0f32
            var real1bas = ByteBuffer()
            real1bas.write(real1value.toBits().toBeBytes())
            var real1 = real1bas
            var double1value = 20.0f64
            var double1bas = ByteBuffer()
            double1bas.write(double1value.toBits().toBeBytes())
            var double1 = double1bas
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456", "yyyy-MM-dd HH:mm:ss SS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<InputStream>(0, char1)
            statement.set<InputStream>(1, varchar1)
            statement.set<InputStream>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<InputStream>(4, boolean1)
            statement.set<InputStream>(5, tinyint1)
            statement.set<InputStream>(6, smallint1)
            statement.set<InputStream>(7, integer1)
            statement.set<InputStream>(8, bigint1)
            statement.set<InputStream>(9, real1)
            statement.set<InputStream>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp: InputStream = ByteBuffer()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            statement.set<InputStream>(0, varchar1query)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<InputStream>(0)
                varchar1Got = queryResult.get<InputStream>(1)
                clob1Got = queryResult.get<InputStream>(2)
                blob1Got = queryResult.get<InputStream>(3)
                boolean1Got = queryResult.get<InputStream>(4)
                tinyint1Got = queryResult.get<InputStream>(5)
                smallint1Got = queryResult.get<InputStream>(6)
                integer1Got = queryResult.get<InputStream>(7)
                bigint1Got = queryResult.get<InputStream>(8)
                real1Got = queryResult.get<InputStream>(9)
                double1Got = queryResult.get<InputStream>(10)
                date1Got = queryResult.get<InputStream>(11)
                time1Got = queryResult.get<InputStream>(12)
                timetz1Got = queryResult.get<InputStream>(13)
                timestamp1Got = queryResult.get<InputStream>(14)
                interval1Got = queryResult.get<InputStream>(15)

                var tmpcmpstr = inputStreamToStringMax1024(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = inputStreamToStringMax1024(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = inputStreamToStringMax1024(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = inputStreamToStringMax1024(blob1Got)
                println("${tmpcmpstr}==${bytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == bytesToString(blob1))
                tmpcmpstr = inputStreamToStringMax1024(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = inputStreamToStringMax1024(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = inputStreamToStringMax1024(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = inputStreamToStringMax1024(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = inputStreamToStringMax1024(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = inputStreamToStringMax1024(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = inputStreamToStringMax1024(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var varchar1querybas2 = ByteBuffer()
            varchar1querybas2.write(varchar1value.toArray())
            var varchar1query2 = varchar1querybas2

            statement.set<InputStream>(0, varchar1query2)
            statement.query()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableClob(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "nullableclob1"
            var char1bas = ByteBuffer()
            char1bas.write(char1value.toArray())
            var char1 = char1bas
            let varchar1value = "nullableclob2"
            var varchar1bas = ByteBuffer()
            varchar1bas.write(varchar1value.toArray())
            var varchar1 = varchar1bas
            var varchar1querybas = ByteBuffer()
            varchar1querybas.write(varchar1value.toArray())
            var varchar1query = varchar1querybas
            var clob1value = "nullableclob3"
            var clob1bas = ByteBuffer()
            clob1bas.write(clob1value.toArray())
            var clob1 = clob1bas
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "nullableclobgc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1bas = ByteBuffer()
            boolean1bas.write(boolean1value.toArray())
            var boolean1 = boolean1bas
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas
            var real1value = 19.0f32
            var real1bas = ByteBuffer()
            real1bas.write(real1value.toBits().toBeBytes())
            var real1 = real1bas
            var double1value = 20.0f64
            var double1bas = ByteBuffer()
            double1bas.write(double1value.toBits().toBeBytes())
            var double1 = double1bas
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<InputStream>(0, char1)
            statement.set<InputStream>(1, varchar1)
            statement.set<InputStream>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<InputStream>(4, boolean1)
            statement.set<InputStream>(5, tinyint1)
            statement.set<InputStream>(6, smallint1)
            statement.set<InputStream>(7, integer1)
            statement.set<InputStream>(8, bigint1)
            statement.set<InputStream>(9, real1)
            statement.set<InputStream>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp: InputStream = ByteBuffer()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            statement.set<InputStream>(0, varchar1query)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<InputStream>(0)
                varchar1Got = queryResult.get<InputStream>(1)
                clob1Got = queryResult.get<InputStream>(2)
                blob1Got = queryResult.get<InputStream>(3)
                boolean1Got = queryResult.get<InputStream>(4)
                tinyint1Got = queryResult.get<InputStream>(5)
                smallint1Got = queryResult.get<InputStream>(6)
                integer1Got = queryResult.get<InputStream>(7)
                bigint1Got = queryResult.get<InputStream>(8)
                real1Got = queryResult.get<InputStream>(9)
                double1Got = queryResult.get<InputStream>(10)
                date1Got = queryResult.get<InputStream>(11)
                time1Got = queryResult.get<InputStream>(12)
                timetz1Got = queryResult.get<InputStream>(13)
                timestamp1Got = queryResult.get<InputStream>(14)
                interval1Got = queryResult.get<InputStream>(15)

                var tmpcmpstr = inputStreamToStringMax1024(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = inputStreamToStringMax1024(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = inputStreamToStringMax1024(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = inputStreamToStringMax1024(blob1Got)
                println("${tmpcmpstr}==${bytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == bytesToString(blob1))
                tmpcmpstr = inputStreamToStringMax1024(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = inputStreamToStringMax1024(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = inputStreamToStringMax1024(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = inputStreamToStringMax1024(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = inputStreamToStringMax1024(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = inputStreamToStringMax1024(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = inputStreamToStringMax1024(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = inputStreamToStringMax1024(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var varchar1querybas2 = ByteBuffer()
            varchar1querybas2.write(varchar1value.toArray())
            var varchar1query2 = varchar1querybas2

            statement.set<InputStream>(0, varchar1query2)
            statement.query()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlBinary(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "binary1"
            var char1 = char1value.toArray()
            let varchar1value = "binary2"
            var varchar1 = varchar1value.toArray()
            var clob1value = "binary3"
            var clob1 = clob1value.toArray()
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "binarygc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1 = boolean1value.toArray()
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas.bytes()
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas.bytes()
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas.bytes()
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas.bytes()
            var real1value = 19.0f32
            var real1 = real1value.toBits().toBeBytes()
            var double1value = 20.0f64
            var double1 = double1value.toBits().toBeBytes()
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<Array<Byte>>(0, char1)
            statement.set<Array<Byte>>(1, varchar1)
            statement.set<Array<Byte>>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Array<Byte>>(4, boolean1)
            statement.set<Array<Byte>>(5, tinyint1)
            statement.set<Array<Byte>>(6, smallint1)
            statement.set<Array<Byte>>(7, integer1)
            statement.set<Array<Byte>>(8, bigint1)
            statement.set<Array<Byte>>(9, real1)
            statement.set<Array<Byte>>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp = Array<Byte>()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            
            statement.set<Array<Byte>>(0, varchar1)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Array<Byte>>(0)
                varchar1Got = queryResult.get<Array<Byte>>(1)
                clob1Got = queryResult.get<Array<Byte>>(2)
                blob1Got = queryResult.get<Array<Byte>>(3)
                boolean1Got = queryResult.get<Array<Byte>>(4)
                tinyint1Got = queryResult.get<Array<Byte>>(5)
                smallint1Got = queryResult.get<Array<Byte>>(6)
                integer1Got = queryResult.get<Array<Byte>>(7)
                bigint1Got = queryResult.get<Array<Byte>>(8)
                real1Got = queryResult.get<Array<Byte>>(9)
                double1Got = queryResult.get<Array<Byte>>(10)
                date1Got = queryResult.get<Array<Byte>>(11)
                time1Got = queryResult.get<Array<Byte>>(12)
                timetz1Got = queryResult.get<Array<Byte>>(13)
                timestamp1Got = queryResult.get<Array<Byte>>(14)
                interval1Got = queryResult.get<Array<Byte>>(15)

                var tmpcmpstr = bytesToString(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = bytesToString(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = bytesToString(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = bytesToString(blob1Got)
                println("${tmpcmpstr}==${bytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == bytesToString(blob1))
                tmpcmpstr = bytesToString(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = bytesToString(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = bytesToString(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = bytesToString(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = bytesToString(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = bytesToString(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = bytesToString(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = bytesToString(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = bytesToString(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = bytesToString(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = bytesToString(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = bytesToString(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Array<Byte>>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableBinary(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "nullablebinary1"
            var char1 = char1value.toArray()
            let varchar1value = "nullablebinary2"
            var varchar1 = varchar1value.toArray()
            var clob1value = "nullablebinary3"
            var clob1 = clob1value.toArray()
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "nullablebinarygc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1 = boolean1value.toArray()
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas.bytes()
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas.bytes()
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas.bytes()
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas.bytes()
            var real1value = 19.0f32
            var real1 = real1value.toBits().toBeBytes()
            var double1value = 20.0f64
            var double1 = double1value.toBits().toBeBytes()
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<Array<Byte>>(0, char1)
            statement.set<Array<Byte>>(1, varchar1)
            statement.set<Array<Byte>>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Array<Byte>>(4, boolean1)
            statement.set<Array<Byte>>(5, tinyint1)
            statement.set<Array<Byte>>(6, smallint1)
            statement.set<Array<Byte>>(7, integer1)
            statement.set<Array<Byte>>(8, bigint1)
            statement.set<Array<Byte>>(9, real1)
            statement.set<Array<Byte>>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp = Array<Byte>()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            statement.set<Array<Byte>>(0, varchar1)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Array<Byte>>(0)
                varchar1Got = queryResult.get<Array<Byte>>(1)
                clob1Got = queryResult.get<Array<Byte>>(2)
                blob1Got = queryResult.get<Array<Byte>>(3)
                boolean1Got = queryResult.get<Array<Byte>>(4)
                tinyint1Got = queryResult.get<Array<Byte>>(5)
                smallint1Got = queryResult.get<Array<Byte>>(6)
                integer1Got = queryResult.get<Array<Byte>>(7)
                bigint1Got = queryResult.get<Array<Byte>>(8)
                real1Got = queryResult.get<Array<Byte>>(9)
                double1Got = queryResult.get<Array<Byte>>(10)
                date1Got = queryResult.get<Array<Byte>>(11)
                time1Got = queryResult.get<Array<Byte>>(12)
                timetz1Got = queryResult.get<Array<Byte>>(13)
                timestamp1Got = queryResult.get<Array<Byte>>(14)
                interval1Got = queryResult.get<Array<Byte>>(15)

                var tmpcmpstr = opBytesToString(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = opBytesToString(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = opBytesToString(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = opBytesToString(blob1Got)
                println("${tmpcmpstr}==${opBytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == opBytesToString(blob1))
                tmpcmpstr = opBytesToString(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = opBytesToString(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = opBytesToString(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = opBytesToString(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = opBytesToString(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = opBytesToString(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = opBytesToString(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = opBytesToString(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = opBytesToString(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = opBytesToString(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = opBytesToString(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = opBytesToString(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Array<Byte>>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlVarBinary(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "varbinary1"
            var char1 = char1value.toArray()
            let varchar1value = "varbinary2"
            var varchar1 = varchar1value.toArray()
            var clob1value = "varbinary3"
            var clob1 = clob1value.toArray()
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "varbinarygc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1 = boolean1value.toArray()
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas.bytes()
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas.bytes()
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas.bytes()
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas.bytes()
            var real1value = 19.0f32
            var real1 = real1value.toBits().toBeBytes()
            var double1value = 20.0f64
            var double1 = double1value.toBits().toBeBytes()
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<Array<Byte>>(0, char1)
            statement.set<Array<Byte>>(1, varchar1)
            statement.set<Array<Byte>>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Array<Byte>>(4, boolean1)
            statement.set<Array<Byte>>(5, tinyint1)
            statement.set<Array<Byte>>(6, smallint1)
            statement.set<Array<Byte>>(7, integer1)
            statement.set<Array<Byte>>(8, bigint1)
            statement.set<Array<Byte>>(9, real1)
            statement.set<Array<Byte>>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp = Array<Byte>()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            statement.set<Array<Byte>>(0, varchar1)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Array<Byte>>(0)
                varchar1Got = queryResult.get<Array<Byte>>(1)
                clob1Got = queryResult.get<Array<Byte>>(2)
                blob1Got = queryResult.get<Array<Byte>>(3)
                boolean1Got = queryResult.get<Array<Byte>>(4)
                tinyint1Got = queryResult.get<Array<Byte>>(5)
                smallint1Got = queryResult.get<Array<Byte>>(6)
                integer1Got = queryResult.get<Array<Byte>>(7)
                bigint1Got = queryResult.get<Array<Byte>>(8)
                real1Got = queryResult.get<Array<Byte>>(9)
                double1Got = queryResult.get<Array<Byte>>(10)
                date1Got = queryResult.get<Array<Byte>>(11)
                time1Got = queryResult.get<Array<Byte>>(12)
                timetz1Got = queryResult.get<Array<Byte>>(13)
                timestamp1Got = queryResult.get<Array<Byte>>(14)
                interval1Got = queryResult.get<Array<Byte>>(15)

                var tmpcmpstr = bytesToString(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = bytesToString(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = bytesToString(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = bytesToString(blob1Got)
                println("${tmpcmpstr}==${bytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == bytesToString(blob1))
                tmpcmpstr = bytesToString(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = bytesToString(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = bytesToString(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = bytesToString(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = bytesToString(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = bytesToString(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = bytesToString(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = bytesToString(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = bytesToString(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = bytesToString(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = bytesToString(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = bytesToString(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Array<Byte>>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableVarBinary(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                println("cannot get the opengauss driver")
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        try (conn = ds.connect()) {
            @Assert(conn.state == ConnectionState.Connected)
            let metadata = conn.getMetaData()
            @Assert(metadata.size > 0)
            var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            let char1value = "nullablevarbinary1"
            var char1 = char1value.toArray()
            let varchar1value = "nullablevarbinary2"
            var varchar1 = varchar1value.toArray()
            var clob1value = "nullablevarbinary3"
            var clob1 = clob1value.toArray()
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "nullablevarbinarygc4".toArray()
            // 二进制类型boolean需要0或1
            var boolean1value = "1"
            var boolean1 = boolean1value.toArray()
            // 二进制类型数字需要二进制
            var tinyint1value = 15
            var tinyint1bas = ByteBuffer()
            tinyint1bas.write(UInt8(tinyint1value))
            var tinyint1 = tinyint1bas.bytes()
            var smallint1value = 16
            var smallint1bas = ByteBuffer()
            smallint1bas.write(0)
            smallint1bas.write(UInt8(smallint1value))
            var smallint1 = smallint1bas.bytes()
            var integer1value = 17
            var integer1bas = ByteBuffer()
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(0)
            integer1bas.write(UInt8(integer1value))
            var integer1 = integer1bas.bytes()
            var bigint1value = 18
            var bigint1bas = ByteBuffer()
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(0)
            bigint1bas.write(UInt8(bigint1value))
            var bigint1 = bigint1bas.bytes()
            var real1value = 19.0f32
            var real1 = real1value.toBits().toBeBytes()
            var double1value = 20.0f64
            var double1 = double1value.toBits().toBeBytes()
            // 时间使用二进制目前存在一些问题，因此目前先不使用二进制测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = 
                Duration.day * 23456 + Duration.hour * 13 + Duration.minute * 29 + Duration.second * 37

            statement.set<Array<Byte>>(0, char1)
            statement.set<Array<Byte>>(1, varchar1)
            statement.set<Array<Byte>>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Array<Byte>>(4, boolean1)
            statement.set<Array<Byte>>(5, tinyint1)
            statement.set<Array<Byte>>(6, smallint1)
            statement.set<Array<Byte>>(7, integer1)
            statement.set<Array<Byte>>(8, bigint1)
            statement.set<Array<Byte>>(9, real1)
            statement.set<Array<Byte>>(10, double1)
            statement.set<DateTime>(11, date1)
            statement.set<DateTime>(12, time1)
            statement.set<DateTime>(13, timetz1)
            statement.set<DateTime>(14, timestamp1)
            statement.set<Duration>(15, interval1)
            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            var tmp = Array<Byte>()
            var char1Got = tmp
            var varchar1Got = tmp
            var clob1Got = tmp
            var blob1Got = tmp
            var boolean1Got = tmp
            var tinyint1Got = tmp
            var smallint1Got = tmp
            var integer1Got = tmp
            var bigint1Got = tmp
            var real1Got = tmp
            var double1Got = tmp
            var date1Got = tmp
            var time1Got = tmp
            var timetz1Got = tmp
            var timestamp1Got = tmp
            var interval1Got = tmp

            statement.set<Array<Byte>>(0, varchar1)
            let queryResult = statement.query()
            let buffer = Array<Byte>(10000, repeat: 0)
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Array<Byte>>(0)
                varchar1Got = queryResult.get<Array<Byte>>(1)
                clob1Got = queryResult.get<Array<Byte>>(2)
                blob1Got = queryResult.get<Array<Byte>>(3)
                boolean1Got = queryResult.get<Array<Byte>>(4)
                tinyint1Got = queryResult.get<Array<Byte>>(5)
                smallint1Got = queryResult.get<Array<Byte>>(6)
                integer1Got = queryResult.get<Array<Byte>>(7)
                bigint1Got = queryResult.get<Array<Byte>>(8)
                real1Got = queryResult.get<Array<Byte>>(9)
                double1Got = queryResult.get<Array<Byte>>(10)
                date1Got = queryResult.get<Array<Byte>>(11)
                time1Got = queryResult.get<Array<Byte>>(12)
                timetz1Got = queryResult.get<Array<Byte>>(13)
                timestamp1Got = queryResult.get<Array<Byte>>(14)
                interval1Got = queryResult.get<Array<Byte>>(15)

                var tmpcmpstr = opBytesToString(char1Got)
                println("${tmpcmpstr}==${char1value}")
                @Assert(tmpcmpstr.trimAscii() == char1value)
                tmpcmpstr = opBytesToString(varchar1Got)
                println("${tmpcmpstr}==${varchar1value}")
                @Assert(tmpcmpstr == varchar1value)
                tmpcmpstr = opBytesToString(clob1Got)
                println("${tmpcmpstr}==${clob1value}")
                @Assert(tmpcmpstr == clob1value)
                tmpcmpstr = opBytesToString(blob1Got)
                println("${tmpcmpstr}==${opBytesToString(blob1)}")
                @Assert(tmpcmpstr.trimAscii() == opBytesToString(blob1))
                tmpcmpstr = opBytesToString(boolean1Got)
                println("${tmpcmpstr}==${boolean1value}")
                @Assert(tmpcmpstr[0] == (boolean1value == "1").toString()[0])
                tmpcmpstr = opBytesToString(tinyint1Got)
                println("${tmpcmpstr}==${tinyint1value}")
                @Assert(tmpcmpstr == tinyint1value.toString())
                tmpcmpstr = opBytesToString(smallint1Got)
                println("${tmpcmpstr}==${smallint1value}")
                @Assert(tmpcmpstr == smallint1value.toString())
                tmpcmpstr = opBytesToString(integer1Got)
                println("${tmpcmpstr}==${integer1value}")
                @Assert(tmpcmpstr == integer1value.toString())
                tmpcmpstr = opBytesToString(bigint1Got)
                println("${tmpcmpstr}==${bigint1value}")
                @Assert(tmpcmpstr == bigint1value.toString())
                tmpcmpstr = opBytesToString(real1Got)
                println("${tmpcmpstr}==${real1value}")
                @Assert(tmpcmpstr == real1value.toString())
                tmpcmpstr = opBytesToString(double1Got)
                println("${tmpcmpstr}==${double1value}")
                @Assert(tmpcmpstr == double1value.toString())
                var strtmp = opBytesToString(date1Got)
                var date1GotTime = stringToDateTime(strtmp)
                var date1Time = date1
                println("${date1GotTime}==${date1Time}")
                @Assert(date1GotTime.year == date1Time.year)
                @Assert(date1GotTime.month == date1Time.month)
                @Assert(date1GotTime.dayOfMonth == date1Time.dayOfMonth)
                strtmp = opBytesToString(time1Got)
                var time1GotTime = stringToDateTime(strtmp)
                var time1Time = time1
                println("${time1GotTime}==${time1Time}")
                @Assert(time1GotTime.hour == time1Time.hour)
                @Assert(time1GotTime.minute == time1Time.minute)
                @Assert(time1GotTime.second == time1Time.second)
                strtmp = opBytesToString(timetz1Got)
                var timetz1GotTime = stringToDateTime(strtmp)
                var timetz1Time = timetz1
                println("${timetz1GotTime}==${timetz1Time}")
                @Assert(timetz1GotTime.hour == timetz1Time.hour)
                @Assert(timetz1GotTime.minute == timetz1Time.minute)
                @Assert(timetz1GotTime.second == timetz1Time.second)
                @Assert(timetz1GotTime.zoneId == timetz1Time.zoneId)
                strtmp = opBytesToString(timestamp1Got)
                println("${strtmp}==${timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO")}")
                @Assert(strtmp == timestamp1.format("yyyy-MM-dd HH:mm:ss.SSO"))
                strtmp = opBytesToString(interval1Got)
                println("${strtmp}==${intervalToString(interval1)}")
                @Assert(strtmp == intervalToString(interval1))
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Array<Byte>>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

}
