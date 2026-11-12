#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build-time glyph generator for AMS Cangjie OCR (Windows GDI, stdlib only).

WHY THIS EXISTS
---------------
The runtime OCR is pure Cangjie, in-process, zero dependency. A CJK template
dictionary cannot be hand-authored reliably, so we render glyphs ONCE at build
time from local Windows fonts and emit them as compact hex bitmaps in
`packages/ams-core/src/media/glyphdata.cj`. The generated file is plain data;
no font, GDI, Python or external process is ever needed at runtime.

OUTPUT
------
  packages/ams-core/src/media/glyphdata.cj
    GlyphData.CJK_CHARS / CJK_BITS   : 2 prototypes per char (SimSun, SimHei)
    GlyphData.HAND_CHARS / HAND_BITS: 6 prototypes per digit (handwriting
                                      typefaces + shear/thicken variants)
    GlyphData.TEST_*                 : cross-font raster fixtures (hex bits)

Re-run whenever the character set or prototype fonts change:
    python3 scripts/gen-media-glyphs.py

HONEST SCOPE
------------
These are *printed / handwriting-style typeface* prototypes, not a trained
handwriting model and not a full CJK font. Recognition of real cursive
handwriting and of characters outside the curated set still requires an
external OCR engine. See SECURITY.md.
"""
import ctypes
import io
import os
import sys
from ctypes import wintypes

W = H = 16
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "packages", "ams-core", "src", "media", "glyphdata.cj")

# Frequent Chinese characters + archive-domain vocabulary. Order is stable.
CJK_FREQUENT = (
    "的一是在不了有人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经"
    "十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形"
    "相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展"
    "五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战"
    "先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教"
)
CJK_DOMAIN = (
    "档案证件编号姓名性别出生年月住址联系电话单位学历职务职称资格有效签发机关资料个人基本教育经历职业资质联系方式家庭关系健康资产影像附件"
    "自定义分类备注审核归档共享导出导入搜索保存删除新增编辑状态来源敏感度市区县街道路号室男女汉族婚姻政治面貌毕业院校专业学位入职离职部门"
    "岗位工资社保公积金病历诊断药品过敏疫苗体检报告房产车辆银行卡存款股票基金保险债权债务合同发票凭证照片扫描复印件原件电子签章打印邮箱微信"
    "年月日时分秒元角整共计合计总计第页份盖章签字确认同意不予受理已办结待审"
)


def dedupe(text, cap):
    seen = set()
    out = []
    for ch in text:
        if ch not in seen and ord(ch) > 127:
            seen.add(ch)
            out.append(ch)
        if len(out) >= cap:
            break
    return out


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER)]


class Gdi:
    def __init__(self):
        self.g = ctypes.WinDLL("gdi32", use_last_error=True)
        self.u = ctypes.WinDLL("user32", use_last_error=True)
        self.bmi = BITMAPINFO()
        self.bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        self.bmi.bmiHeader.biWidth = W
        self.bmi.bmiHeader.biHeight = H
        self.bmi.bmiHeader.biPlanes = 1
        self.bmi.bmiHeader.biBitCount = 24
        self.bmi.bmiHeader.biCompression = 0
        self.hdc = self.u.GetDC(None)
        self.mem = self.g.CreateCompatibleDC(self.hdc)
        self.bits = ctypes.c_void_p()
        self.bmp = self.g.CreateDIBSection(
            self.mem, ctypes.byref(self.bmi), 0, ctypes.byref(self.bits), None, 0)
        if not self.bmp or not self.bits.value:
            raise RuntimeError("CreateDIBSection failed")
        self.g.SelectObject(self.mem, self.bmp)
        self.g.SetBkColor(self.mem, 0xFFFFFF)
        self.g.SetTextColor(self.mem, 0x000000)
        self.white = (ctypes.c_ubyte * (W * 3 * H))(*([255] * (W * 3 * H)))

    def render(self, ch, face, size=16, bold=False, italic=False, charset=134):
        ctypes.memmove(self.bits.value, self.white, len(self.white))
        weight = 700 if bold else 400
        # charset=134 (GB2312) is right for CJK faces, but Latin-only script
        # faces do not cover GB2312 and GDI silently falls back to a default
        # font -- every "handwriting" prototype would then be identical.
        hfont = self.g.CreateFontW(size, 0, 0, 0, weight,
                                   1 if italic else 0, 0, 0, charset, 0, 0, 0, 0, face)
        old = self.g.SelectObject(self.mem, hfont)
        self.g.TextOutW(self.mem, 0, 0, ch, 1)
        self.g.SelectObject(self.mem, old)
        self.g.DeleteObject(hfont)
        raw = ctypes.string_at(self.bits.value, W * 3 * H)
        rows = []
        for y in range(H):
            base = (H - 1 - y) * W * 3  # DIB is bottom-up
            rows.append([1 if raw[base + x * 3] < 128 else 0 for x in range(W)])
        return rows

    def close(self):
        self.g.DeleteObject(self.bmp)
        self.g.DeleteDC(self.mem)
        self.u.ReleaseDC(None, self.hdc)


def to_hex(rows):
    bits = [v for row in rows for v in row]
    assert len(bits) == 256
    out = []
    for i in range(0, 256, 4):
        n = (bits[i] << 3) | (bits[i + 1] << 2) | (bits[i + 2] << 1) | bits[i + 3]
        out.append("0123456789ABCDEF"[n])
    return "".join(out)


def shear(rows, delta):
    out = [[0] * W for _ in range(H)]
    for y, row in enumerate(rows):
        shift = (y * delta) // H
        for x, v in enumerate(row):
            nx = x + shift
            if 0 <= nx < W:
                out[y][nx] = v
    return out


def dilate(rows):
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if rows[y][x]:
                for dy in (-1, 0, 1):
                    for dx in (0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < H and 0 <= nx < W:
                            out[ny][nx] = 1
    return out


def line_image(gdi, chars, face, gap, size=16, bold=False, italic=False, charset=134):
    width = len(chars) * W + (len(chars) - 1) * gap
    grid = [[0] * width for _ in range(H)]
    for i, ch in enumerate(chars):
        cell = gdi.render(ch, face, size, bold, italic, charset)
        x0 = i * (W + gap)
        for y in range(H):
            for x in range(W):
                grid[y][x0 + x] = cell[y][x]
    return width, grid


def hex_line(width, grid):
    bits = [v for row in grid for v in row]
    while len(bits) % 4:
        bits.append(0)
    out = []
    for i in range(0, len(bits), 4):
        n = (bits[i] << 3) | (bits[i + 1] << 2) | (bits[i + 2] << 1) | bits[i + 3]
        out.append("0123456789ABCDEF"[n])
    return width, "".join(out)


def cj_string_array(name, values, per_line=8):
    lines = ["    public static let %s: Array<String> = [" % name]
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        suffix = "," if i + per_line < len(values) else ""
        lines.append("        " + ", ".join('"%s"' % v for v in chunk) + suffix)
    lines.append("    ]")
    return "\n".join(lines)


def main():
    if sys.platform != "win32":
        print("This generator needs Windows GDI; run it on Windows once and commit the output.")
        return 1
    # Domain vocabulary first: a pure frequency list would crowd out the
    # characters this product actually needs to read (档案 / 编号 / 姓名 ...).
    chars = dedupe(CJK_DOMAIN + CJK_FREQUENT, 220)
    if len(chars) < 50:
        raise RuntimeError("font/GDI produced no usable character set")

    gdi = Gdi()
    # Eight prototypes per character: four common printed typefaces plus
    # brush/serif, bold and size variants. More prototypes = better tolerance
    # to weight/size drift, at the cost of a larger generated data file.
    cjk_styles = (
        ("SimSun", False, 16), ("SimHei", False, 16),
        ("Microsoft YaHei", False, 16), ("FangSong", False, 16),
        ("KaiTi", False, 16), ("SimHei", True, 16),
        ("Microsoft YaHei", True, 16), ("SimSun", False, 15),
    )
    cjk_bits = []
    for ch in chars:
        for face, bold, size in cjk_styles:
            cjk_bits.append(to_hex(gdi.render(ch, face, size, bold)))

    hand_chars = list("0123456789")
    hand_faces = [("Segoe Print", 0), ("Comic Sans MS", 0),
                  ("Lucida Handwriting", 0), ("Pristina", 0),
                  ("Brush Script MT", 0), ("Mistral", 0), ("KaiTi", 134)]
    hand_bits = []
    for ch in hand_chars:
        base = None
        for face, charset in hand_faces:
            rows = gdi.render(ch, face, 16, False, False, charset)
            if base is None:
                base = rows
            hand_bits.append(to_hex(rows))
        hand_bits.append(to_hex(shear(base, 2)))
        hand_bits.append(to_hex(dilate(base)))

    # Cross-font fixtures: render with fonts NOT used for prototypes, so the
    # unit test measures generalisation rather than memorisation.
    # SimSun bold is NOT among the eight prototypes (only SimHei/YaHei bold).
    cjk_w, cjk_grid = line_image(gdi, "档案编号", "SimSun", 2, 16, True)
    # Bold Segoe Print is an unseen weight (prototypes are regular).
    hand_w, hand_grid = line_image(gdi, "7350", "Segoe Print", 3, 16, True, False, 0)
    _, cjk_hex = hex_line(cjk_w, cjk_grid)
    _, hand_hex = hex_line(hand_w, hand_grid)
    gdi.close()

    body = [
        "// ============================================================",
        "// ams.core.media · GENERATED FILE — DO NOT EDIT BY HAND",
        "//",
        "// Generated by scripts/gen-media-glyphs.py (build-time only).",
        "// Each 64-char hex string is a 16x16 binary glyph, row-major,",
        "// 4 pixels per hex digit, MSB first. Runtime needs no font/GDI.",
        "// CJK prototypes: SimSun + SimHei. Hand prototypes: handwriting",
        "// typefaces + shear/thicken variants (digits only).",
        "// ============================================================",
        "package ams.core.media",
        "",
        "public class GlyphData {",
        cj_string_array("CJK_CHARS", chars),
        cj_string_array("CJK_BITS", cjk_bits, per_line=2),
        cj_string_array("HAND_CHARS", hand_chars),
        cj_string_array("HAND_BITS", hand_bits, per_line=2),
        "    /** Eight prototypes per CJK character (4 typefaces + brush/bold/size variants). */",
        "    public static let CJK_PROTOS: Int64 = 8",
        "    /** Nine prototypes per handwritten digit (7 styles + shear + thicken). */",
        "    public static let HAND_PROTOS: Int64 = 9",
        "    public static let TEST_CJK_W: Int64 = %d" % cjk_w,
        "    public static let TEST_CJK_H: Int64 = %d" % H,
        '    public static let TEST_CJK_BITS: String = "%s"' % cjk_hex,
        '    public static let TEST_CJK_EXPECT: String = "档案编号"',
        "    public static let TEST_HAND_W: Int64 = %d" % hand_w,
        "    public static let TEST_HAND_H: Int64 = %d" % H,
        '    public static let TEST_HAND_BITS: String = "%s"' % hand_hex,
        '    public static let TEST_HAND_EXPECT: String = "7350"',
        "}",
    ]
    io.open(OUT, "w", encoding="utf-8", newline="").write("\r\n".join(body) + "\r\n")
    print("WROTE", OUT)
    print("CJK chars", len(chars), "prototypes", len(cjk_bits))
    print("HAND chars", len(hand_chars), "prototypes", len(hand_bits))
    print("fixtures cjk", cjk_w, "x", H, "hand", hand_w, "x", H)
    return 0


if __name__ == "__main__":
    sys.exit(main())
