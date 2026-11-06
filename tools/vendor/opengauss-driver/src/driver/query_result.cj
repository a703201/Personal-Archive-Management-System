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
package cangjie_tpc::opengauss.driver

import std.collection.*
internal import std.convert.*
import std.database.sql.*
import std.io.*
import std.math.numeric.Decimal
import std.sync.*
import std.time.*
import cangjie_tpc::opengauss.pgconn.*
import cangjie_tpc::opengauss.proto3.*
import cangjie_tpc::opengauss.slog
internal import cangjie_tpc::opengauss.utils.formatTS
import cangjie_tpc::opengauss.utils.bytesToString
public import cangjie_tpc::opengauss.pgconn.{SqlArray, bytesToDateTime, stringToDateTime}

private let DECIMAL_ZERO = Decimal('0')
public class Rows <: QueryResult {
    let rr: ResultReader
    let closed = AtomicBool(false)

    let logger = slog.Default()

    public init(rr: ResultReader) {
        this.rr = rr
    }

    /*
     * 判断资源是否关闭
     * 返回值 Bool - 如果已经关闭返回 true，否则返回 false
     */
    public func isClosed(): Bool {
        return closed.load()
    }

    /*
     * 关闭资源
     */
    public func close(): Unit {
        if (isClosed()) {
            return
        }
        closed.store(true)
        rr.close()
    }

    /*
     * 返回 SELECT 结果列个数
     */
    public prop columnInfos: Array<ColumnInfo> {
        get() {
            let cis = ArrayList<ColumnInfo>(rr.columns.size)
            for (fd in rr.columns) {
                cis.add(fd2column(fd))
            }
            return cis.toArray()
        }
    }    

    @Deprecated
    public func next(_: Array<SqlDbType>): Bool {
        throw UnsupportedException("Deprecated method")
    }

    /*
     * 向后移动一行，必须先调用一次 next 才能移动到第一行，第二次调用移动到第二行，依此类推。
     * 当返回 false 时结束。当是 false 时调用其它 get 函数会抛异常。
     * 返回值 Bool - 存在下一行则返回true，否则返回false
     */
    public func next(): Bool {
        if (isClosed()) {
            return false
        }
        if (rr.nextRow() == false) {
            this.close()
            return false
        }

        return true
    }

    public func get<T>(index: Int): T {
        getOrNull<T>(index).getOrThrow()
    }

    public func getOrNull<T>(index: Int): ?T {
        if (index >= rr.values.size || 0 > index) {
            throw SqlException("index: ${index} out of bounds: ${rr.values.size}")
        }

        try {
            var res: Option<T> = None
            fillData(res, rr.values[index], rr.columns[index], index)
        } catch (e: SqlException) {
            // sql异常直接抛出
            throw e
        } catch (e: Exception) {
            // 普通异常转换为sql异常抛出
            var err = ""
            if (rr.columns.size > index) {
                err = "cannot get the value of the param ${index} and the column is ${rr.columns[index].name}. the value is ${bytesToString(rr.values[index].val, true)}. fillData error: ${e.toString()}"
            } else {
                err = "cannot get the value of the param ${index}. the value is ${bytesToString(rr.values[index].val, true)}. fillData error: ${e.toString()}"
            }
            logger.error("${err}")
            throw SqlException(err)
        }
    }

