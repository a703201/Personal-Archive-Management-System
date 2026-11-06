package cangjie_tpc::opengauss.pgconn

import std.unittest.*
import std.unittest.testmacro.*
import std.binary.*
import cangjie_tpc::opengauss.utils.*

@Test
public class TestPGTypes {

    @TestCase
    func testBaseTypes(): Unit {
        // bool
        var val = "t".toArray()
        @Assert(PGbool(val, 0).toString() == "true")
        val = "f".toArray()
        @Assert(PGbool(val, 0).toString() == "false")
        val = Array<Byte>(1, {i: Int64 => 1})
        @Assert(PGbool(val, 0).toString() == "true")
        val = Array<Byte>(1, {i: Int64 => 0})
        @Assert(PGbool(val, 0).toString() == "false")

        val = "a".toArray()
        @Assert(PGchar(val, 0).toString() == "a")

        val = "11".toArray()
        @Assert(PGint2(val, 0).toString() == "11")
        val = Array<Byte>(1, {i: Int64 => 12})
        @Assert(PGint2(val, 1).toString() == "12")
        val = Array<Byte>(2, {i: Int64 => 0})
        val[0] = 0
        val[1] = 13
        @Assert(PGint2(val, 1).toString() == "13")

        val = "15".toArray()
        @Assert(PGint4(val, 0).toString() == "15")
        val = Array<Byte>(1, {i: Int64 => 16})
        @Assert(PGint4(val, 1).toString() == "16")
        val = Array<Byte>(2, {i: Int64 => 0})
        val[0] = 0
        val[1] = 17
        @Assert(PGint4(val, 1).toString() == "17")
        val = Array<Byte>(4, {i: Int64 => 0})
        val[0] = 0
        val[1] = 0
        val[2] = 0
        val[3] = 18
        @Assert(PGint4(val, 1).toString() == "18")

        val = "20".toArray()
        @Assert(PGint8(val, 0).toString() == "20")
        val = Array<Byte>(1, {i: Int64 => 21})
        @Assert(PGint8(val, 1).toString() == "21")
        val = Array<Byte>(2, {i: Int64 => 0})
        val[0] = 0
        val[1] = 22
        @Assert(PGint8(val, 1).toString() == "22")
        val = Array<Byte>(4, {i: Int64 => 0})
        val[0] = 0
        val[1] = 0
        val[2] = 0
        val[3] = 23
        @Assert(PGint8(val, 1).toString() == "23")
        val = Array<Byte>(8, {i: Int64 => 0})
        val[0] = 0
        val[1] = 0
        val[2] = 0
        val[3] = 0
        val[4] = 0
        val[5] = 0
        val[6] = 0
        val[7] = 24
        @Assert(PGint8(val, 1).toString() == "24")

        val = "1.1".toArray()        
        @Assert(PGfloat4(val, 0).toString() == "1.100000")
        let f = 1.2f32
        val = Array<Byte>(4, {i: Int64 => 0})
        f.writeBigEndian(val)
        @Assert(PGfloat4(val, 1).toString() == "1.200000")

        val = "1.3".toArray()
        println("PGfloat8  ${PGfloat8(val, 0).toString()}")
        @Assert(PGfloat8(val, 0).toString() == "1.300000")
        let df = 1.4f64
        val = Array<Byte>(8, {i: Int64 => 0})
        df.writeBigEndian(val)
        @Assert(PGfloat8(val, 1).toString() == "1.400000")
    }

