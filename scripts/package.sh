#!/bin/bash
# ============================================================
# AMS · 交付物打包脚本
#
# 用途：把构建产物整理成可分发的发布包（对应架构文档 §7.3 交付物结构）：
#
#   ams-release-<version>-<os>-<arch>/
#   ├── bin/          ams-server.exe + 运行时 DLL（**必须随包分发**）
#   ├── web/          前端 SPA 静态产物（index.html + assets/）
#   ├── config/       配置模板（不含密钥）
#   ├── scripts/      启停 / 健康检查
#   ├── docs/         部署说明
#   ├── LICENSE / NOTICE
#   ├── VERSION
#   └── CHECKSUMS.sha256
#
# **一个进程、一个端口**：ams-server 同时提供 /api/* 与前端 SPA
#   （back-end 侧见 packages/ams-api/src/server/static.cj）。
#   部署方只需启动 bin/ams-server，无需再装 Nginx 或另起静态服务器。
#
# 用法：
#   bash scripts/package.sh                    # 用 build/ 里的现有产物
#   bash scripts/package.sh --version 1.0.0    # 指定版本
#   bash scripts/package.sh --out dist
#   bash scripts/package.sh --skip-web         # 复用 web/dist（不重新构建前端）
#
# 关键约束（架构文档 §7.3 注）：
#   ⚠️ stdx 运行时与仓颉运行时**必须随包分发**。
#      漏发会导致程序启动即报 "error while loading shared libraries"，
#      这是部署期最常见的踩坑点。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 引入路径兼容工具（Git Bash / WSL / 原生 Windows 通用）
# shellcheck source=scripts/ci/pathutil.sh
. "$ROOT/scripts/ci/pathutil.sh"

VERSION=""
OUT_DIR="dist"
SKIP_BUILD=0
SKIP_WEB=0

# 参数解析（同时支持 --version=1.0 与 --version 1.0 两种写法）
while [ $# -gt 0 ]; do
    case "$1" in
        --version=*) VERSION="${1#*=}" ;;
        --version)   shift; VERSION="${1:-}" ;;
        --out=*)     OUT_DIR="${1#*=}" ;;
        --out)       shift; OUT_DIR="${1:-dist}" ;;
        --skip-build) SKIP_BUILD=1 ;;
        --skip-web)   SKIP_WEB=1 ;;
        -h|--help)   sed -n '2,31p' "$0"; exit 0 ;;
        *) echo "[WARN] 未知参数：$1" ;;
    esac
    shift
done

# ---- 版本号：优先取参数，其次 git describe，最后用日期 ----
if [ -z "$VERSION" ]; then
    if git describe --tags --abbrev=0 >/dev/null 2>&1; then
        VERSION="$(git describe --tags --abbrev=0)"
    else
        VERSION="0.1.0-dev.$(date +%Y%m%d)"
    fi
fi
VERSION="${VERSION#v}"

# ---- 平台标识 ----
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    Linux)                OS="linux" ;;
    Darwin)               OS="darwin" ;;
    *)                    OS="unknown" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)             ARCH="$(uname -m)" ;;
esac

PKG_NAME="ams-release-${VERSION}-${OS}-${ARCH}"
STAGE="${OUT_DIR}/${PKG_NAME}"

echo "=== AMS · 打包交付物 ==="
echo "  版本 : ${VERSION}"
echo "  平台 : ${OS}-${ARCH}"
echo "  输出 : ${STAGE}"
echo ""

# ---- 1. 构建（除非跳过）----
if [ "$SKIP_BUILD" = "0" ]; then
    echo "[1/6] 构建后端..."
    bash scripts/build.sh > /tmp/ams_package_build.log 2>&1 || {
        echo "[ERROR] 构建失败，日志尾部："
        tail -20 /tmp/ams_package_build.log | sed 's/^/  /'
        exit 1
    }
else
    echo "[1/6] 跳过后端构建（--skip-build）"
fi

