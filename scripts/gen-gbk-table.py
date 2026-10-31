#!/usr/bin/env python3
# ============================================================
# 生成 GBK（GB2312 双字节区）→ Unicode 映射表，输出仓颉源码。
#
# 为什么需要这张表：
#   中文 Windows 的「右键 → 发送到 → 压缩(zipped)文件夹」用系统 ANSI
#   代码页（GBK）写文件名，且**不置** ZIP 通用标志位 bit 11。
#   ZIP 规范默认按 CP437 解释，GBK 字节按 CP437 解码就是乱码。
#   要让这类包能用，必须自带一张 GBK 表（本机 SDK 无 iconv/编码库）。
#
# 表结构：87 行 × 94 列，行 = 首字节 0xA1..0xF7，列 = 次字节 0xA1..0xFE。
# 未分配位置用 ASCII ? 占位（解码时视为非法）。
#
# 用法：python scripts/gen-gbk-table.py
# 产物：packages/ams-app/src/importer/gbk.cj（请勿手工编辑）
# ============================================================
import os

SENTINEL = '?'

HI_START, HI_END = 0xA1, 0xF7
LO_START, LO_END = 0xA1, 0xFE

rows = []
for hi in range(HI_START, HI_END + 1):
    chars = []
    for lo in range(LO_START, LO_END + 1):
        try:
            ch = bytes([hi, lo]).decode("gbk")
            chars.append(ch if len(ch) == 1 else SENTINEL)
        except UnicodeDecodeError:
            chars.append(SENTINEL)
    rows.append("".join(chars))

# 统计有效映射数，写进文件头做交叉核对
valid = sum(1 for r in rows for c in r if c != SENTINEL)

out = []
out.append("// ============================================================")
out.append("// ams.app.importer · GBK（GB2312 双字节区）→ Unicode 映射表")
out.append("//")
out.append("// 【本文件由脚本生成，请勿手工编辑】")
out.append("//   生成器：scripts/gen-gbk-table.py")
out.append("//   有效映射：%d 个（87 行 × 94 列，未分配位置为 ASCII ?）" % valid)
out.append("//")
out.append("// 【为什么需要】")
out.append("//   中文 Windows 的「压缩(zipped)文件夹」用 GBK 写文件名且不置")
out.append("//   通用标志位 bit 11；ZIP 规范默认 CP437，直接解会全是乱码。")
out.append("//   本机 SDK 无 iconv / 编码转换库，故内置这张表。")
out.append("// ============================================================")
out.append("package ams.app.importer")
out.append("")

out.append("")
out.append("/**")
out.append(" * GBK 双字节解码。")
out.append(" */")
out.append("class Gbk {")
out.append("    /** 首字节下界 / 上界（含） */")
out.append("    static let HI_FIRST: Int64 = 0x%02X" % HI_START)
out.append("    static let HI_LAST: Int64 = 0x%02X" % HI_END)
out.append("    /** 次字节下界 / 上界（含） */")
out.append("    static let LO_FIRST: Int64 = 0x%02X" % LO_START)
out.append("    static let LO_LAST: Int64 = 0x%02X" % LO_END)
out.append("")
out.append("    /** 每行字符数 */")
out.append("    static let COLS: Int64 = %d" % (LO_END - LO_START + 1))
out.append("")
out.append("    /**")
out.append("     * 逐行映射表。")
out.append("     *")
out.append("     * 用 87 个字符串而不是一个 8000 字符长串：单行过长会让")
out.append("     * 编译器的行列号失去意义，出错时定位不到具体行。")
out.append("     */")
out.append("    static let rows: Array<String> = [")
for r in rows:
    out.append('        "%s",' % r)
out.append("    ]")
out.append("")
out.append("    /**")
out.append("     * 尝试把一段字节按 GBK 解码。")
out.append("     *")
out.append("     * @return 全部字节都能解码时返回字符串；否则返回 None")
out.append("     *         （调用方据此判定「文件名编码无法识别」，不做半截解码）")
out.append("     */")
out.append("    static func decode(b: Array<Byte>, from: Int64, len: Int64): ?String {")
out.append("        let sb = StringBuilder()")
out.append("        var i = from")
out.append("        let end = from + len")
out.append("        while (i < end) {")
out.append("            let b0 = Int64(b[i])")
out.append("            if (b0 < 0x80) {")
out.append("                // ASCII 原样")
out.append("                sb.append(String.fromUtf8(Array<Byte>(1, repeat: UInt8(b0))))")
out.append("                i = i + 1")
out.append("                continue")
out.append("            }")
out.append("            if (i + 1 >= end) {")
out.append("                return None")
out.append("            }")
out.append("            let b1 = Int64(b[i + 1])")
out.append("            if (b0 < Gbk.HI_FIRST || b0 > Gbk.HI_LAST ||")
out.append("                b1 < Gbk.LO_FIRST || b1 > Gbk.LO_LAST) {")
out.append("                return None")
out.append("            }")
out.append("            let col = b1 - Gbk.LO_FIRST")
out.append("            let ch = Gbk.at(b0 - Gbk.HI_FIRST, col)")
out.append("            if (ch == \"?\") {")
out.append("                return None")
out.append("            }")
out.append("            sb.append(ch)")
out.append("            i = i + 2")
out.append("        }")
out.append("        return sb.toString()")
out.append("    }")
out.append("")
out.append("    /** 取第 row 行第 col 列的字符（越界返回占位符）。 */")
out.append("    private static func at(row: Int64, col: Int64): String {")
out.append("        if (row < 0 || row >= Gbk.rows.size || col < 0 || col >= Gbk.COLS) {")
out.append("            return \"?\"")
out.append("        }")
out.append("        let line = Gbk.rows[row]")
out.append("        var i: Int64 = 0")
out.append("        for (r in line.runes()) {")
out.append("            if (i == col) {")
out.append("                return r.toString()")
out.append("            }")
out.append("            i = i + 1")
out.append("        }")
out.append("        return \"?\"")
out.append("    }")
out.append("}")
out.append("")

target = os.path.join("packages", "ams-app", "src", "importer", "gbk.cj")
with open(target, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out))
print("wrote %s : %d rows, %d valid mappings" % (target, len(rows), valid))
