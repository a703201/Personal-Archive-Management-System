// ============================================================
// ams-storage · Q2 方案 A（存储可插拔骨架）单元测试
//
// 重点：
//   ① 默认 fs 零回归（backendCode=0）；
//   ② 未知后端 / 缺配置 / 缺传输层一律失败关闭，绝不静默回落；
//   ③ 注入真实 transport 后骨架可读写、URL 与键前缀正确；
//   ④ 对象键消毒不切碎中文 UTF-8（本仓踩过多次的坑）。
//
// 纯内存驱动，不依赖数据库 / 网络 / 真实对象存储。
// 运行：bash scripts/test.sh ams-storage
// ============================================================
package ams.storage.test

import std.unittest.*
import std.collection.*
import std.env.*

import ams.storage.*

/** 内存传输层：用于验证骨架的接口与 URL 组装，不代表真实 S3 能力。 */
class MemoryS3Transport <: S3Transport {
    private let objects: HashMap<String, Array<Byte>>
    public var lastUrl: String = ""

    public init() {
        this.objects = HashMap<String, Array<Byte>>()
    }

    public func putObject(url: String, data: Array<Byte>): Unit {
        this.lastUrl = url
        this.objects[url] = data
    }

    public func getObject(url: String): Option<Array<Byte>> {
        return this.objects.get(url)
    }
}

@Test
public class S3SkeletonTest {
    private static func resetEnv(): Unit {
        setVariable("AMS_STORAGE_PROVIDER", "")
        setVariable("AMS_STORAGE_BACKEND", "fs")
        setVariable("AMS_S3_ENDPOINT", "")
        setVariable("AMS_S3_BUCKET", "")
        setVariable("AMS_S3_REGION", "")
        setVariable("AMS_S3_ACCESS_KEY", "")
        setVariable("AMS_S3_SECRET_KEY", "")
    }

    private static func fullS3Env(): Unit {
        setVariable("AMS_STORAGE_BACKEND", "s3")
        setVariable("AMS_S3_ENDPOINT", "http://minio:9000")
        setVariable("AMS_S3_BUCKET", "ams-attachments")
        setVariable("AMS_S3_REGION", "cn-south-1")
        setVariable("AMS_S3_ACCESS_KEY", "test-ak")
        setVariable("AMS_S3_SECRET_KEY", "test-sk")
    }

    private static func cfg(pathStyle: Bool): S3StorageConfig {
        return S3StorageConfig(
            "http://minio:9000", "ams-attachments", "cn-south-1",
            "test-ak", "test-sk", pathStyle, "attachments")
    }

    /** 捕获异常并返回是否抛出（仓颉单测无 AssertThrows，沿用项目既有范式）。 */
    private static func throws(f: () -> Unit): Bool {
        var thrown = false
        try {
            f()
        } catch (e: Exception) {
            thrown = true
        }
        return thrown
    }

