#!/bin/bash
# ============================================================
# AMS · ams-kit 框架静态库分发打包（架构演进方案 A · docs/15 §4.1）
#
# 【为什么是这个形态】
#   cjpm 1.2.0 要求 toml `name`（扁平标识符，如 cjDemo）与源码
#   `package` 声明逐字相等；AMS 全仓用点号分层命名（ams.kit），两者不兼容。
#   2026-11-08 已决策：**不做全仓改名**（方案 A）。框架以「静态库 + Cangjie
#   接口快照（.cjo）+ LICENSE + 使用说明」打包，随 GitHub Release 分发。
#   `packages/ams-{kernel,crypto,kit}/cjpm.toml` 仅保留为元数据文档，
#   不参与任何构建，**不要**对它们跑 cjpm build / cjpm publish。
#
# 【产物布局】
#   ams-kit-<version>-<platform>/
#   ├── lib/       lib<包名>.a   （框架依赖闭包的静态库）
#   ├── cjo/       <包名>.cjo    （编译单元接口快照，cjc --import-path 用）
#   ├── LICENSE                  （Apache-2.0，必须随发布包分发）
#   ├── README.md                （框架使用说明 = packages/ams-kit/README.md）
#   ├── VERSION
#   ├── MANIFEST.txt             （闭包 / 版本 / 构建目录 / 逐文件 sha256）
#   └── CHECKSUMS.sha256
#
# 【依赖闭包不写死】
#   从 `ams.kit` 的 import 出发递归扫描 packages/*/src 下的源码，
#   实时推导闭包，避免以后加了一个 import 却忘了更新白名单导致
#   第三方链接缺符号。可用 --print-closure 单独查看。
#
# 用法：
#   bash scripts/package-kit.sh                       # 用 build/（Windows 产物）
#   bash scripts/package-kit.sh --build-dir build/linux   # Linux 产物
#   bash scripts/package-kit.sh --out dist --version 0.1.0-alpha
#   bash scripts/package-kit.sh --print-closure
#
# 前置：先跑 `bash scripts/build.sh`（或 build-linux-docker.sh）产出 .a/.cjo。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
OUT_DIR="dist"
VERSION=""
PLATFORM=""
PRINT_CLOSURE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --print-closure) PRINT_CLOSURE=1; shift ;;
        -h|--help)
            sed -n '2,42p' "$0"
            exit 0 ;;
        *) echo "[ERROR] 未知参数: $1" >&2; exit 2 ;;
    esac
done

# ---- 版本号：单一来源为 kit.cj 的 KIT_VERSION，不另抄一份 ----
if [ -z "$VERSION" ]; then
    VERSION="$(grep -oE 'public let KIT_VERSION: String = "[^"]+"' \
        "$ROOT/packages/ams-kit/src/kit.cj" | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/')"
fi
if [ -z "$VERSION" ]; then
    echo "[ERROR] 无法从 packages/ams-kit/src/kit.cj 提取 KIT_VERSION" >&2
    exit 1
fi

if [ -z "$PLATFORM" ]; then
    case "$BUILD_DIR" in
        *linux*) PLATFORM="linux-x86_64" ;;
        *) PLATFORM="windows-x86_64" ;;
    esac
fi

if [ ! -d "$BUILD_DIR" ]; then
    echo "[ERROR] 构建目录不存在: $BUILD_DIR" >&2
    echo "        先跑 bash scripts/build.sh（Windows）或 bash deploy/scripts/build-linux-docker.sh（Linux）" >&2
    exit 1
fi

# ---- 闭包计算（纯 ASCII 输出，规避 Windows runner 的 cp1252 stdout） ----
# python 只输出包名清单到 .tmp/kit-closure.txt，不 print 任何中文。
mkdir -p "$ROOT/.tmp"
PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
    echo "[ERROR] 需要 python 计算依赖闭包" >&2
    exit 1
fi

"$PY" - "$ROOT" "$BUILD_DIR" > "$ROOT/.tmp/kit-closure.txt" <<'PYEOF'
import os, re, sys, pathlib
root = pathlib.Path(sys.argv[1])
build = pathlib.Path(sys.argv[2])
pkgs_root = root / 'packages'

def files_for(pkg):
    parts = pkg.split('.')
    d = pkgs_root / ('ams-' + parts[1]) / 'src'
    if len(parts) > 2:
        d = d / parts[2]
    return sorted(d.glob('*.cj')) if d.is_dir() else []

def imports_of(pkg):
    out = set()
    for f in files_for(pkg):
        for line in f.read_text(encoding='utf-8', errors='ignore').splitlines():
            m = re.match(r'^import\s+(ams\.[A-Za-z0-9_.]+)', line)
            if m:
                out.add(m.group(1).rstrip('.'))
    return out

seen, stack = set(), ['ams.kit']
while stack:
    p = stack.pop()
    if p in seen:
        continue
    seen.add(p)
    for d in imports_of(p):
        if d not in seen:
            stack.append(d)

closure = sorted(seen)
missing = []
for p in closure:
    a = build / ('lib' + p + '.a')
    c = build / (p + '.cjo')
    if not a.is_file():
        missing.append(p + ' (missing .a)')
    if not c.is_file():
        missing.append(p + ' (missing .cjo)')

# 必须用二进制写 stdout：原生 Windows Python 的 text-mode stdout 会把
# '\n' 转成 '\r\n'，bash 的 `read -r` 就会把 '\r' 带进包名，
# 进而 cp 找不到 lib<pkg>\r.a（实测踩过）。
sys.stdout.buffer.write(('\n'.join(closure) + '\n').encode('utf-8'))
if missing:
    sys.stderr.write('MISSING_ARTIFACTS: ' + '; '.join(missing) + '\n')
    sys.exit(3)
