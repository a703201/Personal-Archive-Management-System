#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成竞品对照用的**合成**样本集（不含任何真实用户数据）。

两套装样本喂给 AMS 与 Paperless-ngx，保证输入完全一致：
  sample_01.txt  纯文本档案（含证件号/姓名/单位等敏感字段，均为虚构值）
  sample_02.txt  第二份档案（用于检索区分度测试）
  sample_03.png  含中文的 16x16 点阵放大图（用于 OCR 路径对照）

用法：python3 scripts/ci/competitor-study/make_samples.py [输出目录]
输出目录默认 .tmp/competitor-study/samples
"""
import os
import struct
import sys
import zlib

# 脚本位于 <repo>/scripts/ci/competitor-study/ → 仓库根需上跳 3 层
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, ".tmp", "competitor-study", "samples")
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)

# 全部为虚构数据，不对应任何真实个人
TXT1 = """个人档案 · 样本一（虚构数据）
姓名：张三测试
证件编号：110101199001011234
联系电话：13800000001
单位：示例科技有限公司
学历：本科
备注：用于竞品对照实验，非真实档案
关键词：麒麟对照标记 ALPHA
"""
TXT2 = """个人档案 · 样本二（虚构数据）
姓名：李四测试
证件编号：110101199202025678
联系电话：13800000002
单位：另一示例单位
学历：硕士
备注：用于竞品对照实验，非真实档案
关键词：貔貅对照标记 BETA
"""

# 16x16 点阵「档案」二字的简易放大图（每行 16 像素，重复 8 次放大到 128x256）
# 目的不是测 OCR 准确率，而是提供一个「含中文的位图」输入，
# 用于观察两个系统的 OCR 是否依赖外部进程/引擎。
GLYPHS = [
    "0011111111111100", "0000001110000000", "0011111111111100", "0010000000000100",
    "0011111111111100", "0001000010001000", "0011111111111100", "0000100001000000",
    "0011111111111100", "0000010010000000", "0011111111111100", "0000001000000000",
    "0011111111111100", "0000010000000000", "0011111111111100", "0000000000000000",
]


def png_gray(width, height, pixel_fn):
    """纯 stdlib 生成 8-bit 灰度 PNG（filter 0）。"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.append(pixel_fn(x, y))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def main():
    for name, text in (("sample_01.txt", TXT1), ("sample_02.txt", TXT2)):
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
            f.write(text)

    scale = 8
    w, h = 16 * scale, 16 * scale
    data = png_gray(w, h, lambda x, y: 0 if GLYPHS[y // scale][x // scale] == "1" else 255)
    with open(os.path.join(OUT, "sample_03.png"), "wb") as f:
        f.write(data)

    print("样本目录:", OUT)
    for n in sorted(os.listdir(OUT)):
        print("  %-18s %d bytes" % (n, os.path.getsize(os.path.join(OUT, n))))
    print("说明: 全部为合成/虚构数据，不含任何真实个人信息。")


if __name__ == "__main__":
    main()