    @TestCase
    public func testDefaultBackendIsFsAndCodeZero() {
        S3SkeletonTest.resetEnv()
        let b = StorageBackends.make("./.tmp/storage-skeleton-test", "attachments")
        @Assert(b.backendCode(), 0)
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testExplicitFsIsSameAsDefault() {
        S3SkeletonTest.resetEnv()
        setVariable("AMS_STORAGE_BACKEND", "fs")
        let b = StorageBackends.make("./.tmp/storage-skeleton-test", "exports")
        @Assert(b.backendCode(), 0)
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testUnknownBackendFailsClosed() {
        S3SkeletonTest.resetEnv()
        setVariable("AMS_STORAGE_BACKEND", "ftp")
        let rejected = S3SkeletonTest.throws({ =>
            let b = StorageBackends.make("./.tmp/storage-skeleton-test", "attachments")
            let n = b.backendCode()
            ()
        })
        @Assert(rejected, true)
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testS3WithoutConfigFailsClosed() {
        S3SkeletonTest.resetEnv()
        setVariable("AMS_STORAGE_BACKEND", "s3")
        let rejected = S3SkeletonTest.throws({ =>
            let b = StorageBackends.make("./.tmp/storage-skeleton-test", "attachments")
            let n = b.backendCode()
            ()
        })
        @Assert(rejected, true)
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testFactoryS3WithConfigBuildsRealTransport() {
        S3SkeletonTest.fullS3Env()
        // 配置完整时，工厂应构建**真实** HttpS3Transport 并返回后端码 1；
        // 真正的网络 I/O 延后到首次 put/get，启动期不连网、不抛错。
        let rejected = S3SkeletonTest.throws({ =>
            let b = StorageBackends.make("./.tmp/storage-skeleton-test", "attachments")
            let n = b.backendCode()
            ()
        })
        @Assert(rejected, false)
        let b = StorageBackends.make("./.tmp/storage-skeleton-test", "attachments")
        @Assert(b.backendCode(), 1)
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testConfigFromEnvAndValidate() {
        S3SkeletonTest.fullS3Env()
        match (S3StorageConfig.fromEnv("exports")) {
            case Some(c) =>
                c.validate()
                @Assert(c.bucket, "ams-attachments")
                @Assert(c.prefix, "exports")
            case None => @Assert(true, false)
        }
        S3SkeletonTest.resetEnv()
    }

    @TestCase
    public func testInvalidEndpointRejected() {
        let bad = S3StorageConfig(
            "minio:9000", "ams-attachments", "cn-south-1",
            "ak", "sk", true, "attachments")
        @Assert(S3SkeletonTest.throws({ => bad.validate() }), true)
    }

    @TestCase
    public func testObjectUrlPathStyle() {
        let c = S3SkeletonTest.cfg(true)
        @Assert(c.objectUrl("att_123.enc"),
            "http://minio:9000/ams-attachments/attachments/att_123.enc")
    }

    @TestCase
    public func testObjectUrlVirtualHost() {
        let c = S3SkeletonTest.cfg(false)
        @Assert(c.objectUrl("att_123.enc"),
            "http://ams-attachments.minio:9000/attachments/att_123.enc")
    }

    @TestCase
    public func testEndpointTrailingSlashTrimmed() {
        let c = S3StorageConfig(
            "http://minio:9000/", "ams-attachments", "cn-south-1",
            "ak", "sk", true, "backups")
        @Assert(c.objectUrl("x.enc"),
            "http://minio:9000/ams-attachments/backups/x.enc")
    }

    @TestCase
    public func testSanitizeKeyBlocksTraversal() {
        let s = S3StorageConfig.sanitizeKey("../../etc/passwd")
        @Assert(s.contains(".."), false)
        @Assert(s.contains("/etc/passwd"), true)
        @Assert(S3StorageConfig.sanitizeKey("a\\b\\c"), "a_b_c")
    }

    @TestCase
    public func testSanitizeKeyKeepsChineseIntact() {
        let s = S3StorageConfig.sanitizeKey("身份证_扫描件.png")
        @Assert(s.contains("身份证"), true)
        @Assert(s.contains("扫描件"), true)
        @Assert(s.endsWith(".png"), true)
    }

    @TestCase
    public func testSanitizeKeyReplacesControlChars() {
        let s = S3StorageConfig.sanitizeKey("a\nb\tc")
        @Assert(s.contains("\n"), false)
        @Assert(s.startsWith("a_b"), true)
    }

    @TestCase
    public func testUnavailableTransportFailsClosed() {
        let s = S3ObjectStorage(S3SkeletonTest.cfg(true))
        @Assert(s.backendCode(), 1)
        @Assert(S3SkeletonTest.throws({ => s.put("k", [1u8, 2u8]) }), true)
        @Assert(S3SkeletonTest.throws({ =>
            match (s.get("k")) {
                case Some(_) => ()
                case None => ()
            }
        }), true)
    }

    @TestCase
    public func testInjectedTransportRoundTrip() {
        let t = MemoryS3Transport()
        let s = S3ObjectStorage(S3SkeletonTest.cfg(true), transport: t)
        @Assert(s.backendCode(), 1)
        s.put("att_9.enc", [9u8, 8u8, 7u8])
        @Assert(t.lastUrl,
            "http://minio:9000/ams-attachments/attachments/att_9.enc")
        match (s.get("att_9.enc")) {
            case Some(d) =>
                @Assert(d.size, 3)
                @Assert(d[0], 9u8)
                @Assert(d[2], 7u8)
            case None => @Assert(true, false)
        }
        @Assert(s.get("missing").isNone(), true)
    }

    @TestCase
    public func testFactoryS3WithInjectedTransportWorks() {
        S3SkeletonTest.fullS3Env()
        let t = MemoryS3Transport()
        let b = StorageBackends.make(
            "./.tmp/storage-skeleton-test", "attachments", transport: Some<S3Transport>(t))
        @Assert(b.backendCode(), 1)
        b.put("k.enc", [42u8])
        match (b.get("k.enc")) {
            case Some(d) => @Assert(d[0], 42u8)
            case None => @Assert(true, false)
        }
        S3SkeletonTest.resetEnv()
    }
}
