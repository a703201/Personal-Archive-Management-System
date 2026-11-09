#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS media worker: OFFLINE REFERENCE IMPLEMENTATION / optional external engine.

IMPORTANT (2026-11-07): this file is NOT part of the runtime. The production
OCR engine is written in Cangjie at packages/ams-core/src/media/ and runs
in-process inside ams-server (single process, single port, no extra container).
This Python version is kept for:
  * cross-checking algorithm behavior and font bitmaps against the Cangjie
    implementation (`python3 scripts/media_worker.py --selftest`, 12/12);
  * deployments that explicitly want an external engine for JPEG / CJK /
    complex scans (wire it up yourself; no spool/worker is shipped by default).
It must never be described as a system dependency.

Design constraints (deliberate):
  * Standard library ONLY. No Pillow / cv2 / tesseract / numpy at runtime.
  * PNG / BMP / PPM decoding, PNG encoding, PDF text extraction, binarization,
    projection segmentation, 5x7 template OCR, resizing and watermark burn-in
    are all implemented here.
  * Bounded scope: the built-in OCR targets monospace printed digits/letters
    whose glyphs resemble the built-in 5x7 font. Complex scans, handwriting,
    CJK and JPEG input need the optional external engine hook
    (AMS_OCR_EXTERNAL_CMD). This is stated honestly, not hidden.
  * File-queue protocol shared with the Cangjie side:
      <spool>/<id>.job        JSON: id, tasks, inputFile/inputBase64, watermarkText
      <spool>/<id>.done.json  JSON: id, ok, ocrText, ocrStatus, ocrEngine,
                              thumbnail(base64 png), watermarked(base64 png), error
      processed/<id>.job      moved here after handling
    ocrStatus: 0 pending, 2 done, 3 failed / unsupported.

Usage:
  python3 scripts/media_worker.py --selftest
  python3 scripts/media_worker.py --job FILE --out DIR
  python3 scripts/media_worker.py --once DIR
  python3 scripts/media_worker.py --watch DIR --interval 3
