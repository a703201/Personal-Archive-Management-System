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

internal import std.random.Random

public class ProxyConnection <: Connection {
    var delegate: Connection
    var poolEntry: Entry<Connection>
    let closed = AtomicBool(true)

    public init(conn: Connection, poolEntry: Entry<Connection>) {
        this.delegate = conn
        this.poolEntry = poolEntry
        closed.store(false)
    }

    public func discard() {
        delegate.close()
    }

    /*
     * 判断资源是否关闭
     * 返回值 Bool - 如果已经关闭返回 true，否则返回 false
     */
    public func isClosed(): Bool {
        closed.load()
    }

    /*
     * 关闭资源
     */
    public func close(): Unit {
        if (isClosed()) {
            return
        }
        closed.store(true)
        poolEntry.release()
    }

    /*
     * 通过传入的 sql 语句，返回一个预执行的 Statement 对象实例
     * 参数 sql - 预执行的 sql 语句
     * 返回值 Statement - 一个可以执行 sql 语句的实例对象
     */
    public func prepareStatement(sql: String): Statement {
        if (isClosed()) {
            throw SqlException("connection closed")
        }
        return delegate.prepareStatement(sql)
    }
    public func getMetaData() {
        delegate.getMetaData()
    }
    public func createTransaction() {
        if (isClosed()) {
            throw SqlException("connection closed")
        }
        delegate.createTransaction()
    }

    public prop state: ConnectionState {
        get() {
            delegate.state
        }
    }
}
