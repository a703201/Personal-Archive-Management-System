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
import std.collection.*
import cangjie_tpc::opengauss.slog.Default

public struct PgConnInterceptorContext {
    public let connId: Int64
    public let threadid: String
    public let host: String
    public let port: UInt16
    public init(connId: Int64, threadid: String, host: String, port: UInt16) {
        this.connId = connId
        this.threadid = threadid
        this.host = host
        this.port = port
    }
}

public interface PgConnInterceptorInteface <: Interceptor {
    func connectStart(context: PgConnInterceptorContext): Unit
    func connectSuccess(context: PgConnInterceptorContext): Unit
    func connectException(context: PgConnInterceptorContext, ex: Exception): Unit
    func close(context: PgConnInterceptorContext): Unit
}

public class PgConnInterceptorManager {
    var interceptors = ArrayList<PgConnInterceptorInteface>()
    var interceptorcount = 0i64
    let interceptorsLock = ReadWriteLock ()

    static let instLock = Mutex()
    static var inst: ?PgConnInterceptorManager = Option<PgConnInterceptorManager>.None

    let logger = Default()

    public static func instance(): PgConnInterceptorManager {
        match (inst) {
            case Some(v) => return v
            case _ => synchronized(instLock) {
                match (inst) {
                    case Some(v) => return v
                    case _ =>
                        var ret = PgConnInterceptorManager()
                        inst = ret
                        return ret
                }
            }
        }
    }

    public func isInterceptorEnable(): Bool {
        return (interceptorcount > 0) && !isDisableInterceptor()
    }

    public func registerInterceptor(interceptor: PgConnInterceptorInteface): Unit {
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

    public func listInterceptors(): ArrayList<PgConnInterceptorInteface> {
        var ret = ArrayList<PgConnInterceptorInteface>()
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

    public func connectStart(context: PgConnInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.connectStart(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} connectStart error. ${ex.toString()}")
            }
        }
    }

    public func connectSuccess(context: PgConnInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.connectSuccess(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} connectSuccess error. ${ex.toString()}")
            }
        }
    }

    public func connectException(context: PgConnInterceptorContext, ex: Exception): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.connectException(context, ex)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex2: Exception) {
                logger.error("interceptor ${inter.name()} connectException error. ${ex2.toString()}")
            }
        }
    }

    public func close(context: PgConnInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.close(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} close error. ${ex.toString()}")
            }
        }
    }
}
