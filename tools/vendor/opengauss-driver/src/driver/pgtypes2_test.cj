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
public class TestTypes2 {
    @TestCase
    func testSqlBlob(): Unit {
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
            let char1value = "blob1"
            var char1bas = ByteBuffer()
            char1bas.write(char1value.toArray())
            var char1 = char1bas
            let varchar1value = "blob2"
            var varchar1bas = ByteBuffer()
            varchar1bas.write(varchar1value.toArray())
            var varchar1 = varchar1bas
            var varchar1querybas = ByteBuffer()
            varchar1querybas.write(varchar1value.toArray())
            var varchar1query = varchar1querybas
            var clob1value = "blob3"
            var clob1bas = ByteBuffer()
            clob1bas.write(clob1value.toArray())
            var clob1 = clob1bas
            var blob1value = "blobgc4"
            var blob1bas = ByteBuffer()
            blob1bas.write(blob1value.toArray())
            var blob1 = blob1bas
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
            statement.set<InputStream>(3, blob1)
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
                println("${tmpcmpstr}==${blob1value}")
                @Assert(tmpcmpstr.trimAscii() == blob1value)
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
    func testSqlNullableBlob(): Unit {
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
            let char1value = "nullableblob1"
            var char1bas = ByteBuffer()
            char1bas.write(char1value.toArray())
            var char1 = char1bas
            let varchar1value = "nullableblob2"
            var varchar1bas = ByteBuffer()
            varchar1bas.write(varchar1value.toArray())
            var varchar1 = varchar1bas
            var varchar1querybas = ByteBuffer()
            varchar1querybas.write(varchar1value.toArray())
            var varchar1query = varchar1querybas
            var clob1value = "nullableblob3"
            var clob1bas = ByteBuffer()
            clob1bas.write(clob1value.toArray())
            var clob1 = clob1bas
            var blob1value = "nullableblobgc4"
            var blob1bas = ByteBuffer()
            blob1bas.write(blob1value.toArray())
            var blob1 = blob1bas
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
            statement.set<InputStream>(3, blob1)
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
                println("${tmpcmpstr}==${blob1value}")
                @Assert(tmpcmpstr.trimAscii() == blob1value)
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
    func testSqlBool(): Unit {
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
            var char1 = true
            var varchar1 = false
            var clob1 = true
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1".toArray()
            var boolean1 = false
            var tinyint1 = true
            var smallint1 = false
            var integer1 = true
            var bigint1 = false
            var real1 = true
            var double1 = true
            // 时间使用SqlBool无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 99237

            statement.set<Bool>(0, char1)
            statement.set<Bool>(1, varchar1)
            statement.set<Bool>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Bool>(5, tinyint1)
            statement.set<Bool>(6, smallint1)
            statement.set<Bool>(7, integer1)
            statement.set<Bool>(8, bigint1)
            statement.set<Bool>(9, real1)
            statement.set<Bool>(10, double1)
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
            var char1Got = false
            var varchar1Got = false
            var clob1Got = false
            var blob1Got = false
            var boolean1Got = false
            var tinyint1Got = false
            var smallint1Got = false
            var integer1Got = false
            var bigint1Got = false
            var real1Got = false
            var double1Got = false
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Bool>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Bool>(0)
                varchar1Got = queryResult.get<Bool>(1)
                clob1Got = queryResult.get<Bool>(2)
                blob1Got = queryResult.get<Bool>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Bool>(5)
                smallint1Got = queryResult.get<Bool>(6)
                integer1Got = queryResult.get<Bool>(7)
                bigint1Got = queryResult.get<Bool>(8)
                real1Got = queryResult.get<Bool>(9)
                double1Got = queryResult.get<Bool>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.toString() == varchar1.toString())
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.toString() == clob1.toString().trimAscii())
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(blob1Got.toString().trimAscii() == (bytesToString(blob1) == "1").toString())
                println("${boolean1Got.toString()[0]} == ${boolean1.toString()[0]}");
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got.toString() == smallint1.toString())
                println("${integer1Got.toString()} == ${integer1}");
                @Assert(integer1Got.toString() == integer1.toString())
                println("${bigint1Got.toString()} == ${bigint1}");
                @Assert(bigint1Got.toString() == bigint1.toString())
                println("${real1Got.toString()} == ${real1}");
                @Assert(real1Got.toString() == real1.toString())
                println("${double1Got.toString()} == ${double1}");
                @Assert(double1Got.toString() == double1.toString())
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