# ---- 2. 前端构建 ----
# 前端产物是**服务的一部分**（同一个进程托管），不是可选项：
# 少了 web/ 目录，ams-server 启动后只会提供 /api/*，根路径 404。
WEB_DIST="web/dist"
if [ "$SKIP_WEB" = "0" ]; then
    echo "[2/6] 构建前端..."
    if [ ! -d "web/node_modules" ]; then
        echo "[ERROR] web/node_modules 不存在，请先：cd web && npm install"
        echo "        或加 --skip-web 复用已有的 ${WEB_DIST}/"
        exit 1
    fi
    # npm run build = vue-tsc --noEmit && vite build —— 类型错误会挡住打包，
    # 这是有意的：前端类型漂移不该被带进交付物。
    ( cd web && npm run build ) > /tmp/ams_package_web.log 2>&1 || {
        echo "[ERROR] 前端构建失败，日志尾部："
        tail -30 /tmp/ams_package_web.log | sed 's/^/  /'
        exit 1
    }
else
    echo "[2/6] 跳过前端构建（--skip-web）"
fi

if [ ! -f "${WEB_DIST}/index.html" ]; then
    echo "[ERROR] 找不到 ${WEB_DIST}/index.html —— 前端产物缺失，无法打包。"
    exit 1
fi

# ---- 2. 检查主程序 ----
SERVER_EXE="build/ams-server.exe"
SERVER_BIN="build/ams-server"
if [ -f "$SERVER_EXE" ]; then
    SERVER_SRC="$SERVER_EXE"
    SERVER_DEST="ams-server.exe"
elif [ -f "$SERVER_BIN" ]; then
    SERVER_SRC="$SERVER_BIN"
    SERVER_DEST="ams-server"
else
    echo "[ERROR] 找不到主程序 build/ams-server(.exe)，请先构建。"
    exit 1
fi

# ---- 3. 组装目录 ----
echo "[3/6] 组装目录..."
rm -rf "$STAGE" 2>/dev/null || true
mkdir -p "$STAGE/bin" "$STAGE/config" "$STAGE/scripts" "$STAGE/docs" "$STAGE/web"

cp "$SERVER_SRC" "$STAGE/bin/$SERVER_DEST"

# 前端 SPA：**平铺到包内 web/**，而不是保留 build 时的 web/dist 层级。
# 原因：ams-server 从**工作目录**出发按 web/dist → web 的顺序探测
# （见 StaticFiles.detect），start 脚本已 cd 到包根，于是 ./web/index.html
# 直接命中，无需设置 AMS_WEB_DIR 也能用。
cp -r "${WEB_DIST}/." "$STAGE/web/"
WEB_FILES="$(find "$STAGE/web" -type f | wc -l | tr -d ' ')"
echo "      前端产物：${WEB_FILES} 个文件"

