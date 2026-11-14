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

# 资产名是否已存在于该 Release（幂等：已存在则跳过，避免重跑因同名 422）
asset_exists() {
  local name="$1"
  local list
  list="$(curl -sS --ssl-no-revoke -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/${REL_ID}/assets" 2>/dev/null)"
  # 资产名为 ASCII，JSON 形如 "name": "xxx"，简单匹配即可
  printf '%s' "$list" | grep -q "\"name\":\"${name}\""
}

# 统一上传一个资产：file 本地路径，name 资产名，required=1 缺失/失败即退出，=0 缺失则跳过
upload_asset() {
  local file="$1" name="$2" required="$3"
  if [ ! -f "$file" ]; then
    if [ "$required" = "1" ]; then
      echo "::error:: 发布包不存在：${file}"
      exit 1
    fi
    echo "未找到 ${file} → 跳过上传（不影响 Release）"
    return 0
  fi
  if asset_exists "$name"; then
    echo "资产 ${name} 已存在 → 跳过（幂等，避免重跑 422）"
    return 0
  fi
  local out; out="$(mktemp)"
  local code
  code="$(curl -sS -o "$out" -w "%{http_code}" \
    --ssl-no-revoke \
    --max-time 1800 \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${file}" \
    "https://uploads.github.com/repos/${REPO}/releases/${REL_ID}/assets?name=${name}")"
  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    echo "::error:: 资产 ${name} 上传失败（HTTP ${code}）"
    head -c 500 "$out"; echo ""
    if [ "$required" = "1" ]; then exit 1; fi
    return 0
  fi
  echo "上传完成（HTTP ${code}）：${name}"
}

# ---- ① 必选：AMS 发布包（Windows x86_64）----
upload_asset "$ZIP" "$(basename "$ZIP")" 1

# ---- ② 可选：ams-kit 框架静态库包（若存在则一并上传）----
# 由 scripts/package-kit.sh 产出；若不存在（如未构建 kit），跳过不报错。
for kz in dist/ams-kit-*.zip; do
  [ -e "$kz" ] || continue
  echo "上传 ${kz} → Release ${REL_ID} ..."
  upload_asset "$kz" "$(basename "$kz")" 0
done

# ---- ③ 可选：鸿蒙客户端 App Pack ----
# 来源：鸿蒙构建产物 mobile/build/outputs/default/mobile-default-signed.app
# 约束：build/ 与 *.app 在 mobile/.gitignore 中被忽略，且 GitHub 托管 runner
#   无鸿蒙 SDK，故托管环境不会产出该文件 → 本段自动跳过（不影响 Release）。
#   若需随 Release 发布，二选一：
#     ① 使用装有 DevEco Studio / 鸿蒙 SDK 的自托管 runner（release.yml 的
#        “构建鸿蒙客户端（可选）”步骤会成功，本段随之上传）；
#     ② 本地构建后 `git add <app>` 纳入仓库再打 tag（CI checkout 即可拿到；
#        .gitignore 已对 mobile-default-signed.app 开白名单，无需 -f）。
# ⚠️ GitHub Release 资产禁止 .apk / .app 扩展名（422 name not allowed），
#   故统一把 .app 打包为 .zip 上传（仓库内仍保留原始 .app，下载解压即得）。
APP_DIR="mobile/build/outputs/default"
APP=""
if [ -d "$APP_DIR" ]; then
  APP="$(find "$APP_DIR" -maxdepth 1 -name 'mobile-default-signed.app' 2>/dev/null | head -1)"
  [ -z "$APP" ] && APP="$(find "$APP_DIR" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
fi
if [ -n "$APP" ]; then
  mkdir -p dist
  # 放到 dist/ 下、用相对路径，避免 Windows runner 上 /tmp 绝对路径被 powershell 误解析
  AZIP="dist/ams-mobile-${VER}.tmp.zip"
  rm -f "$AZIP"
  echo "打包 ${APP} → ${AZIP} ..."
  PK_OK=0
  # 跨平台优先用 python（GitHub runner 自带；zipfile 路径处理最稳，规避 powershell 的 /tmp 问题）
  PYBIN=""
  command -v python3 >/dev/null 2>&1 && PYBIN=python3
  [ -z "$PYBIN" ] && command -v python >/dev/null 2>&1 && PYBIN=python
  if [ -n "$PYBIN" ]; then
    if "$PYBIN" - "$APP" "$AZIP" <<'PY'
import os, sys, zipfile
app, out = sys.argv[1], sys.argv[2]
base = os.path.basename(app.rstrip('/\\'))
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    if os.path.isdir(app):
        for root, _, files in os.walk(app):
            for f in files:
                full = os.path.join(root, f)
                z.write(full, os.path.join(base, os.path.relpath(full, app)))
    else:
        z.write(app, base)
PY
    then
      [ -f "$AZIP" ] && PK_OK=1
    fi
  fi
  # 退而求其次用 zip（Linux runner 常见）
  if [ "$PK_OK" != "1" ] && command -v zip >/dev/null 2>&1; then
    if zip -j -q "$AZIP" "$APP"; then PK_OK=1; fi
  fi
  # 最后兜底 powershell（仅当 python/zip 均不可用时）
  if [ "$PK_OK" != "1" ] && command -v powershell >/dev/null 2>&1; then
    if powershell -NoProfile -Command "Compress-Archive -Path '${APP}' -DestinationPath '${AZIP}'"; then PK_OK=1; fi
  fi
  if [ "$PK_OK" != "1" ]; then
    echo "::error:: 鸿蒙包压缩失败（python/zip/powershell 均不可用）"
    rm -f "$AZIP"
    exit 1
  fi
  ANAME="ams-mobile-${VER}.zip"
  echo "上传 ${AZIP} → Release ${REL_ID} (as ${ANAME}) ..."
  upload_asset "$AZIP" "$ANAME" 0
  rm -f "$AZIP"
else
  echo "未找到鸿蒙 App Pack（mobile/.gitignore 忽略 *.app，且托管 runner 无鸿蒙 SDK）→ 跳过上传（不影响 Release）"
fi
