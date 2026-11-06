/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 */
package cangjie_tpc::opengauss.pgconn

import std.collection.*
import std.time
import std.time.*
import std.database.sql.*
import std.convert.*
import std.binary.*
import std.convert.*
import std.math.*
import std.math.numeric.{Decimal, BigInt}
import cangjie_tpc::opengauss.utils.*

struct PGType {
    static let PGbool: Int32 = 16
    static let PGbytea: Int32 = 17
    static let PGchar: Int32 = 18
    static let PGint2: Int32 = 21
    static let PGint4: Int32 = 23
    static let PGint8: Int32 = 20
    static let PGtext: Int32 = 25
    static let PGjson: Int32 = 114
    static let PGxml: Int32 = 142
    static let PGfloat4: Int32 = 700
    static let PGfloat8: Int32 = 701
    static let PGnumeric: Int32 = 1700
    static let PGbpchar: Int32 = 1042
    static let PGvarchar: Int32 = 1043
    static let PGnvarchar2: Int32 = 3969
    static let PGdate: Int32 = 1082
    static let PGtime: Int32 = 1083
    static let PGtimestamp: Int32 = 1114
    static let PGtimestamptz: Int32 = 1184
    static let PGtimetz: Int32 = 1266
    static let PG_bool: Int32 = 1000
    static let PG_bytea: Int32 = 1001
    static let PG_char: Int32 = 1002
    static let PG_int2: Int32 = 1005
    static let PG_int4: Int32 = 1007
    static let PG_int8: Int32 = 1016
    static let PG_text: Int32 = 1009
    static let PG_json: Int32 = 199
    static let PG_xml: Int32 = 143
    static let PG_float4: Int32 = 1021
    static let PG_float8: Int32 = 1022
    static let PG_numeric: Int32 = 1231
    static let PG_varchar: Int32 = 1015
    static let PG_date: Int32 = 1182
    static let PG_time: Int32 = 1183
    static let PG_timestamp: Int32 = 1115
    static let PG_timestamptz: Int32 = 1185
    static let PG_timetz: Int32 = 1270
}

func PGbool(val: Array<Byte>, fmtCode: Int16): ToString {
    match (val[0]) {
        case b't' => true
        case b'f' => false
        case 1 => true
        case 0 => false
        case _ => throw SqlException("invalid oid 16 value: ${val}")
    }
}

func PGbytea(val: Array<Byte>, fmtCode: Int16): ToString {
    val
}

func PGchar(val: Array<Byte>, fmtCode: Int16): ToString {
    String.fromUtf8(val)
}

func PGint2(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 0) {
        let istr = String.fromUtf8(val)
        Int16.parse(istr)
    } else {
        match (val.size) {
            case 1 => Int16(val[0])
            case 2 => Int16.readBigEndian(val)
            case _ => throw SqlException("invalid length( ${val.size}) for oid 21")
        }
    }
}

func PGint4(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 0) {
        let istr = String.fromUtf8(val)
        Int32.parse(istr)
    } else {
        match (val.size) {
            case 1 => Int32(val[0])
            case 2 => Int32(Int16.readBigEndian(val))
            case 4 => Int32.readBigEndian(val)
            case _ => throw SqlException("invalid length(${val.size}) for oid 23")
        }
    }
}

func PGint8(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 0) {
        let istr = String.fromUtf8(val)
        Int64.parse(istr)
    } else {
        match (val.size) {
            case 1 => Int64(val[0])
            case 2 => Int64(Int32(Int16.readBigEndian(val)))
            case 4 => Int64(Int32.readBigEndian(val))
            case 8 => Int64.readBigEndian(val)
            case _ => throw SqlException("invalid length(${val.size}) for oid 20")
        }
    }
}

func PGfloat4(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 0) {
        let istr = String.fromUtf8(val)
        Float32.parse(istr)
    } else {
        Float32.fromBits(UInt32.readBigEndian(val))
    }
}

