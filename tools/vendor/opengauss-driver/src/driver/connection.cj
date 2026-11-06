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

internal import std.random.Random
import std.database.sql.*
import std.sync.*
import std.time.*
import std.collection.*
import stdx.net.tls.*
import cangjie_tpc::opengauss.pgconn.*

public class PGConnection <: Connection {
    let objId: UInt64
    var closed = AtomicBool(true)
    let pgConn: PgConn
    private var stmt = None<Stmt>
    private var rows = None<Rows>

    public init(pgConn: PgConn) {
        let rnd = Random(UInt64(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        objId = rnd.nextUInt64()
        this.pgConn = pgConn
        closed.store(false)
        logger.debug("driver conn[${objId}] created")
    }
    public func getMetaData(): Map<String, String> {
        return pgConn.getParams()
    }
    public func createTransaction() {
        // 事务总是连接master
        pgConn.checkToResetToMasterConnection()
        PGTransaction(pgConn)
    }

    public prop state: ConnectionState {
        get() {
            match (pgConn.getStatus()) {
                case ConnStatus.Connecting => return ConnectionState.Connecting
                case ConnStatus.Uninitialized => return ConnectionState.Broken
                case ConnStatus.Closed => return ConnectionState.Closed
                case _ => return ConnectionState.Connected
            }
        }
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
        rows?.close()
        stmt
        pgConn.close()
        logger.debug("driver conn[${objId}] closed")
    }

    public func getHost(): String {
        return pgConn.getHost()
    }

    public func getPort(): UInt16 {
        return pgConn.getPort()
    }

    /*
     * 通过传入的 sql 语句，返回一个预执行的 Statement 对象实例
     * 参数 sql - 预执行的 sql 语句
     * 返回值 Statement - 一个可以执行 sql 语句的实例对象
     */
    public func prepareStatement(sql: String): Statement {
        let sd = pgConn.prepare(sql.trimAscii(), [])
        match (sd) {
            case Ok(v) =>
                var stmt = Stmt(v, pgConn)
                this.stmt = stmt
                return stmt
            case Err(v) => throw SqlException(v.message)
        }
    }

    public func update(sql: String): UpdateResult {
        let rr = pgConn.simpleExec(sql)
        let (cmdtag, err) = rr.close()
        if (err != "") {
            throw SqlException(err)
        }
        var ra = RowsAffected(rr.rows(), 0)
        return ra
    }
    public func query(sql: String): QueryResult {
        let rr = pgConn.simpleExec(sql)
        var qr = Rows(rr)
        this.rows = qr
        return qr
    }
}
