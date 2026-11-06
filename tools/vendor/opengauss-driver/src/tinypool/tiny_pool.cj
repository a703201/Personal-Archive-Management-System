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

internal import cangjie_tpc::opengauss.slog.*
internal import std.sync.*
import std.sync.*
import cangjie_tpc::opengauss.sema.*
import cangjie_tpc::opengauss.slog

public class TinyPool<T> <: Pool<T> & Equatable<TinyPool<T>> {
    let logger = slog.Default()
    let DEFAULT_CONN_TIMEOUT = Duration.microsecond * (30)
    let mux = Mutex()
    let idleEntry: BoundedQueue<Entry<T>>
    let options: Options<T>
    var ticker: Timer
    var entryCount: Int32
    let objId: UInt64

    public init(options: Options<T>) {
        this.options = options
        idleEntry = BoundedQueue<Entry<T>>(Int64(options.maxSize))
        entryCount = options.maxIdleSize
        let rnd = Random(UInt64(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        objId = rnd.nextUInt64()
        ticker = Timer.once(Duration.hour, { => ()})
        initIdleEntry()
        backgroundCheckIdleLife()
    }

    public operator func !=(rhs: TinyPool<T>): Bool {
        return this.objId != rhs.objId
    }

    public operator func ==(rhs: TinyPool<T>): Bool {
        return this.objId == rhs.objId
    }

    func initIdleEntry(): Unit {
        let list = ArrayList<Future<Unit>>()
        for (i in 0..options.maxIdleSize) {
            let fut = spawn {
                 => createEntry()
            }
            list.add(fut)
        }
        for (fut in list) {
            fut.get()
        }
    }

    func createEntry(): Unit {
        var value = options.constructor()
        match (value) {
            case Some(v) =>
                let entry = Entry<T>(this, v)
                release(entry)
            case None => throw Exception("constructor entry failed")
        }
    }

    func backgroundCheckIdleLife() {
        ticker.cancel()
        ticker = Timer.repeat(options.keepAliveTime, options.keepAliveTime, checkIdleLife)
    }

    func checkIdleLife(): Unit {
        let idleCount = idleEntry.size
        var discardCount = 0i32
        let list = ArrayList<Entry<T>>()
        try {
            for (i in 0..idleCount) {
                var item = idleEntry.tryGet()
                match (item) {
                    case Some(v) =>
                        var idle = v.idleDuration()
                        if ((idle > options.idleTimeout && Int32(idleCount) - discardCount > options.maxIdleSize) ||
                            (DateTime.now().toUnixTimeStamp() - v.creationTime > options.maxLifeTime)) {
                            v.acquire()
                            this.discard(v)
                            discardCount++
                        } else {
                            list.add(v)
                        }
                    case None =>
                        eprintln("can not try get idle")
                        break
                }
            }
            for (entry in list) {
                this.release(entry)
            }
        } catch (e: Exception) {
            eprintln("exception ${e.message}")
        }
    }

    func getIdleEntry(timeout: Duration): Entry<T> {
        var item = idleEntry.get(timeout)
        match (item) {
            case Some(v) =>
                v.acquire()
                return v
            case None => throw Exception("dead lock")
        }
    }

    public func acquire(): Option<Entry<T>> {
        return acquire(DEFAULT_CONN_TIMEOUT)
    }

    public func acquire(timeout: Duration): Option<Entry<T>> {
        mux.lock()
        if (idleEntry.size == 0 && entryCount < options.maxSize) {
            entryCount++
            mux.unlock()
            var value = options.constructor()
            match (value) {
                case Some(v) =>
                    let entry = Entry<T>(this, v)
                    entry.acquire()
                    return entry
                case None => throw Exception("constructor entry failed")
            }
        }
        mux.unlock()
        return getIdleEntry(timeout)
    }

    public func release(entry: Entry<T>): Option<Unit> {
        if (entry.pool as TinyPool<T> != this) {
            throw Exception("the entry is owned by another pool")
        }

        idleEntry.put(entry)

        return
    }

    public func discard(entry: Entry<T>): Option<Unit> {
        if (entry.pool as TinyPool<T> != this) {
            throw Exception("the entry is owned by another pool")
        }
        options.destructor(entry.value)
        return
    }

    public func stat(): Stat {
        return Stat()
    }
}
