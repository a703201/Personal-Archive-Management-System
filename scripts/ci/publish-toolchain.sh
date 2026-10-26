#!/bin/bash
# ============================================================
# AMS · CI 工具链发布（把 SDK + stdx 做成 GitHub Release 资产）
#
# 用途：让 **GitHub 托管 runner** 能拿到仓颉工具链。
#
# 背景（实测 2026-10-26）：
#   仓颉 SDK 1.2.0 的 Windows 安装包**不在公开的 gitcode release 仓库里**
#   （stdx 在，Cangjie/cangjie_stdx/releases 有；SDK 二进制没有）。
#   官方下载页（https://cangjie-lang.cn/download/1.2.0）的直链由前端动态生成，
#   不便写死在 CI 里。
#   故采用**自举**方案：本机把工具链打成 Release 资产，CI 从中下载。
#
# 用法（cmd / Git Bash 均可）：
#   export GITHUB_TOKEN=ghp_xxx
#   bash scripts/ci/publish-toolchain.sh
#
# 产物（作为 Release 资产上传）：
#   cangjie-sdk-windows-x64-1.2.0.zip    ≈ 250 MB
#   cangjie-stdx-windows-x64-1.2.0.1.zip ≈  22 MB
#
# 对应的 Release tag：toolchain-v1.2.0（或用 --tag 指定）
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SDK_VERSION="${CANGJIE_SDK_VERSION:-1.2.0}"
STDX_VERSION="${CANGJIE_STDX_VERSION:-1.2.0.1}"
TAG="toolchain-v${SDK_VERSION}"
OUT_DIR="dist/toolchain"
SDK_SRC="${CANGJIE_HOME:-${ROOT}/tools/cangjie}"
STDX_SRC="${STDX_ROOT:-E:/CangjieLibs}/windows_x86_64_cjnative/dynamic/stdx"

# 参数
while [ $# -gt 0 ]; do
    case "$1" in
        --sdk=*)    SDK_SRC="${1#*=}" ;;
        --sdk)      shift; SDK_SRC="${1:-}" ;;
        --stdx=*)   STDX_SRC="${1#*=}" ;;
        --stdx)     shift; STDX_SRC="${1:-}" ;;
        --tag=*)    TAG="${1#*=}" ;;
        --tag)      shift; TAG="${1:-}" ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "[WARN] 未知参数：$1" ;;
    esac
    shift
done
DRY_RUN="${DRY_RUN:-0}"

echo "=== AMS · 发布 CI 工具链 ==="
echo "  SDK  : ${SDK_SRC}  (${SDK_VERSION})"
echo "  stdx : ${STDX_SRC}  (${STDX_VERSION})"
echo "  tag  : ${TAG}"
echo ""

if [ ! -f "${SDK_SRC}/bin/cjc.exe" ]; then
    echo "[ERROR] SDK 目录无效（缺 bin/cjc.exe）：${SDK_SRC}"
    exit 1
fi
if [ ! -d "$STDX_SRC" ]; then
    echo "[ERROR] stdx 目录不存在：${STDX_SRC}"
    exit 1
fi

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ "$DRY_RUN" != "1" ]; then
    echo "[ERROR] 未设置 GITHUB_TOKEN。"
    echo "       cmd 下：set GITHUB_TOKEN=ghp_xxx"
    exit 1
fi

# ---- 远程地址与 owner/repo ----
REMOTE="${REMOTE:-origin}"
REMOTE_URL="$(git remote get-url "$REMOTE")"
OWNER_REPO="$(echo "$REMOTE_URL" | sed -E 's#^git@[^:]+:(.+)/(.+)\.git$#\1/\2#; s#^https?://[^/]+/(.+)/(.+)\.git$#\1/\2#')"
API="https://api.github.com/repos/${OWNER_REPO}"
echo "  仓库 : ${OWNER_REPO}"
echo ""

mkdir -p "$OUT_DIR"

# ---- 补齐 MinGW 运行库（**关键**）----
# ⚠️ 仓颉 SDK 1.2.0 的 Windows 包**本身不含** MinGW 运行库
#    （libgcc_s_seh-1.dll / libwinpthread-1.dll / libssp-0.dll），
#    而 cjc 编译 @Test 用例时需要它们 —— 缺了会报
#    "could not find the create task method: RunCJTask"。
#    本机的补齐副本在 tools/cangjie/bin/（由 scripts/install-sdk.sh 补的），
#    官方 SDK 目录（E:/Cangjie）里是没有的。
#
# 故：打包前先把 MinGW DLL 复制进 SDK 源目录的 bin/，再打包。
MINGW_DLLS="libgcc_s_seh-1.dll libwinpthread-1.dll libssp-0.dll"
MINGW_CANDIDATES=(
    "${SDK_SRC}/bin"
    "${ROOT}/tools/cangjie/bin"
    "$(dirname "$(command -v git 2>/dev/null || echo /dev/null)")/../mingw64/bin"
    "/c/Program Files/Git/mingw64/bin"
)
ADDED=0
for req in $MINGW_DLLS; do
    if [ -e "${SDK_SRC}/bin/$req" ]; then
        continue
    fi
    for c in "${MINGW_CANDIDATES[@]}"; do
        [ -z "$c" ] && continue
        if [ -e "$c/$req" ]; then
            cp -f "$c/$req" "${SDK_SRC}/bin/" && ADDED=$((ADDED + 1))
            echo "      补齐 MinGW 运行库: $req  (来自 $c)"
            break
        fi
    done
