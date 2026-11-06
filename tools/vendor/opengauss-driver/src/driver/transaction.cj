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

public class PGTransaction <: Transaction {
    let cn: PgConn
    init(cn: PgConn) {
        this.cn = cn
    }

    private var _isoLevel = TransactionIsoLevel.Unspecified
    public mut prop isoLevel: TransactionIsoLevel {
        get() {
            _isoLevel
        }
        set(v) {
            _isoLevel = v
        }
    }
    var _accessMode = TransactionAccessMode.Unspecified
    public mut prop accessMode: TransactionAccessMode {
        get() {
            _accessMode
        }
        set(v) {
            _accessMode = v
        }
    }
    var _deferrableMode = TransactionDeferrableMode.Unspecified
    public mut prop deferrableMode: TransactionDeferrableMode {
        get() {
            _deferrableMode
        }
        set(v) {
            _deferrableMode = v
        }
    }

    public func begin(): Unit {
        let sb = StringBuilder("begin")
        match (this._isoLevel) {
            case TransactionIsoLevel.Unspecified => ()
            case TransactionIsoLevel.ReadUncommitted => sb.append(" isolation level read uncommitted ")
            case TransactionIsoLevel.ReadCommitted => sb.append(" isolation level read committed ")
            case TransactionIsoLevel.RepeatableRead => sb.append(" isolation level repeatable read ")
            case TransactionIsoLevel.Snapshot => sb.append(" isolation level repeatable read ")
            case TransactionIsoLevel.Serializable => sb.append(" isolation level serializable ")
            case TransactionIsoLevel.Linearizable => throw SqlException("Linearizable not support")
            case TransactionIsoLevel.Chaos => throw SqlException("Chaos not support")
        }
        match (this._accessMode) {
            case TransactionAccessMode.Unspecified => ()
            case TransactionAccessMode.ReadOnly => sb.append(" read only ")
            case TransactionAccessMode.ReadWrite => sb.append(" read write ")
        }
        match (this._deferrableMode) {
            case TransactionDeferrableMode.Unspecified => ()
            case TransactionDeferrableMode.NotDeferrable => sb.append(" NOT DEFERRABLE ")
            case TransactionDeferrableMode.Deferrable => sb.append(" DEFERRABLE ")
        }
        cn.exec(sb.toString())
    }

    public func commit(): Unit {
        cn.exec("commit")
    }

    public func rollback(): Unit {
        cn.exec("rollback")
    }

    public func save(savePointName: String): Unit {
        cn.exec("SAVEPOINT ${savePointName}")
    }

    public func rollback(savePointName: String): Unit {
        cn.exec("ROLLBACK TO SAVEPOINT ${savePointName}")
    }

    public func release(savePointName: String): Unit {
        cn.exec("RELEASE SAVEPOINT ${savePointName}")
    }
}
