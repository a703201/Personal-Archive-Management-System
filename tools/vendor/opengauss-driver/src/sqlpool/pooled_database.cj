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
package cangjie_tpc::opengauss.sqlpool

internal import std.time.*
internal import std.database.sql.*
internal import std.sync.*
internal import cangjie_tpc::opengauss.slog.*
internal import cangjie_tpc::opengauss.tinypool.*
import cangjie_tpc::opengauss.slog

public class PooledDatasource <: Datasource {
    let defaultMaxIdleTimeout = Duration.minute * 10
    let defaultMaxLifetime = Duration.minute * 30
    let defaultConnTimeout = Duration.second * 30
    let defaultHealthCheckPeriod = Duration.minute * 1
    let defaultMaxConns = 10i32
    let defaultMaxIdleConns = 0i32

    var pool: TinyPool<Connection>

    var datasource: Datasource

    public init(datasource: Datasource) {
        this.datasource = datasource
        func newConn(): Option<Connection> {
            var conn = datasource.connect()
            return conn
        }
        func closeConn(conn: Connection): Option<Unit> {
            conn.close()
        }
        var opt = Options<Connection>(
            maxIdleConn_,
            maxConn_,
            idleTimeout_,
            maxLifeTime_,
            healthCheckPeriod_,
            newConn,
            closeConn
        )
        pool = TinyPool<Connection>(opt)
    }

    public init(datasource: Datasource, poolCfg: PoolConfig) {
        this.datasource = datasource
        func newConn(): Option<Connection> {
            var conn = datasource.connect()
            return conn
        }
        func closeConn(conn: Connection): Option<Unit> {
            conn.close()
        }
        var opt = Options<Connection>(
            poolCfg.maxIdleSize,
            poolCfg.maxSize,
            poolCfg.idleTimeout,
            poolCfg.maxLifeTime,
            poolCfg.keepAliveTime,
            newConn,
            closeConn
        )
        pool = TinyPool<Connection>(opt)
    }

    public func setOption(key: String, value: String) {}

    var idleTimeout_ = defaultMaxIdleTimeout
    var maxLifeTime_ = defaultMaxLifetime
    var connTimeout_ = defaultConnTimeout
    var healthCheckPeriod_ = defaultHealthCheckPeriod
    var maxConn_ = defaultMaxConns
    var maxIdleConn_ = defaultMaxIdleConns

    var idleConns_ = AtomicInt64(0)
    public prop idleConns: Int64 {
        get() {
            idleConns_.load()
        }
    }

    var openConns_ = AtomicInt64(0)
    public prop openConns: Int64 {
        get() {
            openConns_.load()
        }
    }

    var usedConn_ = AtomicInt64(0)
    public prop usedConn: Int64 {
        get() {
            usedConn_.load()
        }
    }

    public func closeAllConn(): Unit {}

    /*
     * 判断资源是否关闭
     * 返回值 Bool - 如果已经关闭返回 true，否则返回 false
     */
    public func isClosed(): Bool {
        return datasource.isClosed()
    }

    /*
     * 关闭资源
     */
    public func close(): Unit {
        datasource.close()
    }

    /*
     * 返回一个可用的连接
     * 返回值 Connection - 数据库连接实例
     */
    public func connect(): Connection {
        var item = pool.acquire(connTimeout_)
        match (item) {
            case Some(entry) => return ProxyConnection(entry.value, entry)
            case None => throw SqlException("can not acquire conn")
        }
    }
}