done
if [ "$ADDED" = "0" ]; then
    MISSING=""
    for req in $MINGW_DLLS; do
        [ -e "${SDK_SRC}/bin/$req" ] || MISSING="$MISSING $req"
    done
    if [ -n "$MISSING" ]; then
        echo "[ERROR] 找不到 MinGW 运行库：$MISSING"
        echo "       CI 上编译 @Test 用例会失败（RunCJTask 找不到）。"
        echo "       请运行 bash scripts/install-sdk.sh 补齐，或手动放置。"
        exit 1
    fi
fi

# ---- 打包 SDK ----
SDK_ZIP="${OUT_DIR}/cangjie-sdk-windows-x64-${SDK_VERSION}.zip"
if [ -f "$SDK_ZIP" ]; then
    echo "[1/3] SDK 包已存在，复用：${SDK_ZIP}"
else
    echo "[1/3] 打包 SDK（820 MB → 约 250 MB，需要几分钟）..."
    # 用 Python zipfile：Git Bash 通常没有 zip 命令，
    # 且 Python 能正确处理 Windows 路径与中文名。
    PY="$(command -v python3 || command -v python)"
    "$PY" - "$SDK_SRC" "$SDK_ZIP" <<'PYEOF_ZIP'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
# 压缩包内根目录名固定为 cangjie/，与官方包结构一致
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for base, dirs, files in os.walk(src):
        rel_base = os.path.relpath(base, src)
        if rel_base == ".":
            rel_base = ""
        # 跳过无用的临时文件
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for f in files:
            if f.endswith((".log", ".tmp")):
                continue
            full = os.path.join(base, f)
            arc = os.path.join("cangjie", rel_base, f).replace("\\", "/")
            z.write(full, arc)
PYEOF_ZIP
    echo "      完成：$(du -h "$SDK_ZIP" | cut -f1)"
fi

# ---- 打包 stdx ----
STDX_ZIP="${OUT_DIR}/cangjie-stdx-windows-x64-${STDX_VERSION}.zip"
if [ -f "$STDX_ZIP" ]; then
    echo "[2/3] stdx 包已存在，复用：${STDX_ZIP}"
else
    echo "[2/3] 打包 stdx..."
    PY="$(command -v python3 || command -v python)"
    "$PY" - "$STDX_SRC" "$STDX_ZIP" <<'PYEOF_ZIP'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, _dirs, files in os.walk(src):
        for f in files:
            full = os.path.join(base, f)
            arc = os.path.join("stdx", os.path.relpath(full, src)).replace("\\", "/")
            z.write(full, arc)
PYEOF_ZIP
    echo "      完成：$(du -h "$STDX_ZIP" | cut -f1)"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== dry-run，未上传 ==="
    ls -la "$OUT_DIR"
    exit 0
fi

# ---- 创建/复用 Release ----
echo "[3/3] 上传到 Release ${TAG}..."
REL_ID="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/releases/tags/${TAG}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")"

if [ -z "$REL_ID" ]; then
    echo "      创建 Release..."
    REL_ID="$(curl -fsS -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "${API}/releases" \
        -d "$(python3 - "$TAG" <<'PYEOF_BODY'
import json, sys
tag = sys.argv[1]
print(json.dumps({
    "tag_name": tag,
    "name": "CI 工具链 " + tag,
    "body": "仓颉 SDK 与 stdx 的 CI 工具链资产。\n\n"
            "由 `scripts/ci/publish-toolchain.sh` 生成，供 GitHub 托管 runner 下载。\n\n"
            "- `cangjie-sdk-windows-x64-*.zip`：仓颉 SDK\n"
            "- `cangjie-stdx-windows-x64-*.zip`：stdx 扩展库\n",
    "draft": False,
    "prerelease": False,
}, ensure_ascii=False))
PYEOF_BODY
)" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")"
    if [ -z "$REL_ID" ]; then
        echo "[ERROR] 创建 Release 失败。"
        exit 1
    fi
    echo "      已创建（id=${REL_ID}）"
else
    echo "      Release 已存在（id=${REL_ID}）"
fi

# ---- 上传资产 ----
for ZIP in "$SDK_ZIP" "$STDX_ZIP"; do
    NAME="$(basename "$ZIP")"
    # 删掉同名旧资产（否则 422）
    AID="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API}/releases/${REL_ID}/assets" 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        if a.get('name') == '$NAME':
            print(a['id']); break
except Exception:
    pass
")"
    if [ -n "$AID" ]; then
        curl -fsS -X DELETE -H "Authorization: Bearer ${TOKEN}" \
            "${API}/releases/assets/${AID}" >/dev/null 2>&1 || true
    fi
    echo "      上传 ${NAME}（$(du -h "$ZIP" | cut -f1)）..."
    CODE="$(curl -sS -o /tmp/ams_tc_upload.out -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/zip" \
        --data-binary "@${ZIP}" \
        "${API}/releases/${REL_ID}/assets?name=${NAME}")"
    if [ "$CODE" != "201" ] && [ "$CODE" != "200" ]; then
        echo "[ERROR] 上传失败（HTTP ${CODE}）："
        head -c 400 /tmp/ams_tc_upload.out
        exit 1
    fi
    echo "      ✓ ${NAME}"
done

echo ""
echo "=== 工具链发布完成 ==="
echo "  Release: https://github.com/${OWNER_REPO}/releases/tag/${TAG}"
echo ""
echo "下一步："
echo "  1) 在仓库 Settings → Secrets and variables → Actions → Variables"
echo "     新增变量 CANGJIE_TOOLCHAIN_TAG = ${TAG}"
echo "  2) 提交并推送工作流改动，CI 即可自动下载工具链"
