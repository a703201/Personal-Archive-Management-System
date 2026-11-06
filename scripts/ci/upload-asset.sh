#!/usr/bin/env bash
# ============================================================
# AMS · 上传二进制资产到 GitHub Release
#
# ⚠️ 关键：上传 Release 资产必须用 uploads.github.com，不是 api.github.com。
#    POST 到 api.github.com/repos/{owner}/{repo}/releases/{id}/assets 时，
#    该路径只接受 GET（列出资产），POST 一律返回 404 "Not Found"。
#    官方文档：https://docs.github.com/rest/releases/assets#upload-a-release-asset
#    -H "Content-Type: application/octet-stream" + --data-binary "@file"
#    （文件原始字节）；不能用 -F "file=@..." multipart。
#
# 输入（环境变量）：
#   GH_TOKEN            GitHub token（需 contents:write）
#   VERSION             版本号，如 1.2.0（不含 v）
#   REL_ID              Release id（来自 publish-release.sh 的 steps.rel.outputs.id）
#   GITHUB_REPOSITORY   owner/repo
# ============================================================
set -euo pipefail

VER="${VERSION:?VERSION 未设置}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"
REL_ID="${REL_ID:?REL_ID 未设置}"
TOKEN="${GH_TOKEN:?GH_TOKEN 未设置}"
ZIP="dist/ams-release-${VER}-windows-x86_64.zip"

if [ ! -f "$ZIP" ]; then
  echo "::error:: 发布包不存在：${ZIP}"
  exit 1
fi

# 文件名形如 ams-release-1.2.0-windows-x86_64.zip，纯 ASCII 无空格，
# 无需 URL 编码，直接用作 ?name=（也避免再嵌一层 python -c 引号）。
NAME="$(basename "$ZIP")"
OUT="$(mktemp)"

# --ssl-no-revoke：Windows runner 的 curl 用 schannel，默认查证书吊销状态，
#   被代理/防火墙挡住时会失败（CRYPT_E_NO_REVOCATION_CHECK 0x80092012）。
echo "上传 ${ZIP} → Release ${REL_ID} ..."
CODE="$(curl -sS -o "$OUT" -w "%{http_code}" \
  --ssl-no-revoke \
  --max-time 1800 \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${ZIP}" \
  "https://uploads.github.com/repos/${REPO}/releases/${REL_ID}/assets?name=${NAME}")"

if [ "$CODE" != "201" ] && [ "$CODE" != "200" ]; then
  echo "::error:: 资产上传失败（HTTP ${CODE}）"
  head -c 500 "$OUT"
  echo ""
  exit 1
fi
echo "上传完成（HTTP ${CODE}）"
