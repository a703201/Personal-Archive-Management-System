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

public class RowsAffected <: UpdateResult {
    var rowCount_ = 0
    let lastInsertId_: Int64
    public init(rowCount: Int64, lastInsertId: Int64) {
        this.rowCount_ = rowCount
        this.lastInsertId_ = lastInsertId
    }

    /*
     * 执行 Insert、Update、Delete 语句影响的行数
     */
    public prop rowCount: Int64 {
        get() {
            return rowCount_
        }
    }

    /*
     * 执行 Insert 语句自动生成的最后 row ID，如果不支持则为 0
     */
    public prop lastInsertId: Int64 {
        get() {
            return lastInsertId_
        }
    }
}
