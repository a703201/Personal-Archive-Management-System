#!/bin/bash
# ============================================================
# AMS · 发布到远程仓库 Release
#
# 用途：打包 → 推送 tag → 创建 GitHub Release 并上传资产。
#
# 用法：
#   bash scripts/release.sh --version 0.2.0
#   bash scripts/release.sh --version 0.2.0 --dry-run     # 只打包不发布
#   bash scripts/release.sh --version 0.2.0 --remote gitcode
#
# 前置条件：
#   ① 已在 GitHub 仓库设置 token（环境变量）：
#        GITHUB_TOKEN=ghp_xxx        （或 GH_TOKEN）
#   ② 已配置 git 远程（默认 origin）：
#        git remote -v
#   ③ 远程仓库存在，且当前分支已推送
#
# 说明：
#   本机**未安装 gh CLI**，故直接用 GitHub REST API（curl）发布。
#   装了 gh 的环境也可以用 scripts/package.sh + gh release create，
#   效果等价。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION=""
DRY_RUN=0
REMOTE="origin"
SKIP_BUILD=0
SKIP_PUSH=0
ALLOW_DIRTY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version=*)  VERSION="${1#*=}" ;;
        --version)    shift; VERSION="${1:-}" ;;
        --remote=*)   REMOTE="${1#*=}" ;;
        --remote)     shift; REMOTE="${1:-origin}" ;;
        --dry-run)    DRY_RUN=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --skip-push)  SKIP_PUSH=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "[WARN] 未知参数：$1" ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    echo "[ERROR] 必须指定版本：--version 0.2.0"
    exit 1
fi
VERSION="${VERSION#v}"
TAG="v${VERSION}"

echo "=== AMS · 发布 Release ==="
echo "  版本 : ${VERSION}（tag: ${TAG}）"
echo "  远程 : ${REMOTE}"
echo ""

# ---- 1. 确认工作区干净 ----
# 说明：CI 里从 tag 构建时工作区必然是干净的；
#       本地想先试跑可用 --allow-dirty 跳过。
if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "[ERROR] 工作区有未提交改动，发布前请先提交："
    git status --short | head -10 | sed 's/^/  /'
    exit 1
fi

# ---- 2. 确认远程 ----
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "[ERROR] 远程 ${REMOTE} 不存在。当前可用："
    git remote -v | sed 's/^/  /'
    exit 1
fi
REMOTE_URL="$(git remote get-url "$REMOTE")"
echo "  远程地址: ${REMOTE_URL}"

# 解析 owner/repo（支持 SSH 与 HTTPS 两种形式）
OWNER_REPO=""
if echo "$REMOTE_URL" | grep -qE "^git@[^:]+:(.+)/(.+)\.git$"; then
    OWNER_REPO="$(echo "$REMOTE_URL" | sed -E 's#^git@[^:]+:(.+)/(.+)\.git$#\1/\2#')"
elif echo "$REMOTE_URL" | grep -qE "^https?://[^/]+/(.+)/(.+)\.git$"; then
    OWNER_REPO="$(echo "$REMOTE_URL" | sed -E 's#^https?://[^/]+/(.+)/(.+)\.git$#\1/\2#')"
fi
if [ -z "$OWNER_REPO" ]; then
    echo "[WARN] 无法从远程地址解析 owner/repo，将尝试仅推 tag 不建 Release。"
    echo "       ${REMOTE_URL}"
fi
echo "  仓库   : ${OWNER_REPO:-<未解析>}"

# ---- 3. 打包 ----
echo ""
echo "[1/4] 打包..."
PKG_ARGS=(--version "$VERSION")
[ "$SKIP_BUILD" = "1" ] && PKG_ARGS+=(--skip-build)
bash scripts/package.sh "${PKG_ARGS[@]}"

PKG_ZIP="$(ls -1 dist/ams-release-${VERSION}-*.zip 2>/dev/null | head -1)"
if [ -z "$PKG_ZIP" ]; then
    echo "[ERROR] 未找到打包产物 dist/ams-release-${VERSION}-*.zip"
    exit 1
fi
echo "      产物: ${PKG_ZIP}"

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== dry-run 完成，未推送任何内容 ==="
    echo "  产物: ${PKG_ZIP}"
    echo "  下一步： bash scripts/release.sh --version ${VERSION}"
    exit 0
fi

