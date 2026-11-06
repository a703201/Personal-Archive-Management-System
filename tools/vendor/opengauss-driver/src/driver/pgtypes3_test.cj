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
public class TestTypes3 {
    @TestCase
    func testSqlReal(): Unit {
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
            var char1 = 999.999f32
            var varchar1 = -999.999f32
            var clob1 = 89112.3f32
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "8871.8".toArray()
            // SqlReal不支持转换为boolean以及整数
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 908.91f32
            var double1 = 98.9819f32
            // 时间使用SqlReal无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 9998237

            statement.set<Float32>(0, char1)
            statement.set<Float32>(1, varchar1)
            statement.set<Float32>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float32>(10, double1)
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
            var char1Got = 0.0f32
            var varchar1Got = 0.0f32
            var clob1Got = 0.0f32
            var blob1Got = 0.0f32
            var boolean1Got = 0.0f32
            var tinyint1Got = 0.0f32
            var smallint1Got = 0.0f32
            var integer1Got = 0.0f32
            var bigint1Got = 0.0f32
            var real1Got = 0.0f32
            var double1Got = 0.0f32
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Float32>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Float32>(0)
                varchar1Got = queryResult.get<Float32>(1)
                clob1Got = queryResult.get<Float32>(2)
                blob1Got = queryResult.get<Float32>(3)
                boolean1Got = queryResult.get<Float32>(4)
                tinyint1Got = queryResult.get<Float32>(5)
                smallint1Got = queryResult.get<Float32>(6)
                integer1Got = queryResult.get<Float32>(7)
                bigint1Got = queryResult.get<Float32>(8)
                real1Got = queryResult.get<Float32>(9)
                double1Got = queryResult.get<Float32>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(char1Got), Float64.parse(char1.toString().trimAscii())))
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(varchar1Got), Float64.parse(varchar1.toString())))
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(clob1Got), Float64.parse(clob1.toString().trimAscii())))
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(doubleEquals(Float64(blob1Got), Float64.parse(bytesToString(blob1))))
                println("${boolean1Got != 0.0} == ${boolean1}");
                @Assert((boolean1Got != 0.0) == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Float32(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(doubleEquals(Float64(smallint1Got), Float64(smallint1)))
                println("${Int32(integer1Got).toString()} == ${integer1}");
                @Assert(doubleEquals(Float64(integer1Got), Float64(integer1)))
                println("${Int64(bigint1Got).toString()} == ${bigint1}");
                @Assert(doubleEquals(Float64(bigint1Got), Float64(bigint1)))
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Float32>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableReal(): Unit {
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
            var char1 = 999.996f32
            var varchar1 = -999.996f32
            var clob1 = 89112.3f32
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "8871.8".toArray()
            // SqlNullableReal不支持转换为boolean以及整数
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 908.91f32
            var double1 = 98.9819f32
            // 时间使用SqlNullableReal无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 9998237

            statement.set<Float32>(0, char1)
            statement.set<Float32>(1, varchar1)
            statement.set<Float32>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float32>(10, double1)
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
            var char1Got = 0.0f32
            var varchar1Got = 0.0f32
            var clob1Got = 0.0f32
            var blob1Got = 0.0f32
            var boolean1Got = 0.0f32
            var tinyint1Got = 0.0f32
            var smallint1Got = 0.0f32
            var integer1Got = 0.0f32
            var bigint1Got = 0.0f32
            var real1Got = 0.0f32
            var double1Got = 0.0f32
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Float32>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Float32>(0)
                varchar1Got = queryResult.get<Float32>(1)
                clob1Got = queryResult.get<Float32>(2)
                blob1Got = queryResult.get<Float32>(3)
                boolean1Got = queryResult.get<Float32>(4)
                tinyint1Got = queryResult.get<Float32>(5)
                smallint1Got = queryResult.get<Float32>(6)
                integer1Got = queryResult.get<Float32>(7)
                bigint1Got = queryResult.get<Float32>(8)
                real1Got = queryResult.get<Float32>(9)
                double1Got = queryResult.get<Float32>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(doubleEquals(Float64(getFloat32(char1Got)), Float64.parse(getString(char1).trimAscii())))
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(doubleEquals(Float64(getFloat32(varchar1Got)), Float64.parse(getString(varchar1))))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(doubleEquals(Float64(getFloat32(clob1Got)), Float64.parse(getString(clob1))))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(doubleEquals(Float64(getFloat32(blob1Got)), Float64.parse(bytesToString(blob1))))
                println("${getFloat32(boolean1Got) != 0.0} == ${boolean1}");
                @Assert((getFloat32(boolean1Got) != 0.0) == boolean1)
                println("${getString(tinyint1Got)} == ${tinyint1}");
                @Assert(getFloat32(tinyint1Got) == Float32(tinyint1))
                println("${getString(smallint1Got)} == ${smallint1}");
                @Assert(doubleEquals(Float64(getFloat32(smallint1Got)), Float64(smallint1)))
                println("${getString(integer1Got)} == ${integer1}");
                @Assert(doubleEquals(Float64(getFloat32(integer1Got)), Float64(integer1)))
                println("${getString(bigint1Got)} == ${bigint1}");
                @Assert(doubleEquals(Float64(getFloat32(bigint1Got)), Float64(bigint1)))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(doubleEquals(Float64(getFloat32(real1Got)), Float64(getFloat32(real1))))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(doubleEquals(Float64(getFloat32(double1Got)), Float64(getFloat32(double1))))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Float32>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlDouble(): Unit {
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
            var char1 = 999999999.999999f64
            var varchar1 = -999999999.999999f64
            var clob1 = 8918928791212.3f64
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "8878918791.84".toArray()
            // SqlDouble不支持转换为boolean以及整数
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f64
            var double1 = 9571781818.9819f64
            // 时间使用SqlDouble无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 9998237

            statement.set<Float64>(0, char1)
            statement.set<Float64>(1, varchar1)
            statement.set<Float64>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float64>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = 0.0f64
            var varchar1Got = 0.0f64
            var clob1Got = 0.0f64
            var blob1Got = 0.0f64
            var boolean1Got = 0.0f64
            var tinyint1Got = 0.0f64
            var smallint1Got = 0.0f64
            var integer1Got = 0.0f64
            var bigint1Got = 0.0f64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Float64>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Float64>(0)
                varchar1Got = queryResult.get<Float64>(1)
                clob1Got = queryResult.get<Float64>(2)
                blob1Got = queryResult.get<Float64>(3)
                boolean1Got = queryResult.get<Float64>(4)
                tinyint1Got = queryResult.get<Float64>(5)
                smallint1Got = queryResult.get<Float64>(6)
                integer1Got = queryResult.get<Float64>(7)
                bigint1Got = queryResult.get<Float64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(char1Got), Float64.parse(char1.toString().trimAscii())))
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(varchar1Got), Float64.parse(varchar1.toString())))
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(doubleEquals(Float64(clob1Got), Float64.parse(clob1.toString().trimAscii())))
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(doubleEquals(Float64(blob1Got), Float64.parse(bytesToString(blob1))))
                println("${boolean1Got != 0.0} == ${boolean1}");
                @Assert((boolean1Got != 0.0) == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Float64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(doubleEquals(Float64(smallint1Got), Float64(smallint1)))
                println("${Int32(integer1Got).toString()} == ${integer1}");
                @Assert(doubleEquals(Float64(integer1Got), Float64(integer1)))
                println("${Int64(bigint1Got).toString()} == ${bigint1}");
                @Assert(doubleEquals(Float64(bigint1Got), Float64(bigint1)))
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Float64>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableDouble(): Unit {
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
            var char1 = 999999999.999996f64
            var varchar1 = -999999999.999996f64
            var clob1 = 8918928791212.3f64
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "8878918791.84".toArray()
            // SqlNullableDouble不支持转换为boolean以及整数
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f64
            var double1 = 9571781818.9819f64
            // 时间使用SqlNullableDouble无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 9998237

            statement.set<Float64>(0, char1)
            statement.set<Float64>(1, varchar1)
            statement.set<Float64>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float64>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = 0.0f64
            var varchar1Got = 0.0f64
            var clob1Got = 0.0f64
            var blob1Got = 0.0f64
            var boolean1Got = 0.0f64
            var tinyint1Got = 0.0f64
            var smallint1Got = 0.0f64
            var integer1Got = 0.0f64
            var bigint1Got = 0.0f64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Float64>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Float64>(0)
                varchar1Got = queryResult.get<Float64>(1)
                clob1Got = queryResult.get<Float64>(2)
                blob1Got = queryResult.get<Float64>(3)
                boolean1Got = queryResult.get<Float64>(4)
                tinyint1Got = queryResult.get<Float64>(5)
                smallint1Got = queryResult.get<Float64>(6)
                integer1Got = queryResult.get<Float64>(7)
                bigint1Got = queryResult.get<Float64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(doubleEquals(getFloat64(char1Got), getFloat64(char1)))
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(doubleEquals(getFloat64(varchar1Got), getFloat64(varchar1)))
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(doubleEquals(getFloat64(clob1Got), getFloat64(clob1)))
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(doubleEquals(getFloat64(blob1Got), Float64.parse(bytesToString(blob1))))
                println("${boolean1Got != 0.0} == ${boolean1}");
                @Assert((boolean1Got != 0.0) == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Float64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(doubleEquals(getFloat64(smallint1Got), Float64(smallint1)))
                println("${getString(integer1Got)} == ${integer1}");
                @Assert(doubleEquals(getFloat64(integer1Got), Float64(integer1)))
                println("${getString(bigint1Got)} == ${bigint1}");
                @Assert(doubleEquals(getFloat64(bigint1Got), Float64(bigint1)))
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(getFloat64(real1Got), getFloat64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(getFloat64(double1Got), getFloat64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Float64>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlDate(): Unit {
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
            var char1 = DateTime.parse("2024-01-08", "yyyy-MM-dd")
            var varchar1 = DateTime.parse("2024-02-09", "yyyy-MM-dd")
            var clob1 = DateTime.parse("2024-03-19", "yyyy-MM-dd")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "2023-04-21".toArray()
            // SqlDate与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            var date1tmp = DateTime.parse("2019-11-12", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            // SqlDate与SqlInterval转换无意义
            var interval1 = Duration.second * 18237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.year == char1.year)
                @Assert(char1Got.month == char1.month)
                @Assert(char1Got.dayOfMonth == char1.dayOfMonth)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.year == varchar1.year)
                @Assert(varchar1Got.month == varchar1.month)
                @Assert(varchar1Got.dayOfMonth == varchar1.dayOfMonth)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.year == clob1.year)
                @Assert(clob1Got.month == clob1.month)
                @Assert(clob1Got.dayOfMonth == clob1.dayOfMonth)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = DateTime.parse(bytesToString(blob1), "yyyy-MM-dd")
                @Assert(blob1Got.year == datetimetmp.year)
                @Assert(blob1Got.month == datetimetmp.month)
                @Assert(blob1Got.dayOfMonth == datetimetmp.dayOfMonth)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableDate(): Unit {
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
            var char1 = DateTime.parse("2023-11-08", "yyyy-MM-dd")
            var varchar1 = DateTime.parse("2021-12-09", "yyyy-MM-dd")
            var clob1 = DateTime.parse("2024-03-19", "yyyy-MM-dd")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "2023-04-21".toArray()
            // SqlNullableDate与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            var date1tmp = DateTime.parse("2019-11-12", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            // SqlNullableDate与SqlInterval转换无意义
            var interval1 = Duration.second * 18237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(getDateTime(char1Got).year == getDateTime(char1).year)
                @Assert(getDateTime(char1Got).month == getDateTime(char1).month)
                @Assert(getDateTime(char1Got).dayOfMonth == getDateTime(char1).dayOfMonth)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(getDateTime(varchar1Got).year == getDateTime(varchar1).year)
                @Assert(getDateTime(varchar1Got).month == getDateTime(varchar1).month)
                @Assert(getDateTime(varchar1Got).dayOfMonth == getDateTime(varchar1).dayOfMonth)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(getDateTime(clob1Got).year == getDateTime(clob1).year)
                @Assert(getDateTime(clob1Got).month == getDateTime(clob1).month)
                @Assert(getDateTime(clob1Got).dayOfMonth == getDateTime(clob1).dayOfMonth)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = DateTime.parse(bytesToString(blob1), "yyyy-MM-dd")
                @Assert(getDateTime(blob1Got).year == datetimetmp.year)
                @Assert(getDateTime(blob1Got).month == datetimetmp.month)
                @Assert(getDateTime(blob1Got).dayOfMonth == datetimetmp.dayOfMonth)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(getDateTime(date1Got).year == getDateTime(date1).year)
                @Assert(getDateTime(date1Got).month == getDateTime(date1).month)
                @Assert(getDateTime(date1Got).dayOfMonth == getDateTime(date1).dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                @Assert(getDateTime(time1Got).hour == getDateTime(time1).hour)
                @Assert(getDateTime(time1Got).minute == getDateTime(time1).minute)
                @Assert(getDateTime(time1Got).second == getDateTime(time1).second)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(getDateTime(timetz1Got).hour == getDateTime(timetz1).hour)
                @Assert(getDateTime(timetz1Got).minute == getDateTime(timetz1).minute)
                @Assert(getDateTime(timetz1Got).second == getDateTime(timetz1).second)
                @Assert(getDateTime(timetz1Got).zoneId == getDateTime(timetz1).zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                //@Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlTime(): Unit {
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
            var char1 = DateTime.parse("2020-12-02 09:18:23", "yyyy-MM-dd HH:mm:ss")
            var varchar1 = DateTime.parse("2020-12-02 19:28:33.312", "yyyy-MM-dd HH:mm:ss.S")
            var clob1 = DateTime.parse("2020-12-02 21:58:53.651712", "yyyy-MM-dd HH:mm:ss.SS")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "22:31:41.31242".toArray()
            // SqlTime与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlDate和SqlTime转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456", "yyyy-MM-dd HH:mm:ss SS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlTime与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.hour == char1.hour)
                @Assert(char1Got.minute == char1.minute)
                @Assert(char1Got.second == char1.second)
                @Assert(char1Got.nanosecond == char1.nanosecond)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.hour == varchar1.hour)
                @Assert(varchar1Got.minute == varchar1.minute)
                @Assert(varchar1Got.second == varchar1.second)
                @Assert(varchar1Got.nanosecond == varchar1.nanosecond)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.hour == clob1.hour)
                @Assert(clob1Got.minute == clob1.minute)
                @Assert(clob1Got.second == clob1.second)
                @Assert(clob1Got.nanosecond == clob1.nanosecond)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(blob1Got.hour == datetimetmp.hour)
                @Assert(blob1Got.minute == datetimetmp.minute)
                @Assert(blob1Got.second == datetimetmp.second)
                @Assert(blob1Got.nanosecond == datetimetmp.nanosecond)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${time1Got.nanosecond} == ${time1.nanosecond}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                @Assert(time1Got.nanosecond == time1.nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.nanosecond == timetz1.nanosecond)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${timestamp1Got.nanosecond} == ${timestamp1.nanosecond}");
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                @Assert(timestamp1Got.nanosecond == timestamp1.nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableTime(): Unit {
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
            var char1 = DateTime.parse("2010-12-02 09:18:23", "yyyy-MM-dd HH:mm:ss")
            var varchar1 = DateTime.parse("2011-11-12 19:28:33.312", "yyyy-MM-dd HH:mm:ss.S")
            var clob1 = DateTime.parse("2020-12-02 21:58:53.651712", "yyyy-MM-dd HH:mm:ss.SS")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "22:31:41.31242".toArray()
            // SqlNullableTime与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlDate和SqlNullableTime转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456", "yyyy-MM-dd HH:mm:ss SS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlNullableTime与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(getDateTime(char1Got).hour == getDateTime(char1).hour)
                @Assert(getDateTime(char1Got).minute == getDateTime(char1).minute)
                @Assert(getDateTime(char1Got).second == getDateTime(char1).second)
                @Assert(getDateTime(char1Got).nanosecond == getDateTime(char1).nanosecond)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(getDateTime(varchar1Got).hour == getDateTime(varchar1).hour)
                @Assert(getDateTime(varchar1Got).minute == getDateTime(varchar1).minute)
                @Assert(getDateTime(varchar1Got).second == getDateTime(varchar1).second)
                @Assert(getDateTime(varchar1Got).nanosecond == getDateTime(varchar1).nanosecond)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(getDateTime(clob1Got).hour == getDateTime(clob1).hour)
                @Assert(getDateTime(clob1Got).minute == getDateTime(clob1).minute)
                @Assert(getDateTime(clob1Got).second == getDateTime(clob1).second)
                @Assert(getDateTime(clob1Got).nanosecond == getDateTime(clob1).nanosecond)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(getDateTime(blob1Got).hour == datetimetmp.hour)
                @Assert(getDateTime(blob1Got).minute == datetimetmp.minute)
                @Assert(getDateTime(blob1Got).second == datetimetmp.second)
                @Assert(getDateTime(blob1Got).nanosecond == datetimetmp.nanosecond)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${getDateTime(time1Got).nanosecond} == ${getDateTime(time1).nanosecond}");
                @Assert(getDateTime(time1Got).hour == getDateTime(time1).hour)
                @Assert(getDateTime(time1Got).minute == getDateTime(time1).minute)
                @Assert(getDateTime(time1Got).second == getDateTime(time1).second)
                @Assert(getDateTime(time1Got).nanosecond == getDateTime(time1).nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(getDateTime(timetz1Got).hour == getDateTime(timetz1).hour)
                @Assert(getDateTime(timetz1Got).minute == getDateTime(timetz1).minute)
                @Assert(getDateTime(timetz1Got).second == getDateTime(timetz1).second)
                @Assert(getDateTime(timetz1Got).nanosecond == getDateTime(timetz1).nanosecond)
                @Assert(getDateTime(timetz1Got).zoneId == getDateTime(timetz1).zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${getDateTime(timestamp1Got).nanosecond} == ${getDateTime(timestamp1).nanosecond}");
                //@Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                @Assert(getDateTime(timestamp1Got).nanosecond == getDateTime(timestamp1).nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlTimeTz(): Unit {
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
            var char1 = DateTime.parse("2020-12-02 09:18:23 +01", "yyyy-MM-dd HH:mm:ss O")
            var varchar1 = DateTime.parse("2023-02-02 19:28:33.312 +02", "yyyy-MM-dd HH:mm:ss.S O")
            var clob1 = DateTime.parse("2020-12-02 21:58:53.651712 +03", "yyyy-MM-dd HH:mm:ss.SS O")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "22:31:41.31242+04".toArray()
            // SqlTimeTz与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlDate和SqlTimeTz转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlTimeTz与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.hour == char1.hour)
                @Assert(char1Got.minute == char1.minute)
                @Assert(char1Got.second == char1.second)
                @Assert(char1Got.nanosecond == char1.nanosecond)
                @Assert(char1Got.zoneId == char1.zoneId)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.hour == varchar1.hour)
                @Assert(varchar1Got.minute == varchar1.minute)
                @Assert(varchar1Got.second == varchar1.second)
                @Assert(varchar1Got.nanosecond == varchar1.nanosecond)
                @Assert(varchar1Got.zoneId == varchar1.zoneId)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.hour == clob1.hour)
                @Assert(clob1Got.minute == clob1.minute)
                @Assert(clob1Got.second == clob1.second)
                @Assert(clob1Got.nanosecond == clob1.nanosecond)
                @Assert(clob1Got.zoneId == clob1.zoneId)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(blob1Got.hour == datetimetmp.hour)
                @Assert(blob1Got.minute == datetimetmp.minute)
                @Assert(blob1Got.second == datetimetmp.second)
                @Assert(blob1Got.nanosecond == datetimetmp.nanosecond)
                @Assert(blob1Got.zoneId == datetimetmp.zoneId)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${time1Got.nanosecond} == ${time1.nanosecond}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                @Assert(time1Got.nanosecond == time1.nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.nanosecond == timetz1.nanosecond)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${timestamp1Got.nanosecond} == ${timestamp1.nanosecond}");
                //@Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                @Assert(timestamp1Got.nanosecond == timestamp1.nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableTimeTz(): Unit {
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
            var char1 = DateTime.parse("2020-12-02 09:18:23 +01", "yyyy-MM-dd HH:mm:ss O")
            var varchar1 = DateTime.parse("2023-02-02 19:28:33.312 +02", "yyyy-MM-dd HH:mm:ss.S O")
            var clob1 = DateTime.parse("2020-12-02 21:58:53.651712 +03", "yyyy-MM-dd HH:mm:ss.SS O")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "22:31:41.31242+04".toArray()
            // SqlNullableTimeTz与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlDate和SqlNullableTimeTz转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlNullableTimeTz与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(getDateTime(char1Got).hour == getDateTime(char1).hour)
                @Assert(getDateTime(char1Got).minute == getDateTime(char1).minute)
                @Assert(getDateTime(char1Got).second == getDateTime(char1).second)
                @Assert(getDateTime(char1Got).nanosecond == getDateTime(char1).nanosecond)
                @Assert(getDateTime(char1Got).zoneId == getDateTime(char1).zoneId)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(getDateTime(varchar1Got).hour == getDateTime(varchar1).hour)
                @Assert(getDateTime(varchar1Got).minute == getDateTime(varchar1).minute)
                @Assert(getDateTime(varchar1Got).second == getDateTime(varchar1).second)
                @Assert(getDateTime(varchar1Got).nanosecond == getDateTime(varchar1).nanosecond)
                @Assert(getDateTime(varchar1Got).zoneId == getDateTime(varchar1).zoneId)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(getDateTime(clob1Got).hour == getDateTime(clob1).hour)
                @Assert(getDateTime(clob1Got).minute == getDateTime(clob1).minute)
                @Assert(getDateTime(clob1Got).second == getDateTime(clob1).second)
                @Assert(getDateTime(clob1Got).nanosecond == getDateTime(clob1).nanosecond)
                @Assert(getDateTime(clob1Got).zoneId == getDateTime(clob1).zoneId)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(getDateTime(blob1Got).hour == datetimetmp.hour)
                @Assert(getDateTime(blob1Got).minute == datetimetmp.minute)
                @Assert(getDateTime(blob1Got).second == datetimetmp.second)
                @Assert(getDateTime(blob1Got).nanosecond == datetimetmp.nanosecond)
                @Assert(getDateTime(blob1Got).zoneId == datetimetmp.zoneId)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(getDateTime(date1Got).year == getDateTime(date1).year)
                @Assert(getDateTime(date1Got).month == getDateTime(date1).month)
                @Assert(getDateTime(date1Got).dayOfMonth == getDateTime(date1).dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${getDateTime(time1Got).nanosecond} == ${getDateTime(time1).nanosecond}");
                @Assert(getDateTime(time1Got).hour == getDateTime(time1).hour)
                @Assert(getDateTime(time1Got).minute == getDateTime(time1).minute)
                @Assert(getDateTime(time1Got).second == getDateTime(time1).second)
                @Assert(getDateTime(time1Got).nanosecond == getDateTime(time1).nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(getDateTime(timetz1Got).hour == getDateTime(timetz1).hour)
                @Assert(getDateTime(timetz1Got).minute == getDateTime(timetz1).minute)
                @Assert(getDateTime(timetz1Got).second == getDateTime(timetz1).second)
                @Assert(getDateTime(timetz1Got).nanosecond == getDateTime(timetz1).nanosecond)
                @Assert(getDateTime(timetz1Got).zoneId == getDateTime(timetz1).zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${getDateTime(timestamp1Got).nanosecond} == ${getDateTime(timestamp1).nanosecond}");
                //@Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                @Assert(getDateTime(timestamp1Got).nanosecond == getDateTime(timestamp1).nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlTimestamp(): Unit {
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
            var char1 = DateTime.parse("2024-01-02 19:18:23 +01", "yyyy-MM-dd HH:mm:ss O")
            var varchar1 = DateTime.parse("2024-04-04 19:28:33.312 +02", "yyyy-MM-dd HH:mm:ss.S O")
            var clob1 = DateTime.parse("2023-12-02 21:58:53.651712 +03", "yyyy-MM-dd HH:mm:ss.SS O")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "2024-08-09 22:31:41.31242+04".toArray()
            // SqlTimestamp与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlTimestamp与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.year == char1.year)
                @Assert(char1Got.month == char1.month)
                @Assert(char1Got.dayOfMonth == char1.dayOfMonth)
                @Assert(char1Got.hour == char1.hour)
                @Assert(char1Got.minute == char1.minute)
                @Assert(char1Got.second == char1.second)
                @Assert(char1Got.nanosecond == char1.nanosecond)
                @Assert(char1Got.zoneId == char1.zoneId)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.year == varchar1.year)
                @Assert(varchar1Got.month == varchar1.month)
                @Assert(varchar1Got.dayOfMonth == varchar1.dayOfMonth)
                @Assert(varchar1Got.hour == varchar1.hour)
                @Assert(varchar1Got.minute == varchar1.minute)
                @Assert(varchar1Got.second == varchar1.second)
                @Assert(varchar1Got.nanosecond == varchar1.nanosecond)
                @Assert(varchar1Got.zoneId == varchar1.zoneId)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.year == clob1.year)
                @Assert(clob1Got.month == clob1.month)
                @Assert(clob1Got.dayOfMonth == clob1.dayOfMonth)
                @Assert(clob1Got.hour == clob1.hour)
                @Assert(clob1Got.minute == clob1.minute)
                @Assert(clob1Got.second == clob1.second)
                @Assert(clob1Got.nanosecond == clob1.nanosecond)
                @Assert(clob1Got.zoneId == clob1.zoneId)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(blob1Got.year == datetimetmp.year)
                @Assert(blob1Got.month == datetimetmp.month)
                @Assert(blob1Got.dayOfMonth == datetimetmp.dayOfMonth)
                @Assert(blob1Got.hour == datetimetmp.hour)
                @Assert(blob1Got.minute == datetimetmp.minute)
                @Assert(blob1Got.second == datetimetmp.second)
                @Assert(blob1Got.nanosecond == datetimetmp.nanosecond)
                @Assert(blob1Got.zoneId == datetimetmp.zoneId)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${time1Got.nanosecond} == ${time1.nanosecond}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                @Assert(time1Got.nanosecond == time1.nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.nanosecond == timetz1.nanosecond)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${timestamp1Got.nanosecond} == ${timestamp1.nanosecond}");
                @Assert(timestamp1Got.toString() == timestamp1.toString())
                @Assert(timestamp1Got.nanosecond == timestamp1.nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableTimestamp(): Unit {
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
            var char1 = DateTime.parse("2012-10-01 09:18:23 +01", "yyyy-MM-dd HH:mm:ss O")
            var varchar1 = DateTime.parse("2013-01-12 19:28:33.312 +02", "yyyy-MM-dd HH:mm:ss.S O")
            
            var clob1 = 
                DateTime.parse("2020-11-12 21:58:53.651712 +03", "yyyy-MM-dd HH:mm:ss.SS O")
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "2020-11-15 21:11:41.31242+04".toArray()
            // SqlNullableTimestamp与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            // SqlNullableTimestamp与SqlInterval转换无意义
            var interval1 = Duration.second * 28237

            statement.set<DateTime>(0, char1)
            statement.set<DateTime>(1, varchar1)
            statement.set<DateTime>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = DateTime.now()
            var varchar1Got = DateTime.now()
            var clob1Got = DateTime.now()
            var blob1Got = DateTime.now()
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<DateTime>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<DateTime>(0)
                varchar1Got = queryResult.get<DateTime>(1)
                clob1Got = queryResult.get<DateTime>(2)
                blob1Got = queryResult.get<DateTime>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(getDateTime(char1Got).year == getDateTime(char1).year)
                @Assert(getDateTime(char1Got).month == getDateTime(char1).month)
                @Assert(getDateTime(char1Got).dayOfMonth == getDateTime(char1).dayOfMonth)
                @Assert(getDateTime(char1Got).hour == getDateTime(char1).hour)
                @Assert(getDateTime(char1Got).minute == getDateTime(char1).minute)
                @Assert(getDateTime(char1Got).second == getDateTime(char1).second)
                @Assert(getDateTime(char1Got).nanosecond == getDateTime(char1).nanosecond)
                @Assert(getDateTime(char1Got).zoneId == getDateTime(char1).zoneId)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(getDateTime(varchar1Got).year == getDateTime(varchar1).year)
                @Assert(getDateTime(varchar1Got).month == getDateTime(varchar1).month)
                @Assert(getDateTime(varchar1Got).dayOfMonth == getDateTime(varchar1).dayOfMonth)
                @Assert(getDateTime(varchar1Got).hour == getDateTime(varchar1).hour)
                @Assert(getDateTime(varchar1Got).minute == getDateTime(varchar1).minute)
                @Assert(getDateTime(varchar1Got).second == getDateTime(varchar1).second)
                @Assert(getDateTime(varchar1Got).nanosecond == getDateTime(varchar1).nanosecond)
                @Assert(getDateTime(varchar1Got).zoneId == getDateTime(varchar1).zoneId)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(getDateTime(clob1Got).year == getDateTime(clob1).year)
                @Assert(getDateTime(clob1Got).month == getDateTime(clob1).month)
                @Assert(getDateTime(clob1Got).dayOfMonth == getDateTime(clob1).dayOfMonth)
                @Assert(getDateTime(clob1Got).hour == getDateTime(clob1).hour)
                @Assert(getDateTime(clob1Got).minute == getDateTime(clob1).minute)
                @Assert(getDateTime(clob1Got).second == getDateTime(clob1).second)
                @Assert(getDateTime(clob1Got).nanosecond == getDateTime(clob1).nanosecond)
                @Assert(getDateTime(clob1Got).zoneId == getDateTime(clob1).zoneId)
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                var datetimetmp = bytesToDateTime(blob1)
                @Assert(getDateTime(blob1Got).year == datetimetmp.year)
                @Assert(getDateTime(blob1Got).month == datetimetmp.month)
                @Assert(getDateTime(blob1Got).dayOfMonth == datetimetmp.dayOfMonth)
                @Assert(getDateTime(blob1Got).hour == datetimetmp.hour)
                @Assert(getDateTime(blob1Got).minute == datetimetmp.minute)
                @Assert(getDateTime(blob1Got).second == datetimetmp.second)
                @Assert(getDateTime(blob1Got).nanosecond == datetimetmp.nanosecond)
                @Assert(getDateTime(blob1Got).zoneId == datetimetmp.zoneId)
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(getDateTime(date1Got).year == getDateTime(date1).year)
                @Assert(getDateTime(date1Got).month == getDateTime(date1).month)
                @Assert(getDateTime(date1Got).dayOfMonth == getDateTime(date1).dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${getDateTime(time1Got).nanosecond} == ${getDateTime(time1).nanosecond}");
                @Assert(getDateTime(time1Got).hour == getDateTime(time1).hour)
                @Assert(getDateTime(time1Got).minute == getDateTime(time1).minute)
                @Assert(getDateTime(time1Got).second == getDateTime(time1).second)
                @Assert(getDateTime(time1Got).nanosecond == getDateTime(time1).nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(getDateTime(timetz1Got).hour == getDateTime(timetz1).hour)
                @Assert(getDateTime(timetz1Got).minute == getDateTime(timetz1).minute)
                @Assert(getDateTime(timetz1Got).second == getDateTime(timetz1).second)
                @Assert(getDateTime(timetz1Got).nanosecond == getDateTime(timetz1).nanosecond)
                @Assert(getDateTime(timetz1Got).zoneId == getDateTime(timetz1).zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${getDateTime(timestamp1Got).nanosecond} == ${getDateTime(timestamp1).nanosecond}");
                @Assert(getDateTime(timestamp1Got).toString() == getDateTime(timestamp1).toString())
                @Assert(getDateTime(timestamp1Got).nanosecond == getDateTime(timestamp1).nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)
            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<DateTime>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlInterval(): Unit {
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
            var char1 = Duration.second * 100
            var varchar1 = Duration.minute * 100
            var clob1 = Duration.hour * 100
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "P10-10-10T10:10:10".toArray()
            // SqlInterval与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlInterval与SqlDateTime转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 229237

            statement.set<Duration>(0, char1)
            statement.set<Duration>(1, varchar1)
            statement.set<Duration>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = Duration.second
            var varchar1Got = Duration.second
            var clob1Got = Duration.second
            var blob1Got = Duration.second
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Duration>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Duration>(0)
                varchar1Got = queryResult.get<Duration>(1)
                clob1Got = queryResult.get<Duration>(2)
                blob1Got = queryResult.get<Duration>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got == char1)
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got == varchar1)
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got == clob1)
                println("${blob1Got.toString()} == ${parseDurationStr2(bytesToString(blob1))}");
                @Assert(blob1Got.toString() == parseDurationStr2(bytesToString(blob1)).toString())
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${time1Got.nanosecond} == ${time1.nanosecond}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                @Assert(time1Got.nanosecond == time1.nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.nanosecond == timetz1.nanosecond)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${timestamp1Got.nanosecond} == ${timestamp1.nanosecond}");
                @Assert(timestamp1Got.toString() == timestamp1.toString())
                @Assert(timestamp1Got.nanosecond == timestamp1.nanosecond)
                println("${interval1Got.toString()} == ${interval1}");
                @Assert(interval1Got == interval1)
                count++
            }
            @Assert(count > 0)

            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Duration>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableInterval(): Unit {
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
            var char1 = Duration.second * 10
            var varchar1 = Duration.minute * 10
            var clob1 = Duration.hour * 10
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "P5-5-5T5:5:5".toArray()
            // SqlNullableInterval与boolean及数字转换无意义
            var boolean1 = true
            var tinyint1 = 113i8
            var smallint1 = -21i16
            var integer1 = -19897i32
            var bigint1 = 108917i64
            var real1 = 909.91f32
            var double1 = 9571781818.9819f64
            // SqlNullableInterval与SqlDateTime转换无意义
            var date1tmp = DateTime.parse("2020-12-02", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2018-03-09 10:11:51 126456 +05", "yyyy-MM-dd HH:mm:ss SS O")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223466 +08", "yyyy-MM-dd HH:mm:ss SS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456", "yyyy-MM-dd HH:mm:ss SS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 99837

            statement.set<Duration>(0, char1)
            statement.set<Duration>(1, varchar1)
            statement.set<Duration>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Float32>(9, real1)
            statement.set<Float64>(10, double1)
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
            var char1Got = Duration.second
            var varchar1Got = Duration.second
            var clob1Got = Duration.second
            var blob1Got = Duration.second
            var boolean1Got = true
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0.0f64
            var double1Got = 0.0f64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Duration>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Duration>(0)
                varchar1Got = queryResult.get<Duration>(1)
                clob1Got = queryResult.get<Duration>(2)
                blob1Got = queryResult.get<Duration>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Float64>(9)
                double1Got = queryResult.get<Float64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println(
                    "${getDuration(char1Got).toString().trimAscii()} == ${getDuration(char1).toString().trimAscii()}"
                );
                @Assert(getDuration(char1Got) == getDuration(char1))
                println(
                    "${getDuration(varchar1Got).toString()} == ${getDuration(varchar1).toString().trimAscii()}"
                );
                @Assert(getDuration(varchar1Got) == getDuration(varchar1))
                println(
                    "${getDuration(clob1Got).toString()} == ${getDuration(clob1).toString().trimAscii()}");
                @Assert(getDuration(clob1Got) == getDuration(clob1))
                println("${getDuration(blob1Got).toString()} == ${parseDurationStr2(bytesToString(blob1))}");
                @Assert(getDuration(blob1Got).toString() == parseDurationStr2(bytesToString(blob1)).toString())
                println("${boolean1Got} == ${boolean1}");
                @Assert(boolean1Got == boolean1)
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got == Int64(tinyint1))
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got == Int64(smallint1))
                println("${integer1Got} == ${integer1}");
                @Assert(integer1Got == Int64(integer1))
                println("${bigint1Got} == ${bigint1}");
                @Assert(bigint1Got == bigint1)
                println("${real1Got.toString()} == ${real1}");
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${double1Got.toString()} == ${double1}");
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${date1Got.toString()} == ${date1}");
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got.toString()} == ${time1}");
                println("${time1Got.nanosecond} == ${time1.nanosecond}");
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                @Assert(time1Got.nanosecond == time1.nanosecond)
                println("${timetz1Got.toString()} == ${timetz1}");
                @Assert(timetz1Got.hour == timetz1.hour)
                @Assert(timetz1Got.minute == timetz1.minute)
                @Assert(timetz1Got.second == timetz1.second)
                @Assert(timetz1Got.nanosecond == timetz1.nanosecond)
                @Assert(timetz1Got.zoneId == timetz1.zoneId)
                println("${timestamp1Got.toString()} == ${timestamp1}");
                println("${timestamp1Got.nanosecond} == ${timestamp1.nanosecond}");
                @Assert(timestamp1Got.toString() == timestamp1.toString())
                @Assert(timestamp1Got.nanosecond == timestamp1.nanosecond)
                println("${getDuration(interval1Got).toString()} == ${getDuration(interval1)}");
                @Assert(getDuration(interval1Got) == getDuration(interval1))
                count++
            }
            @Assert(count > 0)

            statement.close()

            sql = "delete from typetest1 where varchar1 = ?"
            statement = conn.prepareStatement(sql)

            statement.set<Duration>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

}
