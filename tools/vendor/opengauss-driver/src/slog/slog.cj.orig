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
package cangjie_tpc::opengauss.slog

import stdx.log.*
import std.sync.*
import stdx.logger.*
import std.env.*

public func Default(): Logger {
    return LoggerWrapper.logger
}
public func setDefault(l: Logger) {
    LoggerWrapper.logger.replace(l)
}
public class LoggerWrapper <: Logger {
    static let logger = LoggerWrapper()
    private let ref: AtomicReference<Logger>
    public init(wrap: Logger){
        ref = AtomicReference<Logger>(wrap)
    }
    private func load(){
        ref.load()
    }
    public init(){
        this(SimpleLogger(getStdOut()))
    }
    public func replace(logger: Logger){
        ref.store(logger)
    }
    public func close(): Unit {
        load().close()
    }
    public func isClosed(): Bool {
        load().isClosed()
    }
    public func log(record: LogRecord): Unit {
        load().log(record)
    }
    public func withAttrs(attrs: Array<Attr>): Logger {
        load().withAttrs(attrs)
    }
    public mut prop level: LogLevel {
        get(){
            load().level
        }
        set(value){
            load().level = value
        }
    } 
}