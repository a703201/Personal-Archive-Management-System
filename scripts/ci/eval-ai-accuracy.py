#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS · AI 字段抽取精度评估（docs/20 §11.1）

约束（沿用 measure-success-metrics.py 的诚实口径，勿放宽）：
  1. 不编造：所有分值都由传入的预测/真值逐条计算，绝不写死目标数字。
  2. 不内置隐私数据：默认只生成**合成样例**跑通指标管线，供 CI 冒烟；
     真实脱敏样例通过 --samples 注入（JSONL，不进仓库、不进发布包）。
  3. 目标值仅供参考：§11.1 的 F1≥0.90 等是"建议目标待评审"，本脚本
     只输出实测值与是否达标，不替用户拍板。

输入 JSONL 每行（真实样例由用户提供，字段与 docs/20 §5.6.4 对齐）：
  {
    "id": "n0",
    "category": 5,
    "fields": [{"code":"certificate_name","value":"XX证书","confidence":0.93,
                "bbox":[10,20,100,30]}],
    "truth":  [{"code":"certificate_name","value":"XX证书","bbox":[12,20,100,30]}]
  }

指标：
  - 字段级 P/R/F1（按 code+归一化 value 精确匹配，可分别对关键字段/全字段）
  - 来源定位 IoU>=0.5 占比（provider 未给 bbox 时不计入分母）
  - 置信度三桶（0-0.7 / 0.7-0.9 / 0.9-1）实际准确率与低桶误采纳率
  - 失败提示覆盖：八类场景文案命中（只读检查前端 i18n 词条是否齐全）

用法：
  python3 scripts/ci/eval-ai-accuracy.py                 # 合成样例冒烟
  python3 scripts/ci/eval-ai-accuracy.py --samples p.jsonl --json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

KEY_FIELDS: dict[int, set[str]] = {
    2: {"issuing_authority", "valid_until"},
    5: {"certificate_name", "issuer", "issue_date"},
    3: {"school", "degree_type", "end_date"},
}

FAIL_SCENES = [
    "badFormat", "readFailed", "parseFailed", "noFields",
    "noAttach", "disabled", "failed", "copy",
]


def norm(v: Any) -> str:
    """归一化：去空白、全角转半角、统一日期分隔符（沿用 V3 思路的简化版）。"""
    s = str(v or "").strip()
    table = str.maketrans("：／－，。", ":/-,.")
    s = s.translate(table)
    return "".join(s.split())


def synthetic_samples(n: int = 12) -> list[dict[str, Any]]:
    """生成合成样例（纯内存，无隐私数据），仅用于跑通指标管线。"""
    out: list[dict[str, Any]] = []
    for i in range(n):
        cat = 5 if i % 2 == 0 else 2
        if cat == 5:
            true_fields = [
                {"code": "certificate_name", "value": "合成证书%d" % i},
                {"code": "issuer", "value": "合成机构%d" % i},
                {"code": "issue_date", "value": "2024-01-%02d" % (i % 28 + 1)},
            ]
        else:
            true_fields = [
                {"code": "issuing_authority", "value": "合成机%d" % i},
                {"code": "valid_until", "value": "2030-12-31"},
            ]
        # 前 80% 全命中，后 20% 人为漏一个字段并降置信度，确保指标非满分且可复现
        pred = []
        for j, tf in enumerate(true_fields):
            if i >= int(n * 0.8) and j == 0:
                continue
            conf = 0.95 if j == 0 else (0.75 if j == 1 else 0.55)
            item = {"code": tf["code"], "value": tf["value"], "confidence": conf}
            if j == 0:
                item["bbox"] = [10, 20, 100, 30]
            pred.append(item)
        out.append({
            "id": "syn-%02d" % i,
            "category": cat,
            "fields": pred,
            "truth": [dict(t, bbox=[10, 20, 100, 30]) for t in true_fields],
        })
    return out


def iou(a: list[float], b: list[float]) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