PYEOF

CLOSURE="$(tr '\n' ' ' < "$ROOT/.tmp/kit-closure.txt")"
COUNT="$(wc -w < "$ROOT/.tmp/kit-closure.txt" | tr -d ' ')"

if [ "$PRINT_CLOSURE" = 1 ]; then
    echo "ams-kit dependency closure ($COUNT packages, build-dir=$BUILD_DIR):"
    while read -r p; do [ -n "$p" ] && echo "  $p"; done < "$ROOT/.tmp/kit-closure.txt"
    echo "  KIT_VERSION=$VERSION  PLATFORM=$PLATFORM"
    exit 0
fi

echo "=== ams-kit 框架静态库打包（方案 A） ==="
echo "  版本     : $VERSION"
echo "  平台     : $PLATFORM"
echo "  构建目录 : $BUILD_DIR"
echo "  闭包     : $COUNT 个包"
echo "            $CLOSURE"
echo ""

PKG_NAME="ams-kit-${VERSION}-${PLATFORM}"
STAGE="${OUT_DIR}/${PKG_NAME}"
rm -rf "$STAGE" 2>/dev/null || true
mkdir -p "$STAGE/lib" "$STAGE/cjo"

# ---- 复制静态库与接口快照 ----
while read -r p; do
    [ -z "$p" ] && continue
    cp "$BUILD_DIR/lib${p}.a" "$STAGE/lib/"
    cp "$BUILD_DIR/${p}.cjo" "$STAGE/cjo/"
done < "$ROOT/.tmp/kit-closure.txt"

# ---- LICENSE 必须随包分发（Apache-2.0，第 3 条明示专利授权） ----
if [ ! -f "$ROOT/LICENSE" ]; then
    echo "[ERROR] 缺少 LICENSE，拒绝产出不合规的发布包" >&2
    exit 1
fi
cp "$ROOT/LICENSE" "$STAGE/LICENSE"

if [ ! -f "$ROOT/packages/ams-kit/README.md" ]; then
    echo "[ERROR] 缺少 packages/ams-kit/README.md（框架使用说明）" >&2
    exit 1
fi
cp "$ROOT/packages/ams-kit/README.md" "$STAGE/README.md"

printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# ---- MANIFEST + CHECKSUMS（UTF-8 显式写，避免 cp1252） ----
"$PY" - "$STAGE" "$VERSION" "$PLATFORM" "$BUILD_DIR" "$ROOT/.tmp/kit-closure.txt" <<'PYEOF'
import hashlib, os, sys, pathlib, datetime
stage = pathlib.Path(sys.argv[1])
version, platform, build_dir, closure_file = sys.argv[2:6]
closure = [l.strip() for l in pathlib.Path(closure_file).read_text(encoding='utf-8').splitlines() if l.strip()]

rows = []
for base, _dirs, files in os.walk(stage):
    for f in files:
        full = pathlib.Path(base) / f
        rel = full.relative_to(stage).as_posix()
        if rel in ('CHECKSUMS.sha256', 'MANIFEST.txt'):
            continue
        h = hashlib.sha256(full.read_bytes()).hexdigest()
        rows.append((rel, h, full.stat().st_size))
rows.sort()

with open(stage / 'CHECKSUMS.sha256', 'w', encoding='utf-8', newline='\n') as out:
    for rel, h, _sz in rows:
        out.write('%s *%s\n' % (h, rel))

with open(stage / 'MANIFEST.txt', 'w', encoding='utf-8', newline='\n') as out:
    out.write('AMS ams-kit framework distribution (architecture decision: Plan A)\n')
    out.write('version      : %s\n' % version)
    out.write('platform     : %s\n' % platform)
    out.write('build-dir    : %s\n' % build_dir)
    utc_now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    out.write('generated-utc: %sZ\n' % utc_now.isoformat())
    out.write('license      : Apache-2.0 (see LICENSE)\n')
    out.write('distribution : static libraries (.a) + Cangjie interface snapshots (.cjo)\n')
    out.write('NOTE         : cjpm.toml files are metadata only; NOT a cjpm package.\n')
    out.write('dependency-closure (%d):\n' % len(closure))
    for p in closure:
        out.write('  - %s\n' % p)
    out.write('\nfiles (%d):\n' % len(rows))
    for rel, h, sz in rows:
        out.write('  %-46s %8d  sha256=%s\n' % (rel, sz, h))
PYEOF

# ---- 压缩（与 package.sh 同款：优先 Python zipfile，Windows 友好） ----
mkdir -p "$OUT_DIR"
ZIP_PATH="${OUT_DIR}/${PKG_NAME}.zip"
rm -f "$ZIP_PATH" 2>/dev/null || true
"$PY" - "$OUT_DIR" "$PKG_NAME" "$ZIP_PATH" <<'PYEOF_ZIP'
import os, sys, zipfile
out_dir, pkg_name, zip_path = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(out_dir, pkg_name)
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for base, _dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(base, f)
            z.write(full, os.path.relpath(full, out_dir))
PYEOF_ZIP

echo "=== 打包完成 ==="
echo "  目录 : $STAGE"
echo "  压缩 : $ZIP_PATH"
echo "  大小 : $(du -h "$ZIP_PATH" | cut -f1)"
echo ""
echo "发布到 GitHub Release："
echo "  gh release upload <tag> ${ZIP_PATH}"
echo ""
echo "接入方用法见包内 README.md；本包不是 cjpm 包，勿执行 cjpm build / cjpm publish。"
