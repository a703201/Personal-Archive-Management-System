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

package sqltype_example

import std.database.sql.*
import std.time.*
import std.io.*
import cangjie_tpc::opengauss.driver.*
import cangjie_tpc::opengauss.pgconn.{bytesToDateTime, stringToDateTime}
import cangjie_tpc::opengauss.utils.*

main(): Int64 {
    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drvopt = DriverManager.getDriver("opengauss")
    var drv: Driver
    match (drvopt) {
        case Some(v) => drv = v
        case None =>
            println("cannot get the opengauss driver")
            return 1
    }
    let ds = drv.open(url)
    try (conn = ds.connect()) {
        let metadata = conn.getMetaData()
        var sql = "insert into typetest1(char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement = conn.prepareStatement(sql)
        var char1: String = "09:18:23"
        var varchar1: String = "19:28:33.312"
        var clob1value = "21:58:53.651712"
        var clob1bas = ByteBuffer()
        clob1bas.write(clob1value.toArray())
        var clob1 = clob1bas
        var blob1value = "22:31:41.31242"
        var blob1bas = ByteBuffer()
        blob1bas.write(blob1value.toArray())
        var blob1 = blob1bas
        var boolean1: Bool = true
        var tinyint1: Int8 = 113i8
        var smallint1: Int16 = -21i16
        var integer1: Int32 = -19897i32
        var bigint1: Int64 = 108917i64
        var real1: Float32 = 909.91f32
        var double1: Float64 = 9571781818.9819f64
        var date1tmp: DateTime = DateTime.parse("2020-12-02", "yyyy-MM-dd")
        var date1 = date1tmp
        var time1tmp: DateTime = DateTime.parse("2018-03-09 10:11:51 123456389", "yyyy-MM-dd HH:mm:ss SSS")
        var time1 = time1tmp
        var time1tztmp = DateTime.parse("2016-11-21 21:01:01 223456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
        var timetz1 = time1tztmp
        var timestamp1tmp = DateTime.parse("2008-11-15 11:20:11 323456389 +08", "yyyy-MM-dd HH:mm:ss SSS O")
        var timestamp1: DateTime = timestamp1tmp
        var interval1: Duration = Duration.second * 28237

        statement.set<String>(0, char1)
        statement.set<String>(1, varchar1)
        statement.set<InputStream>(2, clob1)
        statement.set<InputStream>(3, blob1)
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
        statement.close()

        sql = "select char1, varchar1, clob1, blob1, boolean1, tinyint1, smallint1, integer1, bigint1, real1, double1, date1, time1, timetz1, timestamp1, interval1 from typetest1 where varchar1 = ?"
        statement = conn.prepareStatement(sql)
        statement.set<String>(1, varchar1)
        
        var count = 0        
        let queryResult = statement.query()
        while (queryResult.next()) {

            var char1Got = queryResult.get<String>(0)//SqlChar("")
            var varchar1Got = queryResult.get<String>(1)//SqlVarchar("")
            // var tmp = ByteBuffer()
            var clob1Got = queryResult.get<InputStream>(2)//SqlClob(tmp)
            var blob1Got = queryResult.get<InputStream>(3)//SqlBlob(tmp)
            var boolean1Got = queryResult.get<Bool>(4)//SqlBool(true)
            var tinyint1Got = queryResult.get<Int8>(5)//SqlByte(0i8)
            var smallint1Got = queryResult.get<Int16>(6)//SqlSmallInt(0i16)
            var integer1Got = queryResult.get<Int32>(7)//SqlInteger(0i32)
            var bigint1Got = queryResult.get<Int64>(8)//SqlBigInt(0i64)
            var real1Got = queryResult.get<Float32>(9)//SqlDouble(0.0f64)
            var double1Got = queryResult.get<Float64>(10)//SqlDouble(0.0f64)
            var date1Got = queryResult.get<DateTime>(11)//SqlDate(DateTime.now())
            var time1Got = queryResult.get<DateTime>(12)//SqlTime(DateTime.now())
            var timetz1Got = queryResult.get<DateTime>(13)//SqlTime(DateTime.now())
            var timestamp1Got = queryResult.get<DateTime>(14)//SqlTimeTz(DateTime.now())
            var interval1Got = queryResult.get<Duration>(15)//SqlInterval(Duration.second)          


            println("${char1Got.toString().trimAscii()} == ${char1.toString().trimAscii()}");
            println("${varchar1Got.toString()} == ${varchar1.toString().trimAscii()}");
            println("${inputStreamToStringMax1024(clob1Got)} == ${clob1value}");
            println("${inputStreamToStringMax1024(blob1Got)} == ${blob1value}");
            println("${boolean1Got} == ${boolean1}");
            println("${tinyint1Got.toString()} == ${tinyint1}");
            println("${smallint1Got.toString()} == ${smallint1}");
            println("${integer1Got} == ${integer1}");
            println("${bigint1Got} == ${bigint1}");
            println("${real1Got.toString()} == ${real1}");
            println("${double1Got.toString()} == ${double1}");
            println("${date1Got.toString()} == ${date1}");
            println("${time1Got.toString()} == ${time1}");
            println("${timetz1Got.toString()} == ${timetz1}");
            println("${timestamp1Got.toString()} == ${timestamp1}");
            println("zoneId=${timestamp1Got.zoneId}")
            println("${interval1Got.toString()} == ${interval1}");
            count++
        }
        statement.close()

        sql = "delete from typetest1 where varchar1 = ?"
        statement = conn.prepareStatement(sql)
        statement.set<String>(1, varchar1)
        statement.query()
        statement.close()
    } catch (ex: Exception) {
        ex.printStackTrace()
    }

    return 0
}

func inputStreamToStringMax1024(inputStream: InputStream): String {
    var buf = Array<Byte>(1024, repeat: 0)
    var readlen = inputStream.read(buf)
    return bytesToString(buf, 0, readlen)
}
