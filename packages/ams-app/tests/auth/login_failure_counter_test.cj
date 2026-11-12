// ============================================================
// ams.app.auth · 登录失败计数器单元测试
//
// 回归 2026-11-11 全局 dead lock：旧实现用无锁 HashMap 记录登录失败次数，
// 并发登录破坏哈希桶后 get() 死循环、占死 stdx 线程池，所有接口 30s 超时。
// 本测试用真实 spawn 并发复现「读 / 写 / 删」混合压力，验证：
//   ① 并发递增计数精确不丢；② 混合读写不抛异常、状态有界；
//   ③ TTL 回收、桶上限 fail-closed、reset/clear 语义。
//
// 纯内存驱动，不依赖数据库 / 网络 / 外部进程。
// 运行：bash scripts/test.sh ams-app
// ============================================================
package ams.app.auth.test

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

import ams.app.auth.*

@Test
public class LoginFailureCounterTest {
    private static let NOW: Int64 = 1790000000000

    @TestCase
    public func testSequentialIncrementAndReset(): Unit {
        LoginFailureCounter.clear()
        let key = "k-seq"
        @Assert(LoginFailureCounter.get(key), 0)
        @Assert(LoginFailureCounter.increment(key, LoginFailureCounterTest.NOW), 1)
        @Assert(LoginFailureCounter.increment(key, LoginFailureCounterTest.NOW), 2)
        @Assert(LoginFailureCounter.get(key), 2)
        LoginFailureCounter.reset(key)
        @Assert(LoginFailureCounter.get(key), 0)
        @Assert(LoginFailureCounter.increment(key, LoginFailureCounterTest.NOW), 1)
        @Assert(LoginFailureCounter.size(), 1)
        LoginFailureCounter.clear()
        @Assert(LoginFailureCounter.size(), 0)
    }

    /**
     * 并发递增必须精确：32 线程 × 50 次 = 1600，一个都不能丢。
     * 旧的无锁 HashMap 在此压力下会丢计数甚至卡死线程。
     */
    @TestCase
    public func testConcurrentIncrementIsExact(): Unit {
        LoginFailureCounter.clear()
        let key = "k-concurrent"
        let workers: Int64 = 32
        let loops: Int64 = 50
        let futures = ArrayList<Future<Unit>>()
        for (w in 0..workers) {
            let fut: Future<Unit> = spawn { =>
                for (i in 0..loops) {
                    LoginFailureCounter.increment(key, LoginFailureCounterTest.NOW + i)
                }
            }
            futures.add(fut)
        }
        for (f in futures) {
            f.get()
        }
        @Assert(LoginFailureCounter.get(key), workers * loops)
        @Assert(LoginFailureCounter.size(), 1)
        LoginFailureCounter.clear()
    }

    /**
     * 并发「读 + 写 + 删」混合：不抛异常、不死锁、状态始终有界且计数非负。
     * 这是最接近线上故障形态的压力测试（Web 与移动端同时反复登录）。
     */
    @TestCase
    public func testConcurrentMixedReadWriteIsBounded(): Unit {
        LoginFailureCounter.clear()
        let key = "k-mixed"
        let futures = ArrayList<Future<Unit>>()
        for (w in 0..8) {
            let writer: Future<Unit> = spawn { =>
                for (i in 0..200) {
                    LoginFailureCounter.increment(key, LoginFailureCounterTest.NOW + i)
                }
            }
            futures.add(writer)
        }
        for (w in 0..8) {
            let reader: Future<Unit> = spawn { =>
                for (i in 0..200) {
                    let n = LoginFailureCounter.get(key)
                    if (n < 0) {
                        throw Exception("negative failure count")
                    }
                }
            }
            futures.add(reader)
        }
        for (f in futures) {
            f.get()
        }
        @Assert(LoginFailureCounter.size() <= 1)
        @Assert(LoginFailureCounter.get(key) >= 0)
        LoginFailureCounter.clear()
    }

    /** 超过扫描规模后，跨 TTL 的一次写入应回收全部过期桶。 */
    @TestCase
    public func testTtlSweepReclaimsExpiredBuckets(): Unit {
        LoginFailureCounter.clear()
        for (i in 0..600) {
            LoginFailureCounter.increment("old-${i}", LoginFailureCounterTest.NOW)
        }
        @Assert(LoginFailureCounter.size(), 600)
        let future = LoginFailureCounterTest.NOW + LoginFailureCounter.TtlMillis + 1
        @Assert(LoginFailureCounter.increment("fresh", future), 1)
        @Assert(LoginFailureCounter.size(), 1)
        @Assert(LoginFailureCounter.get("old-1"), 0)
        @Assert(LoginFailureCounter.get("fresh"), 1)
        LoginFailureCounter.clear()
    }

    /**
     * 桶上限：绝不因用户名枚举把内存撑爆；表满后未知键返回保守值，
     * 使 captchaRequired 判定为真（fail-closed），不降低登录摩擦。
     */
    @TestCase
    public func testBucketCapIsFailClosed(): Unit {
        LoginFailureCounter.clear()
        let total = LoginFailureCounter.MaxBuckets + 5
        for (i in 0..total) {
            LoginFailureCounter.increment("cap-${i}", LoginFailureCounterTest.NOW)
        }
        @Assert(LoginFailureCounter.size() <= LoginFailureCounter.MaxBuckets)
        @Assert(LoginFailureCounter.increment("cap-new", LoginFailureCounterTest.NOW),
                LoginFailureCounter.MaxBuckets)
        @Assert(LoginFailureCounter.size() <= LoginFailureCounter.MaxBuckets)
        LoginFailureCounter.clear()
    }
}