func PGfloat8(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 0) {
        let istr = String.fromUtf8(val)
        Float64.parse(istr)
    } else {
        Float64.fromBits(UInt64.readBigEndian(val))
    }
}
const nbase = 10000
const pgNumericZeroSign = 0x0000u16
const pgNumericNaNSign = 0xc000u16
const pgNumericPosInfSign = 0xd000u16
const pgNumericNegInfSign = 0x4000u16
const pgNumericNaN = 0x00000000c0000000
const pgNumericPosInf = 0x00000000d0000000
const pgNumericNegInf = 0x00000000f0000000
const NUMERIC_DSCALE_MASK = 0x00003FFFi32
const Infinity: Int8 = 1
const Finite: Int8 = 0
const NegativeInfinity = -Infinity
var big0 = BigInt(0)
var big1 = BigInt(1)
var big10 = BigInt(10)
var big100 = BigInt(100)
var big1000 = BigInt(1000)
var bigNBase = BigInt(nbase)
var bigNBaseX2 = BigInt(nbase * nbase)
var bigNBaseX3 = BigInt(nbase * nbase * nbase)
var bigNBaseX4 = BigInt(nbase * nbase * nbase * nbase)
func PGDecimal(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 1) {
        decimalFromBigEndianBytes(val)
    } else {
        var str = unsafe { String.fromUtf8Unchecked(val) }
        if (str == "NaN") {
            return Decimal(Float64.NaN)
        } else if (str == "Infinity") {
            return Decimal(Float64.Inf)
        } else if (str == "-Infinity") {
            return Decimal(-Float64.Inf)
        }
        let idx = str.indexOf('.')
        var scale = 0i32
        if (let Some(i) <- idx) {
            scale = Int32((str.size - i - 1))

            str = str[..i] + str[i + 1..]
        }
        let bi = BigInt.parse(str, radix: 10)
        return Decimal(bi, scale)
    }
}
func decimalFromBigEndianBytes(val: Array<Byte>): Decimal {
    if (val.size < 8) {
        throw Exception("numeric incomplete ${val}")
    }
    var rp = 0
    let ndigits = UInt16.readBigEndian(val[rp..])
    rp += 2
    let weight = Int16.readBigEndian(val[rp..])
    rp += 2
    let sign = UInt16.readBigEndian(val[rp..])
    rp += 2
    let dscale = Int16.readBigEndian(val[rp..])
    rp += 2

    if (sign == pgNumericNaNSign) {
        return Decimal(Float64.NaN)
    } else if (sign == pgNumericPosInfSign) {
        return Decimal(Float64.Inf)
    } else if (sign == pgNumericNegInfSign) {
        return Decimal(-Float64.Inf)
    }

    if (ndigits == 0) {
        return Decimal(BigInt(0), Int32(dscale))
    }

    if (val[rp..].size < Int64(ndigits) * 2) {
        throw Exception("numeric incomplete ${val}")
    }

    var accum = BigInt(0)

    for (i in 0..Int64(ndigits + 3) / 4) {
        let (int64accum, bytesRead, digitsRead) = nbaseDigitsToInt64(val[rp..])
        rp += bytesRead

        if (i > 0) {
            var mul: BigInt
            match (digitsRead) {
                case 1 => mul = bigNBase
                case 2 => mul = bigNBaseX2
                case 3 => mul = bigNBaseX3
                case 4 => mul = bigNBaseX4
                case _ => throw Exception("invalid digitsRead: ${digitsRead} (this can't happen)")
            }
            accum *= mul
        }
        accum += BigInt(int64accum)
    }
    var exp = (Int32(weight) - Int32(ndigits) + 1) * 4
    if (dscale > 0) {
        var fracNBaseDigits = Int16(Int32(ndigits) - Int32(weight) - 1)
        var fracDecimalDigits = fracNBaseDigits * 4

        if (dscale > fracDecimalDigits) {
            var multCount = Int64(dscale - fracDecimalDigits)
            for (i in 0..multCount) {
                accum *= big10
                exp--
            }
        } else if (dscale < fracDecimalDigits) {
            var divCount = Int64(fracDecimalDigits - dscale)
            for (i in 0..divCount) {
                accum /= big10
                exp++
            }
        }
    }
    var reduced = BigInt(0)
    var remainder = BigInt(0)
    if (exp >= 0) {
        while (true) {
            remainder = accum % big10
            reduced = accum / big10
            if (remainder != big0) {
                break
            }
            accum = reduced
            exp++
        }
    }
    if (sign != 0) {
        accum *= BigInt(-1)
    }

    return Decimal(accum, Int32(dscale))
}
func nbaseDigitsToInt64(src: Array<Byte>): (Int64, Int64, Int64) {
    var accum = 0
    var digits = src.size / 2
    if (digits > 4) {
        digits = 4
    }
    var rp = 0
    for (i in 0..digits) {
        if (i > 0) {
            accum *= nbase
        }
        accum += Int64(UInt16.readBigEndian(src[rp..]))
        rp += 2
    }
    return (accum, rp, digits)
}

