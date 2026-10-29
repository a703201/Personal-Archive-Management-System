# -*- coding: utf-8 -*-
"""AMS 审计链独立校验器（不依赖 ams-server，也不依赖 Cangjie）

用途
----
`GET /api/audit/verify-chain` 是**服务端自证**：用被测代码校验被测代码。
本脚本按同一份规范化规则用 Python 独立复算一遍 SM3，可与服务端结论交叉比对，
用于验收、取证与排障（例如判断「tampered」是真篡改还是重算口径不一致）。

规范（packages/ams-security/src/audit/audit.cj · AuditService.canonicalize）
--------------------------------------------------------------------------
    record_hash = SM3( hex(prev_hash) | chainSeq | actorId | actorType |
                       action.code() | targetType | targetId | subjectId |
                       category | result | errorCode | clientIp | userAgent |
                       traceId | occurredAt(ms) | detail )
    字段以 '|' 连接；detail 按 key 字典序拼成 k=v&k=v（空 detail → 空串）。

判定
----
  - 哈希一致：重算值 == aud_logs.record_hash
  - 衔接一致：本条 prev_hash == 上一条 record_hash（首条应为 32 字节全 0）
  - 序号连续：chain_seq 逐条 +1（断层 = 记录被删，审计链必然断在这里）

退出码：0 全部一致；1 存在不一致；2 环境/查询失败。

用法
----
    python scripts/verify-audit-chain.py
    python scripts/verify-audit-chain.py --from 900021
    python scripts/verify-audit-chain.py --raw          # 同时打印明细
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

CONTAINER = os.environ.get("AMS_DB_CONTAINER", "ams_opengauss")
DB = os.environ.get("AMS_DB_NAME", "ams")
USER = os.environ.get("AMS_DB_USER", "gaussdb")
PASSWORD = os.environ.get("AMS_DB_PASSWORD", "Ams@Gauss2026")
GSQL = "/usr/local/opengauss/bin/gsql"
LIB = "/usr/local/opengauss/lib:/usr/lib/x86_64-linux-gnu"

GENESIS = "00" * 32
NULL = "<<N>>"

COLS = [
    "chain_seq", "actor_id", "actor_type", "action", "action_desc",
    "target_type", "target_id", "subject_id", "category", "result",
    "error_code", "client_ip", "user_agent", "trace_id", "occurred_ms",
    "detail", "prev_hash", "record_hash",
]

SQL = """SELECT chain_seq, COALESCE(actor_id::text,'0'), actor_type, action,
       COALESCE(action_desc,''), COALESCE(target_type,'{n}'), COALESCE(target_id,'{n}'),
       COALESCE(subject_id::text,'0'), category, result,
       COALESCE(error_code,'{n}'), COALESCE(client_ip,'{n}'), COALESCE(user_agent,'{n}'),
       COALESCE(trace_id,'{n}'), occurred_ms, COALESCE(detail::text,'{{}}'),
       encode(prev_hash,'hex'), encode(record_hash,'hex')
