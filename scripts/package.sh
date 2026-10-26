#!/bin/bash
# ============================================================
# AMS · 交付物打包脚本
#
# 用途：把构建产物整理成可分发的发布包（对应架构文档 §7.3 交付物结构）：
#
#   ams-release-<version>-<os>-<arch>/
#   ├── bin/          ams-server.exe + 运行时 DLL（**必须随包分发**）
#   ├── config/       配置模板（不含密钥）
#   ├── scripts/      启停 / 健康检查
#   ├── docs/         部署说明
#   ├── LICENSE / NOTICE
#   ├── VERSION
#   └── CHECKSUMS.sha256
#
# 用法：
#   bash scripts/package.sh                    # 用 build/ 里的现有产物
#   bash scripts/package.sh --version 0.2.0    # 指定版本
#   bash scripts/package.sh --out dist
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

# 参数解析（同时支持 --version=1.0 与 --version 1.0 两种写法）
while [ $# -gt 0 ]; do
    case "$1" in
        --version=*) VERSION="${1#*=}" ;;
        --version)   shift; VERSION="${1:-}" ;;
        --out=*)     OUT_DIR="${1#*=}" ;;
        --out)       shift; OUT_DIR="${1:-dist}" ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
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
    echo "[1/5] 构建..."
    bash scripts/build.sh > /tmp/ams_package_build.log 2>&1 || {
        echo "[ERROR] 构建失败，日志尾部："
        tail -20 /tmp/ams_package_build.log | sed 's/^/  /'
        exit 1
    }
else
    echo "[1/5] 跳过构建（--skip-build）"
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
echo "[2/5] 组装目录..."
rm -rf "$STAGE" 2>/dev/null || true
mkdir -p "$STAGE/bin" "$STAGE/config" "$STAGE/scripts" "$STAGE/docs"

cp "$SERVER_SRC" "$STAGE/bin/$SERVER_DEST"

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
echo "[3/5] 配置模板..."
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
AMS_HTTP_HOST=127.0.0.1
AMS_HTTP_PORT=8080

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
echo "[4/5] 启停脚本..."
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

echo [INFO] 启动 ams-server，监听 %AMS_HTTP_HOST%:%AMS_HTTP_PORT%
bin\ams-server.exe
CMDEOF

    cat > "$STAGE/scripts/healthcheck.cmd" <<'CMDEOF'
@echo off
REM 健康检查：GET /api/health
setlocal
set PORT=8080
if not "%AMS_HTTP_PORT%"=="" set PORT=%AMS_HTTP_PORT%
curl -fsS --max-time 10 "http://127.0.0.1:%PORT%/api/health"
if errorlevel 1 (
    echo [FAIL] 健康检查未通过
    exit /b 1
)
echo [OK] 健康检查通过
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

echo "[INFO] 启动 ams-server，监听 ${AMS_HTTP_HOST}:${AMS_HTTP_PORT}"
exec bin/ams-server "$@"
SHEOF
    chmod +x "$STAGE/scripts/start.sh"

    cat > "$STAGE/scripts/healthcheck.sh" <<'SHEOF'
#!/bin/bash
# 健康检查：GET /api/health
set -uo pipefail
PORT="${AMS_HTTP_PORT:-8080}"
curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/health" || {
    echo "[FAIL] 健康检查未通过" >&2
    exit 1
}
echo "[OK] 健康检查通过"
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

cat > "$STAGE/DEPLOY.md" <<'DEPLOYEOF'
# AMS 部署说明（${VERSION} · ${OS}-${ARCH}）

## 1. 目录结构

```
${PKG_NAME}/
├── bin/            主程序与运行时（**不要单独拷走 DLL**）
├── config/         配置模板（application.env）
├── scripts/        启动与健康检查
└── docs/           变更说明
```

## 2. 快速开始

```bash
# 1) 复制配置并填写（必填：AMS_TOKEN_SECRET、AMS_DB_PASSWORD）
cp config/application.env config/application.env.local

# 2) 导出环境变量
set -a; . ./config/application.env; set +a

# 3) 启动
scripts/start.sh          # Linux/macOS
scripts\\start.cmd        # Windows

# 4) 健康检查
scripts/healthcheck.sh
```

## 3. 必填配置

| 变量 | 说明 |
| --- | --- |
| `AMS_TOKEN_SECRET` | 令牌签名密钥，**≥ 32 字节**。不设置则拒绝启动。生成：`openssl rand -base64 48` |
| `AMS_DB_PASSWORD` | 数据库口令 |
| `AMS_DB_HOST` / `AMS_DB_PORT` / `AMS_DB_NAME` / `AMS_DB_USER` | 数据库连接 |

> ⚠️ 数据库口令**不要**做 percent-encoding：驱动不解码 `%XX`，
> 编码后会导致认证失败（SQLSTATE 28P01）。

## 4. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动即报 `could not load the dynamic library` | 运行时 DLL 缺失 | 确认 `bin/` 下有 `libstdx.*.dll` 与 `libcangjie-runtime.dll`，**不要**只拷 exe |
| 启动即报 `RunCJTask` 找不到 | MinGW 运行库缺失 | 把 `libgcc_s_seh-1.dll`、`libwinpthread-1.dll`、`libssp-0.dll` 放进 `bin/` |
| 数据库认证失败（28P01） | 口令被 percent-encode | 去掉编码，原样填入 |
| 端口被占用 | 端口冲突 | 改 `AMS_HTTP_PORT` |

## 5. 校验

```bash
sha256sum -c CHECKSUMS.sha256      # Linux
certutil -hashfile ams-release-*.zip SHA256   # Windows
```
DEPLOYEOF

# ---- 7. 校验和 ----
echo "[5/5] 校验和..."
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
