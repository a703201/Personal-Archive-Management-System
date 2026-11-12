// ============================================================
// ams-api 图形验证码单元测试（FR-AUTH-011）
//
// 覆盖：
//   - SVG 格式合法性（根标签 / xmlns / 纯 path 轮廓 / 无文本节点 / 无答案明文）
//   - devHint 生产门禁（production/prod 恒禁用、默认不返回）
//   - 答案长度与字符集（4~6 位、排除易混字符、ID 不可预测且唯一）
//   - Challenge：正确 / 错误 / 过期 / 一次性 / 超次数 / 不存在 / 刷新作废
//
// 严格模仿 api_test.cj：@Test 顶层函数 + @Assert 断言，全部内存驱动，
// 不依赖数据库、HTTP 服务或真实时钟（时间用固定常量显式传入）。
// ============================================================
package ams.api.tests

import std.unittest.*
import std.unittest.testmacro.*

import ams.api.routes.*

/** 固定时间基准，避免测试依赖真实时钟。 */
private const TEST_NOW: Int64 = 1700000000000

/** 把校验结果枚举映射成字符串，便于用 @Assert 直接比较（不依赖枚举 ==）。 */
private func tag(v: CaptchaVerify): String {
    return match (v) {
        case CaptchaVerify.Ok => "ok"
        case CaptchaVerify.NotFound => "notfound"
        case CaptchaVerify.Expired => "expired"
        case CaptchaVerify.Exhausted => "exhausted"
        case CaptchaVerify.Wrong(_) => "wrong"
    }
}

/** 构造一个**必定错误**的答案：只改首字符，保证与正确答案不同且长度一致。 */
private func wrongCode(answer: String): String {
    let first = answer[0..1]
    let replacement = if (first == "A") { "B" } else { "A" }
    return replacement + answer[1..]
}

/**
 * SVG 格式合法性。
 */
@Test
public func testCaptchaSvgFormat(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    let svg = ch.svg
    @Assert(svg.startsWith("<svg"))
    @Assert(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
    @Assert(svg.endsWith("</svg>"))
    @Assert(svg.contains("<rect"))
    @Assert(svg.contains("<path"))     // 字符墨点方块 + 干扰线
    @Assert(svg.contains("<circle"))   // 圆形噪点（与方块形状区分）
    @Assert(svg.contains("<g"))        // 每字符一个变换组
    // 纯 path 轮廓：不得出现文本节点 / 无障碍标签 / 自定义数据属性
    @Assert(!svg.contains("<text"))
    @Assert(!svg.contains("aria-label"))
    @Assert(!svg.contains("data-"))
    // 不得含答案明文
    @Assert(!svg.contains(ch.answer))
    // 长度合理（既不是空壳，也不至于异常膨胀）
    @Assert(svg.size > 500)
    @Assert(svg.size < 100000)
}

/**
 * devHint 生产门禁。
 *
 * 测试进程无法设置进程环境变量，故把「是否允许 devHint」抽成纯函数
 * devHintAllowed(amsEnv, e2eHint) 后直接覆盖各分支：
 *   - AMS_ENV=production / prod：即便显式打开 hint 开关也一律禁用；
 *   - 未显式开启 hint：默认禁用；
 *   - 仅「非生产 + hint=true」两个条件同时成立才开启。
 * 生产环境该门禁恒为 false，故 issue() 产出的 devHint 恒为空串，路由层
 * 非空才并入响应 → 生产响应不含 devHint（如实说明：单测不设环境变量，
 * 以纯函数分支断言替代运行期环境变量注入）。
 */
@Test
public func testCaptchaDevHintGate(): Unit {
    // 生产 / prod：开关形同虚设，必须禁用（大小写不敏感）
    @Assert(!CaptchaGenerator.devHintAllowed("production", "true"))
    @Assert(!CaptchaGenerator.devHintAllowed("prod", "true"))
    @Assert(!CaptchaGenerator.devHintAllowed("PRODUCTION", "true"))
    @Assert(!CaptchaGenerator.devHintAllowed("Prod", "true"))
    // 非生产但未显式开启：默认禁用
    @Assert(!CaptchaGenerator.devHintAllowed("dev", "false"))
    @Assert(!CaptchaGenerator.devHintAllowed("dev", ""))
    @Assert(!CaptchaGenerator.devHintAllowed("", ""))
    // 两个条件同时成立才开启
    @Assert(CaptchaGenerator.devHintAllowed("dev", "true"))
    @Assert(CaptchaGenerator.devHintAllowed("ci", "true"))
    // issue() 的 devHint 与运行期门禁一致：门禁关闭时为空（绝不返回答案）
    let ch = CaptchaStore.issue(TEST_NOW)
    let expected = if (CaptchaGenerator.e2eHintEnabled()) { ch.answer } else { "" }
    @Assert(ch.devHint == expected)
    // 响应片段工具：空 devHint（生产/默认）不产出任何片段 → 响应不含该字段
    let blank = CaptchaChallenge("id", "seed", "<svg/>", 0, 0, "")
    @Assert(CaptchaStore.devHintJson(blank).size == 0)
    let hinted = CaptchaChallenge("id", "seed", "<svg/>", 0, 0, "seed")
    @Assert(CaptchaStore.devHintJson(hinted).contains("devHint"))
}

/**
 * 答案长度与字符集：多次抽样，全部落在 4~6 位且只含 Alphabet。
 */
@Test
public func testCaptchaAnswerCharset(): Unit {
    var allOk = true
    var i: Int64 = 0
    while (i < 64) {
        let a = CaptchaGenerator.randomAnswer()
        if (a.size < CaptchaPolicy.AnswerMinLen || a.size > CaptchaPolicy.AnswerMaxLen) {
            allOk = false
        }
        for (r in a.runes()) {
            if (!CaptchaGenerator.Alphabet.contains(r.toString())) {
                allOk = false
            }
        }
        i = i + 1
    }
    @Assert(allOk)
    // 易混字符 0 / O / 1 / I 绝不在字符集里
    @Assert(!CaptchaGenerator.Alphabet.contains("0"))
    @Assert(!CaptchaGenerator.Alphabet.contains("O"))
    @Assert(!CaptchaGenerator.Alphabet.contains("1"))
    @Assert(!CaptchaGenerator.Alphabet.contains("I"))
}

/**
 * 挑战 ID：32 位十六进制、两次生成不相同（不可预测的基本保障）。
 */
@Test
public func testCaptchaId(): Unit {
    let a = CaptchaGenerator.randomId()
    let b = CaptchaGenerator.randomId()
    @Assert(a.size == 32)
    @Assert(b.size == 32)
    @Assert(a != b)
}

/**
 * 正确答案 → 通过。
 */
@Test
public func testCaptchaVerifyCorrect(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "ok")
}

