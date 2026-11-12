// ============================================================
// ams.app.attachment · 媒体接入单元测试
//
// 覆盖：
//   ① 零回归开关：默认 / 只开一个开关时 mediaEnabled() 均为 false，
//      两个开关同时为 true 才为 true（OCR 需隐私显式同意，PRD FR-ATT-013）；
//   ② MediaResult 字段语义：默认值为空 / 0，失败态 ocrStatus=3 + error。
//
// 纯内存驱动，不依赖数据库 / 网络 / 外部进程。
// 运行：bash scripts/test.sh ams-app
// ============================================================
package ams.app.attachment.test

import std.collection.*
import std.env.*
import std.unittest.*

import ams.app.attachment.*
import ams.core.media.*

@Test
public class MediaSwitchTest {
    /** 两个开关都未显式开启时，自动处理保持关闭（零回归）。 */
    @TestCase
    public func testMediaEnabledDefaultsFalse() {
        setVariable("AMS_MEDIA_ENABLED", "false")
        setVariable("AMS_OCR_CONSENT", "false")
        @Assert(AttachmentService.mediaEnabled(), false)
    }

    /** 只开其中一个开关仍为 false；同时开启才为 true。 */
    @TestCase
    public func testMediaEnabledNeedsBoth() {
        setVariable("AMS_MEDIA_ENABLED", "true")
        setVariable("AMS_OCR_CONSENT", "false")
        @Assert(AttachmentService.mediaEnabled(), false)
        setVariable("AMS_MEDIA_ENABLED", "false")
        setVariable("AMS_OCR_CONSENT", "true")
        @Assert(AttachmentService.mediaEnabled(), false)
        setVariable("AMS_MEDIA_ENABLED", "true")
        setVariable("AMS_OCR_CONSENT", "true")
        @Assert(AttachmentService.mediaEnabled(), true)
        // 还原默认态，避免污染同进程内其它用例
        setVariable("AMS_MEDIA_ENABLED", "false")
        setVariable("AMS_OCR_CONSENT", "false")
    }

    /** 未设置环境变量时默认关闭（?? "false" 回落）。 */
    @TestCase
    public func testMediaEnabledUnsetFallsBack() {
        setVariable("AMS_MEDIA_ENABLED", "")
        setVariable("AMS_OCR_CONSENT", "")
        @Assert(AttachmentService.mediaEnabled(), false)
    }

    /** MediaResult 初值：空文本 / 0 状态 / 空数组 / 空错误。 */
    @TestCase
    public func testMediaResultDefaults() {
        let r = MediaResult()
        @Assert(r.ocrText, "")
        @Assert(r.ocrStatus, 0)
        @Assert(r.ocrEngine, "")
        @Assert(r.thumbnail.size, 0)
        @Assert(r.watermarked.size, 0)
        @Assert(r.error, "")
    }

    /** 失败 / 不支持态：ocrStatus=3 且带 error 说明。 */
    @TestCase
    public func testMediaResultFailureSemantics() {
        let failed = MediaResult()
        failed.ocrStatus = 3
        failed.error = "unsupported format: jpeg"
        @Assert(failed.ocrStatus, 3)
        @Assert(failed.error.isEmpty(), false)
        @Assert(failed.thumbnail.size, 0)
    }
}
