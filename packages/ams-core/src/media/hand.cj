// ============================================================
// ams.core.media · 手写风格数字 OCR（16×16 点阵字典）
//
// 【定位】
//   识别手写风格字体的 0..9。字典由构建期 Windows GDI 渲染：多种
//   手写字体原型 + 倾斜 + 加粗，每字 9 个原型，运行时零依赖。
//
// 【流程】
//   与 CjkOcr 完全同构；最小距离 <= 24 才接受，按 idx/9 取数字。
//
// 【诚实边界】
//   这是「手写风格印刷字体」的点阵匹配，不是训练式手写识别模型；
//   真实连笔草书、非数字字符不在覆盖范围内。
// ============================================================
package ams.core.media

import std.collection.*

public class HandOcr {
    /** 跨字体验证实测 4 字距离 4/0/5/0，阈值取 24 留余量。 */
    private static let THRESHOLD: Int64 = 24

    /** 识别整张图，多行以换行分隔；超阈值的字跳过。 */
    public static func recognize(img: RasterImage): String {
        let bin = MediaOcr.binarize(img)
        let lines = GlyphBits.lineRanges(bin, img.width, img.height)
        let protos = GlyphBits.alignProtos(GlyphData.HAND_BITS)
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
                    if (bestI >= 0 && bestD <= HandOcr.THRESHOLD) {
                        let charIdx = bestI / GlyphData.HAND_PROTOS
                        if (charIdx >= 0 && charIdx < GlyphData.HAND_CHARS.size) {
                            sb.append(GlyphData.HAND_CHARS[charIdx])
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