            statement.set<Bool>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableBool(): Unit {
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
            var char1 = false
            var varchar1 = true
            var clob1 = true
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1".toArray()
            var boolean1 = false
            var tinyint1 = true
            var smallint1 = false
            var integer1 = true
            var bigint1 = false
            var real1 = true
            var double1 = true
            // 时间使用SqlNullableBool无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 99237

            statement.set<Bool>(0, char1)
            statement.set<Bool>(1, varchar1)
            statement.set<Bool>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Bool>(4, boolean1)
            statement.set<Bool>(5, tinyint1)
            statement.set<Bool>(6, smallint1)
            statement.set<Bool>(7, integer1)
            statement.set<Bool>(8, bigint1)
            statement.set<Bool>(9, real1)
            statement.set<Bool>(10, double1)
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
            var char1Got = false
            var varchar1Got = false
            var clob1Got = false
            var blob1Got = false
            var boolean1Got = false
            var tinyint1Got = false
            var smallint1Got = false
            var integer1Got = false
            var bigint1Got = false
            var real1Got = false
            var double1Got = false
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Bool>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Bool>(0)
                varchar1Got = queryResult.get<Bool>(1)
                clob1Got = queryResult.get<Bool>(2)
                blob1Got = queryResult.get<Bool>(3)
                boolean1Got = queryResult.get<Bool>(4)
                tinyint1Got = queryResult.get<Bool>(5)
                smallint1Got = queryResult.get<Bool>(6)
                integer1Got = queryResult.get<Bool>(7)
                bigint1Got = queryResult.get<Bool>(8)
                real1Got = queryResult.get<Bool>(9)
                double1Got = queryResult.get<Bool>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(getString(varchar1Got) == getString(varchar1))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(getString(clob1Got) == getString(clob1))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(getString(blob1Got) == (bytesToString(blob1) == "1").toString())
                println("${getString(boolean1Got)[0]} == ${getString(boolean1)[0]}");
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                println("${getString(tinyint1Got)} == ${getString(tinyint1)}");
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                println("${getString(smallint1Got)} == ${getString(smallint1)}");
                @Assert(getString(smallint1Got) == getString(smallint1))
                println("${getString(integer1Got)} == ${getString(integer1)}");
                @Assert(getString(integer1Got) == getString(integer1))
                println("${getString(bigint1Got)} == ${getString(bigint1)}");
                @Assert(getString(bigint1Got) == getString(bigint1))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(getString(real1Got) == getString(real1))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(getString(double1Got) == getString(double1))
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

            statement.set<Bool>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlByte(): Unit {
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
            var char1 = 127i8
            var varchar1 = -128i8
            var clob1 = 0i8
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "11".toArray()
            var boolean1 = 1i8
            var tinyint1 = 126i8
            var smallint1 = -2i8
            var integer1 = -127i8
            var bigint1 = 101i8
            var real1 = 108i8
            var double1 = 118i8
            // 时间使用SqlByte无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int8>(0, char1)
            statement.set<Int8>(1, varchar1)
            statement.set<Int8>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int8>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int8>(6, smallint1)
            statement.set<Int8>(7, integer1)
            statement.set<Int8>(8, bigint1)
            statement.set<Int8>(9, real1)
            statement.set<Int8>(10, double1)
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
            var char1Got = 0i8
            var varchar1Got = 0i8
            var clob1Got = 0i8
            var blob1Got = 0i8
            var boolean1Got = 0i8
            var tinyint1Got = 0i8
            var smallint1Got = 0i8
            var integer1Got = 0i8
            var bigint1Got = 0i8
            var real1Got = 0i8
            var double1Got = 0i8
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int8>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int8>(0)
                varchar1Got = queryResult.get<Int8>(1)
                clob1Got = queryResult.get<Int8>(2)
                blob1Got = queryResult.get<Int8>(3)
                boolean1Got = queryResult.get<Int8>(4)
                tinyint1Got = queryResult.get<Int8>(5)
                smallint1Got = queryResult.get<Int8>(6)
                integer1Got = queryResult.get<Int8>(7)
                bigint1Got = queryResult.get<Int8>(8)
                real1Got = queryResult.get<Int8>(9)
                double1Got = queryResult.get<Int8>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.toString() == varchar1.toString())
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.toString() == clob1.toString().trimAscii())
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                println("${boolean1Got.toString()[0]} == ${boolean1.toString()[0]}");
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got.toString() == smallint1.toString())
                println("${integer1Got.toString()} == ${integer1}");
                @Assert(integer1Got.toString() == integer1.toString())
                println("${bigint1Got.toString()} == ${bigint1}");
                @Assert(bigint1Got.toString() == bigint1.toString())
                println("${real1Got.toString()} == ${real1}");
                @Assert(real1Got.toString() == real1.toString())
                println("${double1Got.toString()} == ${double1}");
                @Assert(double1Got.toString() == double1.toString())
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

            statement.set<Int8>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableByte(): Unit {
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
            var char1 = 126i8
            var varchar1 = -126i8
            var clob1 = 0i8
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "11".toArray()
            var boolean1 = 1i8
            var tinyint1 = 126i8
            var smallint1 = -2i8
            var integer1 = -127i8
            var bigint1 = 101i8
            var real1 = 108i8
            var double1 = 118i8
            // 时间使用SqlNullableByte无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int8>(0, char1)
            statement.set<Int8>(1, varchar1)
            statement.set<Int8>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int8>(4, boolean1)
            statement.set<Int8>(5, tinyint1)
            statement.set<Int8>(6, smallint1)
            statement.set<Int8>(7, integer1)
            statement.set<Int8>(8, bigint1)
            statement.set<Int8>(9, real1)
            statement.set<Int8>(10, double1)
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
            var char1Got = 0i8
            var varchar1Got = 0i8
            var clob1Got = 0i8
            var blob1Got = 0i8
            var boolean1Got = 0i8
            var tinyint1Got = 0i8
            var smallint1Got = 0i8
            var integer1Got = 0i8
            var bigint1Got = 0i8
            var real1Got = 0i8
            var double1Got = 0i8
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int8>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int8>(0)
                varchar1Got = queryResult.get<Int8>(1)
                clob1Got = queryResult.get<Int8>(2)
                blob1Got = queryResult.get<Int8>(3)
                boolean1Got = queryResult.get<Int8>(4)
                tinyint1Got = queryResult.get<Int8>(5)
                smallint1Got = queryResult.get<Int8>(6)
                integer1Got = queryResult.get<Int8>(7)
                bigint1Got = queryResult.get<Int8>(8)
                real1Got = queryResult.get<Int8>(9)
                double1Got = queryResult.get<Int8>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(getString(varchar1Got) == getString(varchar1))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(getString(clob1Got) == getString(clob1))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(getString(blob1Got) == bytesToString(blob1))
                println("${getString(boolean1Got)[0]} == ${getString(boolean1)[0]}");
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                println("${getString(tinyint1Got)} == ${getString(tinyint1)}");
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                println("${getString(smallint1Got)} == ${getString(smallint1)}");
                @Assert(getString(smallint1Got) == getString(smallint1))
                println("${getString(integer1Got)} == ${getString(integer1)}");
                @Assert(getString(integer1Got) == getString(integer1))
                println("${getString(bigint1Got)} == ${getString(bigint1)}");
                @Assert(getString(bigint1Got) == getString(bigint1))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(getString(real1Got) == getString(real1))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(getString(double1Got) == getString(double1))
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

            statement.set<Int8>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlSmallInt(): Unit {
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
            var char1 = 32767i16
            var varchar1 = -32768i16
            var clob1 = 8987i16
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "11879".toArray()
            var boolean1 = 1i16
            var tinyint1 = 126i16
            var smallint1 = -2i16
            var integer1 = -127i16
            var bigint1 = 101i16
            var real1 = 108i16
            var double1 = 118i16
            // 时间使用SqlSmallInt无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int16>(0, char1)
            statement.set<Int16>(1, varchar1)
            statement.set<Int16>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int16>(4, boolean1)
            statement.set<Int16>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int16>(7, integer1)
            statement.set<Int16>(8, bigint1)
            statement.set<Int16>(9, real1)
            statement.set<Int16>(10, double1)
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
            var char1Got = 0i16
            var varchar1Got = 0i16
            var clob1Got = 0i16
            var blob1Got = 0i16
            var boolean1Got = 0i16
            var tinyint1Got = 0i16
            var smallint1Got = 0i16
            var integer1Got = 0i16
            var bigint1Got = 0i16
            var real1Got = 0i16
            var double1Got = 0i16
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int16>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int16>(0)
                varchar1Got = queryResult.get<Int16>(1)
                clob1Got = queryResult.get<Int16>(2)
                blob1Got = queryResult.get<Int16>(3)
                boolean1Got = queryResult.get<Int16>(4)
                tinyint1Got = queryResult.get<Int16>(5)
                smallint1Got = queryResult.get<Int16>(6)
                integer1Got = queryResult.get<Int16>(7)
                bigint1Got = queryResult.get<Int16>(8)
                real1Got = queryResult.get<Int16>(9)
                double1Got = queryResult.get<Int16>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.toString() == varchar1.toString())
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.toString() == clob1.toString().trimAscii())
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                println("${boolean1Got.toString()[0]} == ${boolean1.toString()[0]}");
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got.toString() == smallint1.toString())
                println("${integer1Got.toString()} == ${integer1}");
                @Assert(integer1Got.toString() == integer1.toString())
                println("${bigint1Got.toString()} == ${bigint1}");
                @Assert(bigint1Got.toString() == bigint1.toString())
                println("${real1Got.toString()} == ${real1}");
                @Assert(real1Got.toString() == real1.toString())
                println("${double1Got.toString()} == ${double1}");
                @Assert(double1Got.toString() == double1.toString())
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

            statement.set<Int16>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableSmallInt(): Unit {
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
            var char1 = 32766i16
            var varchar1 = -32766i16
            var clob1 = 8987i16
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "11879".toArray()
            var boolean1 = 1i16
            var tinyint1 = 126i16
            var smallint1 = -2i16
            var integer1 = -127i16
            var bigint1 = 101i16
            var real1 = 108i16
            var double1 = 118i16
            // 时间使用SqlNullableSmallInt无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int16>(0, char1)
            statement.set<Int16>(1, varchar1)
            statement.set<Int16>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int16>(4, boolean1)
            statement.set<Int16>(5, tinyint1)
            statement.set<Int16>(6, smallint1)
            statement.set<Int16>(7, integer1)
            statement.set<Int16>(8, bigint1)
            statement.set<Int16>(9, real1)
            statement.set<Int16>(10, double1)
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
            var char1Got = 0i16
            var varchar1Got = 0i16
            var clob1Got = 0i16
            var blob1Got = 0i16
            var boolean1Got = 0i16
            var tinyint1Got = 0i16
            var smallint1Got = 0i16
            var integer1Got = 0i16
            var bigint1Got = 0i16
            var real1Got = 0i16
            var double1Got = 0i16
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int16>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int16>(0)
                varchar1Got = queryResult.get<Int16>(1)
                clob1Got = queryResult.get<Int16>(2)
                blob1Got = queryResult.get<Int16>(3)
                boolean1Got = queryResult.get<Int16>(4)
                tinyint1Got = queryResult.get<Int16>(5)
                smallint1Got = queryResult.get<Int16>(6)
                integer1Got = queryResult.get<Int16>(7)
                bigint1Got = queryResult.get<Int16>(8)
                real1Got = queryResult.get<Int16>(9)
                double1Got = queryResult.get<Int16>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(getString(varchar1Got) == getString(varchar1))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(getString(clob1Got) == getString(clob1))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(getString(blob1Got) == bytesToString(blob1))
                println("${getString(boolean1Got)[0]} == ${getString(boolean1)[0]}");
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                println("${getString(tinyint1Got)} == ${getString(tinyint1)}");
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                println("${getString(smallint1Got)} == ${getString(smallint1)}");
                @Assert(getString(smallint1Got) == getString(smallint1))
                println("${getString(integer1Got)} == ${getString(integer1)}");
                @Assert(getString(integer1Got) == getString(integer1))
                println("${getString(bigint1Got)} == ${getString(bigint1)}");
                @Assert(getString(bigint1Got) == getString(bigint1))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(getString(real1Got) == getString(real1))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(getString(double1Got) == getString(double1))
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

            statement.set<Int16>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlInteger(): Unit {
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
            var char1 = 2147483647i32
            var varchar1 = -2147483648i32
            var clob1 = 899987i32
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1189779".toArray()
            var boolean1 = 1i32
            var tinyint1 = 125i32
            var smallint1 = -2i32
            var integer1 = -1278981989i32
            var bigint1 = 1089177811i32
            var real1 = 10891i32
            var double1 = 879789891i32
            // 时间使用SqlInteger无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int32>(0, char1)
            statement.set<Int32>(1, varchar1)
            statement.set<Int32>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int32>(4, boolean1)
            statement.set<Int32>(5, tinyint1)
            statement.set<Int32>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int32>(8, bigint1)
            statement.set<Int32>(9, real1)
            statement.set<Int32>(10, double1)
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
            var char1Got = 0i32
            var varchar1Got = 0i32
            var clob1Got = 0i32
            var blob1Got = 0i32
            var boolean1Got = 0i32
            var tinyint1Got = 0i32
            var smallint1Got = 0i32
            var integer1Got = 0i32
            var bigint1Got = 0i32
            var real1Got = 0i32
            var double1Got = 0i32
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int32>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int32>(0)
                varchar1Got = queryResult.get<Int32>(1)
                clob1Got = queryResult.get<Int32>(2)
                blob1Got = queryResult.get<Int32>(3)
                boolean1Got = queryResult.get<Int32>(4)
                tinyint1Got = queryResult.get<Int32>(5)
                smallint1Got = queryResult.get<Int32>(6)
                integer1Got = queryResult.get<Int32>(7)
                bigint1Got = queryResult.get<Int32>(8)
                real1Got = queryResult.get<Int32>(9)
                double1Got = queryResult.get<Int32>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.toString() == varchar1.toString())
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.toString() == clob1.toString().trimAscii())
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                println("${boolean1Got.toString()[0]} == ${boolean1.toString()[0]}");
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got.toString() == smallint1.toString())
                println("${integer1Got.toString()} == ${integer1}");
                @Assert(integer1Got.toString() == integer1.toString())
                println("${bigint1Got.toString()} == ${bigint1}");
                @Assert(bigint1Got.toString() == bigint1.toString())
                println("${real1Got.toString()} == ${real1}");
                @Assert(real1Got.toString() == real1.toString())
                println("${double1Got.toString()} == ${double1}");
                @Assert(double1Got.toString() == double1.toString())
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

            statement.set<Int32>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableInteger(): Unit {
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
            var char1 = 2147483646i32
            var varchar1 = -2147483646i32
            var clob1 = 899987i32
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1189779".toArray()
            var boolean1 = 1i32
            var tinyint1 = 125i32
            var smallint1 = -2i32
            var integer1 = -1278981989i32
            var bigint1 = 1089177811i32
            var real1 = 10891i32
            var double1 = 879789891i32
            // 时间使用SqlNullableInteger无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int32>(0, char1)
            statement.set<Int32>(1, varchar1)
            statement.set<Int32>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int32>(4, boolean1)
            statement.set<Int32>(5, tinyint1)
            statement.set<Int32>(6, smallint1)
            statement.set<Int32>(7, integer1)
            statement.set<Int32>(8, bigint1)
            statement.set<Int32>(9, real1)
            statement.set<Int32>(10, double1)
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
            var char1Got = 0i32
            var varchar1Got = 0i32
            var clob1Got = 0i32
            var blob1Got = 0i32
            var boolean1Got = 0i32
            var tinyint1Got = 0i32
            var smallint1Got = 0i32
            var integer1Got = 0i32
            var bigint1Got = 0i32
            var real1Got = 0i32
            var double1Got = 0i32
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int32>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int32>(0)
                varchar1Got = queryResult.get<Int32>(1)
                clob1Got = queryResult.get<Int32>(2)
                blob1Got = queryResult.get<Int32>(3)
                boolean1Got = queryResult.get<Int32>(4)
                tinyint1Got = queryResult.get<Int32>(5)
                smallint1Got = queryResult.get<Int32>(6)
                integer1Got = queryResult.get<Int32>(7)
                bigint1Got = queryResult.get<Int32>(8)
                real1Got = queryResult.get<Int32>(9)
                double1Got = queryResult.get<Int32>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(getString(varchar1Got) == getString(varchar1))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(getString(clob1Got) == getString(clob1))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(getString(blob1Got) == bytesToString(blob1))
                println("${getString(boolean1Got)[0]} == ${getString(boolean1)[0]}");
                @Assert(getString(boolean1Got)[0] == getString(boolean1)[0])
                println("${getString(tinyint1Got)} == ${getString(tinyint1)}");
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                println("${getString(smallint1Got)} == ${getString(smallint1)}");
                @Assert(getString(smallint1Got) == getString(smallint1))
                println("${getString(integer1Got)} == ${getString(integer1)}");
                @Assert(getString(integer1Got) == getString(integer1))
                println("${getString(bigint1Got)} == ${getString(bigint1)}");
                @Assert(getString(bigint1Got) == getString(bigint1))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(getString(real1Got) == getString(real1))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(getString(double1Got) == getString(double1))
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

            statement.set<Int32>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlBigInt(): Unit {
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
            var char1 = 9223372036854775807i64
            var varchar1 = -9223372036854775808i64
            var clob1 = 89998711135i64
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1189909889779".toArray()
            var boolean1 = 1i64
            var tinyint1 = 123i64
            var smallint1 = -21i64
            var integer1 = -1988979i64
            var bigint1 = 1089178977811i64
            var real1 = 90891i64
            var double1 = 98981987781891i64
            // 时间使用SqlBigInt无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int64>(0, char1)
            statement.set<Int64>(1, varchar1)
            statement.set<Int64>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int64>(4, boolean1)
            statement.set<Int64>(5, tinyint1)
            statement.set<Int64>(6, smallint1)
            statement.set<Int64>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Int64>(9, real1)
            statement.set<Int64>(10, double1)
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
            var char1Got = 0i64
            var varchar1Got = 0i64
            var clob1Got = 0i64
            var blob1Got = 0i64
            var boolean1Got = 0i64
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0i64
            var double1Got = 0i64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int64>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int64>(0)
                varchar1Got = queryResult.get<Int64>(1)
                clob1Got = queryResult.get<Int64>(2)
                blob1Got = queryResult.get<Int64>(3)
                boolean1Got = queryResult.get<Int64>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Int64>(9)
                double1Got = queryResult.get<Int64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
                @Assert(char1Got.toString().trimAscii() == char1.toString().trimAscii())
                println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
                @Assert(varchar1Got.toString() == varchar1.toString())
                println("${clob1Got.toString()} == ${clob1.toString().trimAscii()}");
                @Assert(clob1Got.toString() == clob1.toString().trimAscii())
                println("${blob1Got.toString().trimAscii()} == ${bytesToString(blob1)}");
                @Assert(blob1Got.toString().trimAscii() == bytesToString(blob1))
                println("${boolean1Got.toString()[0]} == ${boolean1.toString()[0]}");
                @Assert(boolean1Got.toString()[0] == boolean1.toString()[0])
                println("${tinyint1Got.toString()} == ${tinyint1}");
                @Assert(tinyint1Got.toString() == tinyint1.toString())
                println("${smallint1Got.toString()} == ${smallint1}");
                @Assert(smallint1Got.toString() == smallint1.toString())
                println("${integer1Got.toString()} == ${integer1}");
                @Assert(integer1Got.toString() == integer1.toString())
                println("${bigint1Got.toString()} == ${bigint1}");
                @Assert(bigint1Got.toString() == bigint1.toString())
                println("${real1Got.toString()} == ${real1}");
                @Assert(real1Got.toString() == real1.toString())
                println("${double1Got.toString()} == ${double1}");
                @Assert(double1Got.toString() == double1.toString())
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

            statement.set<Int64>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    @TestCase
    func testSqlNullableBigInt(): Unit {
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
            var char1 = 9223372036854775806i64
            var varchar1 = -9223372036854775806i64
            var clob1 = 89998711135i64
            // blob类型目前还需要使用binary类型，要不然会有问题
            var blob1 = "1189909889779".toArray()
            var boolean1 = 1i64
            var tinyint1 = 123i64
            var smallint1 = -21i64
            var integer1 = -1988979i64
            var bigint1 = 1089178977811i64
            var real1 = 90891i64
            var double1 = 98981987781891i64
            // 时间使用SqlNullableBigInt无意义，因此不测试
            var date1tmp = DateTime.parse("2021-01-01", "yyyy-MM-dd")
            var date1 = date1tmp
            var time1tmp = DateTime.parse("2021-01-01 20:01:01 123456389", "yyyy-MM-dd HH:mm:ss SSS")
            var time1 = time1tmp
            var time1tztmp = DateTime.parse("2021-01-01 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
            var timetz1 = time1tztmp
            var timestamp1tmp = DateTime.parse("2020-01-05 01:10:11 323456389", "yyyy-MM-dd HH:mm:ss SSS")
            var timestamp1 = timestamp1tmp
            var interval1 = Duration.second * 999237

            statement.set<Int64>(0, char1)
            statement.set<Int64>(1, varchar1)
            statement.set<Int64>(2, clob1)
            statement.set<Array<Byte>>(3, blob1)
            statement.set<Int64>(4, boolean1)
            statement.set<Int64>(5, tinyint1)
            statement.set<Int64>(6, smallint1)
            statement.set<Int64>(7, integer1)
            statement.set<Int64>(8, bigint1)
            statement.set<Int64>(9, real1)
            statement.set<Int64>(10, double1)
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
            var char1Got = 0i64
            var varchar1Got = 0i64
            var clob1Got = 0i64
            var blob1Got = 0i64
            var boolean1Got = 0i64
            var tinyint1Got = 0i64
            var smallint1Got = 0i64
            var integer1Got = 0i64
            var bigint1Got = 0i64
            var real1Got = 0i64
            var double1Got = 0i64
            var date1Got = DateTime.now()
            var time1Got = DateTime.now()
            var timetz1Got = DateTime.now()
            var timestamp1Got = DateTime.now()
            var interval1Got = Duration.second

            statement.set<Int64>(0, varchar1)
            let queryResult = statement.query()
            var count = 0
            while (queryResult.next()) {
                char1Got = queryResult.get<Int64>(0)
                varchar1Got = queryResult.get<Int64>(1)
                clob1Got = queryResult.get<Int64>(2)
                blob1Got = queryResult.get<Int64>(3)
                boolean1Got = queryResult.get<Int64>(4)
                tinyint1Got = queryResult.get<Int64>(5)
                smallint1Got = queryResult.get<Int64>(6)
                integer1Got = queryResult.get<Int64>(7)
                bigint1Got = queryResult.get<Int64>(8)
                real1Got = queryResult.get<Int64>(9)
                double1Got = queryResult.get<Int64>(10)
                date1Got = queryResult.get<DateTime>(11)
                time1Got = queryResult.get<DateTime>(12)
                timetz1Got = queryResult.get<DateTime>(13)
                timestamp1Got = queryResult.get<DateTime>(14)
                interval1Got = queryResult.get<Duration>(15)

                println("${getString(char1Got).trimAscii()} == ${getString(char1).trimAscii()}");
                @Assert(getString(char1Got).trimAscii() == getString(char1).trimAscii())
                println("${getString(varchar1Got)} == ${getString(varchar1)}");
                @Assert(getString(varchar1Got) == getString(varchar1))
                println("${getString(clob1Got)} == ${getString(clob1)}");
                @Assert(getString(clob1Got) == getString(clob1))
                println("${getString(blob1Got)} == ${bytesToString(blob1)}");
                @Assert(getString(blob1Got) == bytesToString(blob1))
                println("${getString(boolean1Got).toString()[0]} == ${getString(boolean1).toString()[0]}");
                @Assert(getString(boolean1Got).toString()[0] == getString(boolean1).toString()[0])
                println("${getString(tinyint1Got)} == ${getString(tinyint1)}");
                @Assert(getString(tinyint1Got) == getString(tinyint1))
                println("${getString(smallint1Got)} == ${getString(smallint1)}");
                @Assert(getString(smallint1Got) == getString(smallint1))
                println("${getString(integer1Got)} == ${getString(integer1)}");
                @Assert(getString(integer1Got) == getString(integer1))
                println("${getString(bigint1Got)} == ${getString(bigint1)}");
                @Assert(getString(bigint1Got) == getString(bigint1))
                println("${getString(real1Got)} == ${getString(real1)}");
                @Assert(getString(real1Got) == getString(real1))
                println("${getString(double1Got)} == ${getString(double1)}");
                @Assert(getString(double1Got) == getString(double1))
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

            statement.set<Int64>(0, varchar1)
            statement.update()
            statement.close()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

}
