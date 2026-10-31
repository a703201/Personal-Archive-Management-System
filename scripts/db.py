#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS · 数据库辅助脚本

用途：本地开发时对 openGauss 执行 SQL（建表、导数据、查数据）。
依赖：容器内 gsql（openGauss 客户端），通过 docker exec 调用。

为什么用「写临时文件 + gsql -f」而不是 `gsql -c`：
    - `-c` 的 SQL 里若含引号/分号会被 shell 与 gsql 双重解析，极易出错
    - `-f` 走文件，语义与 psql 一致，行为可预测

用法：
    python scripts/db.py exec db/migrations/001_core_schema.sql       # 执行 SQL 文件
    python scripts/db.py exec -s "SELECT 1;"                           # 执行单条 SQL
    python scripts/db.py psql -s "SELECT * FROM sys_users;"            # 交互式终端
    python scripts/db.py tables                                       # 列出所有表
    python scripts/db.py count sys_users                               # 统计行数
    python scripts/db.py reset                                         # 删库重建（危险，需确认）
"""
import os
import subprocess
import sys

# ---- 连接配置（本地开发默认值，可用环境变量覆盖）----
CONTAINER = os.environ.get("AMS_DB_CONTAINER", "ams_opengauss")
DB = os.environ.get("AMS_DB_NAME", "ams")
USER = os.environ.get("AMS_DB_USER", "gaussdb")
PASSWORD = os.environ.get("AMS_DB_PASSWORD", "Ams@Gauss2026")
HOST_PORT = os.environ.get("AMS_DB_PORT", "15432")

GSQL = "/usr/local/opengauss/bin/gsql"


def _docker(sql_text, use_file=False):
    """在容器内执行 SQL，返回 (rc, 输出)。"""
    if use_file:
        cmd = (
            "cat > /tmp/_ams_sql.sql && "
            "export LD_LIBRARY_PATH=/usr/local/opengauss/lib:$LD_LIBRARY_PATH && "
            f"{GSQL} -d {DB} -U {USER} -W '{PASSWORD}' -f /tmp/_ams_sql.sql 2>&1; "
            'echo "__RC=$?"'
        )
    else:
        cmd = (
            "export LD_LIBRARY_PATH=/usr/local/opengauss/lib:$LD_LIBRARY_PATH && "
            f"{GSQL} -d {DB} -U {USER} -W '{PASSWORD}' -c \"$1\" 2>&1; "
            'echo "__RC=$?"'
        )
    args = ["docker", "exec", "-i", CONTAINER, "bash", "-c", cmd]
    if use_file:
        args.append("--")
    else:
        args += ["--", sql_text]
    p = subprocess.run(args, input=(sql_text if use_file else None),
                       capture_output=True, text=True, timeout=600)
    out = p.stdout + p.stderr
    rc = 0
    for line in out.splitlines():
        if line.startswith("__RC="):
            rc = int(line.split("=")[1])
    return rc, out.replace("__RC=", "")


def _split_statements(text):
    """
    按 ; 拆分为独立语句，但忽略出现在以下上下文中的 ;：
      - 美元引用串（$$...$$ 或 $tag$...$tag$，如 DO 块 / 函数体）
      - 单引号字符串字面量（'...'）
    这样 DO $$ BEGIN ... END $$; 这类语句不会被拆碎。
    """
    stmts = []
    buf = []
    in_dollar = False
    dollar_tag = ""
    in_quote = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_dollar:
            buf.append(ch)
            # 匹配闭标签：连续两个 $（裸 $$）或 $tag$
            if ch == "$" and nxt == "$":
                in_dollar = False
                buf.append(nxt)
                i += 2
                continue
            if ch == "$":
                # 尝试读 $tag$
                j = i + 1
                tag = "$"
                while j < n and text[j] != "$":
                    tag += text[j]
                    j += 1
                if j < n:
                    tag += "$"
                    if tag == dollar_tag:
                        in_dollar = False
                        buf.append(tag)
                        i = j + 1
                        continue
                # 不匹配，当普通字符
                buf.append(tag)
                i = j + 1
                continue
            i += 1
            continue
        if in_quote:
            buf.append(ch)
            if ch == "'":
                # '' 是转义引号，不退出
                if nxt == "'":
                    buf.append(nxt)
                    i += 2
                    continue
                in_quote = False
            i += 1
            continue
        # 普通状态
        if ch == ";":
            s = "".join(buf).strip()
            if s:
                stmts.append(s)
            buf = []
            i += 1
            continue
        if ch == "'":
            in_quote = True
            buf.append(ch)
            i += 1
            continue
        if ch == "$" and nxt == "$":
            in_dollar = True
            dollar_tag = "$$"
            buf.append(ch)
            buf.append(nxt)
            i += 2
            continue
        if ch == "$":
            # 可能的 $tag$
            j = i + 1
            tag = "$"
            while j < n and text[j] != "$":
                tag += text[j]
                j += 1
            if j < n and 1 < len(tag) < 64:  # 合法美元标签：至少 $x$
                tag += "$"
                in_dollar = True
                dollar_tag = tag
                buf.append(tag)
                i = j + 1
                continue
            buf.append(ch)
            i += 1
            continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def exec_file(path):
    """执行 SQL 文件（按 ; 拆分为独立语句，便于定位失败；尊重美元引用串）。"""
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    # 去掉整行注释
    lines = [l for l in raw.split("\n") if not l.strip().startswith("--")]
    stmts = [s for s in _split_statements("\n".join(lines)) if s.strip()]
    ok = 0
    fails = []
    for s in stmts:
        rc, out = _docker(s + ";", use_file=True)
        if "ERROR" in out:
            fails.append((s.split("\n")[0][:70], out.strip()[:300]))
        else:
            ok += 1
    print(f"执行完成：成功 {ok} / 失败 {len(fails)}（共 {len(stmts)} 条）")
    for head, err in fails:
        print(f"  [NG] {head}")
        print(f"       {err}")
    return 0 if not fails else 1


def exec_sql(sql):
    rc, out = _docker(sql, use_file=True)
    print(out.rstrip())
    return rc


def psql():
    """打开交互式 SQL 终端。"""
    cmd = (
        "export LD_LIBRARY_PATH=/usr/local/opengauss/lib:$LD_LIBRARY_PATH && "
        f"{GSQL} -d {DB} -U {USER} -W '{PASSWORD}'"
    )
    subprocess.run(["docker", "exec", "-it", CONTAINER, "bash", "-c", cmd])


def tables():
    return exec_sql(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='public' ORDER BY table_name;")


def count(table):
    return exec_sql(f"SELECT count(*) AS n FROM {table};")


def reset():
    """删库重建 —— 危险操作，必须显式确认。"""
    print("这将删除数据库并重建：")
    print(f"  容器 {CONTAINER} / 库 {DB}")
    ans = input("确认请输入 RESET：").strip()
    if ans != "RESET":
        print("已取消")
        return 1
    # 断开连接后删库
    _docker(
        f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        f"WHERE datname='{DB}' AND pid<>pg_backend_pid();", use_file=True)
    _docker(f"DROP DATABASE IF EXISTS {DB};", use_file=True)
    _docker(f"CREATE DATABASE {DB};", use_file=True)
    print(f"数据库 {DB} 已重建")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    args = sys.argv[2:]

    if cmd == "exec":
        if not args:
            print("用法: db.py exec <sql 文件>")
            return 1
        return exec_file(args[0])
    if cmd == "sql":
        if not args:
            print("用法: db.py sql -s \"<SQL>\"")
            return 1
        return exec_sql(args[-1])
    if cmd == "psql":
        return psql()
    if cmd == "tables":
        return tables()
    if cmd == "count":
        if not args:
            print("用法: db.py count <表名>")
            return 1
        return count(args[0])
    if cmd == "reset":
        return reset()
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
