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
package cangjie_tpc::opengauss.utils

import std.unittest.* //testfame
import std.unittest.testmacro.* //macro_Defintion

@Test
func test_partition(): Unit {
    var l = {
         =>
        let qry = "=myapp"
        let (n, _, v) = qry.partition(b'=')
        println("${n}, ${v}")
    }
    l()
    l = {
         =>
        let qry = "a=myapp"
        let (n, _, v) = qry.partition(b'=')
        println("${n}, ${v}")
    }
    l()
    l = {
         =>
        let qry = "target_session_attrs=a"
        let (n, _, v) = qry.partition(b'=')
        println("${n}, ${v}")
    }
    l()
}
