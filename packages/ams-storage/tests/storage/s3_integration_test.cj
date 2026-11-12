// ============================================================
// ams-storage · 真实 OBS 端到端集成测试（可选）
//
// 默认**跳过**（不依赖外部服务，test.sh 全绿）。
// 仅在同时满足以下条件时真连对象存储做往返验证：
//   · 环境变量 AMS_IT_MINIO=1
//   · 127.0.0.1:9000 有可达的 MinIO（docker 起一个即可）
//
// 启动 MinIO（任选其一）：
//   docker run -d --name ams-minio -p 9000:9000 -p 9001:9001 \
//     -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
//     minio/minio server /data --console-address ":9001"
//
// 然后：AMS_IT_MINIO=1 bash scripts/test.sh ams-storage
//
// 验证内容：创建桶 → PUT 对象（含中文/二进制）→ GET 原样返回 →
//   GET 不存在对象返回 None → DELETE 对象 → 删除桶（清理）。
// 这证明 SigV4 签名 + HTTP/1.1 客户端 + 响应解析**真实可用**。
// ============================================================
package ams.storage.test

import std.unittest.*
import std.collection.*
import std.env.*
import std.net.*
import std.time.*

import ams.storage.*

@Test
public class S3IntegrationTest {

    private static func enabled(): Bool {
        return (getVariable("AMS_IT_MINIO") ?? "") == "1"
    }

    private static func minioReachable(): Bool {
        try {
            let s = TcpSocket("127.0.0.1", 9000u16)
            s.connect(timeout: Duration.second * 2)
            s.close()
            return true
        } catch (e: Exception) {
            return false
        }
    }

    private static func env(name: String, fallback: String): String {
        match (getVariable(name)) {
            case Some(v) => return if (v.isEmpty()) { fallback } else { v }
            case None => return fallback
        }
    }

    @TestCase
    public func testRealMinioRoundTrip() {
        if (!S3IntegrationTest.enabled()) {
            println("[SKIP] S3IntegrationTest：未设置 AMS_IT_MINIO=1，跳过真实 OBS 连通测试")
            @Assert(true, true)
            return
        }
        if (!S3IntegrationTest.minioReachable()) {
            println("[SKIP] S3IntegrationTest：127.0.0.1:9000 不可达，跳过（请先启动 MinIO）")
            @Assert(true, true)
            return
        }

        let endpoint = S3IntegrationTest.env("AMS_IT_MINIO_ENDPOINT", "http://127.0.0.1:9000")
        let region = S3IntegrationTest.env("AMS_IT_MINIO_REGION", "us-east-1")
        let ak = S3IntegrationTest.env("AMS_IT_MINIO_ROOT_USER", "minioadmin")
        let sk = S3IntegrationTest.env("AMS_IT_MINIO_ROOT_PASSWORD", "minioadmin")
        let bucket = "ams-it-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"

        let cfg = S3StorageConfig(endpoint, bucket, region, ak, sk, true, "")
        let t = HttpS3Transport.forConfig(cfg)

        // 1) 创建桶（PUT /bucket）
        t.putObject("${endpoint}/${bucket}", Array<Byte>())

        // 2) PUT 对象（含中文与二进制，验证签名 + 上传 + 中文密钥编码）
        let payload = "加密附件密文-中文payload-\u{00}ab\u{ff}".toArray()
        let objUrl = cfg.objectUrl("附件_a.enc")
        t.putObject(objUrl, payload)

        // 3) GET 原样返回
        match (t.getObject(objUrl)) {
            case Some(got) =>
                @Assert(got.size, payload.size)
                var same = true
                var i: Int64 = 0
                while (i < payload.size) {
                    if (got[i] != payload[i]) {
                        same = false
                    }
                    i = i + 1
                }
                @Assert(same, true)
            case None => @Assert(true, false)
        }

        // 4) GET 不存在对象 → None（语义区分于故障）
        @Assert(t.getObject(cfg.objectUrl("missing.enc")).isNone(), true)

        // 5) DELETE 对象
        t.deleteObject(objUrl)

        // 6) 删除桶（清理）
        t.deleteObject("${endpoint}/${bucket}")

        println("[OK] S3IntegrationTest：MinIO 往返成功（PUT/GET/404/DELETE）")
    }
}
