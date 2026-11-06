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
package cangjie_tpc::opengauss.proto3

import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
public class TestStartupMessage {
    @TestCase
    func encode(): Unit {
        var sm = StartupMessage()
        sm.addParam("user", "foo")
        sm.addParam("sassword", "bar")
        sm.addParam("database", "flirt")
        sm.addParam("replication", "false")
        var dst = sm.encode()
        for (i in 0..dst.size) {
            print(dst[i].format("#x"))
            print(" ")
        }
        var want: Array<UInt8> = [
            0x0,
            0x0,
            0x0,
            0x40,
            0x0,
            0x3,
            0x0,
            0x0,
            0x75,
            0x73,
            0x65,
            0x72,
            0x0,
            0x66,
            0x6f,
            0x6f,
            0x0,
            0x73,
            0x61,
            0x73,
            0x73,
            0x77,
            0x6f,
            0x72,
            0x64,
            0x0,
            0x62,
            0x61,
            0x72,
            0x0,
            0x64,
            0x61,
            0x74,
            0x61,
            0x62,
            0x61,
            0x73,
            0x65,
            0x0,
            0x66,
            0x6c,
            0x69,
            0x72,
            0x74,
            0x0,
            0x72,
            0x65,
            0x70,
            0x6c,
            0x69,
            0x63,
            0x61,
            0x74,
            0x69,
            0x6f,
            0x6e,
            0x0,
            0x66,
            0x61,
            0x6c,
            0x73,
            0x65,
            0x0,
            0x0
        ]
        @Assert(dst == want)
    }

    @TestCase
    func decode(): Unit {
        var src: Array<UInt8> = [
            // 0x0, // len在Backend.receiveMessage已经处理了，在decode中不需要
            // 0x0,
            // 0x0,
            // 0x40,
            0x0,
            0x3,
            0x0,
            0x0,
            0x75,
            0x73,
            0x65,
            0x72,
            0x0,
            0x66,
            0x6f,
            0x6f,
            0x0,
            0x70,
            0x61,
            0x73,
            0x73,
            0x77,
            0x6f,
            0x72,
            0x64,
            0x0,
            0x62,
            0x61,
            0x72,
            0x0,
            0x64,
            0x61,
            0x74,
            0x61,
            0x62,
            0x61,
            0x73,
            0x65,
            0x0,
            0x66,
            0x6c,
            0x69,
            0x72,
            0x74,
            0x0,
            0x72,
            0x65,
            0x70,
            0x6c,
            0x69,
            0x63,
            0x61,
            0x74,
            0x69,
            0x6f,
            0x6e,
            0x0,
            0x66,
            0x61,
            0x6c,
            0x73,
            0x65,
            0x0,
            0x0
        ]
        var sm = StartupMessage()
        sm.decode(src)
        println(sm.toString())
    }
}
