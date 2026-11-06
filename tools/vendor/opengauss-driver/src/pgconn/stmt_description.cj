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

import cangjie_tpc::opengauss.proto3.*

public class StmtDescription {
    public let name: String
    public let sql: String
    public var localname: String = ""
    public var parse: ?Parse = Option<Parse>.None
    public var paramOIDs = Array<Int32>()
    public var fields = Array<FieldDescription>()
    public var fieldsgot = false
    public var paramCount: UInt16
    public init(name: String, sql: String, paramCount: UInt16) {
        this.name = name
        this.sql = sql
        this.paramCount = paramCount
    }
}
