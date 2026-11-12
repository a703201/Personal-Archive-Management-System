// ============================================================
// ams.api.routes.captcha · 图形验证码（FR-AUTH-011 真实能力）
//
// 背景：
//   PRD:352「FR-AUTH-011 图形验证码/滑块 | P2 | 触发条件：同 IP 高频失败、
//   注册洪泛」；docs/03:493「单账号失败 5 次触发验证码」。此前降级方案只有
//   「IP 限流 300/分钟 + 登录递增延时 + 失败次数阈值锁定」，验证码一直标注
//   「P1 暂未接入」。本文件把它做成真实能力。
//
// 为什么用 SVG：
//   仓颉 SDK 无图像编解码库，但 SVG 是纯文本字符串，拼字符串即可产出，
//   不需要任何第三方依赖。前端用 <img :src="data:image/svg+xml,..."> 渲染，
//   禁止 v-html，避免注入。
//
// 安全约束：
//   ① answer（正确答案）默认只在服务端内存里，**绝不**写进任何 HTTP 响应、
//      日志或异常消息；下发给前端的只有 captchaId / svg / expiresAt。
//      唯一例外：显式开启的非生产 E2E 测试通道 devHint（见 devHintAllowed
//      注释），生产环境恒关闭、绝不返回该字段。
//   ② captchaId 与答案用 ams.crypto 的 SecureRandom 生成（不可预测），
//      不新写任何密码学原语。
//   ③ Challenge：内存 HashMap + TTL 5 分钟 + 一次性消费（校验通过即删）
//      + 每 ID 最多 3 次尝试；过期行惰性清理。
//
// [部署限制 · 如实标注]
//   本存储是**单实例内存态**：进程重启即丢失、多实例之间不共享。
//   多副本 / 多机部署必须改为落库（openGauss）或 Redis 等共享存储，
//   否则「实例 A 签发、实例 B 校验」会一律判定为验证码失效。
//   本项目其余内存态（MemorySessionStore / AuthService.failureCounts）
//   采用同样的单机取舍，故此处保持一致，并在报告中明确说明。
// ============================================================
package ams.api.routes

import std.collection.*
import std.sync.*
import std.env.*

import ams.crypto.impl.*
import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 验证码策略常量（集中放置，便于单测与后续调整）。
 */
public class CaptchaPolicy {
    /** Challenge 有效期：5 分钟 */
    public static let TtlMillis: Int64 = 5 * 60 * 1000
    /** 单个 captchaId 最多允许的错误尝试次数 */
    public static let MaxAttempts: Int64 = 3
    /** 答案最短长度 */
    public static let AnswerMinLen: Int64 = 4
    /** 答案最长长度 */
    public static let AnswerMaxLen: Int64 = 6
    /** 内存态挑战总量上限（防匿名高频签发堆积内存） */
    public static let MaxChallenges: Int64 = 10000
    /** 单 IP 签发窗口长度：60 秒 */
    public static let IpWindowMillis: Int64 = 60 * 1000
    /** 单 IP 每个窗口内最多签发次数 */
    public static let IpMaxIssues: Int64 = 30
}

/**
 * 一次验证码挑战（服务端内存记录）。
 *
 * 【重要】answer 字段是**服务端专属**：路由层构造对外 JSON 时只取
 * captchaId / svg / expiresAt，绝不会把 answer 序列化出去；测试因与
 * 本类同属被测包而可读到该字段，运行时它始终是进程内的私有数据。
 */
public class CaptchaChallenge {
    /** 挑战 ID（不可预测，随响应下发） */
    public let captchaId: String
    /** 正确答案（仅服务端内存持有，绝不返回前端） */
    public let answer: String
    /** 渲染好的 SVG（纯 path 轮廓，人眼可读、无机器可读答案字段） */
    public let svg: String
    /** 过期时间（Unix 毫秒） */
    public let expiresAt: Int64
    /** 已错误尝试次数（同一 ID 累计） */
    public var attempts: Int64
    /**
     * 【仅供本地/自托管 E2E 的显式开关，生产禁用】
     * 仅当 AMS_ENV 非 production/prod 且 AMS_E2E_CAPTCHA_HINT=true 时等于答案，
     * 否则恒为空串。生产环境（SEC-001 凭据门禁强制）绝不返回该字段。
     * 路由层（auth.cj）仅在非空时才把 devHint 并入对外 JSON；本文件只产出值、
     * 不拼装 HTTP 响应。答案字符集为 [A-Z2-9]，无需 JSON 转义。
     */
    public let devHint: String