func PGdate(val: Array<Byte>, fmtCode: Int16): ToString {
    return PGtimestamp(val, 0)
}

func PGtime(val: Array<Byte>, fmtCode: Int16): ToString {
    let current = time.DateTime.now()
    return PGtimestamp(
        "${current.year.format("04")}-${current.month.toInteger().format("02")}-${current.dayOfMonth.format("02")} ${bytesToString(val)}"
            .toArray(),
        0
    )
}

func PGtimetz(val: Array<Byte>, fmtCode: Int16): ToString {
    let current = time.DateTime.now()
    return PGtimestamptz(
        "${current.year.format("04")}-${current.month.toInteger().format("02")}-${current.dayOfMonth.format("02")} ${bytesToString(val)}"
            .toArray(),
        0
    )
}

func PGtimestamp(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 1) {
        let microsecSinceY2K = Int64.readBigEndian(val)
        match {
            case microsecSinceY2K == infinityMicrosecondOffset => DateTime.fromUnixTimeStamp(Duration.Max)
            case microsecSinceY2K == negativeInfinityMicrosecondOffset => DateTime.fromUnixTimeStamp(Duration.Min)
            case _ => DateTime.ofEpoch(
                second: microsecFromUnixEpochToY2K / 1000000 + microsecSinceY2K / 1000000,
                nanosecond: (microsecFromUnixEpochToY2K % 1000000 * 1000) + (microsecSinceY2K % 1000000 * 1000)
            )
        }
    } else {
        var dts = String.fromUtf8(val)
        dts = dts.trimAscii()
        var bc = false
        if (dts.endsWith(" BC")) {
            dts = dts[..dts.size - 3]
            bc = true
        }
        var dtstmp = formatTS(dts)
        match (dtstmp[1]) {
            case Some(v) => return v
            case _ =>
                var dt: DateTime
                for (dtfmt in pgTimestampFormats) {
                    try {
                        dt = DateTime.parse(dtstmp[0], dtfmt)
                        if (bc) {
                            let year = -dt.year + 1
                            dt = DateTime.of(year: year, month: dt.month, dayOfMonth: dt.dayOfMonth, hour: dt.hour,
                                minute: dt.minute, second: dt.second, nanosecond: dt.nanosecond, timeZone: dt.zone)
                        }
                        return dt
                    } catch (e: Exception) {
                        continue
                    }
                }
        }
        throw SqlException("cannot parse ${dts}")
    }
}

func PGtimestamptz(val: Array<Byte>, fmtCode: Int16): ToString {
    if (fmtCode == 1) {
        let microsecSinceY2K = Int64.readBigEndian(val)
        match {
            case microsecSinceY2K == infinityMicrosecondOffset => DateTime.fromUnixTimeStamp(Duration.Max)
            case microsecSinceY2K == negativeInfinityMicrosecondOffset => DateTime.fromUnixTimeStamp(Duration.Min)
            case _ => DateTime.ofEpoch(
                second: microsecFromUnixEpochToY2K / 1000000 + microsecSinceY2K / 1000000,
                nanosecond: (microsecFromUnixEpochToY2K % 1000000 * 1000) + (microsecSinceY2K % 1000000 * 1000)
            )
        }
    } else {
        var dts = String.fromUtf8(val)
        dts = dts.trimAscii()
        var bc = false
        if (dts.endsWith(" BC")) {
            dts = dts[..dts.size - 3]
            bc = true
        }
        var dtstmp = formatTS(dts)
        match (dtstmp[1]) {
            case Some(v) => return v
            case _ =>
                var dt: DateTime
                for (dtfmt in pgTimestampFormats) {
                    try {
                        dt = DateTime.parse(dtstmp[0], dtfmt)
                        if (bc) {
                            let year = -dt.year + 1
                            dt = DateTime.of(year: year, month: dt.month, dayOfMonth: dt.dayOfMonth, hour: dt.hour,
                                minute: dt.minute, second: dt.second, nanosecond: dt.nanosecond, timeZone: dt.zone)
                        }
                        return dt
                    } catch (e: Exception) {
                        continue
                    }
                }
        }
        throw SqlException("cannot parse ${dts}")
    }
}

public func bytesToDateTime(u8arr: Array<Byte>): DateTime {
    return bytesToDateTime(u8arr, 0, u8arr.size)
}

public func bytesToDateTime(u8arr: Array<Byte>, pos: Int64, count: Int64): DateTime {
    let ret = PGtimestamp(u8arr[pos..pos + count], 0)
    match (ret) {
        case v: DateTime => return v
        case _ => throw SqlException("cannot parse ${u8arr[pos..pos + count]} to DateTime")
    }
}

