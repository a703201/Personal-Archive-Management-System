package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.io.*
import std.time.*
import std.convert.*
import cangjie_tpc::opengauss.utils.*

func inputStreamToStringMax1024(inputStream: InputStream): String {
    var buf = Array<Byte>(1024, repeat: 0)
    var readlen = inputStream.read(buf)
    return bytesToString(buf, 0, readlen)
}

func inputStreamToStringMax1024(inputStream: ?InputStream): String {
    match (inputStream) {
        case Some(v) =>
            var buf = Array<Byte>(1024, repeat: 0)
            var readlen = v.read(buf)
            return bytesToString(buf, 0, readlen)
        case _ => return "<NONE>"
    }
}

func intervalToString(duration: Duration) {
    var seconds = duration.toSeconds()
    let days = seconds / Duration.day.toSeconds()
    seconds -= days * Duration.day.toSeconds()
    let hours = seconds / Duration.hour.toSeconds()
    seconds -= hours * Duration.hour.toSeconds()
    let minutes = seconds / Duration.minute.toSeconds()
    seconds -= minutes * Duration.minute.toSeconds()
    return "${days} days ${hours}:${minutes}:${seconds}"
}

func opBytesToString(u8arr: ?Array<UInt8>): String {
    match (u8arr) {
        case Some(v) => return bytesToString(v)
        case _ => return "<NONE>"
    }
}

func doubleEquals(double1: Float64, double2: Float64): Bool {
    return (double1 == double2) || ((double2 - 0.01 < double1) && (double1 < double2 + 0.01)) || ((double1 - 0.01 <
        double2) && (double2 < double1 + 0.01))
}

func getString(str: ?String): String {
    match (str) {
        case Some(v) => return v
        case _ => return "<NONE>"
    }
}

func getString(b: ?Bool): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?UInt8): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?Int8): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?UInt16): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?Int16): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?UInt32): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?Int32): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?Int64): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?UInt64): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getString(b: ?Float32): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getFloat32(b: ?Float32): Float32 {
    match (b) {
        case Some(v) => return v
        case _ => return 0.0f32
    }
}

func getString(b: ?Float64): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getFloat64(b: ?Float64): Float64 {
    match (b) {
        case Some(v) => return v
        case _ => return 0.0f64
    }
}

func getString(b: ?DateTime): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getDateTime(b: ?DateTime): DateTime {
    match (b) {
        case Some(v) => return v
        case _ => return DateTime.ofEpoch(second: 0, nanosecond: 0)
    }
}

func getString(b: ?Duration): String {
    match (b) {
        case Some(v) => return v.toString()
        case _ => return "<NONE>"
    }
}

func getDuration(b: ?Duration): Duration {
    match (b) {
        case Some(v) => return v
        case _ => return Duration.second * 0
    }
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
        throw SqlException("cannot parse duration ${str}: ${ex.toString()}")
    }
    return ret
}


@Test
func testTypeTestUtils(): Unit {
    @Assert("<NONE>" == getString(Option<String>.None))
    @Assert("true" == getString(Some(true)))
    @Assert("<NONE>" == getString(Option<Bool>.None))
    @Assert("1" == getString(Some(1u8)))
    @Assert("<NONE>" == getString(Option<UInt8>.None))    
    @Assert("1" == getString(Some(1i8)))
    @Assert("<NONE>" == getString(Option<Int8>.None))
    @Assert("1" == getString(Some(1u16)))
    @Assert("<NONE>" == getString(Option<UInt16>.None))
    @Assert("1" == getString(Some(1i16)))
    @Assert("<NONE>" == getString(Option<Int16>.None))
    @Assert("1" == getString(Some(1i32)))
    @Assert("<NONE>" == getString(Option<Int32>.None))
    @Assert("1" == getString(Some(1u32)))
    @Assert("<NONE>" == getString(Option<UInt32>.None))
    @Assert("1" == getString(Some(1i64)))
    @Assert("<NONE>" == getString(Option<Int64>.None))
    @Assert("1" == getString(Some(1u64)))
    @Assert("<NONE>" == getString(Option<UInt64>.None))
    @Assert("1.100000" == getString(Some(1.1f32)))
    @Assert("<NONE>" == getString(Option<Float32>.None))
    @Assert("1.100000" == getString(Some(1.1f64)))
    @Assert("<NONE>" == getString(Option<Float64>.None))
    @Assert(1.1f32 == getFloat32(Some(1.1f32)))
    @Assert(0.0f32 == getFloat32(Option<Float32>.None))
    @Assert(1.1f64 == getFloat64(Some(1.1f64)))
    @Assert(0.0f64 == getFloat64(Option<Float64>.None))
    @Assert(DateTime.ofEpoch(second: 1, nanosecond: 0) == getDateTime(Some(DateTime.ofEpoch(second: 1, nanosecond: 0))))
    @Assert(DateTime.ofEpoch(second: 0, nanosecond: 0) == getDateTime(Option<DateTime>.None))
    @Assert(Duration.second * 1 == getDuration(Some(Duration.second * 1)))
    @Assert(Duration.second * 0 == getDuration(Option<Duration>.None))
    @Assert("<NONE>" == getString(Option<DateTime>.None))
    @Assert("<NONE>" == getString(Option<Duration>.None))
    @Assert(doubleEquals(0.1, 0.1))
    @Assert("<NONE>" == inputStreamToStringMax1024(Option<InputStream>.None))
    @Assert("<NONE>" == opBytesToString(Option<Array<UInt8>>.None))

    let v = "abc"
    let input = ByteBuffer(v.toArray())
    let input_stream = BufferedInputStream(input)
    @Assert(v == inputStreamToStringMax1024(Some(input_stream)))
    @Assert(v == opBytesToString(Some(v.toArray())))
}