    @TestCase
    func tesoid2typename(): Unit {
        @Assert(oid2typename(16) == "SqlBool")
        @Assert(oid2typename(17) == "SqlVarBinary")
        @Assert(oid2typename(18) == "SqlChar")
        @Assert(oid2typename(21) == "SqlSmallInt")
        @Assert(oid2typename(23) == "SqlInteger")
        @Assert(oid2typename(20) == "SqlBigInt")
        @Assert(oid2typename(25) == "SqlVarchar")
        @Assert(oid2typename(114) == "SqlVarchar")
        @Assert(oid2typename(142) == "SqlVarchar")
        @Assert(oid2typename(700) == "SqlReal")
        @Assert(oid2typename(701) == "SqlDouble")
        @Assert(oid2typename(1042) == "SqlChar")
        @Assert(oid2typename(1043) == "SqlVarchar")
        @Assert(oid2typename(1082) == "SqlDate")
        @Assert(oid2typename(1083) == "SqlTime")
        @Assert(oid2typename(1114) == "SqlTimestamp")
        @Assert(oid2typename(1184) == "SqlTimestamp")
        @Assert(oid2typename(1266) == "SqlTimeTz")
        @Assert(oid2typename(3969) == "SqlVarchar")
        @Assert(oid2typename(1000) == "Array<SqlBool>")
        @Assert(oid2typename(1001) == "Array<SqlVarBinary>")
        @Assert(oid2typename(1002) == "Array<SqlChar>")
        @Assert(oid2typename(1005) == "Array<SqlBigInt>")
        @Assert(oid2typename(1007) == "Array<SqlSmallInt>")
        @Assert(oid2typename(1016) == "Array<SqlInteger>")
        @Assert(oid2typename(1009) == "Array<SqlVarchar>")
        @Assert(oid2typename(199) == "Array<SqlVarchar>")
        @Assert(oid2typename(143) == "Array<SqlVarchar>")
        @Assert(oid2typename(1021) == "Array<SqlReal>")
        @Assert(oid2typename(1022) == "Array<SqlDouble>")
        @Assert(oid2typename(1015) == "Array<SqlVarchar>")
        @Assert(oid2typename(1182) == "Array<SqlDate>")
        @Assert(oid2typename(1183) == "Array<SqlTime>")
        @Assert(oid2typename(1115) == "Array<SqlTimestamp>")
        @Assert(oid2typename(1185) == "Array<SqlTimestamp>")
        @Assert(oid2typename(1270) == "Array<SqlTimeTz>")
        @Assert(oid2typename(12700) == "SqlVarchar")
    }

    @TestCase
    func testPGtimestamp(): Unit {

        // 构造 1 秒后的 timestamp (2000-01-01 00:00:01 UTC)
        let oneSecMicros = 1000000i64
        var val = Array<Byte>(8, {i: Int64 => 0})
        oneSecMicros.writeBigEndian(val)
        @Assert(PGtimestamp(val, 1).toString() == "2000-01-01T00:00:01Z")
        val = "0001-01-01 00:00:00 BC".toArray()
        println("PGtimestamp:${PGtimestamp(val, 0).toString()}")
        // @Assert(PGtimestamp(val, 0).toString() == "0001-01-01T00:00:00Z") // 受时区影响，显示会有差异

        oneSecMicros.writeBigEndian(val)
        @Assert(PGtimestamptz(val, 1).toString() == "2000-01-01T00:00:01Z")
        val = "0001-01-01 00:00:00 BC".toArray()
        println("PGtimestamptz:${PGtimestamptz(val, 0).toString()}")
        // @Assert(PGtimestamptz(val, 0).toString() == "0001-01-01T00:00:00Z")
    }

    @TestCase
    func testGetSqlArrayValue(): Unit {
        var write_buffer = ReadWriteBuffer()
        // ArrayHeader
        write_buffer.add(1i32)  //numDims
        write_buffer.add(0u32)  //containsNull
        write_buffer.add(PGType.PGint4)  //elementOID

        // ArrayDimension
        write_buffer.add(2i32) // length
        write_buffer.add(0i32) // lowerBound

        // array data
        write_buffer.add(1i32)  // len
        write_buffer.add("1".toArray())  // value
        write_buffer.add(1i32)  // len
        write_buffer.add("1".toArray())  // value

        let ret = getSqlArrayValue<Int32>(write_buffer.data(), 0i16)
        @Assert(2 == ret.size)

        let sql_array = SqlArray<Int32>(Array<Int32>(1, {i: Int64 => 0}))
        sql_array.dimension = 1
        @Assert(1i64 == sql_array.dimension)
        @Assert("SqlArray<T>" == sql_array.name)
        @Assert(1i64 == sql_array.value.size)
        ret.toString()
    }
}




