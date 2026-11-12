#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AMS static consistency gate (no DB, no Cangjie SDK required).

Runs on every CI job before the expensive build. It is deliberately
dependency-free (stdlib only) and prints ASCII only, because the Windows
runner uses cp1252 as its default locale.

Checks:
  1. migration numbering (007 duplicate is a known historical exception)
  2. HTTP route path prefix
  3. layer direction: ams.app must not import ams.api, core stays pure
  4. ams.api -> ams.data.repo direct imports must not grow past baseline
  5. i18n catalogs: no `${...}` / backtick dead entries
  6. OpenAPI: delegate to scripts/ci/check-openapi.py
  7. version consistency: web/package.json vs server boot log
  8. compose credentials: three mandatory `:?` variables
  9. workflow YAML parses (when PyYAML is available)
  10. every HTTP route declared in code is documented in the OpenAPI spec

Exit 0 = PASS, 1 = FAIL.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAILURES = []
KNOWN_DUP_MIGRATIONS = {"007"}
# ams.api -> ams.data.repo 的静态 import 计数上限（防分层被侵蚀）。
# 2026-11-12 由 24 上调至 26：本批新增两个同向合法依赖 ——
#   ams-api/src/middleware/tenantquota.cj（配额闸门）
#   ams-api/src/routes/tenantregistry.cj（租户注册/引导）
# 二者都是 ams.api -> ams.data.repo 的正常向下依赖，未引入反向或跨层引用。
API_REPO_BASELINE = 26


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def ok(msg):
    print("[OK]   " + msg)


def fail(msg):
    print("[FAIL] " + msg)
    FAILURES.append(msg)


def check_migrations():
    files = sorted((ROOT / "db" / "migrations").glob("*.sql"))
    nums = {}
    for f in files:
        m = re.match(r"^(\d{3})_", f.name)
        if not m:
            fail("migration filename without 3-digit prefix: " + f.name)
            continue
        nums.setdefault(m.group(1), []).append(f.name)
    dups = {k: v for k, v in nums.items() if len(v) > 1}
    unknown = set(dups) - KNOWN_DUP_MIGRATIONS
    if unknown:
        fail("new duplicate migration numbers: " + ", ".join(sorted(unknown)))
    else:
        ok("migration numbering: %d files, known duplicate(s)=%s" %
           (len(files), ",".join(sorted(dups)) or "none"))


def check_routes():
    files = sorted((ROOT / "packages" / "ams-api" / "src" / "routes").glob("*.cj"))
    pattern = re.compile(r'router\.(?:get|post|put|delete)\(\s*"([^"]+)"')
    paths = []
    for f in files:
        paths += pattern.findall(f.read_text(encoding="utf-8"))
    bad = [p for p in paths if not p.startswith("/api/")]
    if bad:
        fail("routes not under /api/: " + ", ".join(bad[:5]))
    elif not paths:
        fail("no routes found")
    else:
        ok("route prefix: %d declarations in %d files" % (len(paths), len(files)))


def _norm_route(path):
    """Normalise a route so ':id' (code) and '{id}' (OpenAPI) compare equal."""
    return re.sub(r":([A-Za-z_]\w*)", "{}",
                  re.sub(r"\{[^}]+\}", "{}", path))


def check_route_doc_coverage():
    """Every (method, path) declared in code must be in the OpenAPI spec."""
    spec = sorted((ROOT / "docs").glob("14-*.yaml"))
    if not spec:
        fail("OpenAPI spec (docs/14-*.yaml) not found")
        return
    doc_text = spec[0].read_text(encoding="utf-8")
    documented = set()
    current = None
    for line in doc_text.splitlines():
        pm = re.match(r"^  (/api/[^:]+):", line)
        if pm:
            current = _norm_route(pm.group(1))
            continue
        om = re.match(r"^    (get|post|put|delete|patch|head):", line)
        if om and current:
            documented.add((om.group(1), current))
    code = set()
    for f in sorted((ROOT / "packages" / "ams-api" / "src" / "routes").glob("*.cj")):
        for m in re.finditer(r'router\.(get|post|put|delete)\(\s*"([^"]+)"',
                             f.read_text(encoding="utf-8")):
            code.add((m.group(1), _norm_route(m.group(2))))
    missing = sorted(code - documented)
    if missing:
        fail("OpenAPI missing %d operation(s): %s" %
             (len(missing), ", ".join("%s %s" % x for x in missing[:6])))
    else:
        ok("OpenAPI operation coverage: %d/%d code operations documented" %
           (len(code), len(code)))