    public init(
        captchaId: String,
        answer: String,
        svg: String,
        expiresAt: Int64,
        attempts: Int64,
        devHint: String
    ) {
        this.captchaId = captchaId
        this.answer = answer
        this.svg = svg
        this.expiresAt = expiresAt
        this.attempts = attempts
        this.devHint = devHint
    }
}

/**
 * 校验结果。用枚举而非异常表达可预期的失败，路由层据此映射成明确错误。
 */
public enum CaptchaVerify {
    | Ok
    /** ID 不存在 / 已被消费 / 被刷新作废 */
    | NotFound
    /** 已过期 */
    | Expired
    /** 错误次数达上限，已被作废 */
    | Exhausted
    /** 答案错误；载荷为剩余可尝试次数 */
    | Wrong(Int64)
}

/**
 * SVG 验证码生成器（纯字符串拼装，无图像依赖）。
 *
 * 随机性全部来自 ams.crypto.impl.StdxCryptoProvider 的 SecureRandom，
 * 不自行实现任何密码学原语。
 */
public class CaptchaGenerator {
    /**
     * 答案字符集：大写字母去掉易混的 O / I，数字去掉易混的 0 / 1。
     * 共 24 + 8 = 32 个字符（2 的幂），取模无偏。
     */
    public static let Alphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /** 复用的密码学实现（构造为空、线程安全） */
    private static let crypto: StdxCryptoProvider = StdxCryptoProvider()

    /**
     * devHint 开关判定（纯函数，便于在不设置进程环境变量的单测里覆盖各分支）。
     * 仅当 ① AMS_ENV 不是 production/prod 且 ② AMS_E2E_CAPTCHA_HINT == "true"
     * 两个条件同时成立时返回 true；生产环境一律 false。
     */
    public static func devHintAllowed(amsEnv: String, e2eHint: String): Bool {
        let env = amsEnv.toAsciiLower()
        let isProd = (env == "production" || env == "prod")
        return (!isProd) && (e2eHint == "true")
    }

    /**
     * 运行期开关：读取进程环境变量后交给 devHintAllowed 判定。
     * 【仅供本地/自托管 E2E 的显式开关，生产禁用】
     * 生产（AMS_ENV=production/prod，SEC-001 凭据门禁强制）绝不返回 devHint；
     * 未显式设置 AMS_E2E_CAPTCHA_HINT=true 时默认关闭。
     */
    public static func e2eHintEnabled(): Bool {
        return CaptchaGenerator.devHintAllowed(
            getVariable("AMS_ENV") ?? "",
            getVariable("AMS_E2E_CAPTCHA_HINT") ?? "")
    }

    /**
     * 生成不可预测的挑战 ID：16 字节随机数 → 32 位小写十六进制。
     */
    public static func randomId(): String {
        let bytes = CaptchaGenerator.randomBytes(16)
        let sb = StringBuilder()
        for (b in bytes) {
            sb.append(CaptchaGenerator.hex2(Int64(b)))
        }
        return sb.toString()
    }

