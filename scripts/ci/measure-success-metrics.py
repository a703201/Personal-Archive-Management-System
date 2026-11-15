#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS · 成功指标只读度量（docs/01 §2.4 中可自动观测的部分）。

设计约束（重要，勿放宽）：
  1. 只读：只发 GET 到公开只读端点，不注册账号、不写库、不改任何数据。
  2. 不编造：测不出的一律标 SKIP / NEEDS_EXTERNAL，绝不填占位数字。
  3. 不等价声明：公开只读端点的延迟只用于观测服务响应与可用性，
     **不等价于** docs/01 §2.4 定义的「检索到目标条目的 P95」——
     后者需要有效登录态 + 真实样本数据，见 REPORT 里的说明。

docs/01 §2.4 七项指标的分类（本脚本据此输出，不越界）：
  - 采纳率 / 30 日留存 / 单条录入耗时  → NEEDS_USERS（需真实用户 + 埋点）
  - 检索 P95 ≤ 800ms                  → NEEDS_AUTH_SAMPLE（需登录态 + 样本；本脚本只做只读近似观测）
  - 审计日志覆盖率 100%               → 由 scripts/ci/verify-audit.sh 断言（需 auditor 账号，本脚本不代跑）
  - 高危/严重漏洞 0                   → NEEDS_THIRD_PARTY（需第三方渗透测试报告）
  - 服务可用性 ≥ 99.9%               → 本脚本可做**窗口内采样**，但短窗口不能推出年度/月度 99.9%

用法：
  python3 scripts/ci/measure-success-metrics.py
  AMS_METRICS_BASE=http://127.0.0.1:8080 AMS_METRICS_N=30 python3 scripts/ci/measure-success-metrics.py
  python3 scripts/ci/measure-success-metrics.py --json   # 机器可读输出
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("AMS_METRICS_BASE", "http://127.0.0.1:8080").rstrip("/")
N = int(os.environ.get("AMS_METRICS_N", "30"))
TIMEOUT = float(os.environ.get("AMS_METRICS_TIMEOUT", "5"))

# 公开只读端点：health 不碰 DB，branding / setup/status 碰 DB，可区分两类路径
PROBES = (
    ("health", "/api/health", False),
    ("branding(DB)", "/api/branding", True),
    ("setup_status(DB)", "/api/setup/status", True),
)


def probe(path):
    req = urllib.request.Request(BASE + path, method="GET")
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            body = r.read()
            return (r.status, (time.perf_counter() - t0) * 1000.0, len(body))
    except urllib.error.HTTPError as e:
        return (e.code, (time.perf_counter() - t0) * 1000.0, 0)
    except Exception:
        return (0, (time.perf_counter() - t0) * 1000.0, 0)


def percentile(sorted_vals, p):
    """最近秩法（nearest-rank）：ceil(p/100 * N) 位置，不做插值。"""
    if not sorted_vals:
        return None
    import math
    k = max(1, math.ceil(p / 100.0 * len(sorted_vals)))
    return sorted_vals[min(k, len(sorted_vals)) - 1]


def main():
    results = {}
    reachable = False
    for name, path, _touches_db in PROBES:
        samples = []
        ok = 0
        for _ in range(N):
            code, ms, _size = probe(path)
            samples.append(ms)
            if code == 200:
                ok += 1
        if ok > 0:
            reachable = True
        s = sorted(samples)
        results[name] = {
            "n": N,
            "ok": ok,
            "availability_in_window_pct": round(ok * 100.0 / N, 2),
            "p50_ms": round(percentile(s, 50), 1),
            "p95_ms": round(percentile(s, 95), 1),
            "p99_ms": round(percentile(s, 99), 1),
            "max_ms": round(s[-1], 1),
        }

    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "base": BASE,
        "samples_per_probe": N,
        "service_reachable": reachable,
        "measured_readonly": results if reachable else {},
        "metrics_classification": {
            "adoption_7d_ge5_items": "NEEDS_USERS - real users + tracking; no data in repo",
            "retention_30d": "NEEDS_USERS - real users + tracking; no data in repo",
            "entry_time_le_90s": "NEEDS_USERS - real users + frontend tracking; no data in repo",
            "search_p95_le_800ms": "NEEDS_AUTH_SAMPLE - requires valid token + real dataset; "
                                   "readonly probes above are NOT equivalent",
            "audit_coverage_100pct": "AUTOMATABLE - scripts/ci/verify-audit.sh (needs auditor account)",
            "critical_vulns_zero": "NEEDS_THIRD_PARTY - external pentest report; none in repo",
            "availability_ge_99_9pct": "PARTIAL - window sampling above only; "
                                       "short window cannot prove 99.9% monthly/annual SLA",
        },
        "red_lines": [
            "No competitor numbers fabricated (docs/19 red line 3).",
            "No user/tracking data invented; missing metrics are marked, not filled.",
            "Read-only: no account created, no DB row written.",
        ],
    }

    if "--json" in sys.argv:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0

    print("=== AMS success-metrics readonly probe (%s, n=%d) ===" % (BASE, N))
    if not reachable:
        print("[SKIP] service not reachable; no metrics were measured (nothing fabricated).")
    else:
        for name, r in results.items():
            print("[%s] ok=%d/%d avail=%.2f%% p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms"
                  % (name, r["ok"], r["n"], r["availability_in_window_pct"],
                     r["p50_ms"], r["p95_ms"], r["p99_ms"], r["max_ms"]))
    print("--- docs/01 2.4 classification ---")
    for k, v in report["metrics_classification"].items():
        print("  %-28s %s" % (k, v))
    print("NOTE: readonly probe latency != search P95; no competitor/user/third-party data invented.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
