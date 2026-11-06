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

import std.collection.*
import std.sync.*
import cangjie_tpc::opengauss.slog

public struct ConnHolder {
    public var host = "127.0.0.1"
    public var port = 5432u16
    public var connCount = 0i32
}

public class ConnManager {
    var connMap = HashMap<String, ConnHolder>()
    let connMapLock = ReadWriteLock()

    var connIndex = AtomicInt64(0)

    static let instLock = Mutex()
    static var inst: ?ConnManager = Option<ConnManager>.None

    public static func instance(): ConnManager {
        match (inst) {
            case Some(v) => return v
            case _ => synchronized(instLock) {
                match (inst) {
                    case Some(v) => return v
                    case _ =>
                        var ret = ConnManager()
                        inst = ret
                        return ret
                }
            }
        }
    }

    public func add(host: String, port: UInt16): Unit {
        let key = "${host}:${port}"
        try {
            connMapLock.writeLock.lock()
            var conn = connMap.get(key)
            match (conn) {
                case Some(v) =>
                    var connHolder = v
                    connHolder.connCount++
                    connMap[key] = connHolder
                case _ =>
                    var connHolder = ConnHolder()
                    connHolder.host = host
                    connHolder.port = port
                    connHolder.connCount = 1i32
                    connMap[key] = connHolder
            }
        } finally {
            connMapLock.writeLock.unlock()
        }
    }

    public func remove(host: String, port: UInt16): Unit {
        let key = "${host}:${port}"
        try {
            connMapLock.writeLock.lock()
            var conn = connMap.get(key)
            match (conn) {
                case Some(v) =>
                    var connHolder = v
                    connHolder.connCount--
                    if (connHolder.connCount <= 0) {
                        connMap.remove(key)
                    } else {
                        connMap[key] = connHolder
                    }
                case _ => ()
            }
        } finally {
            connMapLock.writeLock.unlock()
        }
    }

    public func nextConnectionIndex(): Int64 {
        var ret = connIndex.fetchAdd(1i64)
        if (ret >= 10000) {
            // 最大轮转到10000
            connIndex.swap(0)
        }
        return ret
    }

    public func count(host: String, port: UInt16): Int32 {
        let key = "${host}:${port}"
        var ret = 0i32
        try {
            connMapLock.readLock.lock()
            let conn = connMap.get(key)
            match (conn) {
                case Some(v) => ret = v.connCount
                case _ => ()
            }
        } finally {
            connMapLock.readLock.unlock()
        }
        return ret
    }
}