    /**
     * 生成随机答案：长度 4~6，字符取自 Alphabet（大小写归一为大写）。
     *
     * 用 8 字节随机数：第 0 字节决定长度，其后每位一个字节取字符集下标。
     */
    public static func randomAnswer(): String {
        let bytes = CaptchaGenerator.randomBytes(8)
        let span: Int64 = CaptchaPolicy.AnswerMaxLen - CaptchaPolicy.AnswerMinLen + 1
        let len: Int64 = CaptchaPolicy.AnswerMinLen + (Int64(bytes[0]) % span)
        let n = CaptchaGenerator.Alphabet.size
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < len) {
            let idx: Int64 = Int64(bytes[1 + i]) % n
            sb.append(CaptchaGenerator.Alphabet[idx..idx + 1])
            i = i + 1
        }
        return sb.toString()
    }

    /**
     * 5×7 点阵字模（精简内嵌，复用 ams-core ocr 点阵思路）。
     * 顺序与 Alphabet 完全一致：ABCDEFGHJKLMNPQRSTUVWXYZ23456789。
     * 每个字符 35 个符号（7 行 × 5 列），'#' 为墨点、'.' 为空白。
     */
    private static let Glyphs: Array<String> = [
        ".###." + "#...#" + "#...#" + "#####" + "#...#" + "#...#" + "#...#", // A
        "####." + "#...#" + "#...#" + "####." + "#...#" + "#...#" + "####.", // B
        ".####" + "#...." + "#...." + "#...." + "#...." + "#...." + ".####", // C
        "####." + "#...#" + "#...#" + "#...#" + "#...#" + "#...#" + "####.", // D
        "#####" + "#...." + "#...." + "####." + "#...." + "#...." + "#####", // E
        "#####" + "#...." + "#...." + "####." + "#...." + "#...." + "#....", // F
        ".####" + "#...." + "#...." + "#..##" + "#...#" + "#...#" + ".###.", // G
        "#...#" + "#...#" + "#...#" + "#####" + "#...#" + "#...#" + "#...#", // H
        "..###" + "...#." + "...#." + "...#." + "...#." + "#..#." + ".##..", // J
        "#...#" + "#..#." + "#.#.." + "##..." + "#.#.." + "#..#." + "#...#", // K
        "#...." + "#...." + "#...." + "#...." + "#...." + "#...." + "#####", // L
        "#...#" + "##.##" + "#.#.#" + "#...#" + "#...#" + "#...#" + "#...#", // M
        "#...#" + "##..#" + "#.#.#" + "#..##" + "#...#" + "#...#" + "#...#", // N
        "####." + "#...#" + "#...#" + "####." + "#...." + "#...." + "#....", // P
        ".###." + "#...#" + "#...#" + "#...#" + "#.#.#" + "#..#." + ".##.#", // Q
        "####." + "#...#" + "#...#" + "####." + "#.#.." + "#..#." + "#...#", // R
        ".####" + "#...." + "#...." + ".###." + "....#" + "....#" + "####.", // S
        "#####" + "..#.." + "..#.." + "..#.." + "..#.." + "..#.." + "..#..", // T
        "#...#" + "#...#" + "#...#" + "#...#" + "#...#" + "#...#" + ".###.", // U
        "#...#" + "#...#" + "#...#" + "#...#" + "#...#" + ".#.#." + "..#..", // V
        "#...#" + "#...#" + "#...#" + "#.#.#" + "#.#.#" + "##.##" + "#...#", // W
        "#...#" + "#...#" + ".#.#." + "..#.." + ".#.#." + "#...#" + "#...#", // X
        "#...#" + "#...#" + ".#.#." + "..#.." + "..#.." + "..#.." + "..#..", // Y
        "#####" + "....#" + "...#." + "..#.." + ".#..." + "#...." + "#####", // Z
        ".###." + "#...#" + "....#" + "...#." + "..#.." + ".#..." + "#####", // 2
        "####." + "....#" + "....#" + ".###." + "....#" + "....#" + "####.", // 3
        "...#." + "..##." + ".#.#." + "#..#." + "#####" + "...#." + "...#.", // 4
        "#####" + "#...." + "#...." + "####." + "....#" + "....#" + "####.", // 5
        "..##." + ".#..." + "#...." + "####." + "#...#" + "#...#" + ".###.", // 6
        "#####" + "....#" + "...#." + "..#.." + ".#..." + ".#..." + ".#...", // 7
        ".###." + "#...#" + "#...#" + ".###." + "#...#" + "#...#" + ".###.", // 8
        ".###." + "#...#" + "#...#" + ".####" + "....#" + "...#." + ".##.."  // 9
    ]

    /**
     * 把答案渲染成 SVG 文本（纯图形轮廓，无任何机器可读答案）。
     *
     * 抗自动化：字符用内嵌 5×7 点阵字模逐点画成 <path> 小方块，每个字符
     * 包在 <g transform="..."> 里做缩放 / 旋转 / 倾斜 / 随机抖动；再叠加细
     * 贝塞尔干扰线（<path stroke>）与圆形噪点（<circle>）。噪点是圆、字符
     * 是方块，形状明显不同，人眼仍可读。
     * SVG 内不含文本节点、无障碍标签、自定义数据属性、答案明文或任何答案字段。
     */
    public static func renderSvg(answer: String): String {
        let rnd = CaptchaGenerator.randomBytes(128)
        let sz = rnd.size
        let n = answer.size
        let cell: Int64 = 170 / (if (n > 0) { n } else { 1 })
        let colors = ["#2b3a55", "#1f6f54", "#8a3b3b", "#3b4f8a", "#6a4a1f"]
        let sb = StringBuilder()
        sb.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"180\" height=\"52\" viewBox=\"0 0 180 52\">")
        sb.append("<rect width=\"180\" height=\"52\" fill=\"#eef2f7\"/>")

        // 干扰线（二次贝塞尔，细且浅，置于字符之下）
        var i: Int64 = 0
        while (i < 4) {
            let x1: Int64 = Int64(rnd[(i * 4) % sz]) % 180
            let y1: Int64 = Int64(rnd[(i * 4 + 1) % sz]) % 52
            let x2: Int64 = Int64(rnd[(i * 4 + 2) % sz]) % 180
            let y2: Int64 = Int64(rnd[(i * 4 + 3) % sz]) % 52
            let cx: Int64 = (x1 + x2) / 2
            let cy: Int64 = Int64(rnd[(i * 4 + 8) % sz]) % 52
            sb.append("<path d=\"M${x1} ${y1} Q${cx} ${cy} ${x2} ${y2}\" stroke=\"#c3ccd8\" stroke-width=\"1\" fill=\"none\"/>")
            i = i + 1
        }

        // 噪点：小圆，形状与字符方块明显区分
        i = 0
        while (i < 14) {
            let cx: Int64 = Int64(rnd[(i * 3 + 16) % sz]) % 180
            let cy: Int64 = Int64(rnd[(i * 3 + 17) % sz]) % 52
            let r: Int64 = 1 + (Int64(rnd[(i * 3 + 18) % sz]) % 2)
            sb.append("<circle cx=\"${cx}\" cy=\"${cy}\" r=\"${r}\" fill=\"#b7c0cd\"/>")
            i = i + 1
        }

        // 字符：逐字 <g> 变换 + 逐墨点 <path> 小方块
        i = 0
        while (i < n) {
            let ch = answer[i..i + 1]
            let glyph = CaptchaGenerator.glyphOf(ch)
            let s: Int64 = 3 + (Int64(rnd[(i * 9 + 40) % sz]) % 3)
            let x0: Int64 = 6 + i * cell + (Int64(rnd[(i * 9 + 41) % sz]) % 5)
            let y0: Int64 = 9 + (Int64(rnd[(i * 9 + 42) % sz]) % 7)
            let rot: Int64 = (Int64(rnd[(i * 9 + 43) % sz]) % 21) - 10
            let skew: Int64 = (Int64(rnd[(i * 9 + 44) % sz]) % 13) - 6
            let color = colors[Int64(rnd[(i * 9 + 45) % sz]) % colors.size]
            sb.append("<g fill=\"${color}\" transform=\"translate(${x0} ${y0}) scale(${s}) rotate(${rot} 2 3) skewX(${skew})\">")
            var row: Int64 = 0
            while (row < 7) {
                var col: Int64 = 0
                while (col < 5) {
                    let p = row * 5 + col
                    if (glyph[p..p + 1] == "#") {
                        sb.append("<path d=\"M${col} ${row} h1 v1 h-1 z\"/>")
                    }
                    col = col + 1
                }
                row = row + 1
            }
            sb.append("</g>")
            i = i + 1
        }

        sb.append("</svg>")
        return sb.toString()
    }

    /** 按 Alphabet 顺序取字模（答案字符必在 Alphabet 内）。 */
    private static func glyphOf(ch: String): String {
        var i: Int64 = 0
        while (i < CaptchaGenerator.Alphabet.size) {
            if (CaptchaGenerator.Alphabet[i..i + 1] == ch) {
                return CaptchaGenerator.Glyphs[i]
            }
            i = i + 1
        }
        return CaptchaGenerator.Glyphs[0]
    }

    /** 取 n 字节安全随机数；失败抛内部错误（不吞、不退化成可预测值）。 */
    private static func randomBytes(n: Int64): Array<Byte> {
        match (CaptchaGenerator.crypto.randomBytes(n)) {
            case CryptoResult.Ok(b) => return b
            case CryptoResult.Err(_) =>
                throw AppError(AppErrorKind.Internal, "验证码随机数生成失败")
        }
    }

    /** 字节 → 两位小写十六进制。 */
    private static func hex2(v: Int64): String {
        let digits = "0123456789abcdef"
        let hi = (v / 16) % 16
        let lo = v % 16
        return digits[hi..hi + 1] + digits[lo..lo + 1]
    }
}

