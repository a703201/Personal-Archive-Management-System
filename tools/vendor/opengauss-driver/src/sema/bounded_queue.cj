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

import cangjie_tpc::opengauss.collections.{Queue as Q}

public class BoundedQueue<T> {
    let m: Mutex  = Mutex ()
    var notFull: Condition
    var notEmpty: Condition
    var maxSize: Int64
    let items: Q<T>

    public init(maxSize: Int64) {
        this.maxSize = maxSize
        items = Q<T>(maxSize)
        synchronized(m) {
            notFull = m.condition()
            notEmpty = m.condition()
        }
    }

    public prop size: Int64 {
        get() {
            synchronized(m) {
                return items.size
            }
        }
    }

    public func put(x: T) {
        synchronized(m) {
            while (items.size == maxSize) {
                // If the queue is full, wait for the "queue notFull" event.
                notFull.wait()
            }
            items.put(x)
            notEmpty.notify()
        }
    }

    public func get(timeout: Duration): Option<T> {
        synchronized(m) {
            while (items.size == 0) {
                // If the queue is empty, wait for the "queue notEmpty" event.
                var w = notEmpty.wait(timeout: timeout)
                if (!w) {
                    return None
                }
            }
            let x = items.get()
            notFull.notify()
            return x
        }
    }

    public func tryGet(): Option<T> {
        synchronized(m) {
            if (items.size == 0) {
                return None
            }
            let x = items.get()
            notFull.notify()
            return x
        }
    }
}