# ---- 4. 推 tag ----
echo ""
echo "[2/4] 推送 tag ${TAG}..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "      tag 已存在，跳过创建"
else
    git tag -a "$TAG" -m "AMS ${VERSION}"
fi
if [ "$SKIP_PUSH" = "0" ]; then
    git push "$REMOTE" "$TAG"
    echo "      已推送"
else
    echo "      --skip-push：跳过推送"
fi

# ---- 5. 创建 Release 并上传资产 ----
echo ""
echo "[3/4] 创建 GitHub Release..."

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    echo "[ERROR] 未设置 GITHUB_TOKEN 环境变量，无法创建 Release。"
    echo "       tag 已推送，可手动在仓库页面创建 Release 并上传："
    echo "         ${PKG_ZIP}"
    exit 1
fi
if [ -z "$OWNER_REPO" ]; then
    echo "[ERROR] 缺少 owner/repo 且无法解析，无法创建 Release。"
    exit 1
fi

API="https://api.github.com/repos/${OWNER_REPO}"

# 5.1 Release 是否已存在
REL_ID="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/releases/tags/${TAG}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")"

if [ -z "$REL_ID" ]; then
    echo "      创建 Release..."
    NOTES_FILE="$(mktemp)"
    if [ -f CHANGELOG.md ]; then
        # 取 CHANGELOG 里该版本对应的段落
        python3 - "$VERSION" "$NOTES_FILE" <<'PYEOF_NOTES' 2>/dev/null || true
import re, sys
version, out = sys.argv[1], sys.argv[2]
try:
    text = open("CHANGELOG.md", encoding="utf-8").read()
except Exception:
    sys.exit(0)
# 找到 "## [x.y.z]" 或 "## x.y.z" 段落
m = re.search(r"^##\s+\[?v?" + re.escape(version) + r"\]?.*?(?=^##\s|\Z)", text, re.M | re.S)
if m:
    open(out, "w", encoding="utf-8").write(m.group(0).strip())
PYEOF_NOTES
    fi
    if [ ! -s "$NOTES_FILE" ]; then
        echo "AMS ${VERSION}" > "$NOTES_FILE"
    fi
    REL_ID="$(curl -fsS -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${API}/releases" \
        -d "$(python3 - "$TAG" "$VERSION" "$NOTES_FILE" <<'PYEOF_BODY'
import json, sys
tag, version, notes_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    body = open(notes_file, encoding="utf-8").read()
except Exception:
    body = ""
print(json.dumps({
    "tag_name": tag,
    "name": "AMS " + version,
    "body": body,
    "draft": False,
    "prerelease": False,
}, ensure_ascii=False))
PYEOF_BODY
)" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")"
    if [ -z "$REL_ID" ]; then
        echo "[ERROR] 创建 Release 失败。可手动创建并上传：${PKG_ZIP}"
        exit 1
    fi
    echo "      已创建（id=${REL_ID}）"
else
    echo "      Release 已存在（id=${REL_ID}），直接上传资产"
fi

echo ""
echo "[4/4] 上传资产..."
UPLOAD_URL="${API}/releases/${REL_ID}/assets?name=$(python3 -c "
import urllib.parse, sys
print(urllib.parse.quote(sys.argv[1]))" "$(basename "$PKG_ZIP")")"
HTTP_CODE="$(curl -sS -o /tmp/ams_release_upload.out -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/zip" \
    --data-binary "@${PKG_ZIP}" \
    "${UPLOAD_URL}")"

if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
    echo "[ERROR] 资产上传失败（HTTP ${HTTP_CODE}）："
    head -c 500 /tmp/ams_release_upload.out | sed 's/^/  /'
    echo ""
    echo "      可手动上传：${PKG_ZIP}"
    exit 1
fi

RELEASE_URL="https://github.com/${OWNER_REPO}/releases/tag/${TAG}"
echo ""
echo "=== 发布完成 ==="
echo "  产物   : ${PKG_ZIP}"
echo "  Release: ${RELEASE_URL}"
echo ""
echo "安装："
echo "  1. 下载 ${TAG} 的 zip 并解压"
echo "  2. cp config/application.env config/application.env.local 并填写"
echo "  3. export AMS_TOKEN_SECRET=... && scripts/start.sh   # Linux"
echo "     set AMS_TOKEN_SECRET=... && scripts\\start.cmd     # Windows"
