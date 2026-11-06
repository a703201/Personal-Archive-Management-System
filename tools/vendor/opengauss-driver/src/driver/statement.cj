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

import std.binary.*
import std.collection.*
import std.convert.*
import std.database.sql.*
internal import std.io.*
import std.sync.*
internal import std.time.*
internal import std.convert.*
import cangjie_tpc::opengauss.pgconn.*
import cangjie_tpc::opengauss.proto3.*
import cangjie_tpc::opengauss.interx.*
import cangjie_tpc::opengauss.utils.*

let stmtIdSeed = AtomicInt64(1)

public class Stmt <: Statement {
    let stDesc: StmtDescription
    let cn: PgConn
    let name: String
    let stmtId: Int64
    var execstart = false
    var values: Array<BindParameter>
    var paramCount: Int64
    var isParameterInit: Array<Bool>

    let closed = AtomicBool(false)

    private var rows = None<Rows>

    public init(stDesc: StmtDescription, cn: PgConn) {
        this.stDesc = stDesc
        this.cn = cn
        this.stmtId = stmtIdSeed.fetchAdd(1)
        this.name = "${DateTime.now()} ${stmtId}"
        stDesc.localname = name
        this.paramCount = Int64(this.stDesc.paramCount)

        this.values = Array<BindParameter>(paramCount, {x:Int64 => BindParameter()})
        this.isParameterInit = Array<Bool>(paramCount, {x:Int64 => false})
    }

    public func getStmtId(): Int64 {
        return stmtId
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
        try {
            closed.store(true)
            this.rows?.close()
            cn.closeStmt(stDesc.name)
        } finally {
            cn.unlock(name)
        }
    }

    public func setOption(key: String, value: String): Unit {
        // 目前没有针对statement的option
    }

