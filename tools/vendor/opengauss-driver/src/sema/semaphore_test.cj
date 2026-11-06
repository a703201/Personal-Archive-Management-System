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
internal import std.collection.*
internal import std.time.*
import cangjie_tpc::opengauss.collections.{Queue as Q}


@Test
public class TestSemaphore {
    @TestCase
    func testsema2(): Unit {
        let ticket_sum = 10
        let tickets = Q<Int64>(ticket_sum)
        for (i in 0..10) {
            tickets.put(i + 1)
        }
        let sema = SemaphoreInner(4)
        let list = ArrayList<Future<Unit>>()

        for (i in 0..4) {
            let fut = spawn {
                 => sell_ticket2(i + 1, sema, tickets)
            }
            list.add(fut)
        }
        for (fut in list) {
            fut.get()
        }
    }

    func sell_ticket2(id: Int64, sema: SemaphoreInner, tickets: Q<Int64>) {
        println("cur id is ${id}")
        while (true) {
            var flag = sema.acquire(1, Duration.second)
            match (flag) {
                case Some(v) =>
                    if (tickets.size > 0) {
                        let no = tickets.get() ?? 0
                        sleep(Duration.second)
                        println("${id} sell tickno ${no}")
                        sema.release(1)
                    } else {
                        sema.release(1)
                        break
                    }

                case None => break
            }
        }
    }
}
