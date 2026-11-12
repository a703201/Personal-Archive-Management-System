// ============================================================
// ams-storage · 多厂商 Provider Registry 单元测试（Q2 扩展）
//
// 验证：平台清单完整、本地为默认、旧变量兼容、新变量优先、
//       未知平台失败关闭、厂商 profile 真的影响寻址风格。
// ============================================================
package ams.storage.test

import std.unittest.*
import std.env.*
import std.collection.*

import ams.storage.*

class MemoryTransportForProviders <: S3Transport {
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
public class ProvidersTest {
    private static func reset(): Unit {
        setVariable("AMS_STORAGE_PROVIDER", "")
        setVariable("AMS_STORAGE_BACKEND", "fs")
        setVariable("AMS_S3_ENDPOINT", "")
        setVariable("AMS_S3_BUCKET", "")
        setVariable("AMS_S3_REGION", "")
        setVariable("AMS_S3_ACCESS_KEY", "")
        setVariable("AMS_S3_SECRET_KEY", "")
        setVariable("AMS_S3_PATH_STYLE", "")
    }

    private static func fullEnv(): Unit {
        setVariable("AMS_S3_ENDPOINT", "http://minio:9000")
        setVariable("AMS_S3_BUCKET", "ams-attachments")
        setVariable("AMS_S3_REGION", "cn-north-4")
        setVariable("AMS_S3_ACCESS_KEY", "test-ak")
        setVariable("AMS_S3_SECRET_KEY", "test-sk")
        setVariable("AMS_S3_PATH_STYLE", "")
    }

    @TestCase
    public func testAllProvidersAvailable() {
        @Assert(StorageProviders.all().size, 8)
    }

    @TestCase
    public func testEveryProviderHasIdentityAndNotes() {
        for (p in StorageProviders.all()) {
            @Assert(p.code.isEmpty(), false)
            @Assert(p.displayName.isEmpty(), false)
            @Assert(p.bucketRule.isEmpty(), false)
            @Assert(p.notes.isEmpty(), false)
        }
    }

    @TestCase
    public func testKnownProvidersFound() {
        let codes = ["local", "minio", "huawei", "aliyun", "qiniu", "tencent", "aws", "s3"]
        for (c in codes) {
            @Assert(StorageProviders.find(c).isSome(), true)
        }
        @Assert(StorageProviders.find("not-a-cloud").isSome(), false)
    }

    @TestCase
    public func testLocalIsTheOnlyLocalBackend() {
        var localCount: Int64 = 0
        for (p in StorageProviders.all()) {
            if (p.isLocal()) {
                localCount = localCount + 1
                @Assert(p.backendCode(), 0)
                @Assert(p.needsCredentials(), false)
            } else {
                @Assert(p.backendCode(), 1)
                @Assert(p.needsCredentials(), true)
            }
        }
        @Assert(localCount, 1)
    }

    @TestCase
    public func testSignatureProtocolMapping() {
        match (StorageProviders.find("local")) {
            case Some(p) => @Assert(StorageProviders.signatureName(p.signature), "none")
            case None => @Assert(true, false)
        }
        let s3Codes = ["minio", "huawei", "aliyun", "qiniu", "tencent", "aws", "s3"]
        for (c in s3Codes) {
            match (StorageProviders.find(c)) {
                case Some(p) => @Assert(StorageProviders.signatureName(p.signature), "sigv4")
                case None => @Assert(true, false)
            }
        }
    }

    @TestCase
    public func testAddressingStyleDiffersByVendor() {
        // MinIO 默认 path-style；华为云/阿里云/腾讯/七牛/AWS 默认 virtual-host
        match (StorageProviders.find("minio")) {
            case Some(p) => @Assert(p.defaultPathStyle, true)
            case None => @Assert(true, false)
        }
        let vhost = ["huawei", "aliyun", "qiniu", "tencent", "aws"]
        for (c in vhost) {
            match (StorageProviders.find(c)) {
                case Some(p) =>
                    @Assert(p.defaultPathStyle, false)
                    @Assert(p.supportsVirtualHost, true)
                case None => @Assert(true, false)
            }
        }
    }

    @TestCase
    public func testCurrentCodeDefaultsToLocal() {
        ProvidersTest.reset()
        @Assert(StorageProviders.currentCode(), "local")
        @Assert(StorageProviders.current().isLocal(), true)
    }

    @TestCase
    public func testLegacyBackendCompatibility() {
        ProvidersTest.reset()
        setVariable("AMS_STORAGE_BACKEND", "s3")
        @Assert(StorageProviders.currentCode(), "s3")
        setVariable("AMS_STORAGE_BACKEND", "fs")
        @Assert(StorageProviders.currentCode(), "local")
        ProvidersTest.reset()
    }

    @TestCase
    public func testProviderTakesPriorityOverLegacyBackend() {
        ProvidersTest.reset()
        setVariable("AMS_STORAGE_BACKEND", "s3")
        setVariable("AMS_STORAGE_PROVIDER", "huawei")
        @Assert(StorageProviders.currentCode(), "huawei")
        ProvidersTest.reset()
    }

    @TestCase
    public func testUnknownProviderFailsClosed() {
        ProvidersTest.reset()
        setVariable("AMS_STORAGE_PROVIDER", "unknown-cloud")
        var rejected = false
        try {
            let p = StorageProviders.current()
            if (p.code.isEmpty()) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
        ProvidersTest.reset()
    }

    @TestCase
    public func testHintContainsEndpointTemplate() {
        let h = StorageProviders.hint("huawei")
        @Assert(h.contains("obs.<region>.myhuaweicloud.com"), true)
        @Assert(h.contains("signature=sigv4"), true)
        @Assert(StorageProviders.hint("local").contains("signature=none"), true)
        @Assert(StorageProviders.hint("nope"), "")
    }

    @TestCase
    public func testFactoryAppliesVendorAddressingStyle() {
        ProvidersTest.reset()
        setVariable("AMS_STORAGE_PROVIDER", "huawei")
        ProvidersTest.fullEnv()
        let t = MemoryTransportForProviders()
        let b = StorageBackends.make(
            "./.tmp/storage-provider-test", "attachments",
            transport: Some<S3Transport>(t))
        @Assert(b.backendCode(), 1)
        b.put("k.enc", [1u8])
        // huawei profile 默认 virtual-host，不是 path-style
        @Assert(t.lastUrl.startsWith("http://ams-attachments."), true)
        @Assert(t.lastUrl.contains("/ams-attachments/attachments/"), false)
        ProvidersTest.reset()
    }

    @TestCase
    public func testFactoryMinioUsesPathStyle() {
        ProvidersTest.reset()
        setVariable("AMS_STORAGE_PROVIDER", "minio")
        ProvidersTest.fullEnv()
        let t = MemoryTransportForProviders()
        let b = StorageBackends.make(
            "./.tmp/storage-provider-test", "exports",
            transport: Some<S3Transport>(t))
        b.put("k.enc", [1u8])
        @Assert(t.lastUrl, "http://minio:9000/ams-attachments/exports/k.enc")
        ProvidersTest.reset()
    }
}
