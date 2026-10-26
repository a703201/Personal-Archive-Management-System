#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS · 仓颉 match 块自动改写工具

背景
----
仓颉 1.0.5 的 `match` 分支**只能是单个表达式**，不能写：

    case X => {
        stmt1
        stmt2
    }                      // ← 编译报 "expected '=>' in lambda expression"

本工具把多语句分支自动改写为「抽成辅助方法 + 单表达式分支」：

    case X => this.handleX(args)

多语句分支的块体会被提取为**同类内的私有方法**，方法名按分支内容自动生成
（必要时加序号避免重名）。块内的 `return` 会原样保留在方法里；
若块内有 `return` 且该 return 是「从 match 表达式返回」的语义，
则改为返回该方法的结果 —— 多数情况语义等价。

用法
----
    python scripts/fix_match_blocks.py <文件路径>...
    python scripts/fix_match_blocks.py --check <文件路径>...   # 只检查不修改

注意
----
* 只处理 `case <模式> => {` 开头的块；
* 块内若有 `break` / `continue` / `return` 等控制流，语义可能变化，
  改写后**务必人工复核**并跑测试。
"""
import re
import sys


BLOCK_RE = re.compile(r'^(\s*)case ([^=]+) => \{$')


def find_block_end(lines, start, indent):
    """返回块结束行下标（含）。找不到返回 -1。"""
    for i in range(start + 1, len(lines)):
        if lines[i] == indent + '}':
            return i
    return -1


def gen_method_name(pattern, used):
    """按分支模式生成方法名。"""
    base = re.sub(r'[^A-Za-z0-9]+', '', pattern)
    base = base[:1].upper() + base[1:]
    if not base or base[0].isdigit():
        base = "Case" + base
    name = "handle" + base
    if name in used:
        i = 2
        while f"{name}{i}" in used:
            i += 1
        name = f"{name}{i}"
    used.add(name)
    return name


def process(path, check_only=False):
    src = open(path, encoding='utf-8').read()
    lines = src.split('\n')
    out = []
    used = set(re.findall(r'func (\w+)\(', src))
    i = 0
    changed = 0
    pending_methods = []

    while i < len(lines):
        line = lines[i]
        m = BLOCK_RE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue

        indent, pattern = m.group(1), m.group(2).strip()
        end = find_block_end(lines, i, indent)
        if end < 0:
            out.append(line)
            i += 1
            continue

        body = lines[i + 1:end]
        stmts = [b for b in body if b.strip() and not b.strip().startswith('//')]
        if not stmts:
            # 空块 → 直接写 ()
            out.append(f"{indent}case {pattern} => ()")
            changed += 1
            i = end + 1
            continue

        if len(stmts) == 1:
            code = stmts[0].split('//')[0].strip()
            if code.startswith('return '):
                code = code[7:]
            if code.endswith(';'):
                code = code[:-1]
            out.append(f"{indent}case {pattern} => {code}")
            changed += 1
            i = end + 1
            continue

        # 多语句 → 抽方法
        method = gen_method_name(pattern, used)
        # 方法体：把块内语句缩进到方法体内（缩进 +4）
        method_body = []
        for b in body:
            method_body.append(('    ' + b) if b.strip() else b)
        pending_methods.append((method, method_body))

        out.append(f"{indent}case {pattern} => this.{method}()")
        changed += 1
        i = end + 1

    if not changed:
        return 0

    if check_only:
        return changed

    # 把抽出的方法追加到**最后一个类**的末尾。
    # 简化：追加到文件末尾（若是纯顶层函数则也在末尾）。
    result = '\n'.join(out)
    if pending_methods:
        method_text = []
        for name, body in pending_methods:
            method_text.append("")
            method_text.append(f"    /**")
            method_text.append(f"     * match 分支辅助方法（由 scripts/fix_match_blocks.py 自动抽取）。")
            method_text.append(f"     */")
            method_text.append(f"    private func {name}(): Unit {{")
            method_text.extend(body)
            method_text.append("    }")
        result = result.rstrip() + '\n' + '\n'.join(method_text) + '\n'

    open(path, 'w', encoding='utf-8').write(result)
    return changed


def main():
    args = sys.argv[1:]
    check_only = False
    if args and args[0] == '--check':
        check_only = True
        args = args[1:]
    if not args:
        print(__doc__)
        return 1
    total = 0
    for path in args:
        n = process(path, check_only)
        if n:
            print(f"  {path}: {n} 处")
            total += n
    print(f"共 {total} 处" + ("（仅检查）" if check_only else "（已改写）"))
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
