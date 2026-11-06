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
package cangjie_tpc::opengauss.sema

internal import cangjie_tpc::opengauss.slog.*
internal import std.random.*
internal import std.sync.*
internal import std.time.*
import cangjie_tpc::opengauss.slog

public class SemaphoreInner <: Equatable<SemaphoreInner> {
    let logger = slog.Default()

    let m: Mutex = Mutex()
    var semacond: Condition
    let maxSize: Int64
    var state: Int64
    let objId: UInt64

    public init(maxSize: Int64) {
        this.maxSize = maxSize
        state = maxSize
        let rnd = Random(UInt64(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        objId = rnd.nextUInt64()
        synchronized(m) {
            semacond = m.condition()
        }
    }

    public operator func !=(rhs: SemaphoreInner): Bool {
        return this.objId != rhs.objId
    }

    public operator func ==(rhs: SemaphoreInner): Bool {
        return this.objId == rhs.objId
    }

    public func acquire(n: Int64, timeout: Duration): Option<Int64> {
        synchronized(m) {
            var cur = state
            while (cur == 0 || cur < n) {
                var w = semacond.wait(timeout: timeout)
                if (!w) {
                    return None
                }
            }
            state -= n
            if (state > 0) {
                semacond.notify()
            }
            return n
        }
    }

    public func tryAcquire(n: Int64): Bool {
        synchronized(m) {
            var cur = state
            if (n <= maxSize - cur) {
                state -= n
                return true
            }
            return false
        }
    }

    public func release(n: Int64): Bool {
        synchronized(m) {
            var cur = state
            if (cur == maxSize || cur > maxSize - n) {
                return false
            }
            state += n
            semacond.notify()
            return true
        }
    }
}
