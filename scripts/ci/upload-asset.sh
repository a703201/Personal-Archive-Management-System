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

# ---- 可选：ams-kit 框架静态库包（若存在则一并上传）----
# 由 scripts/package-kit.sh 产出；若不存在（如未构建 kit），跳过不报错。
for kz in dist/ams-kit-*.zip; do
  [ -e "$kz" ] || continue
  KNAME="$(basename "$kz")"
  KOUT="$(mktemp)"
  echo "上传 ${kz} → Release ${REL_ID} ..."
  KCODE="$(curl -sS -o "$KOUT" -w "%{http_code}" \
    --ssl-no-revoke \
    --max-time 1800 \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${kz}" \
    "https://uploads.github.com/repos/${REPO}/releases/${REL_ID}/assets?name=${KNAME}")"
  if [ "$KCODE" != "201" ] && [ "$KCODE" != "200" ]; then
    echo "::error:: kit 资产上传失败（HTTP ${KCODE}）"
    head -c 500 "$KOUT"
    echo ""
    exit 1
  fi
  echo "kit 上传完成（HTTP ${KCODE}）"
done

# ---- 可选：鸿蒙客户端 App Pack 安装包（若存在则一并上传）----
# 来源：鸿蒙构建产物 mobile/build/outputs/default/mobile-default-signed.app
# 约束：build/ 与 *.app 在 mobile/.gitignore 中被忽略，且 GitHub 托管 runner
#   无鸿蒙 SDK，故托管环境不会产出该文件 → 本段自动跳过（不影响 Release）。
#   若需随 Release 发布，二选一：
#     ① 使用装有 DevEco Studio / 鸿蒙 SDK 的自托管 runner（release.yml 的
#        “构建鸿蒙客户端（可选）”步骤会成功，本段随之上传）；
#     ② 本地构建后 `git add <app>` 纳入仓库再打 tag（CI checkout 即可拿到；
#        .gitignore 已对 mobile-default-signed.app 开白名单，无需 -f）。
APP_DIR="mobile/build/outputs/default"
APP=""
if [ -d "$APP_DIR" ]; then
  APP="$(find "$APP_DIR" -maxdepth 1 -name 'mobile-default-signed.app' 2>/dev/null | head -1)"
  [ -z "$APP" ] && APP="$(find "$APP_DIR" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
fi
if [ -n "$APP" ]; then
  ANAME="ams-mobile-${VER}.app"
  AOUT="$(mktemp)"
  echo "上传 ${APP} → Release ${REL_ID} (as ${ANAME}) ..."
  ACODE="$(curl -sS -o "$AOUT" -w "%{http_code}" \
    --ssl-no-revoke \
    --max-time 1800 \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${APP}" \
    "https://uploads.github.com/repos/${REPO}/releases/${REL_ID}/assets?name=${ANAME}")"
  if [ "$ACODE" != "201" ] && [ "$ACODE" != "200" ]; then
    echo "::error:: 鸿蒙 App Pack 资产上传失败（HTTP ${ACODE}）"
    head -c 500 "$AOUT"
    echo ""
    exit 1
  fi
  echo "App Pack 上传完成（HTTP ${ACODE}）"
else
  echo "未找到鸿蒙 App Pack（mobile/.gitignore 忽略 *.app，且托管 runner 无鸿蒙 SDK）→ 跳过上传（不影响 Release）"
fi