def imports_in(subdir):
    text = ""
    for f in (ROOT / "packages" / subdir).rglob("*.cj"):
        text += f.read_text(encoding="utf-8") + "\n"
    return text


def check_layers():
    app_src = imports_in("ams-app/src")
    core_src = imports_in("ams-core/src")
    api_src = imports_in("ams-api/src")
    if re.search(r"^import\s+ams\.api", app_src, re.M):
        fail("ams.app imports ams.api (layer violation)")
    else:
        ok("layer direction: ams.app does not import ams.api")
    if re.search(r"^import\s+ams\.(?:data|api|app)", core_src, re.M):
        fail("ams.core imports an upper layer")
    else:
        ok("layer direction: ams.core stays pure")
    n = len(re.findall(r"^import\s+ams\.data\.repo", api_src, re.M))
    if n > API_REPO_BASELINE:
        fail("ams.api -> ams.data.repo imports grew: %d > baseline %d" %
             (n, API_REPO_BASELINE))
    else:
        ok("cross-layer baseline: %d/%d ams.api -> ams.data.repo imports" %
           (n, API_REPO_BASELINE))


def check_i18n():
    names = ["catalog.zh-CN.ts", "catalog.en.ts", "catalog.fr.ts"]
    total = 0
    bad = 0
    for name in names:
        text = read("web/src/i18n/" + name)
        dead = text.count("${") + text.count("`")
        if dead:
            fail("%s has %d dead-entry markers" % (name, dead))
            bad += 1
        keys = set(re.findall(r"^\s*'([^']+)'\s*:", text, re.M))
        total += len(keys)
    if not bad:
        ok("i18n catalogs: no template/backtick dead entries (%d keys)" % total)


def check_openapi():
    script = ROOT / "scripts" / "ci" / "check-openapi.py"
    if not script.exists():
        fail("missing scripts/ci/check-openapi.py")
        return
    p = subprocess.run([sys.executable, str(script)], cwd=str(ROOT),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        fail("check-openapi.py failed: " +
             p.stdout.decode("utf-8", "replace").strip().splitlines()[-1])
    else:
        ok("OpenAPI schema gate passed")


def check_versions():
    pkg = json.loads(read("web/package.json"))
    web_ver = pkg.get("version", "")
    main = read("packages/ams-server/src/main.cj")
    m = re.search(r'\("version",\s*"([0-9]+\.[0-9]+\.[0-9]+)"\)', main)
    boot_ver = m.group(1) if m else ""
    if not web_ver or not boot_ver or web_ver != boot_ver:
        fail("version mismatch: web=%s server.boot=%s" % (web_ver, boot_ver))
    else:
        ok("version consistency: %s" % web_ver)


def check_compose():
    text = read("deploy/compose/docker-compose.yml")
    required = ["AMS_DB_PASSWORD:?", "AMS_TOKEN_SECRET:?", "AMS_KEK:?"]
    missing = [k for k in required if k not in text]
    if missing:
        fail("compose credentials not mandatory: " + ", ".join(missing))
    elif ":-Ams@Gauss2026" in text or ":-change-me-in-production" in text:
        fail("compose still contains dev credential defaults")
    else:
        ok("compose credentials: 3 mandatory variables, no dev defaults")


def check_workflows():
    try:
        import yaml
    except ImportError:
        print("[SKIP] PyYAML unavailable, workflow YAML parse skipped")
        return
    files = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    bad = 0
    for f in files:
        try:
            data = yaml.safe_load(f.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or "jobs" not in data:
                fail("workflow not a valid mapping with jobs: " + f.name)
                bad += 1
        except Exception as e:
            fail("workflow YAML parse error in %s: %s" % (f.name, type(e).__name__))
            bad += 1
    if not bad:
        ok("workflow YAML: %d files parsed" % len(files))


def main():
    check_migrations()
    check_routes()
    check_layers()
    check_i18n()
    check_openapi()
    check_route_doc_coverage()
    check_versions()
    check_compose()
    check_workflows()
    print("")
    if FAILURES:
        print("RESULT: FAIL (%d)" % len(FAILURES))
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
