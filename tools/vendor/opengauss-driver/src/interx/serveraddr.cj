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

package cangjie_tpc::opengauss.interx

import std.database.sql.*
import std.sync.*
import std.time.*
import std.collection.*
import cangjie_tpc::opengauss.slog
import cangjie_tpc::opengauss.proto3.*

public struct ServerAddrInterceptorContext {
    // 当前待选的地址
    public let addrs: ArrayList<(String, UInt16)>
    // errorAddrs的格式为 Map<地址:端口, 异常信息>
    public let errorAddrs: Map<String, String>
    // errorInterceptorAddrs的格式为 Map<地址:端口, 异常信息>
    public let errorInterceptorAddrs: Map<String, String>
    public init(addrs: ArrayList<(String, UInt16)>, errorAddrs: Map<String, String>,
        errorInterceptorAddrs: Map<String, String>) {
        this.addrs = addrs
        this.errorAddrs = errorAddrs
        this.errorInterceptorAddrs = errorInterceptorAddrs
    }
}

public interface ServerAddrInterceptorInteface <: Interceptor {
    func getServerAddr(context: ServerAddrInterceptorContext): ?(String, UInt16)
}

public class ServerAddrInterceptorManager {
    var interceptors = ArrayList<ServerAddrInterceptorInteface>()
    var interceptorcount = 0i64
    let interceptorsLock = ReadWriteLock()

    static let instLock = Mutex()
    static var inst: ?ServerAddrInterceptorManager = Option<ServerAddrInterceptorManager>.None

    let logger = slog.Default()

    public static func instance(): ServerAddrInterceptorManager {
        match (inst) {
            case Some(v) => return v
            case _ => synchronized(instLock) {
                match (inst) {
                    case Some(v) => return v
                    case _ =>
                        var ret = ServerAddrInterceptorManager()
                        inst = ret
                        return ret
                }
            }
        }
    }

    public func isInterceptorEnable(): Bool {
        return (interceptorcount > 0) && !isDisableInterceptor()
    }

    public func registerInterceptor(interceptor: ServerAddrInterceptorInteface): Unit {
        var add = false
        var index = 0i64
        try {
            interceptorsLock.writeLock.lock()
            for (itcpt in interceptors) {
                if (interceptor.name() == itcpt.name()) {
                    throw SqlException("the interceptor ${interceptor.name()} exists already")
                }
            }
            for (itcpt in interceptors) {
                if (interceptor.priority() > itcpt.priority()) {
                    interceptors.add(interceptor, at: index)
                    add = true
                    break
                }
                index++
            }
            if (!add) {
                interceptors.add(interceptor)
            }
            interceptorcount = interceptors.size
        } finally {
            interceptorsLock.writeLock.unlock()
        }
    }

    public func unregisterInterceptor(name: String): Unit {
        try {
            interceptorsLock.writeLock.lock()
            var index = 0
            for (itcpt in interceptors) {
                if (name == itcpt.name()) {
                    break
                }
                index++
            }
            if (index < interceptors.size) {
                interceptors.remove(index..index + 1)
            }
            interceptorcount = interceptors.size
        } finally {
            interceptorsLock.writeLock.unlock()
        }
    }

    public func listInterceptors(): ArrayList<ServerAddrInterceptorInteface> {
        var ret = ArrayList<ServerAddrInterceptorInteface>()
        try {
            interceptorsLock.readLock.lock()
            for (itcpt in interceptors) {
                ret.add(itcpt)
            }
        } finally {
            interceptorsLock.readLock.unlock()
        }
        return ret
    }

    public func getServerAddr(context: ServerAddrInterceptorContext): ?(String, UInt16) {
        var ret = Option<(String, UInt16)>.None
        if (isDisableInterceptor()) {
            return ret
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                ret = inter.getServerAddr(context)
                match (ret) {
                    case Some(v) => break
                    case _ => ()
                }
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} getServerAddr error. ${ex.toString()}")
            }
        }
        return ret
    }
}
