#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
AMS · 家庭协作（FR-ACL-010）端到端验收 + 前后端同端口部署验收。

用法：
    python scripts/ci/verify-family.py
    # 自定义端口（默认 18102，避开 verify-authz.sh 的 18101）
    AMS_VERIFY_PORT=18103 python scripts/ci/verify-family.py

脚本自己负责启停服务：从仓库根目录起 `build/ams-server(.exe)`，
退出时按 PID 精确清理（不用 pkill —— 其匹配范围会命中本脚本自身）。

覆盖：
  一、静态托管（前后端同进程）
      /                → 200 text/html（index.html）
      /archive         → 200 text/html（SPA history 回落）
      /api/nope        → 404 application/json（接口前缀不被 HTML 接管）
      /assets/missing  → 404（带扩展名缺失必须真 404）
      /..%2f..%2f...   → 400/404（目录穿越被拒）
  二、邀请闭环
      A 建组 → A 生成邀请 → 公开落地页 → B 输码入组（含 normalize：小写+连字符）
      → 幂等再接受不报失效 → 非成员拿 404
  三、失效语义
      错误码 → 403 且失败计数 +1；达上限即作废，之后 code 正确也 404
      已撤销 → 404；落地页 valid=false 且不返回组名（防枚举）
  四、可见性
      授权前 B 列表为空 → 主体级授权后可见 → 撤销后立刻 404
      B 自始至终无法访问 /api/items（入组不改变全局权限）
  五、主体级授权 + 列表下推
      被授权条目必须出现在 /api/items（列表与详情口径一致）
      主体筛选不得因「被授权分支」被绕过
  六、条目级授权的隔离性
      同主体下只授一条 → 共享列表恰好 1 条，另一条详情 404
      /api/items 里也只多这一条（不因同一主体而整片放开）
  三-B、并发 accept 压测
      单条使用邀请（maxUses=1）下 10 个账号并发兑换 → 恰好 1 人成功入组、其余 9 人一律 404
      （验证 consumeOnce 的单条 UPDATE + WHERE 行锁原子语义）
