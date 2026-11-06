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


@Test
public class TestKDF {
    @TestCase
    func testKDF(): Unit {
        var ret = toHexString(PBKDF2.key("password".toArray(), "saltBytes".toArray(), 2048, 32, newSHA1))
        println("testKDF newSHA1 ret:${ret}")
        @Assert(ret == "b2f63a1149bcd421ff23b2dc7f7460d04ef81ef381710ead780355ce31e6ca01")

        ret = toHexString(PBKDF2.key("password".toArray(), "saltBytes".toArray(), 2048, 32, newSHA256))
        println("testKDF newSHA256 ret:${ret}")
        @Assert(ret == "10581174ab41adca99f398d4a62d621acb0406c87e25df882a2a1af8a0eeb730")
    }
}