/**
 * 验证码 Challenge 单例存储（内存态，见文件头「部署限制」）。
 *
 * 线程安全：所有读写经 Mutex 串行化（仿 MemorySessionStore）。
 * 通过 `issue / verify / invalidate` 三个静态方法暴露能力，由 AuthRoutes
 * 直接调用，无需改动 main.cj 的装配。
 */
public class CaptchaStore {
    private static let challenges: HashMap<String, CaptchaChallenge> = HashMap<String, CaptchaChallenge>()
    private static let mutex: Mutex = Mutex()
    /** 每 IP 固定窗口起点（Unix 毫秒），仅用于签发限流，不参与校验。 */
    private static let ipWindowStart: HashMap<String, Int64> = HashMap<String, Int64>()
    /** 每 IP 当前窗口内已签发次数。 */
    private static let ipIssueCount: HashMap<String, Int64> = HashMap<String, Int64>()

    /**
     * 签发一个新挑战并存入内存（不限 IP，供单测与内部调用）。
     *
     * @param nowMillis 当前 Unix 毫秒（显式传入便于单测，不依赖真实时钟）
     */
    public static func issue(nowMillis: Int64): CaptchaChallenge {
        return CaptchaStore.issueForIp("", nowMillis)
    }

    /**
     * 带 IP 限流的签发入口（路由层使用）。
     *
     * 两道闸门：① 单 IP 固定窗口内最多 IpMaxIssues 次；② 全局挑战总量
     * 不超过 MaxChallenges。超额一律抛 RateLimited，绝不静默丢弃或无限堆积。
     */
    public static func issueForIp(ip: String, nowMillis: Int64): CaptchaChallenge {
        CaptchaStore.mutex.lock()
        try {
            CaptchaStore.purgeExpiredLocked(nowMillis)
            if (CaptchaStore.challenges.size >= CaptchaPolicy.MaxChallenges) {
                throw AppError(AppErrorKind.RateLimited, "验证码服务繁忙，请稍后重试")
            }
            if (!ip.isEmpty()) {
                var start: Int64 = 0
                var count: Int64 = 0
                match (CaptchaStore.ipWindowStart.get(ip)) {
                    case Some(v) => start = v
                    case None => ()
                }
                match (CaptchaStore.ipIssueCount.get(ip)) {
                    case Some(v) => count = v
                    case None => ()
                }
                if (start == 0 || nowMillis - start > CaptchaPolicy.IpWindowMillis) {
                    start = nowMillis
                    count = 0
                }
                if (count >= CaptchaPolicy.IpMaxIssues) {
                    throw AppError(AppErrorKind.RateLimited, "验证码请求过于频繁，请稍后重试")
                }
                CaptchaStore.ipWindowStart[ip] = start
                CaptchaStore.ipIssueCount[ip] = count + 1
            }
            let answer = CaptchaGenerator.randomAnswer()
            let svg = CaptchaGenerator.renderSvg(answer)
            // devHint 仅在显式测试开关下产出；生产恒为空（见 devHintAllowed 注释）。
            // 【接线约定 · 路由层 auth.cj】仅在 ch.devHint 非空时才把该字段并入
            // 对外 JSON；生产环境恒为空，故响应里绝不出现 devHint。
            let hint = if (CaptchaGenerator.e2eHintEnabled()) { answer } else { "" }
            let ch = CaptchaChallenge(
                CaptchaGenerator.randomId(),
                answer,
                svg,
                nowMillis + CaptchaPolicy.TtlMillis,
                0,
                hint
            )
            CaptchaStore.challenges[ch.captchaId] = ch
            return ch
        } finally {
            CaptchaStore.mutex.unlock()
        }
    }

