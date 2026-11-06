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
public class TestAuthMd5 {
    @TestCase
    func testAuthMd5(): Unit {
        let ret = authMd5("user_name", "password", "salt".toArray())
        println("testAuthMd5 ret:${ret}")
        @Assert(ret == "md5f6b639a5f6c5cc454dc592b415b0e776")
    }

    @TestCase
    func testAuthSha256(): Unit {
        let ret = authSha256("user_name", "password", "token".toArray(), "salt".toArray())
        println("testAuthSha256 ret:${ret}")
        @Assert(ret == "sha256b0f8f739615c2751db27680b94194187cf8efd1d2f6783582a2de5882837717f")
    }

    @TestCase
    func testAuthMd5Sha256(): Unit {
        let ret = authMd5Sha256("user_name", "password", "salt".toArray())
        println("testAuthMd5Sha256 ret:${ret}")
        @Assert(ret == "sha2565b9f7b922c417518ef7466bca60675078716f8fec90cf39ce3aa963950dfbe68")
    }
}