public func stringToDateTime(str: String): DateTime {
    let ret = PGtimestamp(str.toArray(), 0)
    match (ret) {
        case v: DateTime => return v
        case _ => throw SqlException("cannot parse ${str} to DateTime")
    }
}

public func oid2typename(datatypeOid: Int32): String {
    match (datatypeOid) {
        case 16 => "SqlBool"
        case 17 => "SqlVarBinary"
        case 18 => "SqlChar"
        case 21 => "SqlSmallInt"
        case 23 => "SqlInteger"
        case 20 => "SqlBigInt"
        case 25 => "SqlVarchar"
        case 114 => "SqlVarchar"
        case 142 => "SqlVarchar"
        case 700 => "SqlReal"
        case 701 => "SqlDouble"
        case 1700 => "SqlDecimal"
        case 1042 => "SqlChar"
        case 1043 => "SqlVarchar"
        case 1082 => "SqlDate"
        case 1083 => "SqlTime"
        case 1114 => "SqlTimestamp"
        case 1184 => "SqlTimestamp"
        case 1266 => "SqlTimeTz"
        case 3969 => "SqlVarchar"
        case 1000 => "Array<SqlBool>"
        case 1001 => "Array<SqlVarBinary>"
        case 1002 => "Array<SqlChar>"
        case 1005 => "Array<SqlBigInt>"
        case 1007 => "Array<SqlSmallInt>"
        case 1016 => "Array<SqlInteger>"
        case 1009 => "Array<SqlVarchar>"
        case 199 => "Array<SqlVarchar>"
        case 143 => "Array<SqlVarchar>"
        case 1021 => "Array<SqlReal>"
        case 1022 => "Array<SqlDouble>"
        case 1231 => "Array<SqlDecimal>"
        case 1015 => "Array<SqlVarchar>"
        case 1182 => "Array<SqlDate>"
        case 1183 => "Array<SqlTime>"
        case 1115 => "Array<SqlTimestamp>"
        case 1185 => "Array<SqlTimestamp>"
        case 1270 => "Array<SqlTimeTz>"
        //case _ => throw SqlException("not supported oid ${datatypeOid}")
        // 不认识的oid一律使用SqlVarchar替代
        case _ => "SqlVarchar"
    }
}

public let PGTypeMap: Map<Int32, (Array<Byte>, Int16) -> ToString> = HashMap<Int32, (Array<Byte>, Int16) -> ToString>(
    [
        (PGType.PGbool, PGbool),
        (PGType.PGbytea, PGbytea),
        (PGType.PGchar, PGchar),
        (PGType.PGint2, PGint2),
        (PGType.PGint4, PGint4),
        (PGType.PGint8, PGint8),
        (PGType.PGtext, PGchar),
        (PGType.PGjson, PGchar),
        (PGType.PGbpchar, PGchar),
        (PGType.PGnvarchar2, PGchar),
        (PGType.PGxml, PGchar),
        (PGType.PGfloat4, PGfloat4),
        (PGType.PGfloat8, PGfloat8),
        (PGType.PGnumeric, PGDecimal),
        (PGType.PGvarchar, PGchar),
        (PGType.PGdate, PGdate),
        (PGType.PGtime, PGtime),
        (PGType.PGtimestamp, PGtimestamp),
        (PGType.PGtimestamptz, PGtimestamptz),
        (PGType.PGtimetz, PGtimetz)
    ]
)

public func getSqlArrayValue<T>(val: Array<Byte>, fmtCode: Int16): Array<?T> {
    let ah = ArrayHeader()
    var rp = ah.decode(val)
    let elementCount = cardinality(ah.dimensions)
    let elems = ArrayList<?T>()
    for (i in 0..elementCount) {
        let elemLen = Int64(Int32.readBigEndian(val[rp..]))
        rp += 4
        if (elemLen >= 0) {
            match (PGTypeMap.get(ah.elementOID)) {
                case Some(fromFunc) =>
                    let elem = fromFunc(val[rp..rp + elemLen], fmtCode)
                    match (elem) {
                        case v: T => elems.add(v)
                        case _ => throw SqlException("can not convert ${ah.elementOID} value[${elem}] to T")
                    }
                case None => throw SqlException("not supported oid ${ah.elementOID}")
            }
            rp += elemLen
        } else {
            elems.add(None)
        }
    }
    return elems.toArray()
}
