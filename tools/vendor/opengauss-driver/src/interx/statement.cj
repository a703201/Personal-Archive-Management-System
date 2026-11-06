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

import std.sync.*
import std.collection.*
import std.database.sql.*
import cangjie_tpc::opengauss.slog

public struct StmtInterceptorContext {
    public let pgConnContext: PgConnInterceptorContext
    public let stmtId: Int64
    public let sql: String
    public init(context: PgConnInterceptorContext, stmtId: Int64, sql: String) {
        this.pgConnContext = context
        this.stmtId = stmtId
        this.sql = sql
    }
}

public interface StmtInterceptorInteface <: Interceptor {
    func queryStart(context: StmtInterceptorContext): Unit
    func querySuccess(context: StmtInterceptorContext): Unit
    func queryException(context: StmtInterceptorContext, ex: Exception): Unit
    func updateStart(context: StmtInterceptorContext): Unit
    func updateSuccess(context: StmtInterceptorContext): Unit
    func updateException(context: StmtInterceptorContext, ex: Exception): Unit
}

public class StmtInterceptorManager {
    var interceptors = ArrayList<StmtInterceptorInteface>()
    var interceptorcount = 0i64
    let interceptorsLock = ReadWriteLock()

    static let instLock = Mutex()
    static var inst: ?StmtInterceptorManager = Option<StmtInterceptorManager>.None

    let logger = slog.Default()

    public static func instance(): StmtInterceptorManager {
        match (inst) {
            case Some(v) => return v
            case _ => synchronized(instLock) {
                match (inst) {
                    case Some(v) => return v
                    case _ =>
                        var ret = StmtInterceptorManager()
                        inst = ret
                        return ret
                }
            }
        }
    }

    public func isInterceptorEnable(): Bool {
        return (interceptorcount > 0) && !isDisableInterceptor()
    }

    public func registerInterceptor(interceptor: StmtInterceptorInteface): Unit {
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

    public func listInterceptors(): ArrayList<StmtInterceptorInteface> {
        var ret = ArrayList<StmtInterceptorInteface>()
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

    public func queryStart(context: StmtInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.queryStart(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} queryStart error. ${ex.toString()}")
            }
        }
    }

    public func querySuccess(context: StmtInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.querySuccess(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} queryEnd error. ${ex.toString()}")
            }
        }
    }

    public func queryException(context: StmtInterceptorContext, ex: Exception): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.queryException(context, ex)
            } catch (ex2: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex2.toString()}")
                throw ex2
            } catch (ex2: Exception) {
                logger.error("interceptor ${inter.name()} queryException error. ${ex2.toString()}")
            }
        }
    }

    public func updateStart(context: StmtInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.updateStart(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} updateStart error. ${ex.toString()}")
            }
        }
    }

    public func updateSuccess(context: StmtInterceptorContext): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.updateSuccess(context)
            } catch (ex: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex.toString()}")
                throw ex
            } catch (ex: Exception) {
                logger.error("interceptor ${inter.name()} updateEnd error. ${ex.toString()}")
            }
        }
    }

    public func updateException(context: StmtInterceptorContext, ex: Exception): Unit {
        if (isDisableInterceptor()) {
            return
        }
        var inters = listInterceptors()
        for (inter in inters) {
            try {
                inter.updateException(context, ex)
            } catch (ex2: InterceptorBreakException) {
                // 如果是这个异常，那么直接往外抛出
                logger.error("interceptor ${inter.name()} throws InterceptorBreakException. ${ex2.toString()}")
                throw ex2
            } catch (ex2: Exception) {
                logger.error("interceptor ${inter.name()} updateException error. ${ex2.toString()}")
            }
        }
    }
}
