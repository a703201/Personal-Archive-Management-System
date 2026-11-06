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
package cangjie_tpc::opengauss.tinypool

internal import std.random.Random
import cangjie_tpc::opengauss.slog

public class Entry<T> {
    let EntryStatusConstructing = 1u8
    let EntryStatusIdle = 2u8
    let EntryStatusAcquired = 3u8
    let EntryStatusDestructing = 4u8

    let logger = slog.Default()
    var value_: T
    let pool: Pool<T>

    var creationTime: Duration
    var lastAccessed: Duration = Duration.Zero
    var poolResetCount: Int32 = 0
    var status: UInt8 = EntryStatusConstructing

    public init(pool: Pool<T>, value: T) {
        this.pool = pool
        this.value_ = value

        let now = DateTime.now().toUnixTimeStamp()
        let rnd = Random(UInt64(now.toMilliseconds()))
        let jitter = Duration.second * rnd.nextFloat64()
        this.creationTime = now + jitter
    }

    public prop value: T {
        get() {
            if (!(status == EntryStatusAcquired)) {
                throw Exception("entry is not acquired")
            }
            return this.value_
        }
    }

    public func acquire(): Unit {
        this.status = EntryStatusAcquired
    }

    public func release() {
        if ((status != EntryStatusAcquired)) {
            throw Exception("entry is not acquired")
        }
        this.status = EntryStatusIdle
        this.lastAccessed = DateTime.now().toUnixTimeStamp()
        pool.release(this)
    }

    public func idleDuration(): Duration {
        var now = DateTime.now().toUnixTimeStamp()
        return now - this.lastAccessed
    }
}