    /*
     * 预执行 sql 语句中，占位的参数个数
     */
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            // 由于加上这段逻辑获取字段信息后，silo会报异常“prepare sql argument size is 4, not same as sql config arg num:0”，因此暂时不获取字段信息
            // if (!stDesc.fieldsgot) {
            //     // 如果还没有获取到字段描述消息，获取字段描述消息
            //     if (execstart) {
            //         throw SqlException("cannot get the parameter columns after query or update")
            //     }
            //     getFields()
            // }
            let cis = ArrayList<ColumnInfo>(stDesc.fields.size)
            for (fd in stDesc.fields) {
                cis.add(fd2column(fd))
            }
            return cis.toArray()
        }
    }

    public func update(): UpdateResult {
        if (isClosed()) {
            throw SqlException("the statement is closed")
        }
        checkIfParamIsInit()

        while (true) {
            // 锁连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
            match (cn.lock(name)) {
                case Some(v) =>
                    logger.debug("${v.message}. sleep 1 second and try again")
                    sleep(Duration.second)
                case _ => break
            }
        }

        execstart = true
        var interceptorenabled = StmtInterceptorManager.instance().isInterceptorEnable()
        var context = Option<StmtInterceptorContext>.None
        if (interceptorenabled) {
            var threadid = getCurrentThreadId()
            var pgConnContext = PgConnInterceptorContext(cn.getConnId(), threadid, cn.getHost(), cn.getPort())
            context = StmtInterceptorContext(pgConnContext, stmtId, stDesc.sql)
        }
        try {
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().updateStart(v)
                case _ => ()
            }
            match (stDesc.parse) {
                case Some(v) =>
                    if (stDesc.name.isEmpty()) {
                        // 匿名语句总是发送，因为Parse消息、transaction等消息都有可能关闭匿名语句，因此总是发送匿名语句
                        cn.send(v)
                    } else {
                        // 命名语句只发送一次
                        cn.send(v)
                        stDesc.parse = Option<Parse>.None
                    }
                case _ => ()
            }
            let rr = cn.execPrepared(stDesc, values.toArray())
            let (cmdtag, err) = rr.close()
            if (err != "") {
                throw SqlException(err)
            }
            var lastInsertId = 0
            if (rr.values.size == 1) {
                let df = rr.values[0]
                if (rr.columns[0].fmtCode == 0) {
                    lastInsertId = Int64.tryParse(String.fromUtf8(df.val)) ?? 0
                } else {
                    lastInsertId = match (rr.columns[0].datatypeOid) {
                        case 23 => // int4
                            Int64(Int32.readBigEndian(df.val))
                        case _ => 0
                    }
                }
            }
            var ra = RowsAffected(rr.rows(), lastInsertId)
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().updateSuccess(v)
                case _ => ()
            }
            return ra
        } catch (ex: Exception) {
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().updateException(v, ex)
                case _ => ()
            }
            throw ex
        }
    }

    public func query(): QueryResult {
        if (isClosed()) {
            throw SqlException("the statement is closed")
        }
        checkIfParamIsInit()

        while (true) {
            // 锁连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
            match (cn.lock(name)) {
                case Some(v) =>
                    logger.debug("${v.message}. sleep 1 second and try again")
                    sleep(Duration.second)
                case _ => break
            }
        }
        execstart = true
        var interceptorenabled = StmtInterceptorManager.instance().isInterceptorEnable()
        var context = Option<StmtInterceptorContext>.None
        if (interceptorenabled) {
            var threadid = getCurrentThreadId()
            var pgConnContext = PgConnInterceptorContext(cn.getConnId(), threadid, cn.getHost(), cn.getPort())
            context = StmtInterceptorContext(pgConnContext, stmtId, stDesc.sql)
        }
        try {
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().queryStart(v)
                case _ => ()
            }
            match (stDesc.parse) {
                case Some(v) =>
                    if (stDesc.name.isEmpty()) {
                        // 匿名语句总是发送，因为Parse消息、transaction等消息都有可能关闭匿名语句，因此总是发送匿名语句
                        cn.send(v)
                    } else {
                        // 命名语句只发送一次
                        cn.send(v)
                        stDesc.parse = Option<Parse>.None
                    }
                case _ => ()
            }
            let rr = cn.execPrepared(stDesc, values.toArray())
            var qa = Rows(rr)
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().querySuccess(v)
                case _ => ()
            }
            this.rows = qa
            return qa
        } catch (ex: Exception) {
            match (context) {
                case Some(v) => StmtInterceptorManager.instance().queryException(v, ex)
                case _ => ()
            }
            throw ex
        }
    }

    // 当前没有用到，先注释掉
    // private func getFields(): Unit {
    //     if (isClosed()) {
    //         throw SqlException("the statement is closed")
    //     }
    //     while (true) {
    //         // 锁连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
    //         match (cn.lock(name)) {
    //             case Some(v) =>
    //                 logger.debug("${v.message}. sleep 1 second and try again")
    //                 sleep(Duration.second)
    //             case _ => break
    //         }
    //     }
    //     try {
    //         match (stDesc.parse) {
    //             case Some(v) =>
    //                 if (stDesc.name.isEmpty()) {
    //                     // 匿名语句总是发送，因为Parse消息、transaction等消息都有可能关闭匿名语句，因此总是发送匿名语句
    //                     cn.send(v)
    //                 } else {
    //                     // 命名语句只发送一次
    //                     cn.send(v)
    //                     stDesc.parse = Option<Parse>.None
    //                 }
    //             case _ => ()
    //         }
    //         let desc = Describe(b'S', stDesc.name)
    //         cn.send(desc)
    //         let sync = Sync()
    //         cn.send(sync)
    //         cn.flush()
    //         stDesc.fieldsgot = true

    //         while (true) {
    //             let m = cn.receiveMessage()
    //             if (logger.level.ge(LogLevel.Debug)) {
    //                 logger.debug("getfields recv ${m}")
    //             }
    //             match (m) {
    //                 case Ok(msg) => match (msg) {
    //                     case bm: ParameterDescription => stDesc.paramOIDs = bm.paramOids
    //                     case bm: RowDescription => stDesc.fields = bm.fields
    //                     case bm: ErrorResponse =>
    //                         var ex = SqlException(bm.getMessage())
    //                         throw ex
    //                     case bm: ReadyForQuery => break
    //                     case _ => ()
    //                 }
    //                 case Err(e) => throw e
    //             }
    //         }
    //     } finally {
    //         cn.unlock(name)
    //     }
    // }

    @Deprecated
    public override func query(_: Array<SqlDbType>): QueryResult {
        throw UnsupportedException("Deprecated method")
    }

    @Deprecated
    public override func update(_: Array<SqlDbType>): UpdateResult {
        throw UnsupportedException("Deprecated method")
    }

    public func set<T>(index: Int, value: T): Unit {
        if (index >= paramCount || 0 > index) {
            throw SqlException("index: ${index} out of bounds: ${paramCount}")
        }

        let oid = 0i32 //stDesc.paramOIDs.size>i?stDesc.paramOIDs[index]:0i32
        match (value) {
            case p: String => values[index] = bindValue(value, oid)
            case p: Array<Byte> => values[index] = bindValue(value, oid)
            case p: InputStream => values[index] = bindValue(value, oid)
            case p: Bool => values[index] = bindValue(value, oid)
            case p: Int8 => values[index] = bindValue(value, oid)
            case p: Int16 => values[index] = bindValue(value, oid)
            case p: Int32 => values[index] = bindValue(value, oid)
            case p: Int64 => values[index] = bindValue(value, oid)
            case p: Float32 => values[index] = bindValue(value, oid)
            case p: Float64 => values[index] = bindValue(value, oid)
            case p: DateTime => values[index] = bindValue(value, oid)
            case p: Duration => values[index] = bindValue(value, oid)
            case _ => throw SqlException("not supported type ${stDesc.name}")
        }
        this.isParameterInit[index] = true
    }

    public func setNull(index: Int): Unit {
        if (index >= paramCount || 0 > index) {
            throw SqlException("index: ${index} out of bounds: ${paramCount}")
        }

        values[index] = BindParameter(-1, [])
        this.isParameterInit[index] = true
    }

    func bindValue(value: Any, oid: Int32): BindParameter {
        // bindValue目前都使用String的方式
        match (value) {
            case v: Bool =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val: UInt8
                    if (v) {
                        val = 1
                    } else {
                        val = 0
                    }
                    let len: Int32 = 1
                    return BindParameter(len, [val], true)
                } else {
                    // 文本传输
                    let val: UInt8
                    if (v) {
                        val = 1
                    } else {
                        val = 0
                    }
                    let valstr = val.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Int8 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let len: Int32 = 1
                    return BindParameter(len, [UInt8(v)], true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Int16 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toBeBytes()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Int32 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toBeBytes()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Int64 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toBeBytes()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Float32 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toBits().toBeBytes()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: Float64 =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toBits().toBeBytes()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let valstr = v.toString().toArray()
                    let len: Int32 = Int32(valstr.size)
                    return BindParameter(len, valstr)
                }
            case v: String =>
                if (cn.isBinarytransfer()) {
                    // 二进制传输
                    let val = v.toArray()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val, true)
                } else {
                    // 文本传输
                    let val = v.toArray()
                    let len: Int32 = Int32(val.size)
                    return BindParameter(len, val)
                }
            case v: Array<Byte> =>
                // 文本模式下，Array<Byte>类型也用二进制模式
                let val = v
                let len: Int32 = Int32(val.size)
                return BindParameter(len, val, true)
            case v: InputStream =>
                // 文本模式下，InputStream类型也用二进制模式
                let val = inputStreamToBytes(v)
                let len: Int32 = Int32(val.size)
                return BindParameter(len, val, true)
            case v: DateTime =>
                // 目前DateTime类型都暂时使用文本传输
                // if (cn.isBinarytransfer()) {
                //     // 二进制传输
                //     match (oid) {
                //         case 1082 =>
                //             // date
                //             let ymd = DateTime.of(year: v.year, month: v.month, dayOfMonth: v.dayOfMonth, hour: 0,
                //                 minute: 0, second: 0, nanosecond: 0, timeZone: TimeZone.UTC)
                //             let ymdUnix = ymd.toUnixTimeStamp()
                //             let dateEpoch =
                //                 DateTime.of(year: 2000, month: 1, dayOfMonth: 1, hour: 0, minute: 0, second: 0,
                //                 nanosecond: 0, timeZone: TimeZone.UTC).toUnixTimeStamp()
                //             let secSinceDateEpoch = (ymdUnix - dateEpoch).toSeconds()
                //             let daysSinceDateEpoch = secSinceDateEpoch / 86400
                //             return BindParameter(4, Int32(daysSinceDateEpoch).toBeBytes(), true)
                //         case 1083 | 1183 => // time 
                //             throw SqlException("current not support convert to time[${oid}]")
                //         case 1266 | 1270 => // timetz 
                //             throw SqlException("current not support convert to timetz[${oid}]")
                //         case 1114 | 1184 =>
                //             // timestamp
                //             let msecSinceUnixEpoch: Int64 = v.toUnixTimeStamp().toSeconds() * 1000000 + v.nanosecond / 1000
                //             let msecSinceY2K: Int64 = msecSinceUnixEpoch - microsecFromUnixEpochToY2K
                //             return BindParameter(8, msecSinceY2K.toBeBytes(), true)
                //         case _ => throw SqlException("DateTime[${v}] can't convert to ${oid}")
                //     }
                // } else {
                // 文本传输
                let valstr = v.format("yyyy-MM-dd HH:mm:ss.SSSO")
                let val = valstr.toArray()
                let len: Int32 = Int32(val.size)
                return BindParameter(len, val)
            // }
            case v: Duration =>
                // Duration总使用文本模式
                let valstr = toDurationStr(v)
                let val = valstr.toArray()
                let len: Int32 = Int32(val.size)
                return BindParameter(len, val)
            case _ => throw SqlException("not supported type")
        }
    }

    func toDurationStr(duration: Duration): String {
        var seconds = duration.toSeconds()
        let days = seconds / Duration.day.toSeconds()
        seconds -= days * Duration.day.toSeconds()
        let hours = seconds / Duration.hour.toSeconds()
        seconds -= hours * Duration.hour.toSeconds()
        let minutes = seconds / Duration.minute.toSeconds()
        seconds -= minutes * Duration.minute.toSeconds()
        return "P0-0-${days}T${hours}:${minutes}:${seconds}"
    }

    func checkIfParamIsInit(): Unit {
        for (i in 0..isParameterInit.size) {
            if (!isParameterInit[i]) {
                throw SqlException("The parameter at the ${i} position has not been set.")
            }
        }
    }
}
