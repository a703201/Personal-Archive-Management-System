// ============================================================
// ams.app.attachment · 迁移期双写开关单元测试
//
// 纯内存驱动：
//   - 未开启迁移：mirror 不产生任何写入
//   - 开启后：同一份字节写入目标；目标失败只计数、不抛错
//   - 关闭后：目标清空、失败计数归零
// 运行：bash scripts/test.sh ams-app
// ============================================================
package ams.app.attachment.test

import std.unittest.*
import std.unittest.testmacro.*

import ams.app.attachment.*
import ams.kernel.error.*
import ams.storage.*

/** 内存后端：记录 put 次数，可切换为抛错。 */
private class CountingBackend <: StorageBackend {
    public var puts: Int64 = 0
    public var fail: Bool = false

    public func put(key: String, data: Array<Byte>): Unit {
        if (this.fail) {
            throw AppError(AppErrorKind.Internal, "target unavailable")
        }
        this.puts = this.puts + 1
    }

    public func get(key: String): Option<Array<Byte>> {
        return None
    }

    public func backendCode(): Int64 {
        return 0
    }
}

@Test
public class StorageDualWriteTest {
    @TestCase
    public func idleByDefault(): Unit {
        let d = StorageDualWrite()
        @Assert(!d.isActive())
        @Assert(d.failureCount() == 0)
        let target = CountingBackend()
        d.mirror("att_1_v1.bin", Array<Byte>(4, repeat: 1))
        @Assert(target.puts == 0)
    }

    @TestCase
    public func mirrorsWhenActive(): Unit {
        let d = StorageDualWrite()
        let target = CountingBackend()
        d.setTarget(target)
        @Assert(d.isActive())
        d.mirror("att_1_v1.bin", Array<Byte>(4, repeat: 1))
        d.mirror("thumb_1.png", Array<Byte>(2, repeat: 2))
        @Assert(target.puts == 2)
        @Assert(d.failureCount() == 0)
    }

    @TestCase
    public func failureIsCountedNotThrown(): Unit {
        let d = StorageDualWrite()
        let target = CountingBackend()
        target.fail = true
        d.setTarget(target)
        d.mirror("att_1_v1.bin", Array<Byte>(4, repeat: 1))
        @Assert(d.failureCount() == 1)
        d.setTarget(None)
        @Assert(!d.isActive())
        @Assert(d.failureCount() == 0)
    }
}
