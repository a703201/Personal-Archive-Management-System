// ============================================================
// ams.ai · 底座单元测试
//
// 覆盖 docs/20 的关键纯函数：
//   - 五层提示词转义 / 槽位替换（防注入）
//   - 容错 JSON 解析（三档降级的客户端补救）
//   - provider 选择链（本地优先 / 出境同意 / 失败关闭）
//   - 能力发现（opt-out 零痕迹）
//
// 测试代码与产品代码物理分离（见 ams.kernel.error.test 注释）。
// ============================================================
package ams.ai.test

import ams.ai.*
import std.unittest.*

@Test
public class AiFoundationTest {
    @TestCase
    public func testPromptEscapeXml() {
        @Assert(PromptBuilder.escapeXml("a<b>&\"'"), "a&lt;b&gt;&amp;&quot;&apos;")
        @Assert(PromptBuilder.escapeXml(" normal "), " normal ")
        // 中文是合法多字节 UTF-8：逐字节 fromUtf8 会抛异常（Q 域 500 根因，防回归）
        @Assert(PromptBuilder.escapeXml("找所有证书"), "找所有证书")
        @Assert(PromptBuilder.escapeXml("证书<机密>"), "证书&lt;机密&gt;")
    }

    @TestCase
    public func testPromptSlotReplace() {
        let dollar = String.fromUtf8([36u8])
        let text = "分类：" + dollar + "{categoryName}，字段：" + dollar + "{fieldSchema}"
        let out = PromptBuilder.replaceSlots(text, [("categoryName", "证件信息"), ("fieldSchema", "{}")])
        @Assert(out, "分类：证件信息，字段：{}")
    }

    @TestCase
    public func testJsonStringUnescape() {
        // 模型的 content 内层 JSON 是转义形式（\" 与 \\n）：readStringValue 必须反转义，
        // 否则下游 AiJson.of(content) 定位 "fields" 失败 → V 域识别恒为空（2026-11-17）
        let raw = "{\"content\":\"{\\n  \\\"fields\\\": [{\\\"code\\\": \\\"cert_name\\\", \\\"value\\\": \\\"Huawei\\\"}]\\n}\"}"
        let j = AiJson.of(raw)
        match (j) {
            case Some(jj) =>
                match (jj.str("content")) {
                    case Some(c) =>
                        @Assert(c.contains("\"fields\""), true)
                        match (AiJson.of(c)) {
                            case Some(inner) =>
                                match (inner.value("fields")) { case Some(_) => (); case None => @Assert(false, true) }
                            case None => @Assert(false, true)
                        }
                    case None => @Assert(false, true)
                }
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func testMultimodalBodyJsonValid() {
        // 多模态请求体必须闭合 text 对象：否则 image_url 被当成 text 的键，Ollama 400
        let req = AiChatRequest(
            "sys", "图片内容", AiDomain.Vision, "ocr-v1",
            images: [AiImage("data:image/png;base64,AAAA")],
            responseFormat: "json_object")
        let body = String.fromUtf8(OpenAIClient.buildBody("qwen2.5vl:3b", req))
        // AiJson 能解析即证明结构合法（畸形时 of 返回 None）
        match (AiJson.of(body)) {
            case Some(_) => ()
            case None => @Assert(false, true)
        }
        @Assert(body.contains("\"text\":\"图片内容\"},{\"type\":\"image_url\""), true)
    }

    @TestCase
    public func testJsonEscapeUnicode() {
        // 中文/emoji 是合法多字节 UTF-8，逐字节 fromUtf8 会抛 Invalid utf8 byte sequence
        @Assert(AiJsonEscape.s("测试查询"), "测试查询")
        @Assert(AiJsonEscape.s("a\"b\\c\n"), "a\\\"b\\\\c\\n")
        @Assert(AiJsonEscape.s("证书：毕业证"), "证书：毕业证")
    }

    @TestCase
    public func testPromptSafeTag() {
        let b = PromptBuilder()
        b.data("my-tag!", "<script>alert(1)</script>")
        let (_, userText) = b.build([])
        // 标签只保留字母数字与下划线；内容里的尖括号被转义
        @Assert(userText.contains("<mytag>"), true)
        @Assert(userText.contains("&lt;script&gt;"), true)
    }

    @TestCase
    public func testAiJsonNestedContent() {
        let raw = "{\"choices\":[{\"message\":{\"content\":\"OKVALUE\"}}],\"usage\":{\"prompt_tokens\":12}}"
        match (AiJson.of(raw)) {
            case Some(j) =>
                match (j.messageContent()) {
                    case Some(c) => @Assert(c, "OKVALUE")
                    case None => @Assert(false, true)
                }
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func testAiJsonArray() {
        let raw = "{\"sources\":[12,15],\"answer\":\"ok\"}"
        match (AiJson.of(raw)) {
            case Some(j) =>
                let arr = j.array("sources")
                @Assert(arr.size, 2)
                @Assert(j.str("answer"), "ok")
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func testProviderKinds() {
        @Assert(isOnlineProvider(AiProviderKind.Ollama), false)
        @Assert(isOnlineProvider(AiProviderKind.LocalBuiltin), false)
        @Assert(isOnlineProvider(AiProviderKind.DeepSeek), true)
        @Assert(supportsVision(AiProviderKind.DeepSeek), false)
        @Assert(supportsVision(AiProviderKind.Ollama), true)
        @Assert(providerName(parseProvider("siliconflow")), "siliconflow")
    }

    @TestCase
    public func testProviderUnavailable() {
        let noKey = ProviderConfig(AiProviderKind.OpenAI, "https://api.openai.com/v1", "", "gpt-4o")
        @Assert(noKey.unavailableReason(), "no_key")
        let bad = ProviderConfig(AiProviderKind.Ollama, "file:///etc/passwd", "", "m")
        @Assert(bad.unavailableReason(), "bad_endpoint")
        let good = ProviderConfig(AiProviderKind.Ollama, "http://127.0.0.1:11434/v1", "", "m")
        @Assert(good.unavailableReason(), "")
    }

    @TestCase
    public func testSelectProviderOnlineNeedsConsent() {
        let local = ProviderConfig(AiProviderKind.Ollama, "http://127.0.0.1:11434/v1", "", "m")
        let online = ProviderConfig(AiProviderKind.OpenAI, "https://api.openai.com/v1", "sk-test", "gpt-4o")
        // 未同意出境：只能选本地
        match (selectProvider([local, online], false)) {
            case Some(p) => @Assert(providerName(p.kind), "ollama")
            case None => @Assert(false, true)
        }
        // 本地不可用时，未同意 → 无 provider（失败关闭）
        let brokenLocal = ProviderConfig(AiProviderKind.Ollama, "", "", "m")
        match (selectProvider([brokenLocal, online], false)) {
            case Some(_) => @Assert(false, true)
            case None => @Assert(true, true)
        }
        // 同意后可选在线
        match (selectProvider([brokenLocal, online], true)) {
            case Some(p) => @Assert(providerName(p.kind), "openai")
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func testCapabilitiesOptOut() {
        let caps = AiCapabilities(true, true, false, true, true, true, true)
        @Assert(caps.anyEnabled(), false)
        @Assert(caps.domainEnabled(AiDomain.Vision), false)
        let open = AiCapabilities(true, false, false, true, false, false, false)
        @Assert(open.anyEnabled(), true)
        @Assert(open.domainEnabled(AiDomain.Vision), true)
        @Assert(open.domainEnabled(AiDomain.Query), false)
    }
}
