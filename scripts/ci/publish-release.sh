#!/usr/bin/env bash
# ============================================================
# AMS · 创建 / 复用 GitHub Release（notes 取自 CHANGELOG）
#
# 设计要点：
#   - 所有内嵌 python 一律用「heredoc + 单引号定界符 + 变量走 argv」，
#     杜绝 YAML run: 块里嵌套双引号 / $(...) 导致的语法炸裂。
#   - Release body 先写成 JSON 文件再用 --data-binary @file 发送，
#     避免 -d 内联 json.dumps 的引号地狱。
#
# 输入（环境变量）：
#   GH_TOKEN            GitHub token（需 contents:write）
#   VERSION             版本号，如 1.2.0（不含 v）
#   GITHUB_REPOSITORY   owner/repo
# 输出：REL_ID 写入 $GITHUB_OUTPUT（id=...），并 echo 出来供后续步骤读取。
# ============================================================
set -euo pipefail

# Windows runner 的 Python 默认 locale 编码是 cp1252：CHANGELOG 含中文时，
# 任何经 stdout 重定向输出的中文都会 UnicodeEncodeError
# （'charmap' codec can't encode characters ...）。强制所有 python I/O 用 UTF-8。
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || { echo "::error:: 未找到 python3/python"; exit 1; }

VER="${VERSION:?VERSION 未设置}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"
TAG="v${VER}"
ZIP="dist/ams-release-${VER}-windows-x86_64.zip"
API="https://api.github.com/repos/${REPO}"
NOTES="$(mktemp)"

# ① 取 CHANGELOG.md 对应版本段落作为 Release 说明
echo "提取 CHANGELOG [${VER}] 段落作为 Release 说明 ..."
"$PY" - "$VER" "$NOTES" <<'PY'
import re, sys
v, out = sys.argv[1], sys.argv[2]
text = open('CHANGELOG.md', encoding='utf-8').read()
m = re.search(r'^##\s+\[?v?' + re.escape(v) + r'\]?.*?(?=^##\s|\Z)', text, re.M | re.S)
with open(out, 'w', encoding='utf-8') as f:
    f.write((m.group(0).strip() if m else 'AMS ' + v) + '\n')
PY

if [ ! -s "$NOTES" ]; then
  echo "AMS ${VER}" > "$NOTES"
fi

# ② 查询是否已存在该 tag 的 Release（404 属正常，返回空 id）
echo "查询 Release ${TAG} ..."
REL_ID="$(curl --ssl-no-revoke -sS -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/releases/tags/${TAG}" \
  | "$PY" -c "import sys,json; print(json.loads(sys.stdin.buffer.read().decode('utf-8')).get('id',''))")"

if [ -z "$REL_ID" ]; then
  echo "创建 Release ${TAG} ..."
  # ③ 先写 body 到 JSON 文件，避免 -d 内联嵌套引号。
  # ⚠️ 必须由 python 直接以 UTF-8 写文件，不能 print 到 stdout 重定向：
  #    Windows runner 的 Python stdout 编码是 cp1252，中文会 UnicodeEncodeError。
  BODY="$(mktemp)"
  "$PY" - "$TAG" "$VER" "$NOTES" "$BODY" <<'PY'
import json, sys
tag, ver, notes, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(notes, encoding='utf-8') as f:
    body = f.read()
data = json.dumps({
    "tag_name": tag,
    "name": "AMS " + ver,
    "body": body,
    "draft": False,
    "prerelease": False,
}, ensure_ascii=False)
with open(out, 'wb') as f:
    f.write(data.encode('utf-8'))
PY
  REL_ID="$(curl --ssl-no-revoke -fsS -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data-binary "@${BODY}" \
    "${API}/releases" \
    | "$PY" -c "import sys,json; print(json.loads(sys.stdin.buffer.read().decode('utf-8')).get('id',''))")"
  echo "      已创建（id=${REL_ID}）"
else
  echo "      Release 已存在（id=${REL_ID}），复用并清理同名旧资产"
  ASSET_ID="$(curl --ssl-no-revoke -fsS -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/releases/${REL_ID}/assets" \
    | "$PY" -c "import sys,json; n=sys.argv[1]; arr=json.loads(sys.stdin.buffer.read().decode('utf-8')); print(next((a['id'] for a in arr if a.get('name')==n),''))" "$(basename "$ZIP")")"
  if [ -n "$ASSET_ID" ]; then
    curl --ssl-no-revoke -fsS -X DELETE -H "Authorization: Bearer ${GH_TOKEN}" \
      "${API}/releases/assets/${ASSET_ID}" || true
  fi
fi

if [ -z "$REL_ID" ]; then
  echo "::error:: 未能获取 Release id" >&2
  exit 1
fi

echo "id=${REL_ID}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "REL_ID=${REL_ID}"
