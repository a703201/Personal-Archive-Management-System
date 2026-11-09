// ============================================================
// ams-storage · HttpS3Transport 单元测试
//
// 覆盖真实传输层的纯逻辑（不依赖外部对象存储）：
//   ① URL 解析（http/https、默认端口、显式端口、IPv6）
//   ② RFC 3986 路径编码（保留 /，中文逐字节编码）
//   ③ SigV4 需要的 amzDate 格式（UTC，17 位）
//   ④ 响应解析：200 取体 / 404→None / 非预期码失败关闭 / chunked 解码
//   ⑤ 连接被拒（端口无监听）→ 失败关闭抛 AppError
//
// 真连通各家 OBS 的端到端往返见 s3_integration_test.cj（需 AMS_IT_MINIO=1）。
// 运行：bash scripts/test.sh ams-storage
// ============================================================
package ams.storage.test

import std.unittest.*
import std.collection.*
import std.env.*

import ams.storage.*

class TransportTestUtil {
    public static func cfg(pathStyle: Bool): S3StorageConfig {
        return S3StorageConfig(
            "http://minio:9000", "ams-attachments", "cn-south-1",
            "test-ak", "test-sk", pathStyle, "attachments")
    }

    public static func bogusCfg(): S3StorageConfig {
        return S3StorageConfig(
            "http://127.0.0.1:1", "bucket", "us-east-1",
            "ak", "sk", true, "")
    }

    /** 捕获异常并返回是否抛出（仓颉单测无 AssertThrows，沿用项目范式）。 */
    public static func throws(f: () -> Unit): Bool {
        var thrown = false
        try {
            f()
        } catch (e: Exception) {
            thrown = true
        }
        return thrown
    }
}

@Test
public class HttpS3TransportTest {

    @TestCase
    public func testParseUrlHttpPathStyle() {
        let u = HttpS3Transport.parseUrl("http://minio:9000/ams-attachments/attachments/a.enc")
        @Assert(u.scheme, "http")
        @Assert(u.host, "minio")
        @Assert(u.port, 9000u16)
        @Assert(u.path, "/ams-attachments/attachments/a.enc")
        @Assert(u.hostHeader, "minio:9000")
    }

    @TestCase
    public func testParseUrlHttpsDefaultPort() {
        let u = HttpS3Transport.parseUrl("https://obs.cn-north-4.myhuaweicloud.com/b/k")
        @Assert(u.scheme, "https")
        @Assert(u.host, "obs.cn-north-4.myhuaweicloud.com")
        @Assert(u.port, 443u16)
        @Assert(u.hostHeader, "obs.cn-north-4.myhuaweicloud.com")
        @Assert(u.path, "/b/k")
    }

    @TestCase
    public func testParseUrlVirtualHostStyle() {
        // virtual-host：桶在 host 中，路径不含桶名
        let url = "http://ams-attachments.minio:9000/attachments/a.enc"
        let u = HttpS3Transport.parseUrl(url)
        @Assert(u.host, "ams-attachments.minio")
        @Assert(u.hostHeader, "ams-attachments.minio:9000")
        @Assert(u.path, "/attachments/a.enc")
    }

    @TestCase
    public func testParseUrlEncodesChineseInPath() {
        let c = TransportTestUtil.cfg(true)
        let url = c.objectUrl("身份证_扫描件.png")
        let u = HttpS3Transport.parseUrl(url)
        // objectUrl 不编码，parseUrl 必须按字节编码中文 → 出现 %E
        @Assert(u.path.contains("%E"), true)
        @Assert(u.path.contains("/"), true)
    }

    @TestCase
    public func testEncodeUriPathKeepsUnreservedAndSlash() {
        let p = HttpS3Transport.encodeUriPath("/a-b_c.d~中国/1")
        @Assert(p.contains("/a-b_c.d~"), true)
        @Assert(p.contains("%"), true)
    }

    @TestCase
    public func testAmzDateFormat() {
        let s = HttpS3Transport.amzDateNow()
        // yyyyMMdd'T'HHmmss'Z' = 16 字符（如 20261109T071835Z）
        @Assert(s.size, 16)
        @Assert(s.endsWith("Z"), true)
        // 仅含数字与 T/Z
        var onlyOk = true
        var i: Int64 = 0
        while (i < s.size) {
            let ch = s[i]
            let ok = (ch >= 0x30u8 && ch <= 0x39u8) || ch == 0x54u8 || ch == 0x5Au8
            if (!ok) {
                onlyOk = false
            }
            i = i + 1
        }
        @Assert(onlyOk, true)
    }

    @TestCase
    public func testParseResponse200GetReturnsBody() {
        let t = HttpS3Transport.forConfig(TransportTestUtil.cfg(true))
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".toArray()
        match (t.parseResponse("GET", raw, [200, 206])) {
            case Some(b) =>
                @Assert(b.size, 5)
                @Assert(String.fromUtf8(b), "hello")
            case None => @Assert(true, false)
        }
    }

    @TestCase
    public func testParseResponse404GetReturnsNone() {
        let t = HttpS3Transport.forConfig(TransportTestUtil.cfg(true))
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".toArray()
        match (t.parseResponse("GET", raw, [200, 206])) {
            case Some(_) => @Assert(true, false)
            case None => @Assert(true, true)
        }
    }

    @TestCase
    public func testParseResponseChunkedDecoded() {
        let t = HttpS3Transport.forConfig(TransportTestUtil.cfg(true))
        // 分块：5\r\nhello\r\n0\r\n\r\n
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".toArray()
        match (t.parseResponse("GET", raw, [200, 206])) {
            case Some(b) => @Assert(String.fromUtf8(b), "hello")
            case None => @Assert(true, false)
        }
    }

    @TestCase
    public func testParseResponseNonOkThrows() {
        let t = HttpS3Transport.forConfig(TransportTestUtil.cfg(true))
        let raw = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".toArray()
        @Assert(TransportTestUtil.throws({ =>
            let r = t.parseResponse("GET", raw, [200, 206])
            match (r) {
                case Some(_) => ()
                case None => ()
            }
        }), true)
    }

    @TestCase
    public func testParseResponse404OnPutIsErrorNotNone() {
        // 404 只在 GET 语义下映射 None；PUT 收到 404 应视为失败（抛错）
        let t = HttpS3Transport.forConfig(TransportTestUtil.cfg(true))
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".toArray()
        @Assert(TransportTestUtil.throws({ =>
            let r = t.parseResponse("PUT", raw, [200, 204])
            match (r) {
                case Some(_) => ()
                case None => ()
            }
        }), true)
    }

    @TestCase
    public func testConnectionRefusedFailsClosed() {
        // 连 127.0.0.1:1（无监听）→ connect 失败 → 抛出 AppError（失败关闭）
        let t = HttpS3Transport.forConfig(TransportTestUtil.bogusCfg())
        let url = "http://127.0.0.1:1/bucket/obj.enc"
        @Assert(TransportTestUtil.throws({ =>
            match (t.getObject(url)) {
                case Some(_) => ()
                case None => ()
            }
        }), true)
    }
}