"""
import json
import os
import random
import signal
import string
import subprocess
import tempfile
import sys
import time
import urllib.error
import urllib.request
import concurrent.futures

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORT = os.environ.get("AMS_VERIFY_PORT", "18102")
BASE = "http://127.0.0.1:%s" % PORT
SERVER = os.path.join(ROOT, "build", "ams-server.exe")
if not os.path.exists(SERVER):
    SERVER = os.path.join(ROOT, "build", "ams-server")

ok_count = 0
fail_count = 0
srv = None
LOG_PATH = ""


def check(name, cond, extra=""):
    global ok_count, fail_count
    if cond:
        ok_count += 1
        print("  [OK]   %s" % name)
    else:
        fail_count += 1
        print("  [FAIL] %s %s" % (name, extra))


def call(method, path, body=None, token=None, raw=False):
    """返回 (status, content_type, payload_or_text)"""
    url = BASE + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status, ctype, text = r.status, r.headers.get("content-type", ""), r.read()
    except urllib.error.HTTPError as e:
        status, ctype, text = e.code, e.headers.get("content-type", ""), e.read()
    if raw:
        return status, ctype, text
    try:
        return status, ctype, json.loads(text.decode("utf-8"))
    except Exception:
        return status, ctype, text.decode("utf-8", "replace")


def data_of(resp):
    return resp[2].get("data") if isinstance(resp[2], dict) else None


def db_exec(sql):
    subprocess.run([sys.executable, "scripts/db.py", "sql", "-s", sql],
                   cwd=ROOT, capture_output=True, text=True)


def rand(n=6):
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def start_server():
    """从**仓库根**启动服务：静态托管要按 cwd 探测 web/dist。"""
    global srv
    # ⚠️ 用 tempfile.gettempdir() 而不是硬编码 /tmp：本文件由**原生 Windows
    #    Python** 执行（不是 Git Bash），`/tmp` 在那边不存在，会直接 FileNotFoundError。
    log_path = os.path.join(tempfile.gettempdir(), "ams_verify_family.log")
    global LOG_PATH
    LOG_PATH = log_path
    log = open(log_path, "w")
    env = dict(os.environ)
    env["AMS_HTTP_PORT"] = PORT
    env["AMS_TOKEN_SECRET"] = "verify-family-secret-key-2026-abcdefghijkl"
    env["AMS_DB_PASSWORD"] = os.environ.get("AMS_DB_PASSWORD", "Ams@Gauss2026")
    srv = subprocess.Popen([SERVER], cwd=ROOT, env=env,
                           stdout=log, stderr=subprocess.STDOUT)
    # 等健康检查通过（最多 30s）：直接 sleep 固定秒数在慢机器上会假失败
    for _ in range(60):
        time.sleep(0.5)
        try:
            st, _, _ = call("GET", "/api/health")
            if st == 200:
                return True
        except Exception:
            pass
    return False


def stop_server():
    if srv is None:
        return
    try:
        srv.send_signal(signal.SIGTERM)
        srv.wait(timeout=5)
    except Exception:
        try:
            srv.kill()
        except Exception:
            pass


suffix = rand()
user_a = "e2e_a_" + suffix
user_b = "e2e_b_" + suffix
pwd = "Ams@2026#E2E"
print("=== AMS E2E · 家庭协作 + 同端口部署（端口 %s）===" % PORT)

if not os.path.exists(SERVER):
    print("[ABORT] 找不到 %s，请先 bash scripts/build.sh" % SERVER)
    sys.exit(1)
if not start_server():
    print("[ABORT] 服务未能在 30s 内就绪，日志见 %s" % LOG_PATH)
    stop_server()
    sys.exit(1)
# 中途断言异常也要收掉进程，否则下一次跑会端口占用
import atexit
atexit.register(stop_server)

print("  用户 A: %s" % user_a)
print("  用户 B: %s" % user_b)
print()

# ---------------------------------------------------------------
# 一、静态托管
# ---------------------------------------------------------------
print("[一] 前后端同端口静态托管")

st, ctype, body = call("GET", "/", raw=True)
check("GET / → 200", st == 200, "got %s" % st)
check("GET / → text/html", "text/html" in ctype, "got %s" % ctype)
check("GET / → 含前端挂载点", b'id="app"' in body or b"<script" in body, "body=%r" % body[:120])

st, ctype, body = call("GET", "/archive", raw=True)
check("GET /archive → 200（SPA 回落）", st == 200, "got %s" % st)
check("GET /archive → text/html", "text/html" in ctype, "got %s" % ctype)

st, ctype, body = call("GET", "/invite/deadbeef", raw=True)
check("GET /invite/:token → 200（公开页回落）", st == 200, "got %s" % st)

st, ctype, body = call("GET", "/api/definitely-not-a-route", raw=True)
check("GET /api/nope → 404", st == 404, "got %s" % st)
check("GET /api/nope → application/json", "application/json" in ctype, "got %s" % ctype)
check("GET /api/nope → 是 JSON 而非 HTML", body.strip().startswith(b"{"),
      "body=%r" % body[:120])

st, ctype, body = call("GET", "/assets/no-such-file.js", raw=True)
check("GET /assets/missing.js → 404（不回落 HTML）", st == 404, "got %s" % st)

st, ctype, body = call("GET", "/..%2f..%2fetc%2fpasswd", raw=True)
check("路径穿越被拒（400/404）", st in (400, 404), "got %s" % st)

st, ctype, body = call("GET", "/api/health")
check("GET /api/health → OK", st == 200 and data_of((st, ctype, body)) is not None,
      "got %s" % st)

# ---------------------------------------------------------------
# 二、准备两个账号
# ---------------------------------------------------------------
print()
print("[二] 准备账号")

r = call("POST", "/api/auth/register",
         {"username": user_a, "password": pwd, "email": "%s@e2e.local" % user_a})
check("注册 A", r[0] == 200, str(r[2])[:200])
id_a = data_of(r).get("id") if data_of(r) else None

r = call("POST", "/api/auth/register",
         {"username": user_b, "password": pwd, "email": "%s@e2e.local" % user_b})
check("注册 B", r[0] == 200, str(r[2])[:200])
id_b = data_of(r).get("id") if data_of(r) else None

if not id_a or not id_b:
    print("[ABORT] 注册失败，无法继续")
    sys.exit(1)

# A 需要 owner 角色才能建组（family:manage 只授给 owner / curator）。
# 新账号默认无角色是刻意的「默认拒绝」，所以这里由管理员直接落一条绑定。
rid = int(time.time() * 1000) % 1000000000 + 700000000
db_exec(
    "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, granted_by, "
    "granted_at, expires_at, category) VALUES (%d, %d, 800001, NULL, NULL, "
    "CURRENT_TIMESTAMP, NULL, 0)" % (rid, int(id_a))
)

r = call("POST", "/api/auth/login", {"username": user_a, "password": pwd})
check("登录 A", r[0] == 200, str(r[2])[:200])
tok_a = data_of(r).get("accessToken") if data_of(r) else None

r = call("POST", "/api/auth/login", {"username": user_b, "password": pwd})
check("登录 B", r[0] == 200, str(r[2])[:200])
tok_b = data_of(r).get("accessToken") if data_of(r) else None

if not tok_a or not tok_b:
    print("[ABORT] 登录失败")
    sys.exit(1)

r = call("GET", "/api/me", token=tok_a)
perms_a = (data_of(r) or {}).get("perms", [])
check("A 拿到 family:manage", "family:manage" in perms_a, str(perms_a)[:200])
check("A 拿到 family:invite", "family:invite" in perms_a, str(perms_a)[:200])

r = call("GET", "/api/me", token=tok_b)
perms_b = (data_of(r) or {}).get("perms", [])
check("B 无任何 family 权限", "family:manage" not in perms_b, str(perms_b)[:200])

# ---------------------------------------------------------------
# 三、建组 + 邀请
# ---------------------------------------------------------------
print()
print("[三] 建组与邀请")

r = call("POST", "/api/family/groups", {"name": "E2E 家庭 %s" % suffix}, token=tok_a)
check("A 建组", r[0] == 200, str(r[2])[:200])
gid = (data_of(r) or {}).get("groupId")
check("建组返回 role=owner", (data_of(r) or {}).get("role") == "owner", str(r[2])[:200])

r = call("GET", "/api/family/groups", token=tok_a)
groups = (data_of(r) or {}).get("items", [])
check("A 组列表含新建组", any(g["groupId"] == gid for g in groups), str(groups)[:300])
check("A 组列表 myRole=owner",
      any(g["groupId"] == gid and g["myRole"] == "owner" for g in groups), str(groups)[:300])

r = call("POST", "/api/family/groups/%s/invites" % gid,
         {"targetRole": "member", "expiresInMinutes": 30, "maxUses": 1, "maxFails": 3},
         token=tok_a)
check("A 生成邀请", r[0] == 200, str(r[2])[:200])
inv = data_of(r) or {}
code = inv.get("code", "")
itok = inv.get("token", "")
check("邀请码为 8 位", len(code) == 8, "code=%r" % code)
check("邀请码字符集合法（无 0/1/I/O）",
      all(c in "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" for c in code), "code=%r" % code)
check("邀请码不是 ASCII 码串（回归：曾产出 5051525354555657）",
      code != "".join(str(ord(c)) for c in code), "code=%r" % code)
check("token 为 32 位十六进制", len(itok) == 32, "token=%r" % itok)

# 落地页元数据（公开，无 token）
r = call("GET", "/api/family/invites/%s" % itok)
meta = data_of(r) or {}
check("公开落地页可读", r[0] == 200, str(r[2])[:200])
check("落地页 valid=true", meta.get("valid") is True, str(meta)[:200])
check("落地页返回组名", meta.get("groupName", "").startswith("E2E 家庭"), str(meta)[:200])

# 错误邀请码 → 403 且计入失败
r = call("POST", "/api/family/invites/accept",
         {"token": itok, "code": "ZZZZZZZZ"}, token=tok_b)
check("错误邀请码 → 403", r[0] == 403, str(r[2])[:200])

r = call("GET", "/api/family/groups/%s/invites" % gid, token=tok_a)
items = (data_of(r) or {}).get("items", [])
check("失败计数 +1", any(i["failCount"] == 1 for i in items), str(items)[:300])

# 正确邀请码（小写 + 连字符也要能过，验证 normalize）
r = call("POST", "/api/family/invites/accept",
         {"token": itok, "code": (code[:4] + "-" + code[4:]).lower()}, token=tok_b)
acc = data_of(r) or {}
check("B 用规范化后的邀请码入组", r[0] == 200, str(r[2])[:200])
check("入组返回 role=member", acc.get("role") == "member", str(acc)[:200])
check("入组不是 alreadyMember", acc.get("alreadyMember") is False, str(acc)[:200])

# 幂等：已是成员再 accept → 200 + alreadyMember（不消耗次数）
r = call("POST", "/api/family/invites/accept", {"token": itok, "code": code}, token=tok_b)
acc2 = data_of(r) or {}
check("已是成员再 accept → 200（幂等，不报邀请失效）", r[0] == 200, str(r[2])[:200])
check("幂等分支标记 alreadyMember=true", acc2.get("alreadyMember") is True, str(acc2)[:200])

r = call("GET", "/api/family/groups", token=tok_b)
groups_b = (data_of(r) or {}).get("items", [])
check("B 组列表含该组", any(g["groupId"] == gid for g in groups_b), str(groups_b)[:300])
check("B 组列表 myRole=member",
      any(g["groupId"] == gid and g["myRole"] == "member" for g in groups_b),
      str(groups_b)[:300])

# 组详情能力位
r = call("GET", "/api/family/groups/%s" % gid, token=tok_b)
det = data_of(r) or {}
check("成员 canInvite=false", det.get("canInvite") is False, str(det)[:200])
check("成员 canGrant=false", det.get("canGrant") is False, str(det)[:200])
check("成员 canDissolve=false", det.get("canDissolve") is False, str(det)[:200])

# 成员不能创建邀请（后端权威校验）
r = call("POST", "/api/family/groups/%s/invites" % gid, {"targetRole": "member"}, token=tok_b)
check("成员建邀请 → 403", r[0] == 403, str(r[2])[:200])

# ---- 非成员视角：失效邀请一律 404，且落地页不再暴露组名 ----
# C 只用于验证「非成员 + 失效邀请」，不需要任何权限
user_c = "e2e_c_" + suffix
call("POST", "/api/auth/register",
     {"username": user_c, "password": pwd, "email": "%s@e2e.local" % user_c})
r = call("POST", "/api/auth/login", {"username": user_c, "password": pwd})
tok_c = data_of(r).get("accessToken") if data_of(r) else None
check("登录 C（非成员）", bool(tok_c), str(r[2])[:200])

r = call("POST", "/api/family/invites/accept",
         {"token": "0" * 32, "code": "23456789"}, token=tok_c)
check("未知 token accept → 404", r[0] == 404, str(r[2])[:200])

# 撤销后 → 404 + 落地页 valid=false 且不含组名
r = call("POST", "/api/family/groups/%s/invites" % gid,
         {"targetRole": "member", "expiresInMinutes": 30, "maxUses": 1, "maxFails": 5},
         token=tok_a)
inv2 = data_of(r) or {}
r = call("DELETE", "/api/family/invites/%s" % inv2.get("inviteId"), token=tok_a)
check("A 撤销邀请", r[0] == 200, str(r[2])[:200])

r = call("POST", "/api/family/invites/accept",
         {"token": inv2.get("token"), "code": inv2.get("code")}, token=tok_c)
check("已撤销邀请 accept → 404", r[0] == 404, str(r[2])[:200])

r = call("GET", "/api/family/invites/%s" % inv2.get("token"))
m2 = data_of(r) or {}
check("已撤销邀请落地页 valid=false", m2.get("valid") is False, str(m2)[:200])
check("失效后不返回组名（防枚举）", m2.get("groupName") == "", str(m2)[:200])

# 失败次数达上限 → 自动作废，之后即使 code 正确也 404
r = call("POST", "/api/family/groups/%s/invites" % gid,
         {"targetRole": "member", "expiresInMinutes": 30, "maxUses": 1, "maxFails": 2},
         token=tok_a)
inv3 = data_of(r) or {}
call("POST", "/api/family/invites/accept",
     {"token": inv3.get("token"), "code": "ZZZZZZZZ"}, token=tok_c)
r = call("POST", "/api/family/invites/accept",
         {"token": inv3.get("token"), "code": "YYYYYYYY"}, token=tok_c)
check("第 2 次错误码 → 403", r[0] == 403, str(r[2])[:200])

r = call("POST", "/api/family/invites/accept",
         {"token": inv3.get("token"), "code": inv3.get("code")}, token=tok_c)
check("错误超限后即使 code 正确也 404（邀请已作废）", r[0] == 404, str(r[2])[:200])

# ---------------------------------------------------------------
# 三-B、并发 accept 压测
#   单一使用邀请（maxUses=1）下，10 个不同账号并发去兑换，
#   必须恰好 1 人成功入组、其余 9 人一律失败 —— 验证 consumeOnce
#   的「单条 UPDATE + WHERE 行锁」原子语义（docs/14 §12.4 / docs/15 §9）。
#   用不同账号是因为同一账号第二次会走 alreadyMember 幂等分支，
#   不再是并发竞态。
# ---------------------------------------------------------------
print()
print("[三-B] 并发 accept 压测（单条邀请 · 10 并发只应 1 人成功）")

CONC_N = 10
conc_toks = []
for i in range(CONC_N):
    u = "e2e_cc_%d_%s" % (i, suffix)
    call("POST", "/api/auth/register",
         {"username": u, "password": pwd, "email": "%s@e2e.local" % u})
    rr = call("POST", "/api/auth/login", {"username": u, "password": pwd})
    tt = (data_of(rr) or {}).get("accessToken")
    if not tt:
        print("  [WARN] 并发账号 %s 登录失败：%s" % (u, str(rr[2])[:120]))
    conc_toks.append(tt)

# 单条使用邀请：maxUses=1；失败上限放宽到 20，避免 code 错误计数干扰
r = call("POST", "/api/family/groups/%s/invites" % gid,
         {"targetRole": "member", "expiresInMinutes": 30,
          "maxUses": 1, "maxFails": 20}, token=tok_a)
conc = data_of(r) or {}
check("并发段：A 生成单条使用邀请", r[0] == 200, str(r[2])[:200])
ccode = conc.get("code", "")
ctoken = conc.get("token", "")

def _accept_once(tok):
    if not tok:
        return 0
    return call("POST", "/api/family/invites/accept",
                {"token": ctoken, "code": ccode}, token=tok)[0]

with concurrent.futures.ThreadPoolExecutor(max_workers=CONC_N) as ex:
    statuses = list(ex.map(_accept_once, conc_toks))

ok_cnt = sum(1 for s in statuses if s == 200)
non2xx = [s for s in statuses if s != 200]
check("并发 10 次接受，恰好 1 次成功（原子 consumeOnce）",
      ok_cnt == 1, "ok=%d statuses=%s" % (ok_cnt, statuses))
check("其余 9 次全部非 2xx", len(non2xx) == CONC_N - 1, "non2xx=%s" % non2xx)
check("失败均为 404（已用尽/不可枚举，非 5xx）",
      all(s == 404 for s in non2xx), "non2xx=%s" % non2xx)

# 组内实际只多了 1 名成员（owner A + B 已在本组；并发胜出者 +1，而非 10 人）
r = call("GET", "/api/family/groups/%s/members" % gid, token=tok_a)
joined = [m for m in (data_of(r) or {}).get("items", [])
          if str(m.get("userId")) not in (str(id_a), str(id_b))]
check("并发准入后组内恰好 1 名新成员（非 10）", len(joined) == 1,
      "joined=%s" % [m.get("userId") for m in joined])

# ---------------------------------------------------------------
# 四、授权前：B 看不到任何东西
# ---------------------------------------------------------------
print()
print("[四] 授权前的可见性")

r = call("GET", "/api/family/shared-items", token=tok_b)
check("B 的共享列表为空", (data_of(r) or {}).get("total") == 0, str(r[2])[:200])

r = call("GET", "/api/items?size=5", token=tok_b)
check("B 访问 /api/items → 403（入组不改变全局权限）", r[0] == 403, str(r[2])[:200])

# A 准备一个主体与一条条目
r = call("GET", "/api/subjects", token=tok_a)
subs = (data_of(r) or {}).get("subjects", [])
check("A 有默认主体", len(subs) >= 1, str(subs)[:200])
sid = subs[0]["id"] if subs else None

r = call("POST", "/api/items",
         {"subjectId": sid, "category": 2, "title": "E2E 证件 %s" % suffix,
          "sensitivity": 1, "issuer": "E2E 发证机关"}, token=tok_a)
check("A 新建档案条目", r[0] == 200, str(r[2])[:300])
iid = None
if r[0] == 200 and isinstance(r[2], dict):
    d = data_of(r)
    iid = d.get("id") if isinstance(d, dict) else None
if not iid:
    # 有的实现返回 {"item": {...}}
    r2 = call("GET", "/api/items?size=100", token=tok_a)
    for it in (data_of(r2) or {}).get("items", []):
        if it.get("title") == "E2E 证件 %s" % suffix:
            iid = it["id"]
            break
check("拿到条目 ID", bool(iid), "iid=%r" % iid)

# ---------------------------------------------------------------
# 五、主体级授权 → B 立刻可见
# ---------------------------------------------------------------
print()
print("[五] 主体级授权")

r = call("POST", "/api/family/groups/%s/grants" % gid,
         {"granteeId": int(id_b), "subjectId": int(sid)}, token=tok_a)
check("A 授权整个主体给 B", r[0] == 200, str(r[2])[:300])
grant_id = (data_of(r) or {}).get("grantId")
check("授权类型为 subject", (data_of(r) or {}).get("resourceType") == "subject",
      str(r[2])[:200])

r = call("GET", "/api/family/shared-items", token=tok_b)
shared = (data_of(r) or {}).get("items", [])
check("B 现在能看到共享条目", (data_of(r) or {}).get("total", 0) >= 1, str(r[2])[:300])
check("共享条目里有刚建的那条", any(x["id"] == str(iid) for x in shared),
      str([x["id"] for x in shared])[:200])

r = call("GET", "/api/family/shared-items/%s" % iid, token=tok_b)
check("B 读该条目详情 200", r[0] == 200, str(r[2])[:200])
check("详情标题正确", (data_of(r) or {}).get("title") == "E2E 证件 %s" % suffix,
      str(r[2])[:200])

r = call("GET", "/api/items?size=5", token=tok_b)
check("B 仍然无法访问 /api/items（只读出口是独立通道）", r[0] == 403, str(r[2])[:200])

# A 的授权列表
r = call("GET", "/api/family/groups/%s/grants" % gid, token=tok_a)
gl = (data_of(r) or {}).get("items", [])
check("A 授权列表可见且 active", any(g["grantId"] == grant_id and g["active"] for g in gl),
      str(gl)[:300])

# ---- 列表下推：被共享的条目也要出现在 /api/items（docs/15 §6 的风险点）----
# 给 B 一个能读自己档案的角色（curator），否则 /api/items 直接被权限挡掉，
# 测不到「列表是否包含被授权条目」。
rid2 = rid + 1
db_exec(
    "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, granted_by, "
    "granted_at, expires_at, category) VALUES (%d, %d, 800002, NULL, NULL, "
    "CURRENT_TIMESTAMP, NULL, 0)" % (rid2, int(id_b))
)

r = call("GET", "/api/items?size=100", token=tok_b)
items_b = (data_of(r) or {}).get("items", [])
hit = [x for x in items_b if x["id"] == str(iid)]
check("B 的档案列表出现被共享条目（列表 = 详情，不再半成品）",
      len(hit) == 1, str([x["id"] for x in items_b])[:200])
check("该条目带 shared=true 标记", len(hit) == 1 and hit[0].get("shared") is True,
      str(hit)[:200])

r = call("GET", "/api/items?size=100&subjectId=%s" % sid, token=tok_b)
check("按主体筛选仍能看到被共享条目",
      any(x["id"] == str(iid) for x in (data_of(r) or {}).get("items", [])),
      str((data_of(r) or {}).get("items"))[:200])

# 关键回归：主体筛选不能因为「被授权分支」而被绕过
r = call("GET", "/api/items?size=100&subjectId=99999999", token=tok_b)
check("主体筛选不会绕过（不返回其他主体的共享条目）",
      len((data_of(r) or {}).get("items", [])) == 0,
      str((data_of(r) or {}).get("items"))[:200])

# 越权：B 不能给任何人授权
r = call("POST", "/api/family/groups/%s/grants" % gid,
         {"granteeId": int(id_a), "subjectId": int(sid)}, token=tok_b)
check("B 尝试授权 → 403", r[0] == 403, str(r[2])[:200])

# 越权：A 不能授出别人的主体（用不存在的 subjectId 模拟）
r = call("POST", "/api/family/groups/%s/grants" % gid,
         {"granteeId": int(id_b), "subjectId": 99999999}, token=tok_a)
check("A 授出不存在的/非自己的主体 → 403", r[0] in (403, 404), str(r[2])[:200])

# ---------------------------------------------------------------
# 六、条目级授权的隔离性
# ---------------------------------------------------------------
print()
print("[六] 条目级授权的隔离性")

# 先撤掉主体级授权：否则「整个主体都可见」会掩盖条目级判定的真实结果。
r = call("DELETE", "/api/family/grants/%s" % grant_id, token=tok_a)
check("撤销主体级授权（为条目级隔离测试清场）", r[0] == 200, str(r[2])[:200])

# 同主体下再建一条：它是「未授权」的对照组，用来证明条目级授权
# 不会因为 subject_id 相同就把同主体下的其它条目一起放开。
title2 = "E2E 对照 %s" % suffix
r = call("POST", "/api/items",
         {"subjectId": sid, "category": 2, "title": title2,
          "sensitivity": 1, "issuer": "E2E 发证机关"}, token=tok_a)
iid2 = None
if r[0] == 200 and isinstance(r[2], dict):
    d = data_of(r)
    iid2 = d.get("id") if isinstance(d, dict) else None
if not iid2:
    r2 = call("GET", "/api/items?size=100", token=tok_a)
    for it in (data_of(r2) or {}).get("items", []):
        if it.get("title") == title2:
            iid2 = it["id"]
            break
check("A 在同主体下再建一条（对照组）", bool(iid2), "iid2=%r" % iid2)

# 只授 iid 这一条
r = call("POST", "/api/family/groups/%s/grants" % gid,
         {"granteeId": int(id_b), "subjectId": int(sid), "itemId": int(iid)}, token=tok_a)
check("A 只授权单条条目", r[0] == 200, str(r[2])[:300])
item_grant_id = (data_of(r) or {}).get("grantId")
check("授权类型为 item", (data_of(r) or {}).get("resourceType") == "item",
      str(r[2])[:200])

r = call("GET", "/api/family/shared-items", token=tok_b)
sh = (data_of(r) or {}).get("items", [])
check("条目级授权后共享列表恰好 1 条", (data_of(r) or {}).get("total") == 1,
      str((data_of(r) or {}).get("total")))
check("共享列表里就是被授的那一条", any(x["id"] == str(iid) for x in sh),
      str([x["id"] for x in sh])[:200])

r = call("GET", "/api/family/shared-items/%s" % iid, token=tok_b)
check("被授条目详情 200", r[0] == 200, str(r[2])[:200])

r = call("GET", "/api/family/shared-items/%s" % iid2, token=tok_b)
check("同主体下未授权条目详情 → 404", r[0] == 404, str(r[2])[:200])

# 关键回归：列表不得因为「同一 subject_id」而把对照条目一起放出来
r = call("GET", "/api/items?size=100", token=tok_b)
ids_b = [x["id"] for x in (data_of(r) or {}).get("items", [])]
check("列表里恰好只多这一条", str(iid) in ids_b and str(iid2) not in ids_b,
      str(ids_b)[:200])

r = call("GET", "/api/items?size=100&subjectId=%s" % sid, token=tok_b)
ids_bs = [x["id"] for x in (data_of(r) or {}).get("items", [])]
check("按主体筛选时对照条目仍不可见",
      str(iid) in ids_bs and str(iid2) not in ids_bs, str(ids_bs)[:200])

# 换给撤销段一个「当前有效」的授权 ID
grant_id = item_grant_id

# ---------------------------------------------------------------
# 七、撤销 → B 立刻不可见
# ---------------------------------------------------------------
print()
print("[七] 撤销与清理")

r = call("DELETE", "/api/family/grants/%s" % grant_id, token=tok_a)
check("A 撤销授权", r[0] == 200, str(r[2])[:200])

r = call("GET", "/api/family/shared-items", token=tok_b)
check("撤销后 B 列表归零", (data_of(r) or {}).get("total") == 0, str(r[2])[:200])

r = call("GET", "/api/family/shared-items/%s" % iid, token=tok_b)
check("撤销后 B 读详情 → 404（不确认条目是否存在）", r[0] == 404, str(r[2])[:200])

r = call("GET", "/api/items?size=100", token=tok_b)
check("撤销后 B 的档案列表不再出现该条目",
      all(x["id"] != str(iid) for x in (data_of(r) or {}).get("items", [])),
      str((data_of(r) or {}).get("items"))[:200])

# 移除成员
r = call("DELETE", "/api/family/groups/%s/members/%d" % (gid, int(id_b)), token=tok_a)
check("A 移除成员 B", r[0] == 200, str(r[2])[:200])

r = call("GET", "/api/family/groups", token=tok_b)
check("B 组列表归零", len((data_of(r) or {}).get("items", [])) == 0, str(r[2])[:200])

r = call("GET", "/api/family/groups/%s" % gid, token=tok_b)
check("B 访问已退出的组 → 403", r[0] == 403, str(r[2])[:200])

# 解散
r = call("DELETE", "/api/family/groups/%s" % gid, token=tok_a)
check("A 解散家庭组", r[0] == 200, str(r[2])[:200])

r = call("GET", "/api/family/groups", token=tok_a)
check("A 组列表归零", len((data_of(r) or {}).get("items", [])) == 0, str(r[2])[:200])

# ---------------------------------------------------------------
print()
print("=" * 56)
print(" 通过 %d 项，失败 %d 项" % (ok_count, fail_count))
print("=" * 56)
stop_server()
sys.exit(0 if fail_count == 0 else 1)
