#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
把仓储层「每次查询新开连接且从不关闭」的写法改成 try/finally 自动归还。

背景：openGauss 的 max_connections=200，而 ams-data 的每个查询方法都
`let c = db.connect()` 后从不 close() → 约 40 次 HTTP 请求（overview 一次要 13 条连接）
就把连接池耗尽，之后全站 500：
    SqlException: Too many clients already, current: 203, max_connections: 200

变换规则（仅针对「try { 之后紧跟 let c = xxx.connect()」的方法体）：

    try {                              let c = this.db.connect()
        let c = this.db.connect()      try {
        ...                     →          ...
    } catch (e: Exception) {           } catch (e: Exception) {
        throw toDbError(e)                 throw toDbError(e)
    }                                  } finally {
                                           c.close()
                                       }

用法：
    python scripts/fix_conn_leak.py --dry-run packages/ams-data/src/repo/item.cj
    python scripts/fix_conn_leak.py packages/ams-data/src/repo/*.cj
"""
import re
import sys

CONNECT_RE = re.compile(r"^\s*let c = .*\.connect\(\)\s*$")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def transform(path: str, dry: bool) -> int:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    out = []
    i = 0
    changed = 0
    n = len(lines)

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # 命中：try { 紧跟 let c = ...connect()
        if stripped == "try {" and i + 1 < n and CONNECT_RE.match(lines[i + 1]):
            ind = indent_of(line)
            next_ind = indent_of(lines[i + 1])
            # 只处理「连接变量在 try 内部声明」且缩进更深的情形
            if next_ind > ind:
                connect_line = lines[i + 1]
                # 1) 把 connect 提到 try 之前
                out.append(" " * ind + connect_line.strip())
                out.append(line)
                i += 2

                # 2) 找到该 try 对应的 catch 块结束位置
                #    形如：
                #    <ind>} catch (e: Exception) {
                #    ...
                #    <ind>}
                catch_end = -1
                j = i
                while j < n:
                    if (
                        lines[j].strip() == "} catch (e: Exception) {"
                        and indent_of(lines[j]) == ind
                    ):
                        k = j + 1
                        while k < n:
                            if lines[k].strip() == "}" and indent_of(lines[k]) == ind:
                                catch_end = k
                                break
                            k += 1
                        break
                    j += 1

                if catch_end < 0:
                    # 结构不符合预期 → 回退，原样输出
                    out.pop()
                    out.pop()
                    out.append(line)
                    i -= 1  # 重新处理当前行
                    # 为避免死循环，直接原样刷出下一行
                    out.append(lines[i + 1])
                    i += 2
                    continue

                # 输出 try 体（i .. j-1）与 catch 体（j .. catch_end-1）
                out.extend(lines[i:catch_end])
                # 把 catch 的收尾 } 改成 } finally { ... }
                out.append(" " * ind + "} finally {")
                out.append(" " * (ind + 4) + "c.close()")
                out.append(" " * ind + "}")
                i = catch_end + 1
                changed += 1
                continue

        out.append(line)
        i += 1

    if changed and not dry:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(out))

    print(f"{path}: {changed} 处")
    return changed


def main() -> int:
    args = sys.argv[1:]
    dry = "--dry-run" in args
    files = [a for a in args if not a.startswith("--")]
    total = 0
    for p in files:
        total += transform(p, dry)
    print(f"合计 {total} 处" + ("（dry-run，未写盘）" if dry else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
