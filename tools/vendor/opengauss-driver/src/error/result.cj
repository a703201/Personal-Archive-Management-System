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
package cangjie_tpc::opengauss.error

public enum Result<T> {
    Ok(T) | Err(Exception)

    public func is_ok(): Bool {
        match (this) {
            case Ok(v) => true
            case Err(v) => false
        }
    }

    public func is_err(): Bool {
        return !is_ok()
    }

    public func unwrap(): T {
        match (this) {
            case Ok(v) => return v
            case Err(v) => throw v
        }
    }

    public func unwrap_err(): Exception {
        match (this) {
            case Ok(v) => throw Exception("called `Result.unwrap_err()` on an `Ok` value")
            case Err(v) => v
        }
    }
}

extend<T> Result<T> <: ToString where T <: ToString {
    public func toString(): String {
        match (this) {
            case Ok(v) => return v.toString()
            case Err(v) => return v.message
        }
    }
}
