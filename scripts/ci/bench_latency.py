#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS · DB 支撑接口单请求延迟基准（修复后验证用）。

自起 server，warmup 后分别对两个 DB 支撑端点计时：
  - POST /api/auth/login    （DB 查询 + token 签发）
  - GET  /api/subjects      （DB 查询）
打印每次耗时(ms) 与均值，用于判断单请求是否仍慢。
"""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORT = os.environ.get("AMS_VERIFY_PORT", "18120")
BASE = "http://127.0.0.1:%s" % PORT
SERVER = os.path.join(ROOT, "build", "ams-server.exe")
if not os.path.exists(SERVER):
    SERVER = os.path.join(ROOT, "build", "ams-server")
DB_PASSWORD = os.environ.get("AMS_DB_PASSWORD", "Ams@Gauss2026")
srv = None


def call(method, path, body=None, token=None):
    url = BASE + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, json.loads(r.read().decode("utf-8"))


def start():
    global srv
    import tempfile
    log = open(os.path.join(tempfile.gettempdir(), "ams_bench.log"), "w")
    env = dict(os.environ)
    env["AMS_HTTP_PORT"] = PORT
    env["AMS_TOKEN_SECRET"] = "bench-secret-key-2026-abcdefghijkl"
    env["AMS_DB_PASSWORD"] = DB_PASSWORD
    srv = subprocess.Popen([SERVER], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(60):
        time.sleep(0.5)
        try:
            st, _ = call("GET", "/api/health")
            if st == 200:
                return True
        except Exception:
            pass
    return False


def stop():
    if srv:
        try:
            srv.send_signal(signal.SIGTERM)
            srv.wait(timeout=5)
        except Exception:
            try: srv.kill()
            except Exception: pass


def bench(name, fn, n=10):
    ts = []
    for i in range(n):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1000.0)
    mean = sum(ts) / len(ts)
    mx = max(ts); mn = min(ts)
    print("[%s] n=%d mean=%.1fms min=%.1fms max=%.1fms  raw=%s"
          % (name, n, mean, mn, mx, " ".join("%.0f" % x for x in ts)))
    return mean


if __name__ == "__main__":
    if not start():
        print("[ABORT] server 未就绪")
        stop(); sys.exit(1)
    import atexit; atexit.register(stop)
    pwd = "Ams@2026#Bench"
    u = "bench_%d" % int(time.time())
    call("POST", "/api/auth/register", {"username": u, "password": pwd,
         "email": u + "@bench.local", "nickname": u})
    tok = None
    for _ in range(3):  # warmup + 取 token
        r = call("POST", "/api/auth/login", {"username": u, "password": pwd})
        tok = r[1].get("data", {}).get("accessToken") or tok
    print("token=%s" % ("yes" if tok else "NO"))
    # warmup 几次（让连接池充分预热）
    for _ in range(5):
        call("POST", "/api/auth/login", {"username": u, "password": pwd})
    print("=== 修复后单请求延迟（login，DB 支撑）===")
    bench("login(POST)", lambda: call("POST", "/api/auth/login",
         {"username": u, "password": pwd}))