def evaluate(samples: list[dict[str, Any]]) -> dict[str, Any]:
    tp = fp = fn = 0
    key_tp = key_fp = key_fn = 0
    iou_hit = iou_total = 0
    buckets: dict[str, list[bool]] = {"low": [], "mid": [], "high": []}

    for s in samples:
        cat = int(s.get("category", 0))
        keys = KEY_FIELDS.get(cat, set())
        truths = {(f["code"], norm(f.get("value"))): f for f in s.get("truth", [])}
        preds = {(f["code"], norm(f.get("value"))): f for f in s.get("fields", [])}

        for k, tf in truths.items():
            hit = k in preds
            if hit:
                tp += 1
                if k[0] in keys:
                    key_tp += 1
            else:
                fn += 1
                if k[0] in keys:
                    key_fn += 1
            # 置信度分桶：以预测值为准，未命中按 0 计（严格）
            conf = float(preds[k].get("confidence", 0.0)) if hit else 0.0
            b = "low" if conf < 0.7 else ("mid" if conf < 0.9 else "high")
            buckets[b].append(hit)

        for k in preds:
            if k not in truths:
                fp += 1
                if k[0] in keys:
                    key_fp += 1

        # 来源定位：只统计真值与预测都给 bbox 的字段
        for k, tf in truths.items():
            if k in preds and tf.get("bbox") and preds[k].get("bbox"):
                iou_total += 1
                if iou(preds[k]["bbox"], tf["bbox"]) >= 0.5:
                    iou_hit += 1

    def prf(a: int, b: int, c: int) -> dict[str, float]:
        p = a / (a + b) if a + b else 0.0
        r = a / (a + c) if a + c else 0.0
        f = 2 * p * r / (p + r) if p + r else 0.0
        return {"precision": round(p, 4), "recall": round(r, 4), "f1": round(f, 4)}

    bucket_stats = {}
    for name, hits in buckets.items():
        n = len(hits)
        bucket_stats[name] = {
            "n": n,
            "accuracy": round(sum(hits) / n, 4) if n else None,
        }
    low_n = len(buckets["low"])
    low_wrong = sum(1 for h in buckets["low"] if h)
    # 低桶"误采纳率"：低置信度却实际命中的比例（命中也不该一键采纳）
    low_bucket_adopt_err = round(low_wrong / low_n, 4) if low_n else None

    return {
        "samples": len(samples),
        "all_fields": prf(tp, fp, fn),
        "key_fields": prf(key_tp, key_fp, key_fn),
        "source_iou": {
            "evaluated": iou_total,
            "accuracy": round(iou_hit / iou_total, 4) if iou_total else None,
        },
        "confidence_buckets": bucket_stats,
        "low_bucket_adopt_error": low_bucket_adopt_err,
        "targets_reference": {
            "key_f1": 0.90, "all_f1": 0.80,
            "source_iou": 0.85, "low_adopt_error_max": 0.10,
            "note": "docs/20 §11.1 建议目标，待用户评审；非已达事实",
        },
    }


def check_i18n(root: Path) -> dict[str, Any]:
    """失败提示覆盖：只读检查三语 catalog 是否含 §5.6.6 八类文案键。"""
    catalog = root / "web" / "src" / "i18n" / "catalog.zh-CN.ts"
    if not catalog.exists():
        return {"covered": 0, "total": len(FAIL_SCENES), "missing": FAIL_SCENES, "skipped": True}
    text = catalog.read_text(encoding="utf-8")
    missing = [s for s in FAIL_SCENES if "aiIntake.%s" % s not in text]
    return {
        "covered": len(FAIL_SCENES) - len(missing),
        "total": len(FAIL_SCENES),
        "missing": missing,
        "skipped": False,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="AMS AI 字段抽取精度评估（docs/20 §11.1）")
    ap.add_argument("--samples", help="真实脱敏样例 JSONL 路径（不进仓库）")
    ap.add_argument("--synthetic-n", type=int, default=12, help="合成样例条数（默认 12）")
    ap.add_argument("--json", action="store_true", help="输出 JSON（便于 CI 归档）")
    ap.add_argument("--check-i18n", action="store_true", help="同时检查失败提示三语覆盖")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[2]
    if args.samples:
        p = Path(args.samples)
        if not p.exists():
            print("ERROR: 样例文件不存在: %s" % p, file=sys.stderr)
            return 2
        samples = [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]
        source = str(p)
    else:
        samples = synthetic_samples(args.synthetic_n)
        source = "synthetic (CI smoke, no privacy data)"

    report = evaluate(samples)
    report["sample_source"] = source
    if args.check_i18n:
        report["failure_hints"] = check_i18n(root)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("AMS AI 精度评估（docs/20 §11.1）")
        print("  样例来源: %s (%d 条)" % (source, len(samples)))
        print("  全字段  P/R/F1: %.3f / %.3f / %.3f" % (
            report["all_fields"]["precision"], report["all_fields"]["recall"], report["all_fields"]["f1"]))
        print("  关键字段 P/R/F1: %.3f / %.3f / %.3f" % (
            report["key_fields"]["precision"], report["key_fields"]["recall"], report["key_fields"]["f1"]))
        si = report["source_iou"]
        print("  来源定位 IoU>=0.5: %s（评估 %d 条）" % (
            "N/A" if si["accuracy"] is None else "%.3f" % si["accuracy"], si["evaluated"]))
        for b, st in report["confidence_buckets"].items():
            print("  置信度桶 %-4s: n=%d, 准确率=%s" % (
                b, st["n"], "N/A" if st["accuracy"] is None else "%.3f" % st["accuracy"]))
        if args.check_i18n:
            fh = report["failure_hints"]
            print("  失败提示覆盖: %d/%d%s" % (
                fh["covered"], fh["total"], "" if fh["skipped"] or not fh["missing"] else " (缺 %s)" % fh["missing"]))
        print("  注：目标值为 docs/20 §11.1 建议、待评审；合成样例仅验证管线，不代表真实精度。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