"""
import argparse
import base64
import json
import os
import re
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

# ---------------------------------------------------------------------------
# Built-in 5x7 font (35 bits per glyph, row-major). Hand-written, no font lib.
# ---------------------------------------------------------------------------
FONT_5X7 = {
    "0": "01110" "10001" "10011" "10101" "11001" "10001" "01110",
    "1": "00100" "01100" "00100" "00100" "00100" "00100" "01110",
    "2": "01110" "10001" "00001" "00010" "00100" "01000" "11111",
    "3": "11111" "00010" "00100" "00010" "00001" "10001" "01110",
    "4": "00010" "00110" "01010" "10010" "11111" "00010" "00010",
    "5": "11111" "10000" "11110" "00001" "00001" "10001" "01110",
    "6": "00110" "01000" "10000" "11110" "10001" "10001" "01110",
    "7": "11111" "00001" "00010" "00100" "01000" "01000" "01000",
    "8": "01110" "10001" "10001" "01110" "10001" "10001" "01110",
    "9": "01110" "10001" "10001" "01111" "00001" "00010" "01100",
    "A": "01110" "10001" "10001" "11111" "10001" "10001" "10001",
    "B": "11110" "10001" "10001" "11110" "10001" "10001" "11110",
    "C": "01111" "10000" "10000" "10000" "10000" "10000" "01111",
    "D": "11110" "10001" "10001" "10001" "10001" "10001" "11110",
    "E": "11111" "10000" "10000" "11110" "10000" "10000" "11111",
    "F": "11111" "10000" "10000" "11110" "10000" "10000" "10000",
    "G": "01111" "10000" "10000" "10111" "10001" "10001" "01111",
    "H": "10001" "10001" "10001" "11111" "10001" "10001" "10001",
    "I": "01110" "00100" "00100" "00100" "00100" "00100" "01110",
    "J": "00111" "00010" "00010" "00010" "10010" "10010" "01100",
    "K": "10001" "10010" "10100" "11000" "10100" "10010" "10001",
    "L": "10000" "10000" "10000" "10000" "10000" "10000" "11111",
    "M": "10001" "11011" "10101" "10101" "10001" "10001" "10001",
    "N": "10001" "11001" "10101" "10011" "10001" "10001" "10001",
    "O": "01110" "10001" "10001" "10001" "10001" "10001" "01110",
    "P": "11110" "10001" "10001" "11110" "10000" "10000" "10000",
    "Q": "01110" "10001" "10001" "10001" "10101" "10010" "01101",
    "R": "11110" "10001" "10001" "11110" "10100" "10010" "10001",
    "S": "01111" "10000" "10000" "01110" "00001" "00001" "11110",
    "T": "11111" "00100" "00100" "00100" "00100" "00100" "00100",
    "U": "10001" "10001" "10001" "10001" "10001" "10001" "01110",
    "V": "10001" "10001" "10001" "10001" "10001" "01010" "00100",
    "W": "10001" "10001" "10001" "10101" "10101" "11011" "10001",
    "X": "10001" "10001" "01010" "00100" "01010" "10001" "10001",
    "Y": "10001" "10001" "01010" "00100" "00100" "00100" "00100",
    "Z": "11111" "00001" "00010" "00100" "01000" "10000" "11111",
    "-": "00000" "00000" "00000" "11111" "00000" "00000" "00000",
    ".": "00000" "00000" "00000" "00000" "00000" "01100" "01100",
    "/": "00001" "00010" "00010" "00100" "01000" "01000" "10000",
    ":": "00000" "01100" "01100" "00000" "01100" "01100" "00000",
}
FONT_BITS = {k: [1 if c == "1" else 0 for c in v] for k, v in FONT_5X7.items()}


class Image:
    __slots__ = ("w", "h", "px")

    def __init__(self, w, h, px):
        self.w = w
        self.h = h
        self.px = px  # bytearray, RGB, w*h*3


# ---------------------------------------------------------------------------
# PNG decoding / encoding
# ---------------------------------------------------------------------------
def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def encode_png(img):
    raw = bytearray()
    stride = img.w * 3
    for y in range(img.h):
        raw.append(0)
        raw += img.px[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", img.w, img.h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    w = h = depth = ctype = interlace = None
    palette = b""
    idat = bytearray()
    while pos + 8 <= len(data):
        ln = struct.unpack_from(">I", data, pos)[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h, depth, ctype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"PLTE":
            palette = body
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    if w is None or h is None or w <= 0 or h <= 0:
        raise ValueError("PNG missing IHDR")
    if depth != 8 or interlace != 0 or ctype not in (0, 2, 3, 4, 6):
        raise ValueError("unsupported PNG variant (need 8-bit non-interlaced)")
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    if len(raw) < h * (stride + 1):
        raise ValueError("PNG scanline data truncated")
    px = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(stride):
                if i >= bpp:
                    line[i] = (line[i] + line[i - bpp]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) // 2)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 255
        elif ft != 0:
            raise ValueError("unknown PNG filter %d" % ft)
        for x in range(w):
            o = x * bpp
            if ctype == 0:
                r = g = b = line[o]
            elif ctype == 2:
                r, g, b = line[o], line[o + 1], line[o + 2]
            elif ctype == 3:
                idx = line[o] * 3
                if idx + 2 >= len(palette):
                    raise ValueError("PNG palette index out of range")
                r, g, b = palette[idx], palette[idx + 1], palette[idx + 2]
            elif ctype == 4:
                v, a = line[o], line[o + 1]
                r = g = b = (v * a + 255 * (255 - a)) // 255
            else:
                a = line[o + 3]
                r = (line[o] * a + 255 * (255 - a)) // 255
                g = (line[o + 1] * a + 255 * (255 - a)) // 255
                b = (line[o + 2] * a + 255 * (255 - a)) // 255
            q = (y * w + x) * 3
            px[q], px[q + 1], px[q + 2] = r, g, b
        prev = line
    return Image(w, h, px)


def decode_bmp(data):
    if data[:2] != b"BM":
        raise ValueError("not a BMP")
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    comp = struct.unpack_from("<I", data, 30)[0]
    if bpp != 24 or comp != 0:
        raise ValueError("unsupported BMP (need 24-bit BI_RGB)")
    bottom_up = h > 0
    h = abs(h)
    stride = ((w * 3 + 3) // 4) * 4
    if off + stride * h > len(data):
        raise ValueError("BMP data truncated")
    px = bytearray(w * h * 3)
    for row in range(h):
        src = off + row * stride
        dst = h - 1 - row if bottom_up else row
        for x in range(w):
            b, g, r = data[src + x * 3:src + x * 3 + 3]
            q = (dst * w + x) * 3
            px[q], px[q + 1], px[q + 2] = r, g, b
    return Image(w, h, px)


def decode_ppm(data):
    # Minimal binary P6 parser (comments and single whitespace tolerated).
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise ValueError("not a binary P6 PPM")
    w, h, maxv = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if maxv != 255:
        raise ValueError("PPM maxval must be 255")
    body = data[m.end():]
    if len(body) < w * h * 3:
        raise ValueError("PPM data truncated")
    return Image(w, h, bytearray(body[:w * h * 3]))


def sniff(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:2] == b"BM":
        return "bmp"
    if data[:4] == b"%PDF":
        return "pdf"
    if data[:2] == b"P6":
        return "ppm"
    if data[:2] == b"\xff\xd8":
        return "jpeg"
    return "unknown"


def decode_image(data, fmt):
    if fmt == "png":
        return decode_png(data)
    if fmt == "bmp":
        return decode_bmp(data)
    if fmt == "ppm":
        return decode_ppm(data)
    raise ValueError("no decoder for " + fmt)


# ---------------------------------------------------------------------------
# PDF text extraction (FlateDecode streams + literal-string Tj / TJ operators)
# ---------------------------------------------------------------------------
PDF_STR = re.compile(rb"\((?:\\.|[^\\()])*\)", re.S)
PDF_ESCAPES = {ord("n"): 10, ord("r"): 13, ord("t"): 9,
               ord("b"): 8, ord("f"): 12}


def _pdf_unescape(s):
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c == 92 and i + 1 < len(s):
            n = s[i + 1]
            if n in PDF_ESCAPES:
                out.append(PDF_ESCAPES[n])
                i += 2
                continue
            if 48 <= n <= 55:
                j = i + 1
                octs = bytearray()
                while j < len(s) and 48 <= s[j] <= 55 and len(octs) < 3:
                    octs.append(s[j])
                    j += 1
                out.append(int(octs.decode("ascii"), 8) & 255)
                i = j
                continue
            out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    b = bytes(out)
    if b.startswith(b"\xfe\xff"):
        return b[2:].decode("utf-16-be", "replace")
    return b.decode("latin-1", "replace")


def extract_pdf_text(data):
    parts = []
    for m in re.finditer(rb"stream\r?\n", data):
        start = m.end()
        end = data.find(b"endstream", start)
        if end < 0:
            continue
        raw = data[start:end].rstrip(b"\r\n")
        try:
            stream = zlib.decompress(raw)
        except Exception:
            stream = raw
        for sm in PDF_STR.finditer(stream):
            parts.append(_pdf_unescape(sm.group(0)[1:-1]))
    return re.sub(r"\s+", " ", " ".join(p.strip() for p in parts if p.strip())).strip()


# ---------------------------------------------------------------------------
# OCR: Otsu binarization, projection segmentation, 5x7 template matching
# ---------------------------------------------------------------------------
def to_binary(img):
    gray = bytearray(img.w * img.h)
    for i in range(img.w * img.h):
        q = i * 3
        gray[i] = (img.px[q] * 299 + img.px[q + 1] * 587 + img.px[q + 2] * 114) // 1000
    hist = [0] * 256
    for v in gray:
        hist[v] += 1
    total = len(gray)
    if total == 0:
        return bytearray()
    sum_all = sum(i * hist[i] for i in range(256))
    w_b = 0
    sum_b = 0
    best = -1.0
    thr = 128
    for t in range(256):
        w_b += hist[t]
        if w_b == 0:
            continue
        w_f = total - w_b
        if w_f == 0:
            break
        sum_b += t * hist[t]
        var = w_b * w_f * (sum_b / w_b - (sum_all - sum_b) / w_f) ** 2
        if var > best:
            best = var
            thr = t
    # Degenerate histograms (pure white background + pure black ink) make Otsu
    # pick t=0, which would classify every pixel as background. Fall back to a
    # mid threshold whenever the split lands at either extreme.
    if thr < 16 or thr > 240:
        thr = 128
    return bytearray(1 if v <= thr else 0 for v in gray)


def _line_ranges(binary, w, h):
    ranges = []
    start = None
    for y in range(h):
        row = binary[y * w:(y + 1) * w]
        ink = 1 if any(row) else 0
        if ink and start is None:
            start = y
        elif not ink and start is not None:
            if y - start >= 3:
                ranges.append((start, y))
            start = None
    if start is not None and h - start >= 3:
        ranges.append((start, h))
    return ranges


def _char_ranges(binary, w, y0, y1):
    cols = [0] * w
    for x in range(w):
        s = 0
        for y in range(y0, y1):
            s += binary[y * w + x]
        cols[x] = s
    ranges = []
    start = None
    for x, c in enumerate(cols):
        if c and start is None:
            start = x
        elif not c and start is not None:
            ranges.append((start, x))
            start = None
    if start is not None:
        ranges.append((start, w))
    return ranges


def _normalize(binary, w, x0, x1, y0, y1):
    cw = max(1, x1 - x0)
    ch = max(1, y1 - y0)
    bits = []
    for ty in range(7):
        sy = y0 + min(ch - 1, (ty * ch) // 7)
        for tx in range(5):
            sx = x0 + min(cw - 1, (tx * cw) // 5)
            bits.append(1 if binary[sy * w + sx] else 0)
    return bits


def _match(bits):
    best_ch, best_d = "?", 36
    for ch, fb in FONT_BITS.items():
        d = sum(1 for a, b in zip(bits, fb) if a != b)
        if d < best_d:
            best_ch, best_d = ch, d
    return best_ch if best_d <= 10 else "?"


def ocr_image(img, max_chars=512):
    binary = to_binary(img)
    if not binary:
        return ""
    lines = []
    for y0, y1 in _line_ranges(binary, img.w, img.h):
        chars = []
        for x0, x1 in _char_ranges(binary, img.w, y0, y1):
            if x1 - x0 < 2 or y1 - y0 < 3:
                continue
            chars.append(_match(_normalize(binary, img.w, x0, x1, y0, y1)))
            if len(chars) >= max_chars:
                break
        lines.append("".join(chars))
    return "\n".join(lines).strip()


# ---------------------------------------------------------------------------
# Thumbnail + pixel watermark
# ---------------------------------------------------------------------------
def resize(img, max_side):
    scale = min(float(max_side) / max(img.w, img.h), 1.0)
    nw = max(1, int(round(img.w * scale)))
    nh = max(1, int(round(img.h * scale)))
    out = Image(nw, nh, bytearray(nw * nh * 3))
    for y in range(nh):
        sy = min(img.h - 1, (y * img.h) // nh)
        for x in range(nw):
            sx = min(img.w - 1, (x * img.w) // nw)
            o = (y * nw + x) * 3
            s = (sy * img.w + sx) * 3
            out.px[o:o + 3] = img.px[s:s + 3]
    return out


def _draw_glyph(img, ch, x0, y0, scale, alpha=0.42):
    s = FONT_5X7.get(ch)
    if not s:
        return
    ink = (250, 250, 250)
    for ty in range(7):
        for tx in range(5):
            if s[ty * 5 + tx] != "1":
                continue
            for dy in range(scale):
                for dx in range(scale):
                    x, y = x0 + tx * scale + dx, y0 + ty * scale + dy
                    if not (0 <= x < img.w and 0 <= y < img.h):
                        continue
                    q = (y * img.w + x) * 3
                    for k in range(3):
                        img.px[q + k] = int(img.px[q + k] * (1 - alpha) + ink[k] * alpha)


def burn_watermark(img, text, scale=2):
    out = Image(img.w, img.h, bytearray(img.px))
    t = (text or "AMS").upper()[:80]
    tw = len(t) * 6 * scale
    step_x = max(tw + 40, 140)
    step_y = max(7 * scale + 34, 64)
    row = 0
    y = 8
    while y < img.h:
        x = -((row * 37) % step_x)
        while x < img.w:
            for i, ch in enumerate(t):
                _draw_glyph(out, ch, x + i * 6 * scale, y, scale)
            x += step_x
        y += step_y
        row += 1
    return out


# ---------------------------------------------------------------------------
# Helpers for selftest / external engine hook
# ---------------------------------------------------------------------------
def render_text(text, scale=3, pad=8):
    chars = [c for c in text.upper() if c in FONT_5X7 or c == " "]
    cw, gap = 5 * scale, scale
    w = pad * 2 + len(chars) * (cw + gap)
    h = pad * 2 + 7 * scale
    img = Image(w, h, bytearray(b"\xff" * (w * h * 3)))
    for i, ch in enumerate(chars):
        if ch == " ":
            continue
        s = FONT_5X7[ch]
        for ty in range(7):
            for tx in range(5):
                if s[ty * 5 + tx] != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        x = pad + i * (cw + gap) + tx * scale + dx
                        y = pad + ty * scale + dy
                        q = (y * w + x) * 3
                        img.px[q] = img.px[q + 1] = img.px[q + 2] = 0
    return img


def _external_ocr(cmd, data):
    """Optional hook: command template may contain {input}; stdout is the text."""
    import tempfile
    suffix = ".png"
    fmt = sniff(data)
    if fmt == "pdf":
        suffix = ".pdf"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        f.write(data)
        tmp = f.name
    try:
        real = cmd.replace("{input}", tmp)
        p = subprocess.run(real, shell=True, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=60)
        return p.stdout.decode("utf-8", "replace").strip() if p.returncode == 0 else ""
    except Exception:
        return ""
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def process_job(job_path, out_dir, external_cmd=None):
    src = Path(job_path)
    job = json.loads(src.read_text(encoding="utf-8"))
    jid = str(job.get("id") or src.stem)
    tasks = job.get("tasks") or ["ocr", "thumbnail", "watermark"]
    res = {"id": jid, "ok": True, "ocrText": "", "ocrStatus": 0,
           "ocrEngine": "builtin", "thumbnail": "", "watermarked": "", "error": ""}
    try:
        if job.get("inputFile"):
            data = Path(job["inputFile"]).read_bytes()
        else:
            data = base64.b64decode(job.get("inputBase64", ""))
        if not data:
            raise ValueError("empty input")
        fmt = sniff(data)
        if fmt == "pdf":
            text = extract_pdf_text(data)
            res["ocrText"] = text
            res["ocrStatus"] = 2 if text else 3
            res["ocrEngine"] = "pdf-text"
            if "thumbnail" in tasks or "watermark" in tasks:
                res["error"] = "raster tasks unsupported for PDF"
        elif fmt in ("png", "bmp", "ppm"):
            img = decode_image(data, fmt)
            if "ocr" in tasks:
                text = ocr_image(img)
                if not text and external_cmd:
                    text = _external_ocr(external_cmd, data)
                    if text:
                        res["ocrEngine"] = "external"
                res["ocrText"] = text
                res["ocrStatus"] = 2 if text else 3
            if "thumbnail" in tasks:
                res["thumbnail"] = base64.b64encode(encode_png(resize(img, 256))).decode("ascii")
            if "watermark" in tasks:
                wm = burn_watermark(img, job.get("watermarkText", ""))
                res["watermarked"] = base64.b64encode(encode_png(wm)).decode("ascii")
        else:
            res["ok"] = False
            res["ocrStatus"] = 3
            res["error"] = "unsupported format: %s (JPEG/scans need AMS_OCR_EXTERNAL_CMD)" % fmt
    except Exception as e:
        res["ok"] = False
        res["ocrStatus"] = 3
        res["error"] = type(e).__name__ + ": " + str(e)[:200]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    # Binary artifacts are also written as plain files so the Cangjie side can
    # read them with StorageBackend.get without implementing base64 decoding.
    for field, suffix in (("thumbnail", ".thumb.png"), ("watermarked", ".wm.png")):
        if res[field]:
            try:
                (out / (jid + suffix)).write_bytes(base64.b64decode(res[field]))
            except Exception:
                pass
    (out / (jid + ".done.json")).write_text(
        json.dumps(res, ensure_ascii=False), encoding="utf-8")
    processed = out / "processed"
    processed.mkdir(exist_ok=True)
    try:
        src.rename(processed / src.name)
    except OSError:
        pass
    return res


def selftest():
    checks = []

    def check(name, cond, detail=""):
        checks.append((name, bool(cond), detail))
        print(("  [PASS] " if cond else "  [FAIL] ") + name + (" :: " + detail if detail else ""))

    # 1. PNG round-trip + self-written OCR
    src = render_text("ABC123", scale=3)
    png = encode_png(src)
    back = decode_png(png)
    check("png roundtrip", (back.w, back.h, bytes(back.px)) ==
          (src.w, src.h, bytes(src.px)), "%dx%d" % (back.w, back.h))
    got = ocr_image(back)
    check("builtin OCR ABC123", got.replace("\n", "") == "ABC123", repr(got))

    # 2. BMP round-trip
    bmp_w, bmp_h = src.w, src.h
    stride = ((bmp_w * 3 + 3) // 4) * 4
    body = bytearray()
    for y in range(bmp_h - 1, -1, -1):
        for x in range(bmp_w):
            q = (y * bmp_w + x) * 3
            body += bytes((src.px[q + 2], src.px[q + 1], src.px[q]))
        body += b"\x00" * (stride - bmp_w * 3)
    off = 54
    header = (b"BM" + struct.pack("<IHHI", off + len(body), 0, 0, off)
              + struct.pack("<IiiHHIIiiII", 40, bmp_w, bmp_h, 1, 24, 0,
                            len(body), 2835, 2835, 0, 0))
    bmp_back = decode_bmp(bytes(header) + bytes(body))
    check("bmp roundtrip OCR", ocr_image(bmp_back).replace("\n", "") == "ABC123")

    # 3. Thumbnail keeps aspect and bounds
    thumb = resize(src, 32)
    check("thumbnail bounds & aspect",
          max(thumb.w, thumb.h) <= 32 and abs(thumb.w / thumb.h - src.w / src.h) < 0.25,
          "%dx%d" % (thumb.w, thumb.h))
    check("thumbnail png decodes", decode_png(encode_png(thumb)).w == thumb.w)

    # 4. Watermark actually changes pixels and stays a valid PNG
    wm = burn_watermark(src, "AMS 20261107 #A1B2C3")
    check("watermark changes pixels", bytes(wm.px) != bytes(src.px))
    check("watermarked png decodes", decode_png(encode_png(wm)).w == wm.w)

    # 5. PDF literal-string extraction from a FlateDecode stream
    content = b"BT /F1 12 Tf 72 720 Td (Hello AMS 123) Tj ET"
    comp = zlib.compress(content)
    pdf = (b"%PDF-1.4\n1 0 obj\n<< /Length " + str(len(comp)).encode()
           + b" /Filter /FlateDecode >>\nstream\n" + comp
           + b"\nendstream\nendobj\ntrailer\n<<>>\n%%EOF\n")
    check("pdf text extraction", "Hello AMS 123" in extract_pdf_text(pdf),
          repr(extract_pdf_text(pdf)))

    # 6. Job protocol end-to-end
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        inp = d / "plain.png"
        inp.write_bytes(png)
        job = {"id": "att_1", "tasks": ["ocr", "thumbnail", "watermark"],
               "inputFile": str(inp), "watermarkText": "viewer 2026-11-07"}
        (d / "att_1.job").write_text(json.dumps(job), encoding="utf-8")
        r = process_job(d / "att_1.job", d)
        check("job protocol OCR", r["ocrText"].replace("\n", "") == "ABC123",
              repr(r["ocrText"]))
        check("job protocol thumbnail", len(r["thumbnail"]) > 100)
        check("job protocol watermark", len(r["watermarked"]) > 100)
        check("job writes done.json", (d / "att_1.done.json").exists())

    failed = [n for n, ok, _ in checks if not ok]
    print("RESULT: %s (%d/%d)" % ("PASS" if not failed else "FAIL",
                                  len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description="AMS media worker (stdlib only)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--job", metavar="FILE")
    ap.add_argument("--out", default=".")
    ap.add_argument("--once", metavar="DIR")
    ap.add_argument("--watch", metavar="DIR")
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--external-cmd", default=os.environ.get("AMS_OCR_EXTERNAL_CMD", ""))
    a = ap.parse_args()
    ext = a.external_cmd or None
    if a.selftest:
        return selftest()
    if a.job:
        r = process_job(a.job, a.out, ext)
        print("OK" if r["ok"] else "ERROR", r.get("error", ""))
        return 0
    directory = a.once or a.watch
    if not directory:
        ap.print_help()
        return 2
    d = Path(directory)
    while True:
        for f in sorted(d.glob("*.job")):
            try:
                r = process_job(f, d, ext)
                print(("OK " if r["ok"] else "ERR ") + f.name)
            except Exception as e:
                print("ERR " + f.name + " " + type(e).__name__)
        if a.watch:
            time.sleep(max(0.5, a.interval))
        else:
            return 0


if __name__ == "__main__":
    sys.exit(main())
