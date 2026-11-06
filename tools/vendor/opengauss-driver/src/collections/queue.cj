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
package cangjie_tpc::opengauss.collections

internal import std.sync.*

// Queue class, MT unsafe
public class Queue<T> {
    var count: Int64 // Object count in buffer.
    var head: Int64 // Write index.
    var tail: Int64 // Read index.
    let maxSize: Int64

    let items: Array<T>
    public init(maxSize: Int64) {
        count = 0
        head = 0
        tail = 0
        this.maxSize = maxSize
        items = Array<T>(maxSize, {i => unsafe { zeroValue<T>() }})
    }

    public prop size: Int64 {
        get() {
            return count
        }
    }

    // Insert an object, if the queue is full, return None
    public func put(x: T): Option<Unit> {
        // Acquire the mutex.
        while (count == maxSize) {
            // If the queue is full
            return None
        }
        items[head] = x
        head++
        if (head == maxSize) {
            head = 0
        }
        count++
    }

    // Pop an object, if the queue is empty, return None
    public func get(): Option<T> {
        while (count == 0) {
            // If the queue is empty
            return None
        }
        let x: T = items[tail]
        tail++
        if (tail == maxSize) {
            tail = 0
        }
        count--
        return x
    }
}
