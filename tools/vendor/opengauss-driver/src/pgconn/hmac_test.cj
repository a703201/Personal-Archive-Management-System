/**
 * Copyright 2024 Beijing Baolande Software Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Runtime Library Exception to the Apache 2.0 License:
 *
 * As an exception, if you use this Software to compile your source code and
 * portions of this Software are embedded into the binary product as a result,
 * you may redistribute such product without providing attribution as would
 * otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
 */

package cangjie_tpc::opengauss.pgconn

import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.{SHA256, SHA1}
import stdx.encoding.hex.*

func newSHA256(): SHA256 {
    SHA256()
}

func newSHA1(): SHA1 {
    SHA1()
}

@Test
public class TestHMac {
    @TestCase
    func testDigest(): Unit {
        var ret = toHexString(HMac.digest(newSHA256, "password".toArray(), "salt".toArray()))
        println("TestHMac newSHA256 ret:${ret}")
        @Assert(ret == "fc328232993ff34ca56631e4a101d60393cad12171997ee0b562bf7852b2fed0")

        ret = toHexString(HMac.digest(newSHA1, "password".toArray(), "salt".toArray()))
        println("TestHMac newSHA1 ret:${ret}")
        @Assert(ret == "a2bc8e0d997642c25dab419930b1358328bb93b9")
    }

    @TestCase
    func testHMac(): Unit {
        let prf = HMac(newSHA256, "password".toArray())
        for (i in 1..10) {
            prf.write("data_${i}".toArray())
        }
        var ret = toHexString(prf.finish())
        println("testHMac newSHA256 ret:${ret}")
        @Assert(ret == "36a3500d984bde7c90b824b239138baf0008c6824a040211485bbc2ac82842c3")

        prf.reset()
        for (i in 20..30) {
            prf.write("data_${i}".toArray())
        }
        ret = toHexString(prf.finish())
        println("testHMac reset ret:${ret}")
        @Assert(ret == "43d440e6c28b11f0f1681cb1cd597e56ea6b1ef29931fabc200b47540aac4315")
    }
}

