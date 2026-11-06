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
public class TestAllDbTypes {
    @TestCase
    func testDbTypes(): Unit {
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
            var sql = "insert into typetest2(tinyint1, smallint1, integer1, binteger1, bigint1, numeric1, decimal1, number1, smallserial1, serial1, bigserial1, largeserial1, real1, float41, double1, float81, float7, dec1, interger1, boolean1, char1, character1, nchar1, varchar1, characterv1, varchar21, nvarchar21, text1, clob1, blob1, raw1, bytea1, date1, time1, time2, timestamp1, timestamp2, smalldatetime1, interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8, interval9, interval10, interval11, interval12, reltime1, abstime1, point1, lseg1, box1, path1, path2, polygon1, circle1, cidr1, inet1, macaddr1, bit1, bitv1, tsvector1, tsquery1, uuid1, json1, jsonb1, hll1, int4range1, int8range1, numrange1, tsrange1, tstzrange1, daterange1, money1, xml1, hash161, hash321) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var statement = conn.prepareStatement(sql)
            var tinyint1 = 10i8
            var smallint1 = 100i16
            var integer1 = 1000i32
            var binteger1 = 10000i64
            var bigint1 = 100000i64
            var numeric1 = 1000000.101f64
            var decimal1 = 2000000.202f64
            var number1 = 3000000.303f64
            var smallserial1 = 99i32
            var serial1 = 999i32
            var bigserial1 = 9999i32
            var largeserial1 = 99999i32
            var real1 = 999.11f32
            var float41 = 988.22f32
            var double1 = 3000002.303f64
            var float81 = 5000005.505f64
            var float7 = 8006.62f64
            var dec1 = 9009009.912f64
            var interger1 = 986781i32
            var boolean1 = true
            var char1 = "char1"
            var character1 = "character1"
            var nchar1 = "nchar1"
            var varchar1 = "varchar1"
            var characterv1 = "characterv1"
            var varchar21 = "varchar21"
            var nvarchar21 = "nvarchar21"
            var text1 = "text1"
            var clob1 = "clob1"
            var blob1 = "blob1".toArray()
            var raw1 = "raw1".toArray()
            var bytea1 = "bytea1".toArray()
            var date1 = DateTime.parse("2023-12-19", "yyyy-MM-dd")
            var time1 = DateTime.parse("2022-11-21 21:11:21 323456", "yyyy-MM-dd HH:mm:ss SS")
            var time2 = DateTime.parse("2022-11-21 22:21:31 623", "yyyy-MM-dd HH:mm:ss S")
            var timestamp1 = DateTime.parse("2023-01-01 23:29:51 723", "yyyy-MM-dd HH:mm:ss S")
            var timestamp2 = DateTime.parse("2024-04-01 13:29:51 833+08", "yyyy-MM-dd HH:mm:ss SO")
            var smalldatetime1 = DateTime.parse("2024-08-21 23:48:53 901356", "yyyy-MM-dd HH:mm:ss SS")
            var interval1 = "1 day"
            var interval2 = "1 year"
            var interval3 = "1 mon"
            var interval4 = "1 day"
            var interval5 = "00:01:00"
            var interval6 = "1 day"
            var interval7 = "1 day"
            var interval8 = "01:00:00"
            var interval9 = "00:00:01"
            var interval10 = "1 day"
            var interval11 = "01:00:00"
            var interval12 = "00:01:00"
            var reltime1 = "1 day"
            var abstime1 = "2024-09-12 13:28:23+08"
            var point1 = "(1, 2)"
            var lseg1 = "((10, 20), (3, 4))"
            var box1 = "((20, 30), (40, 50))"
            var path1 = "((200, 300), (400, 500), (100, 100), (100, 200), (10, 20))"
            var path2 = "[(30, 20), (40, 60), (10, 100), (100, 20), (10, 20)]"
            var polygon1 = "((200, 30), (400, 50), (100, 10), (10, 200), (10, 20))"
            var circle1 = "<(21, 35),8>"
            var cidr1 = "192.168.2"
            var inet1 = "192.168.2.10"
            var macaddr1 = "0A:AB:CD:A1:1E:23"
            var bit1 = "101"
            var bitv1 = "10101"
            var tsvector1 = "tsvector1"
            var tsquery1 = "tsquery1"
            var uuid1 = "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"
            var json1 = "{\"json1\": \"1\"}"
            var jsonb1 = "{\"jsonb1\": \"2\"}"
            var hll1 = "\\x484c4c00000000002b05000000000000000000000000000000000000"
            var int4range1 = "(1, 3)"
            var int8range1 = "(10, 30)"
            var numrange1 = "(100, 300)"
            var tsrange1 = "(2020-01-01 10:00:00, 2020-02-01 11:00:00)"
            var tstzrange1 = "(2020-01-01 11:00:00, 2020-03-01 12:00:00)"
            var daterange1 = "(2020-01-01, 2023-09-09)"
            var money1 = "100"
            var xml1 = "<xml1>xcontent</xml1>"
            var hash161 = "9009890"
            var hash321 = "87910131879101318791013187910131"

            statement.set<Int8>(0, tinyint1)
            statement.set<Int16>(1, smallint1)
            statement.set<Int32>(2, integer1)
            statement.set<Int64>(3, binteger1)
            statement.set<Int64>(4, bigint1)
            statement.set<Float64>(5, numeric1)
            statement.set<Float64>(6, decimal1)
            statement.set<Float64>(7, number1)
            statement.set<Int32>(8, smallserial1)
            statement.set<Int32>(9, serial1)
            statement.set<Int32>(10, bigserial1)
            statement.set<Int32>(11, largeserial1)
            statement.set<Float32>(12, real1)
            statement.set<Float32>(13, float41)
            statement.set<Float64>(14, double1)
            statement.set<Float64>(15, float81)
            statement.set<Float64>(16, float7)
            statement.set<Float64>(17, dec1)
            statement.set<Int32>(18, interger1)
            statement.set<Bool>(19, boolean1)
            statement.set<String>(20, char1)
            statement.set<String>(21, character1)
            statement.set<String>(22, nchar1)
            statement.set<String>(23, varchar1)
            statement.set<String>(24, characterv1)
            statement.set<String>(25, varchar21)
            statement.set<String>(26, nvarchar21)
            statement.set<String>(27, text1)
            statement.set<String>(28, clob1)
            statement.set<Array<Byte>>(29, blob1)
            statement.set<Array<Byte>>(30, raw1)
            statement.set<Array<Byte>>(31, bytea1)
            statement.set<DateTime>(32, date1)
            statement.set<DateTime>(33, time1)
            statement.set<DateTime>(34, time2)
            statement.set<DateTime>(35, timestamp1)
            statement.set<DateTime>(36, timestamp2)
            statement.set<DateTime>(37, smalldatetime1)
            statement.set<String>(38, interval1)
            statement.set<String>(39, interval2)
            statement.set<String>(40, interval3)
            statement.set<String>(41, interval4)
            statement.set<String>(42, interval5)
            statement.set<String>(43, interval6)
            statement.set<String>(44, interval7)
            statement.set<String>(45, interval8)
            statement.set<String>(46, interval9)
            statement.set<String>(47, interval10)
            statement.set<String>(48, interval11)
            statement.set<String>(49, interval12)
            statement.set<String>(50, reltime1)
            statement.set<String>(51, abstime1)
            statement.set<String>(52, point1)
            statement.set<String>(53, lseg1)
            statement.set<String>(54, box1)
            statement.set<String>(55, path1)
            statement.set<String>(56, path2)
            statement.set<String>(57, polygon1)
            statement.set<String>(58, circle1)
            statement.set<String>(59, cidr1)
            statement.set<String>(60, inet1)
            statement.set<String>(61, macaddr1)
            statement.set<String>(62, bit1)
            statement.set<String>(63, bitv1)
            statement.set<String>(64, tsvector1)
            statement.set<String>(65, tsquery1)
            statement.set<String>(66, uuid1)
            statement.set<String>(67, json1)
            statement.set<String>(68, jsonb1)
            statement.set<String>(69, hll1)
            statement.set<String>(70, int4range1)
            statement.set<String>(71, int8range1)
            statement.set<String>(72, numrange1)
            statement.set<String>(73, tsrange1)
            statement.set<String>(74, tstzrange1)
            statement.set<String>(75, daterange1)
            statement.set<String>(76, money1)
            statement.set<String>(77, xml1)
            statement.set<String>(78, hash161)
            statement.set<String>(79, hash321)

            var updateresult = statement.update()
            @Assert(updateresult.rowCount == 1)
            statement.close()

            sql = "select tinyint1, smallint1, integer1, binteger1, bigint1, numeric1, decimal1, number1, smallserial1, serial1, bigserial1, largeserial1, real1, float41, double1, float81, float7, dec1, interger1, boolean1, char1, character1, nchar1, varchar1, characterv1, varchar21, nvarchar21, text1, clob1, blob1, raw1, bytea1, date1, time1, time2, timestamp1, timestamp2, smalldatetime1, interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8, interval9, interval10, interval11, interval12, reltime1, abstime1, point1, lseg1, box1, path1, path2, polygon1, circle1, cidr1, inet1, macaddr1, bit1, bitv1, tsvector1, tsquery1, uuid1, json1, jsonb1, hll1, int4range1, int8range1, numrange1, tsrange1, tstzrange1, daterange1, money1, xml1, hash161, hash321 from typetest2 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            println("statement.parameterColumnInfos.size = ${statement.parameterColumnInfos.size}")
            var tinyint1Got = 0i8
            var smallint1Got = 0i16
            var integer1Got = 0i32
            var binteger1Got = 0i64
            var bigint1Got = 0i64
            var numeric1Got = 0.0f64
            var decimal1Got = 0.0f64
            var number1Got = 0.0f64
            var smallserial1Got = 0i32
            var serial1Got = 0i32
            var bigserial1Got = 0i32
            var largeserial1Got = 0i32
            var real1Got = 0.0f32
            var float41Got = 0.0f32
            var double1Got = 0.0f64
            var float81Got = 0.0f64
            var float7Got = 0.0f64
            var dec1Got = 0.0f64
            var interger1Got = 0.0f64
            var boolean1Got = false
            var char1Got = ""
            var character1Got = ""
            var nchar1Got = ""
            var varchar1Got = ""
            var characterv1Got = ""
            var varchar21Got = ""
            var nvarchar21Got = ""
            var text1Got = ""
            var clob1Got = ""
            var blob1Got = "".toArray()
            var raw1Got = "".toArray()
            var bytea1Got = "".toArray()
            var date1Got = DateTime.now()
            var time1Got = DateTime.UnixEpoch
            var time2Got = DateTime.UnixEpoch
            var timestamp1Got = DateTime.UnixEpoch
            var timestamp2Got = DateTime.UnixEpoch
            var smalldatetime1Got = DateTime.UnixEpoch
            var interval1Got = Duration.second
            var interval2Got = Duration.second
            var interval3Got = Duration.second
            var interval4Got = Duration.second
            var interval5Got = Duration.second
            var interval6Got = Duration.second
            var interval7Got = Duration.second
            var interval8Got = Duration.second
            var interval9Got = Duration.second
            var interval10Got = Duration.second
            var interval11Got = Duration.second
            var interval12Got = Duration.second
            var reltime1Got = Duration.second
            var abstime1Got = DateTime.now()
            var point1Got = ""
            var lseg1Got = ""
            var box1Got = ""
            var path1Got = ""
            var path2Got = ""
            var polygon1Got = ""
            var circle1Got = ""
            var cidr1Got = ""
            var inet1Got = ""
            var macaddr1Got = ""
            var bit1Got = ""
            var bitv1Got = ""
            var tsvector1Got = ""
            var tsquery1Got = ""
            var uuid1Got = ""
            var json1Got = ""
            var jsonb1Got = ""
            var hll1Got = ""
            var int4range1Got = ""
            var int8range1Got = ""
            var numrange1Got = ""
            var tsrange1Got = ""
            var tstzrange1Got = ""
            var daterange1Got = ""
            var money1Got = ""
            var xml1Got = ""
            var hash161Got = ""
            var hash321Got = ""

            statement.set<String>(0, varchar1)
            let queryResult = statement.query()
            let rowsOption = queryResult as Rows
            // match (rowsOption) {
            //     case Some(rows) =>
            //         println("name, typeName, displaySize, length, scale, nullable")
            //         for (columnInfo in rows.columnInfos) {
            //             println(
            //                 "${columnInfo.name}, ${columnInfo.typeName}, ${columnInfo.displaySize}, ${columnInfo.length}, ${columnInfo.scale}, ${columnInfo.nullable}"
            //             )
            //         }
            //     case _ => ()
            // }
            var count = 0
            while (queryResult.next()) {
                tinyint1Got = queryResult.get<Int8>(0);
                smallint1Got = queryResult.get<Int16>(1);
                integer1Got = queryResult.get<Int32>(2);
                binteger1Got = queryResult.get<Int64>(3);
                bigint1Got = queryResult.get<Int64>(4);
                numeric1Got = queryResult.get<Float64>(5);
                decimal1Got = queryResult.get<Float64>(6);
                number1Got = queryResult.get<Float64>(7);
                smallserial1Got = queryResult.get<Int32>(8);
                serial1Got = queryResult.get<Int32>(9);
                bigserial1Got = queryResult.get<Int32>(10);
                largeserial1Got = queryResult.get<Int32>(11);
                real1Got = queryResult.get<Float32>(12);
                float41Got = queryResult.get<Float32>(13);
                double1Got = queryResult.get<Float64>(14);
                float81Got = queryResult.get<Float64>(15);
                float7Got = queryResult.get<Float64>(16);
                dec1Got = queryResult.get<Float64>(17);
                interger1Got = queryResult.get<Float64>(18);
                boolean1Got = queryResult.get<Bool>(19);
                char1Got = queryResult.get<String>(20);
                character1Got = queryResult.get<String>(21);
                nchar1Got = queryResult.get<String>(22);
                varchar1Got = queryResult.get<String>(23);
                characterv1Got = queryResult.get<String>(24);
                varchar21Got = queryResult.get<String>(25);
                nvarchar21Got = queryResult.get<String>(26);
                text1Got = queryResult.get<String>(27);
                clob1Got = queryResult.get<String>(28);
                blob1Got = queryResult.get<Array<Byte>>(29);
                raw1Got = queryResult.get<Array<Byte>>(30);
                bytea1Got = queryResult.get<Array<Byte>>(31);
                date1Got = queryResult.get<DateTime>(32);
                time1Got = queryResult.get<DateTime>(33);
                time2Got = queryResult.get<DateTime>(34);
                timestamp1Got = queryResult.get<DateTime>(35);
                timestamp2Got = queryResult.get<DateTime>(36);
                smalldatetime1Got = queryResult.get<DateTime>(37);
                interval1Got = queryResult.get<Duration>(38);
                interval2Got = queryResult.get<Duration>(39);
                interval3Got = queryResult.get<Duration>(40);
                interval4Got = queryResult.get<Duration>(41);
                interval5Got = queryResult.get<Duration>(42);
                interval6Got = queryResult.get<Duration>(43);
                interval7Got = queryResult.get<Duration>(44);
                interval8Got = queryResult.get<Duration>(45);
                interval9Got = queryResult.get<Duration>(46);
                interval10Got = queryResult.get<Duration>(47);
                interval11Got = queryResult.get<Duration>(48);
                interval12Got = queryResult.get<Duration>(49);
                reltime1Got = queryResult.get<Duration>(50);
                abstime1Got = queryResult.get<DateTime>(51);
                point1Got = queryResult.get<String>(52);
                lseg1Got = queryResult.get<String>(53);
                box1Got = queryResult.get<String>(54);
                path1Got = queryResult.get<String>(55);
                path2Got = queryResult.get<String>(56);
                polygon1Got = queryResult.get<String>(57);
                circle1Got = queryResult.get<String>(58);
                cidr1Got = queryResult.get<String>(59);
                inet1Got = queryResult.get<String>(60);
                macaddr1Got = queryResult.get<String>(61);
                bit1Got = queryResult.get<String>(62);
                bitv1Got = queryResult.get<String>(63);
                tsvector1Got = queryResult.get<String>(64);
                tsquery1Got = queryResult.get<String>(65);
                uuid1Got = queryResult.get<String>(66);
                json1Got = queryResult.get<String>(67);
                jsonb1Got = queryResult.get<String>(68);
                hll1Got = queryResult.get<String>(69);
                int4range1Got = queryResult.get<String>(70);
                int8range1Got = queryResult.get<String>(71);
                numrange1Got = queryResult.get<String>(72);
                tsrange1Got = queryResult.get<String>(73);
                tstzrange1Got = queryResult.get<String>(74);
                daterange1Got = queryResult.get<String>(75);
                money1Got = queryResult.get<String>(76);
                xml1Got = queryResult.get<String>(77);
                hash161Got = queryResult.get<String>(78);
                hash321Got =queryResult.get<String>(79);


                println("${tinyint1Got} == ${tinyint1}")
                @Assert(tinyint1Got == tinyint1)
                println("${smallint1Got} == ${smallint1}")
                @Assert(smallint1Got == smallint1)
                println("${integer1Got} == ${integer1}")
                @Assert(integer1Got == integer1)
                println("${binteger1Got} == ${binteger1}")
                @Assert(binteger1Got == binteger1)
                println("${bigint1Got} == ${bigint1}")
                @Assert(bigint1Got == bigint1)
                println("${numeric1Got} == ${numeric1}")
                @Assert(doubleEquals(Float64(numeric1Got), Float64(numeric1)))
                println("${decimal1Got} == ${decimal1}")
                @Assert(doubleEquals(Float64(decimal1Got), Float64(decimal1)))
                println("${number1Got} == ${number1}")
                @Assert(doubleEquals(Float64(number1Got), Float64(number1)))
                println("${smallserial1Got} == ${smallserial1}")
                @Assert(smallserial1Got == smallserial1)
                println("${serial1Got} == ${serial1}")
                @Assert(serial1Got == serial1)
                println("${bigserial1Got} == ${bigserial1}")
                @Assert(bigserial1Got == bigserial1)
                println("${largeserial1Got} == ${largeserial1}")
                @Assert(largeserial1Got == largeserial1)
                println("${real1Got} == ${real1}")
                @Assert(doubleEquals(Float64(real1Got), Float64(real1)))
                println("${float41Got} == ${float41}")
                @Assert(doubleEquals(Float64(float41Got), Float64(float41)))
                println("${double1Got} == ${double1}")
                @Assert(doubleEquals(Float64(double1Got), Float64(double1)))
                println("${float81Got} == ${float81}")
                @Assert(doubleEquals(Float64(float81Got), Float64(float81)))
                println("${float7Got} == ${float7}")
                @Assert(doubleEquals(Float64(float7Got), Float64(float7)))
                println("${dec1Got} == ${dec1}")
                @Assert(doubleEquals(Float64(dec1Got), Float64(dec1)))
                println("${interger1Got} == ${interger1}")
                @Assert(doubleEquals(Float64(interger1Got), Float64(interger1)))
                println("${boolean1Got} == ${boolean1}")
                @Assert(boolean1Got == boolean1)
                println("${char1Got} == ${char1}")
                @Assert(char1Got.trimAscii() == char1.trimAscii())
                println("${character1Got} == ${character1}")
                @Assert(character1Got.trimAscii() == character1.trimAscii())
                println("${nchar1Got} == ${nchar1}")
                @Assert(nchar1Got.trimAscii() == nchar1.trimAscii())
                println("${varchar1Got} == ${varchar1}")
                @Assert(varchar1Got.trimAscii() == varchar1.trimAscii())
                println("${characterv1Got} == ${characterv1}")
                @Assert(characterv1Got.trimAscii() == characterv1.trimAscii())
                println("${varchar21Got} == ${varchar21}")
                @Assert(varchar21Got.trimAscii() == varchar21.trimAscii())
                println("${nvarchar21Got} == ${nvarchar21}")
                @Assert(nvarchar21Got.trimAscii() == nvarchar21.trimAscii())
                println("${text1Got} == ${text1}")
                @Assert(text1Got.trimAscii() == text1.trimAscii())
                println("${clob1Got} == ${clob1}")
                @Assert(clob1Got.trimAscii() == clob1.trimAscii())
                println("${blob1Got} == ${blob1}")
                @Assert(blob1Got.toString() == blob1.toString())
                println("${raw1Got} == ${raw1}")
                @Assert(raw1Got.toString() == raw1.toString())
                println("${bytea1Got} == ${bytea1}")
                @Assert(bytea1Got.toString() == bytea1.toString())
                println("${date1Got} == ${date1}")
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                println("${time1Got} == ${time1}")
                @Assert(time1Got.hour == time1.hour)
                @Assert(time1Got.minute == time1.minute)
                @Assert(time1Got.second == time1.second)
                println("${time2Got} == ${time2}")
                @Assert(time2Got.hour == time2.hour)
                @Assert(time2Got.minute == time2.minute)
                @Assert(time2Got.second == time2.second)
                println("${timestamp1Got} == ${timestamp1}")
                @Assert(timestamp1Got.format("yyyy-MM-dd HH:mm:ss.SS") == timestamp1.format("yyyy-MM-dd HH:mm:ss.SS"))
                println("${timestamp2Got} == ${timestamp2}")
                @Assert(timestamp2Got.toString() == timestamp2.toString())
                println("${smalldatetime1Got} == ${smalldatetime1}")
                @Assert(date1Got.year == date1.year)
                @Assert(date1Got.month == date1.month)
                @Assert(date1Got.dayOfMonth == date1.dayOfMonth)
                @Assert(time1Got.hour == time1.hour)
                println("${interval1Got} == ${interval1}")
                @Assert(interval1Got.toString() == "1d")
                println("${interval2Got} == ${interval2}")
                @Assert(interval2Got.toString() == "365d")
                println("${interval3Got} == ${interval3}")
                @Assert(interval3Got.toString() == "30d")
                println("${interval4Got} == ${interval4}")
                @Assert(interval4Got.toString() == "1d")
                println("${interval5Got} == ${interval5}")
                @Assert(interval5Got.toString() == "1m")
                println("${interval6Got} == ${interval6}")
                @Assert(interval6Got.toString() == "1d")
                println("${interval7Got} == ${interval7}")
                @Assert(interval7Got.toString() == "1d")
                println("${interval8Got} == ${interval8}")
                @Assert(interval8Got.toString() == "1h")
                println("${interval9Got} == ${interval9}")
                @Assert(interval9Got.toString() == "1s")
                println("${interval10Got} == ${interval10}")
                @Assert(interval10Got.toString() == "1d")
                println("${interval11Got} == ${interval11}")
                @Assert(interval11Got.toString() == "1h")
                println("${interval12Got} == ${interval12}")
                @Assert(interval12Got.toString() == "1m")
                println("${reltime1Got} == ${reltime1}")
                @Assert(reltime1Got.toString() == "1d")
                println("${abstime1Got} == ${abstime1}")
                var datetimetmp = DateTime.parse(abstime1, "yyyy-MM-dd HH:mm:ssO")
                @Assert(abstime1Got.year == datetimetmp.year)
                @Assert(abstime1Got.month == datetimetmp.month)
                @Assert(abstime1Got.dayOfMonth == datetimetmp.dayOfMonth)
                @Assert(abstime1Got.hour == datetimetmp.hour)
                @Assert(abstime1Got.minute == datetimetmp.minute)
                @Assert(abstime1Got.second == datetimetmp.second)
                @Assert(abstime1Got.zoneId == datetimetmp.zoneId)
                println("${point1Got} == ${point1}")
                @Assert(point1Got == "(1,2)")
                println("${lseg1Got} == ${lseg1}")
                @Assert(lseg1Got == "[(10,20),(3,4)]")
                println("${box1Got} == ${box1}")
                @Assert(box1Got == "(40,50),(20,30)")
                println("${path1Got} == ${path1}")
                @Assert(path1Got == "((200,300),(400,500),(100,100),(100,200),(10,20))")
                println("${path2Got} == ${path2}")
                @Assert(path2Got == "[(30,20),(40,60),(10,100),(100,20),(10,20)]")
                println("${polygon1Got} == ${polygon1}")
                @Assert(polygon1Got == "((200,30),(400,50),(100,10),(10,200),(10,20))")
                println("${circle1Got} == ${circle1}")
                @Assert(circle1Got == "<(21,35),8>")
                println("${cidr1Got} == ${cidr1}")
                @Assert(cidr1Got == "192.168.2.0/24")
                println("${inet1Got} == ${inet1}")
                @Assert(inet1Got == inet1)
                println("${macaddr1Got} == ${macaddr1}")
                @Assert(macaddr1Got == "0a:ab:cd:a1:1e:23")
                println("${bit1Got} == ${bit1}")
                @Assert(bit1Got == bit1)
                println("${bitv1Got} == ${bitv1}")
                @Assert(bitv1Got == bitv1)
                println("${tsvector1Got} == ${tsvector1}")
                @Assert(tsvector1Got == "'tsvector1'")
                println("${tsquery1Got} == ${tsquery1}")
                @Assert(tsquery1Got == "'tsquery1'")
                println("${uuid1Got} == ${uuid1}")
                @Assert(uuid1Got.toString() == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
                println("${json1Got} == ${json1}")
                @Assert(json1Got == json1)
                println("${jsonb1Got} == ${jsonb1}")
                @Assert(jsonb1Got == jsonb1)
                println("${hll1Got} == ${hll1}")
                @Assert(hll1Got == hll1)
                println("${int4range1Got} == ${int4range1}")
                @Assert(int4range1Got == "[2,3)")
                println("${int8range1Got} == ${int8range1}")
                @Assert(int8range1Got == "[11,30)")
                println("${numrange1Got} == ${numrange1}")
                @Assert(numrange1Got == "(100,300)")
                println("${tsrange1Got} == ${tsrange1}")
                @Assert(tsrange1Got == "(\"2020-01-01 10:00:00\",\"2020-02-01 11:00:00\")")
                println("${tstzrange1Got} == ${tstzrange1}")
                @Assert(tstzrange1Got == "(\"2020-01-01 11:00:00+08\",\"2020-03-01 12:00:00+08\")")
                println("${daterange1Got} == ${daterange1}")
                @Assert(daterange1Got == "[2020-01-02,2023-09-09)")
                println("${money1Got} == ${money1}")
                @Assert(money1Got == "$100.00")
                println("${xml1Got} == ${xml1}")
                @Assert(xml1Got == xml1)
                println("${hash161Got} == ${hash161}")
                @Assert(hash161Got == "0000000009009890")
                println("${hash321Got} == ${hash321}")
                @Assert(hash321Got == hash321)
                count++
            }
            @Assert(count > 0)

            statement.close()

            sql = "delete from typetest2 where varchar1 = ?"
            statement = conn.prepareStatement(sql)
            statement.set<String>(0, varchar1)
            statement.update()
            statement.close()
            println("test finished and the test case is OK.")
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

    func doubleEquals(double1: Float64, double2: Float64): Bool {
        return (double1 == double2) || ((double2 - 0.01 < double1) && (double1 < double2 + 0.01)) || ((double1 - 0.01 <
            double2) && (double2 < double1 + 0.01))
    }
}
