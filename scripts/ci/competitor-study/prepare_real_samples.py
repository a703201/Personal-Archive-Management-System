#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从用户提供的证书目录生成**序号化、脱敏命名**的真实样本副本。

隐私口径（最严格，用户 2026-11-15 确认）：
  · 源目录只读，绝不修改/移动/重命名/删除原件
  · 副本仅写入 .tmp/competitor-study/real/（已被 git 忽略）
  · 副本名一律 n0.ext / n1.ext ...，不含姓名、证书编号或任何原始文件名
  · 不上传、不进 git、不进 Release；用毕由 compare.sh 删除
  · 任何报告只写聚合指标（数量/大小分布），不写文件名或内容

源路径**不硬编码**：由 --src 传入（或环境变量 AMS_CERT_SRC）。
用法：
  python3 scripts/ci/competitor-study/prepare_real_samples.py --src "D:/个人/证书"
"""
import argparse
import glob
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_DST = ROOT / ".tmp" / "competitor-study" / "real"


def pick(src: str):
    """按格式 + 体积分档挑代表性样本，返回 [(path, size), ...]。"""
    groups = {
        "pdf_small": [(f, os.path.getsize(f)) for f in glob.glob(src + "/*.pdf")
                      if os.path.getsize(f) < 500_000],
        "pdf_mid": [(f, os.path.getsize(f)) for f in glob.glob(src + "/*.pdf")
                    if 500_000 <= os.path.getsize(f) < 10_000_000],
        "pdf_large": [(f, os.path.getsize(f)) for f in glob.glob(src + "/*.pdf")
                      if os.path.getsize(f) >= 10_000_000],
        "png": [(f, os.path.getsize(f)) for f in glob.glob(src + "/**/*.png", recursive=True)],
        "jpg": [(f, os.path.getsize(f)) for f in glob.glob(src + "/**/*.jpg", recursive=True)],
    }
    picks = []
    for items in groups.values():
        if not items:
            continue
        s = sorted(items, key=lambda x: x[1])
        picks += [s[0], s[-1]] if len(s) > 1 else [s[0]]
    seen, uniq = set(), []
    for f, sz in picks:
        if f not in seen:
            seen.add(f)
            uniq.append((f, sz))
    return uniq


def main():
    ap = argparse.ArgumentParser(description="生成序号化真实样本副本（源目录只读）")
    ap.add_argument("--src", default=os.environ.get("AMS_CERT_SRC", ""),
                    help="证书源目录（只读）。不硬编码，需显式传入或设 AMS_CERT_SRC")
    ap.add_argument("--dst", default=str(DEFAULT_DST), help="副本输出目录（默认 .tmp 下）")
    ap.add_argument("--clean", action="store_true", help="只删除副本目录，不生成")
    a = ap.parse_args()

    dst = Path(a.dst)
    if a.clean:
        if dst.exists():
            shutil.rmtree(dst)
            print("已删除副本目录:", dst)
        else:
            print("副本目录不存在，无需清理:", dst)
        return 0

    if not a.src or not os.path.isdir(a.src):
        print("[ERROR] 未提供有效的 --src 证书目录（源目录不会被读取以外的方式接触）", file=sys.stderr)
        return 2

    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)

    uniq = pick(a.src)
    for i, (f, _sz) in enumerate(uniq):
        ext = f.rsplit(".", 1)[-1].lower()
        shutil.copy2(f, dst / ("n%d.%s" % (i, ext)))  # copy2 = 只读源，不改原件

    # 只输出聚合指标，绝不打印原始文件名
    total = sum(p.stat().st_size for p in dst.iterdir())
    kinds = {}
    for p in dst.iterdir():
        kinds[p.suffix.lower()] = kinds.get(p.suffix.lower(), 0) + 1
    print("副本数:", len(uniq))
    print("格式分布:", ", ".join("%s=%d" % (k, v) for k, v in sorted(kinds.items())))
    print("总大小: %.1f MB" % (total / 1024 / 1024))
    print("副本目录:", dst)
    print("命名: 已序号化（nN.ext），不含姓名/编号；源目录保持只读。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