/**
 * 错误答案 → 返回 Wrong；累计未达上限仍可用正确答案通过。
 */
@Test
public func testCaptchaVerifyWrong(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    let wrong = wrongCode(ch.answer)
    @Assert(tag(CaptchaStore.verify(ch.captchaId, wrong, TEST_NOW)) == "wrong")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, wrong, TEST_NOW)) == "wrong")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "ok")
}

/**
 * 过期 → Expired 且被删除（后续校验变 NotFound）。
 */
@Test
public func testCaptchaVerifyExpired(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    let future = TEST_NOW + CaptchaPolicy.TtlMillis + 1
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, future)) == "expired")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "notfound")
}

/**
 * 一次性消费：首次通过后立即删除。
 */
@Test
public func testCaptchaVerifyOneTime(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "ok")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "notfound")
}

/**
 * 超次数：连续 3 次错误后作废，即便再传正确答案也失败。
 */
@Test
public func testCaptchaVerifyExhausted(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    let wrong = wrongCode(ch.answer)
    @Assert(tag(CaptchaStore.verify(ch.captchaId, wrong, TEST_NOW)) == "wrong")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, wrong, TEST_NOW)) == "wrong")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, wrong, TEST_NOW)) == "exhausted")
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "notfound")
}

/**
 * 不存在的 ID → NotFound。
 */
@Test
public func testCaptchaVerifyNotFound(): Unit {
    @Assert(tag(CaptchaStore.verify("no-such-captcha-id", "AAAA", TEST_NOW)) == "notfound")
}

/**
 * 刷新验证码时作废旧 ID（invalidate）。
 */
@Test
public func testCaptchaInvalidate(): Unit {
    let ch = CaptchaStore.issue(TEST_NOW)
    CaptchaStore.invalidate(ch.captchaId)
    @Assert(tag(CaptchaStore.verify(ch.captchaId, ch.answer, TEST_NOW)) == "notfound")
}
