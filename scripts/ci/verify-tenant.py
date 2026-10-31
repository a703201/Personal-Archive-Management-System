#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS · 多租户隔离（方案 A）端到端回归。

用法：
    python scripts/ci/verify-tenant.py
    AMS_VERIFY_PORT=18106 python scripts/ci/verify-tenant.py

脚本自己负责启停服务：从仓库根目录起 `build/ams-server(.exe)`，
退出时按 PID 精确清理（不用 pkill）。

覆盖（固化「跨租户查询必须返回空 / 越权必须拒绝」）：
  一、curator（纯 own 角色 800002）跨租户隔离
      - 列表：租户1 用户看不到租户2 的主体与条目
      - 详情：租户1 用户按 ID 读租户2 条目 → 403/404
      - 双向：反过来同样隔离
  二、正向对照：每用户能看到自己的主体与条目详情
  三、创建隔离：租户1 用户不能在租户2 主体下创建条目 → 403
  四、克隆隔离：租户1 用户不能克隆租户2 条目 → 非 200
  五、owner（archive:read:any 角色 800001）详情跨租户探针
      - 【回归目标】owner 也不得跨租户读详情 → 403/404
      - 同租户内 owner 仍可读任意条目（any 语义保留）

数据策略：租户2 幂等创建（UPSERT），用户用随机后缀避免重复；
其余数据（主体/条目）落在测试库，不清理（测试库，可忽略）。
"""
import json
import os
import random
import signal
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORT = os.environ.get("AMS_VERIFY_PORT", "18105")
BASE = "http://127.0.0.1:%s" % PORT
SERVER = os.path.join(ROOT, "build", "ams-server.exe")
if not os.path.exists(SERVER):
    SERVER = os.path.join(ROOT, "build", "ams-server")

ok_count = 0
fail_count = 0
srv = None
LOG_PATH = ""

# 容器对外的真实口令（与 verify-family.py 一致；docker exec 本地走 trust 忽略口令）
DB_PASSWORD = os.environ.get("AMS_DB_PASSWORD", "Ams@Gauss2026")


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
    env = dict(os.environ)
    env["AMS_DB_PASSWORD"] = DB_PASSWORD
    subprocess.run([sys.executable, "scripts/db.py", "sql", "-s", sql],
                   cwd=ROOT, capture_output=True, text=True, env=env)


def rand(n=6):
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def start_server():
    global srv, LOG_PATH
    import tempfile
    log_path = os.path.join(tempfile.gettempdir(), "ams_verify_tenant.log")
    LOG_PATH = log_path
    log = open(log_path, "w")
    env = dict(os.environ)
    env["AMS_HTTP_PORT"] = PORT
    env["AMS_TOKEN_SECRET"] = "verify-tenant-secret-key-2026-abcdefghijkl"
    env["AMS_DB_PASSWORD"] = DB_PASSWORD
    srv = subprocess.Popen([SERVER], cwd=ROOT, env=env,
                           stdout=log, stderr=subprocess.STDOUT)
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
print("=== AMS E2E · 多租户隔离回归（端口 %s）===" % PORT)

if not os.path.exists(SERVER):
    print("[ABORT] 找不到 %s，请先 bash scripts/build.sh" % SERVER)
    sys.exit(1)
if not start_server():
    print("[ABORT] 服务未能在 30s 内就绪，日志见 %s" % LOG_PATH)
    stop_server()
    sys.exit(1)
import atexit
atexit.register(stop_server)

# ---------------------------------------------------------------
# 0. 准备租户2（幂等）
# ---------------------------------------------------------------
print()
print("[0] 准备租户")
db_exec(
    "INSERT INTO sys_tenants (id, code, name, status) "
    "SELECT 2,'tenant2','Tenant 2','active' WHERE NOT EXISTS "
    "(SELECT 1 FROM sys_tenants WHERE id = 2)"
)

# ---------------------------------------------------------------
# 1. 注册并授权两个 curator（纯 own），分属租户1 / 租户2
# ---------------------------------------------------------------
print()
print("[1] 注册并分派 curator（租户1 / 租户2）")
pwd = "Ams@2026#E2E"

u1 = "tenant1_" + suffix
u2 = "tenant2_" + suffix
r = call("POST", "/api/auth/register",
         {"username": u1, "password": pwd, "email": "%s@e2e.local" % u1, "nickname": u1})
check("注册 租户1 用户", r[0] == 200, str(r[2])[:200])
id1 = data_of(r).get("id") if data_of(r) else None
r = call("POST", "/api/auth/register",
         {"username": u2, "password": pwd, "email": "%s@e2e.local" % u2, "nickname": u2})
check("注册 租户2 用户", r[0] == 200, str(r[2])[:200])
id2 = data_of(r).get("id") if data_of(r) else None
if not id1 or not id2:
    print("[ABORT] 注册失败")
    sys.exit(1)

# 租户2 用户改到租户2
db_exec("UPDATE sys_users SET tenant_id = 2 WHERE id = %d" % int(id2))

# 两个 curator（800002 = 纯 own，无 archive:read:any 绕过）
rid1 = int(time.time() * 1000) % 1000000000 + 800000000
rid2 = rid1 + 1
db_exec(
    "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, granted_by, "
    "granted_at, expires_at, category) VALUES (%d, %d, 800002, NULL, NULL, "
    "CURRENT_TIMESTAMP, NULL, 0)" % (rid1, int(id1))
)
db_exec(
    "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, granted_by, "
    "granted_at, expires_at, category) VALUES (%d, %d, 800002, NULL, NULL, "
    "CURRENT_TIMESTAMP, NULL, 0)" % (rid2, int(id2))
)

tok1 = data_of(call("POST", "/api/auth/login", {"username": u1, "password": pwd})).get("accessToken")
tok2 = data_of(call("POST", "/api/auth/login", {"username": u2, "password": pwd})).get("accessToken")
check("登录 租户1 curator", bool(tok1), "no token")
check("登录 租户2 curator", bool(tok2), "no token")

# 各自默认主体 + 一条条目
r = call("GET", "/api/subjects", token=tok1)
s1 = (data_of(r) or {}).get("subjects", [])
check("租户1 有默认主体", len(s1) >= 1, str(s1)[:200])
sid1 = s1[0]["id"] if s1 else None
r = call("GET", "/api/subjects", token=tok2)
s2 = (data_of(r) or {}).get("subjects", [])
check("租户2 有默认主体", len(s2) >= 1, str(s2)[:200])
sid2 = s2[0]["id"] if s2 else None

r = call("POST", "/api/items", {"subjectId": sid1, "category": 2, "title": "T1证件%s" % suffix,
                                "sensitivity": 1, "issuer": "T1机关"}, token=tok1)
iid1 = None
if r[0] == 200 and isinstance(r[2], dict):
    iid1 = (data_of(r) or {}).get("id")
if not iid1:
    rr = call("GET", "/api/items?size=100", token=tok1)
    for it in (data_of(rr) or {}).get("items", []):
        if it.get("title") == "T1证件%s" % suffix:
            iid1 = it["id"]
            break
check("租户1 建条目", bool(iid1), "iid1=%r" % iid1)

r = call("POST", "/api/items", {"subjectId": sid2, "category": 2, "title": "T2证件%s" % suffix,
                                "sensitivity": 1, "issuer": "T2机关"}, token=tok2)
iid2 = None
if r[0] == 200 and isinstance(r[2], dict):
    iid2 = (data_of(r) or {}).get("id")
if not iid2:
    rr = call("GET", "/api/items?size=100", token=tok2)
    for it in (data_of(rr) or {}).get("items", []):
        if it.get("title") == "T2证件%s" % suffix:
            iid2 = it["id"]
            break
check("租户2 建条目", bool(iid2), "iid2=%r" % iid2)

# ---------------------------------------------------------------
# 一、curator 跨租户隔离（双向）
# ---------------------------------------------------------------
print()
print("[一] curator 跨租户隔离（双向）")

# 列表：租户1 看不到租户2 的主体
subs1 = [(data_of(call("GET", "/api/subjects", token=tok1)) or {}).get("subjects", [])]
subs1_ids = [s["id"] for s in subs1[0]] if subs1 else []
check("租户1 主体列表不含租户2 主体", sid2 not in subs1_ids, "subs1=%s sid2=%s" % (subs1_ids, sid2))

# 列表：租户1 看不到租户2 的条目
items1 = [(data_of(call("GET", "/api/items?size=100", token=tok1)) or {}).get("items", [])]
items1_ids = [x["id"] for x in items1[0]] if items1 else []
check("租户1 条目列表不含租户2 条目", iid2 not in items1_ids, "iid2=%s in %s" % (iid2, items1_ids))

# 详情：租户1 按 ID 读租户2 条目 → 必须拒绝
st, _, _ = call("GET", "/api/items/%s" % iid2, token=tok1)
check("租户1 读租户2 条目详情 → 403/404", st in (403, 404), "got %s" % st)

# 反向
subs2_ids = [(data_of(call("GET", "/api/subjects", token=tok2)) or {}).get("subjects", [])]
subs2_ids = [s["id"] for s in subs2_ids[0]] if subs2_ids else []
check("租户2 主体列表不含租户1 主体", sid1 not in subs2_ids, "sid1=%s in %s" % (sid1, subs2_ids))
items2_ids = [(data_of(call("GET", "/api/items?size=100", token=tok2)) or {}).get("items", [])]
items2_ids = [x["id"] for x in items2_ids[0]] if items2_ids else []
check("租户2 条目列表不含租户1 条目", iid1 not in items2_ids, "iid1=%s in %s" % (iid1, items2_ids))
st, _, _ = call("GET", "/api/items/%s" % iid1, token=tok2)
check("租户2 读租户1 条目详情 → 403/404", st in (403, 404), "got %s" % st)

# ---------------------------------------------------------------
# 二、正向对照
# ---------------------------------------------------------------
print()
print("[二] 正向对照（各用户可见自己）")
st, _, b1 = call("GET", "/api/items/%s" % iid1, token=tok1)
check("租户1 读自己条目 → 200", st == 200, "got %s" % st)
st, _, b2 = call("GET", "/api/items/%s" % iid2, token=tok2)
check("租户2 读自己条目 → 200", st == 200, "got %s" % st)

# ---------------------------------------------------------------
# 三、创建隔离
# ---------------------------------------------------------------
print()
print("[三] 创建隔离")
r = call("POST", "/api/items", {"subjectId": sid2, "category": 2, "title": "越权创建%s" % suffix,
                                "sensitivity": 1, "issuer": "x"}, token=tok1)
check("租户1 在租户2 主体下创建 → 403", r[0] == 403, "got %s" % r[0])

# ---------------------------------------------------------------
# 四、克隆隔离
# ---------------------------------------------------------------
print()
print("[四] 克隆隔离")
r = call("POST", "/api/items/%s/clone" % iid2, token=tok1)
check("租户1 克隆租户2 条目 → 非 200", r[0] != 200, "got %s" % r[0])

# ---------------------------------------------------------------
# 五、owner（archive:read:any）详情跨租户探针 —— 回归目标
# ---------------------------------------------------------------
print()
print("[五] owner 跨租户详情探针（回归目标）")
uo = "t1owner_" + suffix
r = call("POST", "/api/auth/register",
         {"username": uo, "password": pwd, "email": "%s@e2e.local" % uo, "nickname": uo})
ido = data_of(r).get("id") if data_of(r) else None
check("注册 owner 用户", r[0] == 200, str(r[2])[:200])
rido = rid2 + 1
# owner = 800001，持有 archive:read:any（路径0 绕过归属校验）
db_exec(
    "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, granted_by, "
    "granted_at, expires_at, category) VALUES (%d, %d, 800001, NULL, NULL, "
    "CURRENT_TIMESTAMP, NULL, 0)" % (rido, int(ido))
)
toko = data_of(call("POST", "/api/auth/login", {"username": uo, "password": pwd})).get("accessToken")
check("登录 owner", bool(toko), "no token")

# 【核心回归】owner 也不得跨租户读详情
st, _, _ = call("GET", "/api/items/%s" % iid2, token=toko)
check("owner 读租户2 条目详情 → 403/404（跨租户拒绝）", st in (403, 404), "got %s" % st)

# 同租户内 owner 仍可读任意条目（any 语义保留）
st, _, _ = call("GET", "/api/items/%s" % iid1, token=toko)
check("owner 读同租户条目 → 200（any 语义保留）", st == 200, "got %s" % st)

# 列表同样隔离（列表走 subjectIds 范围，any 不绕过行级过滤）
items_o = [(data_of(call("GET", "/api/items?size=100", token=toko)) or {}).get("items", [])]
items_o_ids = [x["id"] for x in items_o[0]] if items_o else []
check("owner 条目列表也不含租户2 条目", iid2 not in items_o_ids, "iid2=%s in %s" % (iid2, items_o_ids))

# ---------------------------------------------------------------
print()
print("=" * 56)
print(" 通过 %d 项，失败 %d 项" % (ok_count, fail_count))
print("=" * 56)
stop_server()
sys.exit(0 if fail_count == 0 else 1)
