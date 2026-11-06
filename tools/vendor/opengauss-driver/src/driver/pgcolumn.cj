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
package cangjie_tpc::opengauss.driver

class PGColumn <: ColumnInfo {
    var _name = ""
    public prop name: String {
        get() {
            _name
        }
    }
    var _typename = ""
    public prop typeName: String {
        get() {
            _typename
        }
    }
    var _length = 0
    public prop length: Int64 {
        get() {
            _length
        }
    }
    var _scale = 0
    public prop scale: Int64 {
        get() {
            _scale
        }
    }
    var _nullable = true
    public prop nullable: Bool {
        get() {
            _nullable
        }
    }
    var _displaySize = 0
    public prop displaySize: Int64 {
        get() {
            _displaySize
        }
    }
}
