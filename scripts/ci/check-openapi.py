#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Static integrity checks for the AMS OpenAPI 3.1 document.

Pure standard library only (no PyYAML). Run from any working directory:

    python scripts/ci/check-openapi.py

Checks performed:
  1. no UntypedObject placeholder remains
  2. every $ref target exists in components.schemas / components.responses
  3. counts of paths / operations / schemas are reported
  4. basic structure sanity: starts with openapi:, paths: and components:
     present, even (2-space) indentation, no tabs, consistent CRLF

Exit code 0 = PASS, 1 = FAIL.
All printed output is ASCII, so it is safe under a cp1252 Windows console.
The document is opened with encoding='utf-8' and newline='' so its CRLF
line endings are preserved on read.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DOC = os.path.join(ROOT, "docs", "14-对外API规范-OpenAPI.yaml")

# Character classes such as [$] are used instead of a backslash escape so the
# patterns stay robust regardless of how this file is transferred/encoded.
REF_SCHEMA = re.compile(r"""[$]ref: +['"]#/components/schemas/([A-Za-z0-9_]+)['"]""")
REF_RESPONSE = re.compile(r"""[$]ref: +['"]#/components/responses/([A-Za-z0-9_]+)['"]""")
RE_PATH = re.compile(r"^  /[^:]+: *$")
RE_OP = re.compile(r"^    (get|post|put|delete|patch|head|options|trace): *$")
RE_SCHEMA_DEF = re.compile(r"^    ([A-Za-z0-9_]+): *$")
RE_SUBKEY = re.compile(r"^  [A-Za-z0-9_-]+:")


def collect_child_keys(lines, header):
    """Return 4-space child keys below a 2-space section header."""
    start = None
    for i, line in enumerate(lines):
        if line == header:
            start = i + 1
            break
    names = []
    if start is None:
        return names
    for line in lines[start:]:
        if RE_SUBKEY.match(line):
            break
        m = RE_SCHEMA_DEF.match(line)
        if m:
            names.append(m.group(1))
    return names


def status(ok):
    return "OK" if ok else "FAIL"


def main():
    errors = []
    if not os.path.isfile(DOC):
        print("[FAIL] document not found")
        print("RESULT: FAIL")
        return 1

    with open(DOC, "r", encoding="utf-8", newline="") as fh:
        raw = fh.read()
    with open(DOC, "rb") as fh:
        blob = fh.read()
    lines = raw.splitlines()

    # (1) placeholder removal -------------------------------------------
    n_untyped = raw.count("UntypedObject")
    ok_no_placeholder = n_untyped == 0
    if not ok_no_placeholder:
        errors.append("UntypedObject residual: %d" % n_untyped)

    # (4) structure / indentation / line endings ------------------------
    first_code = ""
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            first_code = line
            break
    top_keys = [ln.split(":", 1)[0].strip() for ln in lines
                if ln and not ln[0].isspace() and ":" in ln]
    ok_structure = (first_code.startswith("openapi:")
                    and "paths" in top_keys
                    and "components" in top_keys)
    if not first_code.startswith("openapi:"):
        errors.append("document must start with openapi:")
    for key in ("paths", "components"):
        if key not in top_keys:
            errors.append("missing top-level key: %s" % key)

    tab_lines = 0
    odd_lines = 0
    for line in lines:
        prefix = line[:len(line) - len(line.lstrip(" \t"))]
        if "\t" in prefix:
            tab_lines += 1
        elif (len(line) - len(line.lstrip(" "))) % 2:
            odd_lines += 1
    if tab_lines:
        errors.append("tab indentation: %d lines" % tab_lines)
    if odd_lines:
        errors.append("odd indentation: %d lines" % odd_lines)

    lf = blob.count(b"\n")
    crlf = blob.count(b"\r\n")
    ok_eol = lf > 0 and lf == crlf
    if not ok_eol:
        errors.append("line endings not pure CRLF (LF=%d CRLF=%d)" % (lf, crlf))

    # (3) counts ---------------------------------------------------------
    n_paths = sum(1 for ln in lines if RE_PATH.match(ln))
    n_ops = sum(1 for ln in lines if RE_OP.match(ln))
    schemas = collect_child_keys(lines, "  schemas:")
    responses = collect_child_keys(lines, "  responses:")
    ok_counts = n_paths > 0 and n_ops > 0 and len(schemas) > 0
    if not ok_counts:
        errors.append("empty paths/operations/schemas")

    # (2) $ref resolution ------------------------------------------------
    schema_refs = REF_SCHEMA.findall(raw)
    response_refs = REF_RESPONSE.findall(raw)
    missing_schema = sorted(set(r for r in schema_refs if r not in schemas))
    missing_response = sorted(set(r for r in response_refs if r not in responses))
    ok_refs = not missing_schema and not missing_response
    for name in missing_schema:
        errors.append("unresolved schema $ref: %s" % name)
    for name in missing_response:
        errors.append("unresolved response $ref: %s" % name)

    # report (ASCII only) ------------------------------------------------
    print("[%s] no UntypedObject residual : %d" % (status(ok_no_placeholder), n_untyped))
    print("[%s] all $refs resolved        : %d schema refs / %d response refs"
          % (status(ok_refs), len(schema_refs), len(response_refs)))
    print("[%s] structure sanity          : openapi/paths/components, even indent, CRLF"
          % status(ok_structure and tab_lines == 0 and odd_lines == 0 and ok_eol))
    print("[INFO] paths      : %d" % n_paths)
    print("[INFO] operations : %d" % n_ops)
    print("[INFO] schemas    : %d" % len(schemas))
    print("[INFO] responses  : %d" % len(responses))
    print("[INFO] lines      : %d" % len(lines))
    for name in missing_schema:
        print("[FAIL] unresolved schema   : %s" % name)
    for name in missing_response:
        print("[FAIL] unresolved response : %s" % name)

    passed = not errors
    print("RESULT: %s" % ("PASS" if passed else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
