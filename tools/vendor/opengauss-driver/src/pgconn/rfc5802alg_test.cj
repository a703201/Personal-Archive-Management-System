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

@Test
public class TestRfc5802alg {
    @TestCase
    func testRfc5802alg(): Unit {
        let ret = RFC5802Algorithm(
            "password",
            "salt",
            "token",
            "",
            0i64,
            "sha256"
        )

        println("testRfc5802alg sha256 ret:${ret}")
        @Assert(ret == "b76e31b64556a4d2b6f5a95c8133990ac5a340786af4d86a526fe4cbcd468f09")
    }
}