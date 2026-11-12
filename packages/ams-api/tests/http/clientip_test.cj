// ============================================================
// ams.api.http · 反向代理客户端 IP 解析单元测试
//
// 覆盖：默认不信任 XFF（零伪造面）、显式开启、可信代理白名单、
//   伪造/非法头回退 socket 地址、X-Real-IP 兜底、IPv4/IPv6 键校验。
// 纯内存驱动，不依赖网络 / 数据库。
// 运行：bash scripts/test.sh ams-api
// ============================================================
package ams.api.http.test

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

import ams.api.http.*

@Test
public class ClientIpTest {
    private static let PEER: String = "10.0.0.1"
    private static let CLIENT: String = "203.0.113.7"

    @TestCase
    public func testDefaultDoesNotTrustForwardedHeaders(): Unit {
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, ClientIpTest.CLIENT, "", false, ""),
                ClientIpTest.PEER)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "", ClientIpTest.CLIENT, false, ""),
                ClientIpTest.PEER)
    }

    @TestCase
    public func testEnabledUsesLeftmostForwardedFor(): Unit {
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, ClientIpTest.CLIENT, "", true, ""),
                ClientIpTest.CLIENT)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER,
                " ${ClientIpTest.CLIENT} , 10.0.0.9 ", "", true, ""),
                ClientIpTest.CLIENT)
    }

    @TestCase
    public func testUntrustedPeerFallsBackToSocketAddress(): Unit {
        @Assert(ClientIp.resolveFrom("198.51.100.2", ClientIpTest.CLIENT, "", true, "10.0.0.1, 10.0.0.2"),
                "198.51.100.2")
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, ClientIpTest.CLIENT, "", true,
                " 10.0.0.2 , ${ClientIpTest.PEER} "),
                ClientIpTest.CLIENT)
    }

    @TestCase
    public func testMalformedHeadersNeverBecomeKeys(): Unit {
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "", "", true, ""), ClientIpTest.PEER)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "not-an-ip", "", true, ""), ClientIpTest.PEER)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "1.2.3.4<script>", "", true, ""), ClientIpTest.PEER)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "9999.1.1.1", "", true, ""), ClientIpTest.PEER)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "1.2.3.4\nX-INJECT: 1", "", true, ""),
                ClientIpTest.PEER)
    }

    @TestCase
    public func testRealIpFallbackAndIpv6(): Unit {
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "", ClientIpTest.CLIENT, true, ""),
                ClientIpTest.CLIENT)
        @Assert(ClientIp.resolveFrom(ClientIpTest.PEER, "2001:db8::1", "", true, ""),
                "2001:db8::1")
        @Assert(ClientIp.validIp("127.0.0.1"), true)
        @Assert(ClientIp.validIp("2001:db8::ffff:192.0.2.1"), true)
        @Assert(ClientIp.validIp(""), false)
        @Assert(ClientIp.validIp("1.2.3"), false)
        @Assert(ClientIp.validIp("1.2.3.4.5"), false)
        @Assert(ClientIp.validIp("1.2.3.9999"), false)
    }

    /** 端到端：未开启开关时，请求头里的 XFF 完全不生效。 */
    @TestCase
    public func testResolveRequestUsesSocketAddressByDefault(): Unit {
        let original = getVariable("AMS_TRUST_PROXY_HEADERS") ?? ""
        setVariable("AMS_TRUST_PROXY_HEADERS", "false")
        let hs = HashMap<String, String>()
        hs.add("x-forwarded-for", ClientIpTest.CLIENT)
        let req = ApiRequest("GET", "/api/auth/captcha", Array<Byte>(), hs, ClientIpTest.PEER)
        @Assert(ClientIp.resolve(req), ClientIpTest.PEER)
        setVariable("AMS_TRUST_PROXY_HEADERS", original)
    }
}