    /**
     * 【供路由层拼装响应】返回应追加到对外 JSON 的 devHint 片段。
     * 门禁关闭时返回空串；开启时返回形如 ,"devHint":"<答案>" 的片段。
     * 答案字符集为 [A-Z2-9]，无需 JSON 转义。
     *
     * 约定：路由层无条件把它接在 expiresAt 字段之后、右花括号之前即可，
     * 因为生产环境这里恒为空串 → 响应里绝不会出现该字段。这样「生产禁用」
     * 的保证完全由本文件持有，路由层无需理解开关条件。
     */
    public static func devHintJson(ch: CaptchaChallenge): String {
        if (ch.devHint.size == 0) {
            return ""
        }
        return ",\"devHint\":\"${ch.devHint}\""
    }

    /**
     * 校验答案。
     *
     * 一次性消费：答案正确即删除；错误累计到 MaxAttempts 也删除并作废；
     * 过期直接删除并作废。任何失败路径都不泄漏正确答案或剩余信息之外的
     * 内容（Wrong 仅回传剩余次数，路由层可只回一句通用提示）。
     */
    public static func verify(id: String, code: String, nowMillis: Int64): CaptchaVerify {
        CaptchaStore.mutex.lock()
        try {
            match (CaptchaStore.challenges.get(id)) {
                case Some(ch) =>
                    if (nowMillis >= ch.expiresAt) {
                        CaptchaStore.challenges.remove(id)
                        return CaptchaVerify.Expired
                    }
                    let normalized = code.trimAscii().toAsciiUpper()
                    if (normalized == ch.answer) {
                        // 一次性：用后即删
                        CaptchaStore.challenges.remove(id)
                        return CaptchaVerify.Ok
                    }
                    ch.attempts = ch.attempts + 1
                    if (ch.attempts >= CaptchaPolicy.MaxAttempts) {
                        CaptchaStore.challenges.remove(id)
                        return CaptchaVerify.Exhausted
                    }
                    return CaptchaVerify.Wrong(CaptchaPolicy.MaxAttempts - ch.attempts)
                case None => return CaptchaVerify.NotFound
            }
        } finally {
            CaptchaStore.mutex.unlock()
        }
    }