FROM aud_logs WHERE chain_seq >= {frm} ORDER BY chain_seq ASC LIMIT {lim};"""


def fetch(from_seq, limit):
    sql = SQL.format(n=NULL, frm=from_seq, lim=limit).replace("\n       ", " ")
    env = dict(os.environ)
    env["MSYS_NO_PATHCONV"] = "1"
    cmd = [
        "docker", "exec", "-e", "LD_LIBRARY_PATH=" + LIB, CONTAINER,
        GSQL, "-U", USER, "-d", DB, "-W", PASSWORD,
        "-A", "-t", "-F", "\x01", "-R", "\x02", "-c", sql,
    ]
    p = subprocess.run(cmd, capture_output=True, env=env)
    out = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0 or "ERROR" in out:
        sys.stderr.write("查询失败：\n" + out + p.stderr.decode("utf-8", "replace"))
        sys.exit(2)
    rows = [r.strip() for r in out.split("\x02") if r.strip()]
    recs = []
    for r in rows:
        f = r.split("\x01")
        if len(f) != len(COLS):
            sys.stderr.write("字段数异常(%d)：%r\n" % (len(f), r[:80]))
            sys.exit(2)
        recs.append(dict(zip(COLS, f)))
    return recs


def sm3(text):
    return hashlib.new("sm3", text.encode("utf-8")).hexdigest()


def detail_canon(text):
    """与 detailToJson/jsonFlatEntries 的往返结果等价。"""
    t = (text or "").strip()
    if not t or t == "{}":
        return ""
    obj = json.loads(t)
    if not isinstance(obj, dict):
        return ""
    return "&".join("%s=%s" % (k, obj[k]) for k in sorted(obj.keys()))


def canon(rec):
    return "|".join([
        rec["prev_hash"].lower(),
        rec["chain_seq"],
        rec["actor_id"],
        rec["actor_type"],
        rec["action"],
        "" if rec["target_type"] == NULL else rec["target_type"],
        "" if rec["target_id"] == NULL else rec["target_id"],
        rec["subject_id"],
        rec["category"],
        rec["result"],
        "" if rec["error_code"] == NULL else rec["error_code"],
        "" if rec["client_ip"] == NULL else rec["client_ip"],
        "" if rec["user_agent"] == NULL else rec["user_agent"],
        "" if rec["trace_id"] == NULL else rec["trace_id"],
        rec["occurred_ms"],
        detail_canon(rec["detail"]),
    ])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", type=int, default=1)
    ap.add_argument("--limit", type=int, default=10000)
    ap.add_argument("--raw", action="store_true", help="打印每条差异明细")
    args = ap.parse_args()

    recs = fetch(args.frm, args.limit)
    if not recs:
        print("审计表为空（chain_seq >= %d 无记录）" % args.frm)
        return 0

    bad_hash, bad_link, gaps = [], [], []
    for i, r in enumerate(recs):
        calc = sm3(canon(r))
        if calc != r["record_hash"].lower():
            bad_hash.append((r["chain_seq"], r["action"], calc[:16], r["record_hash"][:16]))

        want = GENESIS if i == 0 else recs[i - 1]["record_hash"].lower()
        if r["prev_hash"].lower() != want:
            bad_link.append((r["chain_seq"], r["prev_hash"][:16], want[:16]))

        if i > 0:
            d = int(r["chain_seq"]) - int(recs[i - 1]["chain_seq"])
            if d != 1:
                gaps.append((recs[i - 1]["chain_seq"], r["chain_seq"], d))

    n = len(recs)
    print("校验范围：chain_seq %s .. %s（%d 条）" % (recs[0]["chain_seq"], recs[-1]["chain_seq"], n))
    print("哈希复算一致 ：%d / %d" % (n - len(bad_hash), n))
    print("prev 衔接一致：%d / %d" % (n - len(bad_link), n))
    print("序号断层     ：%d 处" % len(gaps))

    if bad_hash:
        print("\n[哈希不一致 → 记录内容被改动过]")
        for b in bad_hash:
            print("  seq=%-9s action=%-24s 实算=%s 落库=%s" % b)
    if bad_link:
        print("\n[prev 衔接断裂 → 前一条记录已不存在]")
        for b in bad_link[:20]:
            print("  seq=%-9s 落库prev=%s 期望=%s" % b)
        if len(bad_link) > 20:
            print("  ... 共 %d 条" % len(bad_link))
    if gaps:
        print("\n[序号断层]")
        for g in gaps[:20]:
            print("  %s -> %s（跨 %d）" % g)
        if len(gaps) > 20:
            print("  ... 共 %d 处" % len(gaps))

    if args.raw:
        print("\n[明细]")
        for r in recs:
            print("  %-9s %-24s %s" % (r["chain_seq"], r["action"], canon(r)[:110]))

    ok = not bad_hash and not bad_link and not gaps
    print("\n结论：" + ("整链一致" if ok else "存在不一致（见上）"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