# 运行时 DLL —— **必须随包分发**
# Windows：stdx 的 dll（build.sh 已拷到 build/）+ 仓颉运行时 dll
if [ "$OS" = "windows" ]; then
    # ⚠️ 必须拷贝 **build/ 下的全部 DLL**，不只是 libstdx*。
    #   build.sh 已把三类运行时都放到 build/：
    #     ① stdx 动态库（libstdx.*.dll）
    #     ② 仓颉运行时（libcangjie-*.dll）
    #     ③ MinGW 运行库（libgcc_s_seh-1.dll / libwinpthread-1.dll / libpcre2-8.dll）
    #   实测：漏掉第 ③ 类时 exe 启动即报
    #     "error while loading shared libraries: cannot open shared object file"
    #   —— 这正是架构文档 §7.3 警告的「部署期最常见踩坑点」。
    DLL_COUNT=0
    for d in build/*.dll; do
        [ -e "$d" ] && cp "$d" "$STAGE/bin/" && DLL_COUNT=$((DLL_COUNT + 1))
    done
    # SDK 运行时目录里的其它 DLL（若 build/ 未覆盖）
    CJ_RUNTIME="$(ams_path_norm "${CANGJIE_HOME:-E:/Cangjie}/runtime/lib/windows_x86_64_cjnative")"
    if [ -d "$CJ_RUNTIME" ]; then
        for d in "$CJ_RUNTIME"/*.dll; do
            [ -e "$d" ] || continue
            bn="$(basename "$d")"
            [ -e "$STAGE/bin/$bn" ] || { cp "$d" "$STAGE/bin/"; DLL_COUNT=$((DLL_COUNT + 1)); }
        done
    fi
    echo "      运行时 DLL：${DLL_COUNT} 个"

    # ---- 关键校验：MinGW 运行库必须齐全 ----
    MISSING=""
    for req in libgcc_s_seh-1.dll libwinpthread-1.dll libpcre2-8.dll libcangjie-runtime.dll; do
        [ -e "$STAGE/bin/$req" ] || MISSING="$MISSING $req"
    done
    if [ -n "$MISSING" ]; then
        echo "[ERROR] 发布包缺少必需的运行时 DLL：$MISSING"
        echo "       缺这些文件会导致 exe 启动即报"
        echo "       "error while loading shared libraries"。"
        exit 1
    fi
else
    chmod +x "$STAGE/bin/$SERVER_DEST" 2>/dev/null || true
fi

# ---- 4. 配置模板 ----
echo "[4/6] 配置模板..."
cat > "$STAGE/config/application.env" <<'ENVEOF'
# ============================================================
# AMS · 服务配置模板
#
# 用法：复制为 application.env 并按实际环境修改；
#       然后用 `set -a; . ./config/application.env; set +a` 导出，
#       或由 scripts/start.sh 自动加载。
#
# ⚠️ 本文件**不得**包含真实密钥。生产密钥请用环境变量注入
#    （容器 secret / systemd EnvironmentFile / CI secret）。
# ============================================================

# ---- HTTP 监听 ----
# **同一个端口同时提供 /api/* 与前端 SPA**：
#   浏览器访问 http://<host>:<port>/ 就是完整的应用，
#   不需要另起 Nginx / 静态服务器，也不存在跨域配置。
# 对外暴露时把 HOST 改成 0.0.0.0，并务必置于可信网络或反向代理之后。
AMS_HTTP_HOST=127.0.0.1
AMS_HTTP_PORT=8080

# ---- 前端产物目录 ----
# 相对路径按**工作目录**解析；留空则自动探测 web/dist → web → ../web/dist。
# 包内布局固定为 <包根>/web/，start 脚本会 cd 到包根，故默认值即可。
AMS_WEB_DIR=web

# ---- 数据库（openGauss）----
# 注意：口令含 URL 保留字符（@ / ? #）时**不能**做 percent-encoding，
#       驱动不解码 %XX（详见 docs/08 §3.1 的实测结论）。
AMS_DB_HOST=127.0.0.1
AMS_DB_PORT=15432
AMS_DB_NAME=ams
AMS_DB_USER=gaussdb
AMS_DB_PASSWORD=
AMS_DB_SSLMODE=disable

# ---- 令牌签名密钥 ----
# ⚠️ 必须 ≥ 32 字节；生产**必须**显式设置（默认值仅供本地开发）。
#    生成：openssl rand -base64 48
AMS_TOKEN_SECRET=

# ---- 日志 ----
AMS_LOG_LEVEL=info
ENVEOF

# ---- 5. 启停与健康检查脚本 ----
echo "[5/6] 启停脚本..."
if [ "$OS" = "windows" ]; then
    cat > "$STAGE/scripts/start.cmd" <<'CMDEOF'
@echo off
REM ============================================================
REM  AMS · 启动服务（Windows）
REM
REM  用法：set AMS_TOKEN_SECRET=... && scripts\start.cmd
REM ============================================================
setlocal
cd /d "%~dp0.."

if not exist "config\application.env" (
    echo [ERROR] 缺少 config\application.env，请先从模板复制并填写。
    exit /b 1
)

REM 加载配置（逐行 set）
for /f "usebackq tokens=1,* delims=#" %%L in ("config\application.env") do (
    echo %%L | findstr /b "AMS_" >nul && set %%L
)

if "%AMS_TOKEN_SECRET%"=="" (
    echo [ERROR] AMS_TOKEN_SECRET 未设置，拒绝以默认密钥启动。
    exit /b 1
)

if not exist "web\index.html" (
    echo [WARN] 未找到 web\index.html：服务将只提供 /api/*，根路径会返回 404。
    echo [WARN] 请确认发布包完整，或把 AMS_WEB_DIR 指向正确的前端目录。
)

echo [INFO] 启动 ams-server（同一端口同时提供前端页面与 /api 接口）
echo [INFO] 打开 http://%AMS_HTTP_HOST%:%AMS_HTTP_PORT%/
bin\ams-server.exe
CMDEOF

    cat > "$STAGE/scripts/healthcheck.cmd" <<'CMDEOF'
@echo off
REM 健康检查：/api/health 通过 + 根路径能取到前端页面
setlocal
set PORT=8080
if not "%AMS_HTTP_PORT%"=="" set PORT=%AMS_HTTP_PORT%

curl -fsS --max-time 10 "http://127.0.0.1:%PORT%/api/health"
if errorlevel 1 (
    echo [FAIL] 接口健康检查未通过
    exit /b 1
)
echo.

REM 同端口部署的关键验证：根路径必须返回前端 HTML，而不是 404
curl -fsS -o nul --max-time 10 "http://127.0.0.1:%PORT%/"
if errorlevel 1 (
    echo [FAIL] 根路径未返回前端页面，检查 web\ 目录与 AMS_WEB_DIR
    exit /b 1
)

echo [OK] 健康检查通过（接口 + 前端页面）
CMDEOF
else
    cat > "$STAGE/scripts/start.sh" <<'SHEOF'
#!/bin/bash
# ============================================================
#  AMS · 启动服务（Linux / macOS）
# ============================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -f "config/application.env" ]; then
    echo "[ERROR] 缺少 config/application.env，请先从模板复制并填写。"
    exit 1
fi
set -a
. ./config/application.env
set +a

if [ -z "${AMS_TOKEN_SECRET:-}" ]; then
    echo "[ERROR] AMS_TOKEN_SECRET 未设置，拒绝以默认密钥启动。"
    exit 1
fi

if [ ! -f "web/index.html" ]; then
    echo "[WARN] 未找到 web/index.html：服务将只提供 /api/*，根路径会返回 404。"
    echo "[WARN] 请确认发布包完整，或把 AMS_WEB_DIR 指向正确的前端目录。"
fi

echo "[INFO] 启动 ams-server（同一端口同时提供前端页面与 /api 接口）"
echo "[INFO] 打开 http://${AMS_HTTP_HOST}:${AMS_HTTP_PORT}/"
exec bin/ams-server "$@"
SHEOF
    chmod +x "$STAGE/scripts/start.sh"

    cat > "$STAGE/scripts/healthcheck.sh" <<'SHEOF'
#!/bin/bash
# 健康检查：/api/health 通过 + 根路径能取到前端页面
set -uo pipefail
PORT="${AMS_HTTP_PORT:-8080}"

curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/health" || {
    echo "[FAIL] 接口健康检查未通过" >&2
    exit 1
}
echo

# 同端口部署的关键验证：根路径必须返回前端 HTML，而不是 404
curl -fsS -o /dev/null --max-time 10 "http://127.0.0.1:${PORT}/" || {
    echo "[FAIL] 根路径未返回前端页面，检查 web/ 目录与 AMS_WEB_DIR" >&2
    exit 1
}

echo "[OK] 健康检查通过（接口 + 前端页面）"
SHEOF
    chmod +x "$STAGE/scripts/healthcheck.sh"
fi

# ---- 6. 文档 ----
# ⚠️ 包内**一律用 ASCII 文件名**。
#   非 ASCII 文件名在 Windows 的 zip 工具链上支持不稳，
#   且会让 CHECKSUMS 清单出现编码损坏（实测：MSYS 的参数传递会把
#   UTF-8 文件名转成乱码，导致 `sha256sum -c` 报 "No such file or directory"）。
cp docs/08-SM4方案变更说明.md "$STAGE/docs/SM4-DESIGN-CHANGE.md" 2>/dev/null || true
cp docs/09-部署与发布指南.md "$STAGE/docs/DEPLOY-GUIDE.md" 2>/dev/null || true
cp README.md "$STAGE/docs/README.md" 2>/dev/null || true
[ -f LICENSE ] && cp LICENSE "$STAGE/LICENSE"
[ -f NOTICE ] && cp NOTICE "$STAGE/NOTICE"

cat > "$STAGE/VERSION" <<VEREOF
${VERSION}
VEREOF

cat > "$STAGE/DEPLOY.md" <<DEPLOYEOF
# AMS 部署说明（${VERSION} · ${OS}-${ARCH}）

> **一个进程、一个端口**：\`bin/ams-server\` 同时提供 \`/api/*\` 接口与前端
> 单页应用。启动后浏览器直接访问 \`http://<host>:<port>/\` 即为完整应用，
> **不需要**再部署 Nginx、也不用另起静态服务器。

## 1. 目录结构

\`\`\`
${PKG_NAME}/
├── bin/            主程序与运行时（**不要单独拷走 DLL**）
├── web/            前端 SPA（index.html + assets/）
├── config/         配置模板（application.env）
├── scripts/        启动与健康检查
└── docs/           变更说明
\`\`\`

## 2. 快速开始

\`\`\`bash
# 1) 复制配置并填写（必填：AMS_TOKEN_SECRET、AMS_DB_PASSWORD）
cp config/application.env config/application.env.local

# 2) 启动（脚本会自动加载 config/application.env）
scripts/start.sh          # Linux/macOS
scripts\\start.cmd        # Windows

# 3) 打开浏览器
#    http://127.0.0.1:8080/        ← 前端页面
#    http://127.0.0.1:8080/api/health  ← 健康检查
\`\`\`

## 3. 必填配置

| 变量 | 说明 |
| --- | --- |
| \`AMS_TOKEN_SECRET\` | 令牌签名密钥，**≥ 32 字节**。不设置则拒绝启动。生成：\`openssl rand -base64 48\` |
| \`AMS_DB_PASSWORD\` | 数据库口令 |
| \`AMS_DB_HOST\` / \`AMS_DB_PORT\` / \`AMS_DB_NAME\` / \`AMS_DB_USER\` | 数据库连接 |
| \`AMS_HTTP_HOST\` / \`AMS_HTTP_PORT\` | 监听地址，默认 \`127.0.0.1:8080\` |
| \`AMS_WEB_DIR\` | 前端目录，默认 \`web\`（相对工作目录）。留空则自动探测 |

> ⚠️ 数据库口令**不要**做 percent-encoding：驱动不解码 \`%XX\`，
> 编码后会导致认证失败（SQLSTATE 28P01）。

## 4. 前后端同端口的路由规则

服务端按前缀分流，部署方无需配置任何转发规则：

| 请求 | 处理 |
| --- | --- |
| \`/api/...\` | 后端接口（未知接口返回 JSON 404，**不会**回落到 HTML） |
| \`/assets/...\` | 前端静态资源，\`cache-control: public, max-age=31536000, immutable\` |
| \`/\`、\`/archive\` 等无扩展名路径 | 回落 \`index.html\`，由前端路由接管（SPA history 模式） |
| \`/xxx.js\` 等带扩展名但文件不存在 | 真正的 404（避免缺失资源被 HTML 掩盖成语法错误） |

## 5. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动即报 \`could not load the dynamic library\` | 运行时 DLL 缺失 | 确认 \`bin/\` 下有 \`libstdx.*.dll\` 与 \`libcangjie-runtime.dll\`，**不要**只拷 exe |
| 启动即报 \`RunCJTask\` 找不到 | MinGW 运行库缺失 | 把 \`libgcc_s_seh-1.dll\`、\`libwinpthread-1.dll\`、\`libssp-0.dll\` 放进 \`bin/\` |
| \`/api/*\` 正常但根路径 404 | 前端产物缺失或路径不对 | 确认 \`web/index.html\` 存在；或把 \`AMS_WEB_DIR\` 指向正确目录；启动日志会打 \`http.static.disabled\` 警告 |
| 刷新子页面 404（旧版 nginx 部署） | 未配置 history 回落 | 本版已内置回落，无需 nginx \`try_files\`；若放在反向代理后，请把 \`/\` 整体转发给本服务 |
| 数据库认证失败（28P01） | 口令被 percent-encode | 去掉编码，原样填入 |
| 端口被占用 | 端口冲突 | 改 \`AMS_HTTP_PORT\` |

## 6. 校验

\`\`\`bash
sha256sum -c CHECKSUMS.sha256      # Linux
certutil -hashfile ams-release-*.zip SHA256   # Windows
\`\`\`
DEPLOYEOF

# ---- 7. 校验和 ----
echo "[6/6] 校验和..."
cd "$STAGE"
# 用 Python 生成校验和清单（**必须**）：
#   `find | xargs sha256sum` 在 Git Bash 下会因 MSYS 的参数传递而
#   损坏非 ASCII 文件名，导致 `sha256sum -c` 报 "No such file or directory"。
#   Python 直接以二进制方式遍历并写清单，不经 shell 参数传递，无此问题。
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    PY="$(command -v python3 || command -v python)"
    "$PY" - <<'PYEOF_SUM'
import hashlib, os
rows = []
for base, _dirs, files in os.walk("."):
    for f in files:
        full = os.path.join(base, f)
        rel = os.path.relpath(full, ".")
        if rel.replace("\\", "/") == "CHECKSUMS.sha256":
            continue
        h = hashlib.sha256()
        with open(full, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        rows.append((rel.replace("\\", "/"), h.hexdigest()))
rows.sort()
with open("CHECKSUMS.sha256", "w", encoding="utf-8", newline="\n") as out:
    for rel, digest in rows:
        out.write("%s *%s\n" % (digest, rel))
PYEOF_SUM
else
    find . -type f ! -name "CHECKSUMS.sha256" -exec shasum -a 256 {} \; > CHECKSUMS.sha256
fi
cd "$ROOT"

# ---- 8. 压缩 ----
mkdir -p "$OUT_DIR"
ZIP_PATH="${OUT_DIR}/${PKG_NAME}.zip"
rm -f "$ZIP_PATH" 2>/dev/null || true

# 压缩：优先用 Python 的 zipfile（产出标准 .zip，Windows 友好）
# 说明：Git Bash 环境**通常没有** zip / 7z（实测本机均无），
# 而 tar 只能产出 .tar.gz，对 Windows 部署方不友好，故优先 Python。
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    PY="$(command -v python3 || command -v python)"
    "$PY" - "$OUT_DIR" "$PKG_NAME" "$ZIP_PATH" <<'PYEOF_ZIP'
import os, sys, zipfile
out_dir, pkg_name, zip_path = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(out_dir, pkg_name)
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, _dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(base, f)
            z.write(full, os.path.relpath(full, out_dir))
PYEOF_ZIP
else
    echo "[WARN] 未找到 python，回退到 tar.gz"
    tar -czf "${ZIP_PATH%.zip}.tar.gz" -C "$OUT_DIR" "$PKG_NAME"
    ZIP_PATH="${ZIP_PATH%.zip}.tar.gz"
fi

echo ""
echo "=== 打包完成 ==="
echo "  目录 : ${STAGE}"
echo "  压缩 : ${ZIP_PATH}"
echo "  大小 : $(du -h "$ZIP_PATH" | cut -f1)"
echo ""
echo "发布到 GitHub Release："
echo "  gh release create ${VERSION} ${ZIP_PATH} --title \"AMS ${VERSION}\" --generate-notes"
echo "  # 或用：bash scripts/release.sh --version ${VERSION}"