    /**
     * 作废一个 ID（前端刷新验证码时携带 old=<id> 触发）。
     */
    public static func invalidate(id: String): Unit {
        CaptchaStore.mutex.lock()
        try {
            CaptchaStore.challenges.remove(id)
        } finally {
            CaptchaStore.mutex.unlock()
        }
    }

    /** 当前存活挑战数（供单测 / 运维观测）。 */
    public static func size(): Int64 {
        CaptchaStore.mutex.lock()
        try {
            return CaptchaStore.challenges.size
        } finally {
            CaptchaStore.mutex.unlock()
        }
    }

    /** 惰性清理过期行与过期 IP 窗口（调用方已持锁）。 */
    private static func purgeExpiredLocked(nowMillis: Int64): Unit {
        let dead = ArrayList<String>()
        for ((k, v) in CaptchaStore.challenges) {
            if (v.expiresAt <= nowMillis) {
                dead.add(k)
            }
        }
        for (k in dead) {
            CaptchaStore.challenges.remove(k)
        }
        // 过期限流窗口一并回收，避免 ipWindowStart / ipIssueCount 无限增长。
        let staleIps = ArrayList<String>()
        for ((ip, start) in CaptchaStore.ipWindowStart) {
            if (nowMillis - start > CaptchaPolicy.IpWindowMillis) {
                staleIps.add(ip)
            }
        }
        for (ip in staleIps) {
            CaptchaStore.ipWindowStart.remove(ip)
            CaptchaStore.ipIssueCount.remove(ip)
        }
    }
}