    func fillData<T>(outer: ?T, df: DataField, fd: FieldDescription, paramindex: Int64): ?T {
        var res: ?T = None

        if (df.valLen == -1) {
            match (outer) {
                case v: Option<Bool> => res = None
                case v: Option<Array<Byte>> => res = None
                case v: Option<InputStream> => res = None
                case v: Option<Int8> => res = None
                case v: Option<Int16> => res = None
                case v: Option<Int32> => res = None
                case v: Option<Int64> => res = None
                case v: Option<Float32> => res = None
                case v: Option<Float64> => res = None
                case v: Option<Decimal> => res = None
                case v: Option<DateTime> => res = None
                case v: Option<Duration> => res = None
                case v: Option<String> => 
                    if (0 < df.val.size) {
                        res = bytesToString(df.val) as T
                    } else {
                        res = None
                    }                    
                case _ => throw SqlException(
                    "not supported type of param ${paramindex} and the column is ${fd.name}")
            }
            return res
        }
        var dfval = df.val
        match (fd.datatypeOid) {
            case 0x58 =>
                // blob，因为返回是字符串，因此需要把两个字节合并为一个字节
                dfval = convertBlob(df.val)
            case 0x56 =>
                // raw，因为返回是字符串，因此需要把两个字节合并为一个字节
                dfval = convertBlob(df.val)
            case 0x11 =>
                // bytea，因为返回是字符串，因此需要把两个字节合并为一个字节
                dfval = convertBytea(df.val)
            case _ => ()
        }
        match (outer) {
            case v: Option<String> =>
                res = bytesToString(dfval) as T
                return res
            case _ => ()
        }
        match (fd.datatypeOid) {
            case 1000 | 1001 | 1002 | 1005 | 1007 | 1016 | 1009 | 199 | 143 | 1021 | 1022 | 1015 | 1182 | 1183 | 1115 | 1185 | 1270 =>
                match (outer) {
                    case v: SqlArray<?Bool> => res = getSqlArrayValue<Bool>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Float32> => res = getSqlArrayValue<Float32>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Float64> => res = getSqlArrayValue<Float64>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Int8> => res = getSqlArrayValue<Int8>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Int16> => res = getSqlArrayValue<Int16>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Int32> => res = getSqlArrayValue<Int32>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Int64> => res = getSqlArrayValue<Int64>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?String> => res = getSqlArrayValue<String>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?Array<UInt8>> => res = getSqlArrayValue<Array<UInt8>>(dfval, fd.fmtCode) as T
                    case v: SqlArray<?DateTime> => res = getSqlArrayValue<DateTime>(dfval, fd.fmtCode) as T
                    case _ => throw SqlException(
                        "not supported type of param ${paramindex} and the column is ${fd.name}")
                }
                return res
            case _ => ()
        }
        match (PGTypeMap.get(fd.datatypeOid)) {
            case Some(fromFunc) =>
                let v = fromFunc(dfval, fd.fmtCode)
                match (v) {
                    case value: Bool => match (outer) {
                        case v: Option<Bool> => res = (value as T) ?? throw Exception()
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Int8> =>
                            if (value) {
                                res = 1i8 as T
                            } else {
                                res = 0i8 as T
                            }
                        case v: Option<Int16> =>
                            if (value) {
                                res = 1i16 as T
                            } else {
                                res = 0i16 as T
                            }
                        case v: Option<Int32> =>
                            if (value) {
                                res = 1i32 as T
                            } else {
                                res = 0i32 as T
                            }
                        case v: Option<Int64> =>
                            if (value) {
                                res = 1i64 as T
                            } else {
                                res = 0i64 as T
                            }
                        case v: Option<Float32> =>
                            if (value) {
                                res = 1.0f32 as T
                            } else {
                                res = 0.0f32 as T
                            }
                        case v: Option<Float64> =>
                            if (value) {
                                res = 1.0f64 as T
                            } else {
                                res = 0.0f64 as T
                            }
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: String => match (outer) {
                        case v: Option<String> => res = value as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(dfval.toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = dfval as T
                        case v: Option<Bool> => res = parseBool(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Int8> => res = Int8.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Int16> => res = Int16.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Int32> => res = Int32.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Int64> => res = Int64.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Float32> => res = Float32.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<Float64> => res = Float64.parse(bytesToString(dfval).trimAscii()) as T
                        case v: Option<DateTime> => res = bytesToDateTime(dfval) as T
                        case v: Option<Duration> => res = parseDurationStr(bytesToString(dfval)) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Array<Byte> => match (outer) {
                        case v: Option<Array<Byte>> => res = value as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: InputStream => match (outer) {
                        case v: Option<InputStream> => res = value as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Int8 => match (outer) {
                        case v: Option<Int8> => res = value as T
                        case v: Option<Int16> => res = Int16(value) as T
                        case v: Option<Int32> => res = Int32(value) as T
                        case v: Option<Int64> => res = Int64(value) as T
                        case v: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case v: Option<Float32> => res = Float32(value) as T
                        case v: Option<Float64> => res = Float64(value) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Int16 => match (outer) {
                        case v: Option<Int8> => res = Int8(value) as T
                        case v: Option<Int16> => res = value as T
                        case v: Option<Int32> => res = Int32(value) as T
                        case v: Option<Int64> => res = Int64(value) as T
                        case v: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case v: Option<Float32> => res = Float32(value) as T
                        case v: Option<Float64> => res = Float64(value) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Int32 => match (outer) {
                        case v: Option<Int8> => res = Int8(value) as T
                        case v: Option<Int16> => res = Int16(value) as T
                        case v: Option<Int32> => res = value as T
                        case v: Option<Int64> => res = Int64(value) as T
                        case v: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case v: Option<Float32> => res = Float32(value) as T
                        case v: Option<Float64> => res = Float64(value) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Int64 => match (outer) {
                        case v: Option<Int8> => res = Int8(value) as T
                        case v: Option<Int16> => res = Int16(value) as T
                        case v: Option<Int32> => res = Int32(value) as T
                        case v: Option<Int64> => res = value as T
                        case v: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case v: Option<Float32> => res = Float32(value) as T
                        case v: Option<Float64> => res = Float64(value) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Float32 => match (outer) {
                        case v: Option<Int8> => res = Int8(value) as T
                        case v: Option<Int16> => res = Int16(value) as T
                        case v: Option<Int32> => res = Int32(value) as T
                        case v: Option<Int64> => res = Int64(value) as T
                        case v: Option<Float32> => res = value as T
                        case _: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0.0f32) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case v: Option<Float64> => res = Float64(value) as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Float64 => match (outer) {
                        case v: Option<Int8> => res = Int8(value) as T
                        case v: Option<Int16> => res = Int16(value) as T
                        case v: Option<Int32> => res = Int32(value) as T
                        case v: Option<Int64> => res = Int64(value) as T
                        case v: Option<Float32> => res = Float32(value) as T
                        case v: Option<Float64> => res = value as T
                        case _: Option<Decimal> => res = Decimal(value) as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == 0.0f64) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Decimal => match(outer){
                        case v: Option<Float32> => res = value.toFloat32() as T
                        case v: Option<Float64> => res = value.toFloat64() as T
                        case _: Option<Decimal> => res = value as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case v: Option<Bool> =>
                            if (value == DECIMAL_ZERO) {
                                res = false as T
                            } else {
                                res = true as T
                            }
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: DateTime => match (outer) {
                        case v: Option<DateTime> => res = value as T
                        case v: Option<String> => res = value.format("yyyy-MM-dd HH:mm:ss.SSO") as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.format("yyyy-MM-dd HH:mm:ss.SSO").toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.format("yyyy-MM-dd HH:mm:ss.SSO").toArray() as T
                        case _ => throw SqlException(
                            "not supported type of param ${paramindex} and the column is ${fd.name}")
                    }
                    case value: Duration => match (outer) {
                        case v: Option<Duration> => res = value as T
                        case v: Option<String> => res = value.toString() as T
                        case v: Option<InputStream> =>
                            var bas = ByteBuffer()
                            bas.write(value.toString().toArray())
                            res = bas as T
                        case v: Option<Array<Byte>> => res = value.toString().toArray() as T
                        case _ => throw SqlException(
                            "not supported typeof param ${paramindex} and the column is ${fd.name}")
                    }
                    case _ => throw SqlException(
                        "not supported type of param ${paramindex} and the column is ${fd.name}")
                }
            // 不知道的类型直接通过string来解析
            case _ => match (outer) {
                case v: SqlArray<?Bool> => res = getSqlArrayValue<Bool>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Float32> => res = getSqlArrayValue<Float32>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Float64> => res = getSqlArrayValue<Float64>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Int8> => res = getSqlArrayValue<Int8>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Int16> => res = getSqlArrayValue<Int16>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Int32> => res = getSqlArrayValue<Int32>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Int64> => res = getSqlArrayValue<Int64>(dfval, fd.fmtCode) as T
                case v: SqlArray<?String> => res = getSqlArrayValue<String>(dfval, fd.fmtCode) as T
                case v: SqlArray<?Array<UInt8>> => res = getSqlArrayValue<Array<UInt8>>(dfval, fd.fmtCode) as T
                case v: SqlArray<?DateTime> => res = getSqlArrayValue<DateTime>(dfval, fd.fmtCode) as T
                case v: Option<String> => res = bytesToString(dfval) as T            
                case v: Option<InputStream> =>
                    var bas = ByteBuffer()
                    bas.write(dfval.toArray())
                    res = bas as T                
                case v: Option<Array<Byte>> => res = dfval as T
                case v: Option<Bool> => res = parseBool(bytesToString(dfval).trimAscii()) as T
                case v: Option<Int8> => res = Int8.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<Int16> => res = Int16.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<Int32> => res = Int32.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<Int64> => res = Int64.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<Float32> => res = Float32.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<Float64> => res = Float64.parse(bytesToString(dfval).trimAscii()) as T
                case v: Option<DateTime> => res = bytesToDateTime(dfval) as T
                case v: Option<Duration> => res = parseDurationStr(bytesToString(dfval)) as T
                case _ => throw SqlException(
                    "not supported type of param ${paramindex} and the column is ${fd.name}")
            }
        }

        return res
    }

    func convertBlob(u8arr: Array<UInt8>): Array<UInt8> {
        var ret = Array<UInt8>(u8arr.size / 2, repeat: 0u8)
        var index = 0
        var value = 0u8
        for (u8 in u8arr) {
            value = convertByte(u8) | (value << 4)
            index++
            if (index % 2 == 0) {
                ret[index / 2 - 1] = value
            }
        }
        return ret
    }

    func convertBytea(u8arr: Array<UInt8>): Array<UInt8> {
        var ret = Array<UInt8>((u8arr.size - 2) / 2, repeat: 0u8)
        var index = 0
        var value = 0u8
        if (u8arr.size > 2) {
            for (u8 in u8arr[2..]) {
                value = convertByte(u8) | (value << 4)
                index++
                if (index % 2 == 0) {
                    ret[index / 2 - 1] = value
                }
            }
        }
        return ret
    }

    func convertByte(u8: UInt8): UInt8 {
        match (u8) {
            case b'0' => return 0
            case b'1' => return 1
            case b'2' => return 2
            case b'3' => return 3
            case b'4' => return 4
            case b'5' => return 5
            case b'6' => return 6
            case b'7' => return 7
            case b'8' => return 8
            case b'9' => return 9
            case b'A' => return 10u8
            case b'B' => return 11u8
            case b'C' => return 12u8
            case b'D' => return 13u8
            case b'E' => return 14u8
            case b'F' => return 15u8
            case b'a' => return 10u8
            case b'b' => return 11u8
            case b'c' => return 12u8
            case b'd' => return 13u8
            case b'e' => return 14u8
            case b'f' => return 15u8
            case _ => return u8
        }
    }

    func parseBool(str: String): Bool {
        var ret = false
        try {
            ret = Bool.parse(str.trimAscii())
        } catch (ex: Exception) {
            if (str == "1") {
                ret = true
            } else if (str == "0") {
                ret = false
            } else {
                throw ex
            }
        }
        return ret
    }

    func parseDurationStr(str: String): Duration {
        try {
            return parseDurationStr1(str)
        } catch (ex: Exception) {
        }
        try {
            return parseDurationStr2(str)
        } catch (ex: Exception) {
        }
        throw Exception("cannot parse duration string: ${str}")
    }

    func parseDurationStr1(str: String): Duration {
        // 格式: XXX year(s) XXX mon(s) XXX day(s) HH:mm:ss
        var ret = Duration.second * 0
        try {
            // year
            let yearsStr = "years"
            let yearStr = "year"
            var year = 0
            var yearsIndexOption = str.indexOf(yearsStr)
            var yearsIndex = -1
            var shortstr = false
            match (yearsIndexOption) {
                case Some(v) => yearsIndex = v
                case None => ()
            }
            if (yearsIndex == -1) {
                yearsIndexOption = str.indexOf(yearStr)
                match (yearsIndexOption) {
                    case Some(v) =>
                        shortstr = true
                        yearsIndex = v
                    case None => ()
                }
            }
            var tmpstr = str
            if (yearsIndex != -1) {
                year = Int64.parse(str[0..Int64(yearsIndex)].trimAscii())
                if (shortstr) {
                    tmpstr = str[Int64(yearsIndex + yearStr.size)..]
                } else {
                    tmpstr = str[Int64(yearsIndex + yearsStr.size)..]
                }
            }

            // month
            let monthsStr = "mons"
            let monthStr = "mon"
            var month = 0
            var monthsIndexOption = tmpstr.indexOf(monthsStr)
            var monthsIndex = -1
            shortstr = false
            match (monthsIndexOption) {
                case Some(v) => monthsIndex = v
                case None => ()
            }
            if (monthsIndex == -1) {
                monthsIndexOption = tmpstr.indexOf(monthStr)
                match (monthsIndexOption) {
                    case Some(v) =>
                        shortstr = true
                        monthsIndex = v
                    case None => ()
                }
            }
            var tmpstr2 = tmpstr
            if (monthsIndex != -1) {
                month = Int64.parse(tmpstr[0..Int64(monthsIndex)].trimAscii())
                if (shortstr) {
                    tmpstr2 = tmpstr[Int64(monthsIndex + monthStr.size)..]
                } else {
                    tmpstr2 = tmpstr[Int64(monthsIndex + monthsStr.size)..]
                }
            }

            // day
            tmpstr2 = tmpstr2.trimAscii()
            let daysStr = "days"
            let dayStr = "day"
            var daysIndexOption = tmpstr2.indexOf(daysStr)
            var daysIndex = -1
            shortstr = false
            match (daysIndexOption) {
                case Some(v) => daysIndex = v
                case None => ()
            }
            if (daysIndex == -1) {
                daysIndexOption = tmpstr2.indexOf(dayStr)
                match (daysIndexOption) {
                    case Some(v) =>
                        shortstr = true
                        daysIndex = v
                    case None => ()
                }
            }

            // time
            if (daysIndex == -1) {
                if (tmpstr2.size > 0) {
                    var time = DateTime.parse("2000-01-01 ${tmpstr2.trimAscii()}", "yyyy-MM-dd HH:mm:ss")
                    ret = Duration.hour * time.hour + Duration.minute * time.minute + Duration.second * time.second
                }
            } else {
                let days = Int64.parse(tmpstr2[0..Int64(daysIndex)].trimAscii())
                var timestr = ""
                if (shortstr) {
                    timestr = tmpstr2[daysIndex + dayStr.size..tmpstr2.size].trimAscii()
                } else {
                    timestr = tmpstr2[daysIndex + daysStr.size..tmpstr2.size].trimAscii()
                }
                if (timestr.size > 0) {
                    var time = DateTime.parse("2000-01-01 ${timestr}", "yyyy-MM-dd HH:mm:ss")
                    ret = Duration.day * days + Duration.hour * time.hour + Duration.minute * time.minute +
                        Duration.second * time.second
                } else {
                    ret = Duration.day * days
                }
            }

            // 没找到ISO-8601中一年几天和一月几天的描述，暂时以一年365天、一个月30天来计算
            ret += year * 365 * Duration.day + month * 30 * Duration.day
        } catch (ex: Exception) {
            logger.debug(ex.toString())
            throw SqlException("cannot parse duration ${str}: ${ex.toString()}")
        }
        return ret
    }

    func parseDurationStr2(str: String): Duration {
        // 格式: Pyear-month-dayThour:minute:second
        var ret = Duration.second
        try {
            let pStr = "P"
            var pIndexOption = str.indexOf(pStr)
            var pIndex = -1
            match (pIndexOption) {
                case Some(v) => pIndex = v
                case None => ()
            }
            let tStr = "T"
            var tIndexOption = str.indexOf(tStr)
            var tIndex = -1
            match (tIndexOption) {
                case Some(v) => tIndex = v
                case None => ()
            }
            if ((pIndex == -1) && (tIndex == -1)) {
                throw SqlException("the format is not a PX-X-XTX:X:X interval format")
            }
            var year = 0i32
            var month = 0i32
            var day = 0i32
            var hour = 0i32
            var minute = 0i32
            var second = 0i32
            if (pIndex != -1) {
                var ymd = str
                if (tIndex != -1) {
                    ymd = ymd[0..Int64(tIndex)]
                }
                ymd = ymd[Int64(pIndex + 1)..].trimAscii()
                var ymdarr = ymd.split("-", 3)
                if (ymdarr.size > 0) {
                    year = Int32.parse(ymdarr[0].trimAscii())
                }
                if (ymdarr.size > 1) {
                    month = Int32.parse(ymdarr[1].trimAscii())
                }
                if (ymdarr.size > 2) {
                    day = Int32.parse(ymdarr[2].trimAscii())
                }
            }
            if (tIndex != -1) {
                var hms = str[Int64(tIndex + 1)..].trimAscii()
                var hmsarr = hms.split(":", 3)
                if (hmsarr.size > 0) {
                    hour = Int32.parse(hmsarr[0].trimAscii())
                }
                if (hmsarr.size > 1) {
                    minute = Int32.parse(hmsarr[1].trimAscii())
                }
                if (hmsarr.size > 2) {
                    second = Int32.parse(hmsarr[2].trimAscii())
                }
            }
            // 没找到ISO-8601中一年几天和一月几天的描述，暂时以一年365天、一个月30天来计算
            ret = Duration.day * Int64(year) * 365 + Duration.day * Int64(month) * 30 + Duration.day * Int64(day) +
                Duration.hour * Int64(hour) + Duration.minute * Int64(minute) + Duration.second * Int64(second)
        } catch (ex: Exception) {
            logger.debug(ex.toString())
            throw SqlException("cannot parse duration ${str}: ${ex.toString()}")
        }
        return ret
    }
}
