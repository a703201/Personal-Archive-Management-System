// ============================================================
// ams.core.media · CJK 印刷体 OCR（16×16 点阵字典）
//
// 【定位】
//   识别宋体 / 黑体 / 雅黑 / 仿宋 / 楷体等常见印刷体汉字。字典由
//   scripts/gen-media-glyphs.py 在构建期用 Windows GDI 渲染成 16×16
//   点阵（每字 8 个原型：多种字体 + 粗体 / 字号变体），运行时零依赖。
//
// 【流程】
//   MediaOcr.binarize → 水平投影分行 → 列投影分字（断笔合并）→
//   box 放进 16×16 零画布（不拉伸）→ 墨迹包围盒对齐 → 与 1760 个
//   对齐原型求位移容差汉明距离 → 最小距离 <= 60 才接受，按 idx/8 取汉字。
//
// 【诚实边界】
//   字典仅覆盖 GlyphData.CJK_CHARS 的 220 个常用汉字；生僻字、
//   真实草书、复杂排版、强倾斜仍需外部 OCR 模型。
// ============================================================
package ams.core.media

import std.collection.*

public class CjkOcr {
    /** 跨字体验证实测 4 字距离 44/28/51/18，阈值取 60 留余量。 */
    private static let THRESHOLD: Int64 = 60

    /** 识别整张图，多行以换行分隔；超阈值的字跳过。 */
    public static func recognize(img: RasterImage): String {
        let bin = MediaOcr.binarize(img)
        let lines = GlyphBits.lineRanges(bin, img.width, img.height)
        // 原型表只解码 / 对齐一次，供本图所有 box 复用
        let protos = GlyphBits.alignProtos(GlyphData.CJK_BITS)
        let sb = StringBuilder()
        var li: Int64 = 0
        while (li + 1 < lines.size) {
            let y0 = lines[li]
            let y1 = lines[li + 1]
            let bx = GlyphBits.boxes(bin, img.width, y0, y1)
            if (li > 0) {
                sb.append("\n")
            }
            var ci: Int64 = 0
            while (ci + 1 < bx.size) {
                let x0 = bx[ci]
                let x1 = bx[ci + 1]
                if (x1 - x0 >= 2 && y1 - y0 >= 3) {
                    let g = GlyphBits.glyphFlat(bin, img.width, x0, x1, y0, y1)
                    let a = GlyphBits.align(g)
                    let r = GlyphBits.bestMatch(a, protos)
                    let bestI = r[0]
                    let bestD = r[1]
                    if (bestI >= 0 && bestD <= CjkOcr.THRESHOLD) {
                        let charIdx = bestI / GlyphData.CJK_PROTOS
                        if (charIdx >= 0 && charIdx < GlyphData.CJK_CHARS.size) {
                            sb.append(GlyphData.CJK_CHARS[charIdx])
                        }
                    }
                }
                ci = ci + 2
            }
            li = li + 2
        }
        return sb.toString()
    }
}
