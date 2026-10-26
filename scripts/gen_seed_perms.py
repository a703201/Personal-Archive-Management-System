#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS · 生成内置权限点与角色的种子 SQL

数据来源：packages/ams-security/src/authz/perm.cj 的 BuiltinPerms
（代码是唯一事实来源，SQL 由本脚本生成，避免两处维护不一致）

openGauss 5.0.0 兼容写法：
  - 不支持 ON CONFLICT → 用 INSERT ... SELECT ... WHERE NOT EXISTS
  - 不支持 BYTEA(n) → BYTEA

用法：python scripts/gen_seed_perms.py
"""
import re
import sys

PERM_SRC = 'packages/ams-security/src/authz/perm.cj'
OUT = 'db/migrations/003_seed_perms_roles.sql'

# id 段（本地开发用固定值；生产由雪花 ID 生成）
PERM_ID_BASE = 900000
ROLE_ID_BASE = 800000
MAP_ID_BASE = 700000

ROLE_META = {
    'Owner':     ('owner', '所有者', 3),
    'Curator':   ('curator', '代管人', 2),
    'Family':    ('family', '家庭成员', 2),
    'OrgAdmin':  ('org_admin', '机构管理员', 3),
    'Auditor':   ('auditor', '审计员', 1),
}


def main():
    src = open(PERM_SRC, encoding='utf-8').read()

    # ---- 解析权限点 ----
    block = src.split('public static func all()')[1].split('return perms.toArray()')[0]
    perms = []
    for m in re.finditer(
            r'Perm\("([^"]+)", "([^"]+)", "([^"]+)", "([^"]*)"(, isSensitive: true)?\)', block):
        perms.append({
            'code': m.group(1), 'domain': m.group(2), 'action': m.group(3),
            'scope': m.group(4), 'sens': 'TRUE' if m.group(5) else 'FALSE',
        })

    # ---- 解析各角色权限 ----
    roles = {}
    for m in re.finditer(r'case BuiltinRole\.(\w+) => return \[(.*?)\]', src, re.S):
        roles[m.group(1)] = re.findall(r'"([^"]+)"', m.group(2))

    perm_id = {}
    for i, p in enumerate(perms, start=1):
        perm_id[p['code']] = PERM_ID_BASE + i
    role_id = {}
    for i, (k, (code, _, _)) in enumerate(ROLE_META.items(), start=1):
        role_id[k] = ROLE_ID_BASE + i

    out = []
    out.append('-- ============================================================')
    out.append('-- AMS · 003_seed_perms_roles.sql')
    out.append('-- 初始化内置权限点与内置角色（FR-ACL-001 / FR-ACL-003）')
    out.append('--')
    out.append('-- 本文件由 scripts/gen_seed_perms.py 从')
    out.append('-- packages/ams-security/src/authz/perm.cj 的 BuiltinPerms 生成 ——')
    out.append('-- 代码是唯一事实来源，请勿手工编辑本文件。')
    out.append('--')
    out.append('-- openGauss 5.0.0 兼容：不支持 ON CONFLICT，故用')
    out.append('-- INSERT ... SELECT ... WHERE NOT EXISTS 实现幂等。')
    out.append('-- ============================================================')
    out.append('')
    out.append('-- 权限点')
    for p in perms:
        out.append(
            "INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) "
            f"SELECT {perm_id[p['code']]}, '{p['code']}', '{p['code']}', "
            f"'{p['domain']}', '{p['action']}', '{p['scope']}', {p['sens']}, '{p['code']}' "
            f"WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = '{p['code']}');")

    out.append('')
    out.append('-- 内置角色')
    for k, (code, name, level) in ROLE_META.items():
        out.append(
            "INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) "
            f"SELECT {role_id[k]}, '{code}', '{name}', TRUE, '内置角色，不可删除', {level} "
            f"WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = '{code}');")

    out.append('')
    out.append('-- 角色-权限映射')
    rid = 0
    for k in ROLE_META:
        for code in roles.get(k, []):
            if code not in perm_id:
                print(f"  [警告] 角色 {k} 引用了目录外的权限 {code}，已跳过")
                continue
            rid += 1
            out.append(
                "INSERT INTO sys_role_perms (id, role_id, perm_id) "
                f"SELECT {MAP_ID_BASE + rid}, {role_id[k]}, {perm_id[code]} "
                f"WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms "
                f"WHERE role_id = {role_id[k]} AND perm_id = {perm_id[code]});")

    open(OUT, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    print(f"已生成 {OUT}")
    print(f"  权限点 {len(perms)} 个，内置角色 {len(ROLE_META)} 个，映射 {rid} 条")
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
