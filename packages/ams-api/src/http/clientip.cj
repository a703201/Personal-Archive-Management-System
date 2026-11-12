// ============================================================
// ams.api.http · 反向代理下的客户端 IP 解析
//
// 【问题】验证码 / 通用限流按 `req.remoteAddr` 分桶。若前面挂了 Nginx、
//   Ingress 或云负载均衡，socket 对端地址恒为代理 IP，所有用户共用一个桶，
//   会被误限流（2026-11-09 审查发现，当时只标注「部署时确认」）。
//
// 【安全前提】X-Forwarded-For / X-Real-IP 是**客户端可伪造**的请求头，
//   默认绝不采信。只有显式设置 `AMS_TRUST_PROXY_HEADERS=true` 才启用，
//   并可用 `AMS_TRUSTED_PROXY_IPS` 限定只信任来自指定代理的直连。
//
// 【部署要求】启用后，反代必须**覆盖**而非追加 XFF，例如 Nginx：
//   proxy_set_header X-Forwarded-For $remote_addr;
//   否则客户端自带的伪造 XFF 会被保留在头部，仍可影响分桶。
//
// 【边界】这里只把 IP 规范化成限流 / 审计的键：校验 IPv4 数字段与
//   IPv6 字符集、长度上限，不做路由级合法性判断；非法一律回退
//   socket 地址，绝不把未校验字符串写进日志或内存表。
// ============================================================
package ams.api.http

import std.env.*

public class ClientIp {
    /** 单个 IP 字符串的最大长度（IPv6 + 端口/区域形态留足余量）。 */
    public static let MaxLen: Int64 = 64

    /**
     * 按当前进程配置解析客户端 IP。
     * 默认关闭代理头（返回 socket 对端地址），零回归、零伪造面。
     */
    public static func resolve(req: ApiRequest): String {
        let trust = (getVariable("AMS_TRUST_PROXY_HEADERS") ?? "").toAsciiLower() == "true"
        let proxies = getVariable("AMS_TRUSTED_PROXY_IPS") ?? ""
        return ClientIp.resolveFrom(
            req.remoteAddr,
            req.headers.get("x-forwarded-for") ?? "",
            req.headers.get("x-real-ip") ?? "",
            trust,
            proxies
        )
    }

    /**
     * 纯函数版（不读进程环境，供单测覆盖各分支）。
     *
     * @param remoteAddr        socket 对端地址
     * @param xForwardedFor     原始 XFF 头（可含逗号分隔的多级代理）
     * @param xRealIp           原始 X-Real-IP 头
     * @param trustProxyHeaders 是否显式信任代理头
     * @param trustedProxies    可信直连代理地址列表（逗号分隔；空=不限制直连来源）
     */
    public static func resolveFrom(
        remoteAddr: String,
        xForwardedFor: String,
        xRealIp: String,
        trustProxyHeaders: Bool,
        trustedProxies: String
    ): String {
        if (!trustProxyHeaders) {
            return remoteAddr
        }
        if (!ClientIp.isTrustedPeer(remoteAddr, trustedProxies)) {
            return remoteAddr
        }
        // XFF 取第一段（代理覆盖写 $remote_addr 时即为真实客户端）。
        // 空串时 split 可能返回空数组，故先判空再取 [0]，避免越界。
        var first = ""
        if (!xForwardedFor.isEmpty()) {
            let parts = xForwardedFor.split(",")
            if (parts.size > 0) {
                first = parts[0].trimAscii()
            }
        }
        if (ClientIp.validIp(first)) {
            return first
        }
        let real = xRealIp.trimAscii()
        if (ClientIp.validIp(real)) {
            return real
        }
        return remoteAddr
    }

    /** 可信直连来源判定：空配置表示不限制；非空时逐项精确匹配。 */
    private static func isTrustedPeer(remoteAddr: String, trustedProxies: String): Bool {
        let list = trustedProxies.trimAscii()
        if (list.isEmpty()) {
            return true
        }
        for (p in list.split(",")) {
            if (p.trimAscii() == remoteAddr) {
                return true
            }
        }
        return false
    }

    /**
     * IP 键规范化校验：仅允许 IPv4（四段 1~3 位数字）或 IPv6
     * （十六进制 / 冒号 / 点）字符集，长度 ≤ MaxLen。
     */
    public static func validIp(s: String): Bool {
        if (s.isEmpty() || s.size > ClientIp.MaxLen) {
            return false
        }
        // IPv4：必须不含冒号，否则形如 2001:db8::ffff:192.0.2.1 的
        // IPv4 映射型 IPv6 会被误判成「四段 IPv4」而遭拒绝。
        if (!s.contains(":")) {
            let dots = s.split(".")
            if (dots.size != 4) {
                return false
            }
            for (p in dots) {
                if (p.isEmpty() || p.size > 3) {
                    return false
                }
                for (b in p.toArray()) {
                    if (b < 0x30u8 || b > 0x39u8) {
                        return false
                    }
                }
            }
            return true
        }
        // IPv6（含 IPv4 映射形态）：只放行十六进制 / 冒号 / 点。
        for (b in s.toArray()) {
            let digit = b >= 0x30u8 && b <= 0x39u8
            let upper = b >= 0x41u8 && b <= 0x46u8
            let lower = b >= 0x61u8 && b <= 0x66u8
            let colon = b == 0x3Au8
            let dot = b == 0x2Eu8
            if (!(digit || upper || lower || colon || dot)) {
                return false
            }
        }
        return true
    }
}
