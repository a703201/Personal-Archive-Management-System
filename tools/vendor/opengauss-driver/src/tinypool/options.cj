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
package cangjie_tpc::opengauss.tinypool

public struct Options<T> {
    let maxIdleSize: Int32
    let maxSize: Int32
    let idleTimeout: Duration
    let maxLifeTime: Duration
    let keepAliveTime: Duration
    let constructor: () -> Option<T>
    let destructor: (T) -> Option<Unit>
    public init(
        maxIdleEntry: Int32,
        maxSize: Int32,
        maxIdleTime: Duration,
        maxLifeTime: Duration,
        keepAliveTime: Duration,
        constructor: () -> Option<T>,
        destructor: (T) -> Option<Unit>
    ) {
        this.maxIdleSize = maxIdleEntry
        this.maxSize = maxSize
        this.idleTimeout = maxIdleTime
        this.maxLifeTime = maxLifeTime
        this.keepAliveTime = keepAliveTime
        this.constructor = constructor
        this.destructor = destructor
    }
}
