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

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
public class TestBoundedQueue {
    @TestCase
    func sema1(): Unit {
        var ticket_sum = 10
        let sema = BoundedQueue<Int64>(ticket_sum)
        let list = ArrayList<Future<Unit>>()
        for (i in 0..ticket_sum) {
            sema.put(i + 1)
        }
        for (i in 0..4) {
            let fut = spawn {
                 => sell_ticket(i + 1, sema)
            }
            list.add(fut)
        }
        for (fut in list) {
            fut.get()
        }
    }

    func sell_ticket(id: Int64, sema: BoundedQueue<Int64>) {
        println("cur id is ${id}")

        while (true) {
            var flag = sema.get(Duration.second)
            match (flag) {
                case Some(v) =>
                    sleep(Duration.second)
                    println("${id} sell tickno ${v}")
                case None => break
            }
        }
    }
}
