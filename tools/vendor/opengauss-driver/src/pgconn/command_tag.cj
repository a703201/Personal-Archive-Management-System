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

public enum Command {
    | INSERT
    | DELETE
    | UPDATE
    | SELECT
    | MOVE
    | FETCH
    | COPY
}

public class CommandTag <: ToString {
    let s: String
    var cmd = ""
    var rows = 0
    var oid = 0
    public init(s: String) {
        this.s = s
        this.parse()
    }
    func parse() {
        let sa = this.s.split(" ")
        if (sa.size == 2) {
            cmd = sa[0]
            rows = Int64.tryParse(sa[1]) ?? 0
        } else if (sa.size == 3) {
            cmd = sa[0]
            rows = Int64.tryParse(sa[2]) ?? 0
        }
    }
    public func rowsAffected(): Int64 {
        return rows
    }
    public func command(): String {
        return cmd
    }
    public func toString(): String {
        return s
    }
}
