#!/usr/bin/env bash
# =================================================================
#  AMS · 真实样本媒体/OCR 能力实测 harness（离线、纯内存、不落库）
# =================================================================
#  用与 scripts/test.sh 相同的 cjc 环境，把 harness 编译成独立可执行，
#  按 bash 生成的文件清单逐个读取字节 → 调用真实 ams.core.media.MediaEngine.process。
#
#  为什么由 bash 列清单：本工具链 std.fs 只稳定提供 File.readFrom /
#  File.writeTo / Directory.create，没有 readDir（见 ams-storage/storage.cj 头注释）。
#
#  隐私红线（最严格口径）：
#   · 原件只读；测试副本只在 .tmp/（已被 git 忽略）
#   · 不连数据库、不发网络请求、不写任何识别正文到 stdout/文件
#   · stdout 只输出聚合指标：序号、格式、状态、字符数、引擎类别、耗时
#   · 文件清单本身也只含序号化文件名（n0/n1/...），不含真实姓名
#
#  用法：bash scripts/ci/competitor-study/run_ams_media_harness.sh <样本目录>
# =================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
SAMPLES="${1:-$ROOT/.tmp/competitor-study/samples}"
WORK="$ROOT/.tmp/competitor-study"
HDIR="$WORK/harness"
mkdir -p "$HDIR"

# ---- 生成序号化副本 + 清单（副本名 n0/n1/...，不含真实姓名）----
STAGE="$WORK/ams-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
LIST="$HDIR/list.txt"
: > "$LIST"
n=0
while IFS= read -r -d '' f; do
    ext="${f##*.}"
    cp -f "$f" "$STAGE/n${n}.${ext}"
    echo "n${n}.${ext}" >> "$LIST"
    n=$((n+1))
done < <(find "$SAMPLES" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
echo "样本数: $n"

# ---- SDK 定位（与 test.sh 一致）----
win_path() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
msys_path() { cygpath -u "$1" 2>/dev/null || echo "$1"; }
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc.exe" ]; then
    if [ -f "$ROOT/tools/cangjie/bin/cjc.exe" ]; then CANGJIE_HOME="$ROOT/tools/cangjie"
    else CANGJIE_HOME="E:/Cangjie"; fi
fi
CJ_HOME_WIN="$(win_path "$CANGJIE_HOME")"
CJC="${CJ_HOME_WIN}/bin/cjc.exe"
STDX_DIR="$(win_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"
STDX_DIR_MSYS="$(msys_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"
BUILD_DIR="$ROOT/build"
RUNTIME_DIR="${CJ_HOME_WIN}/runtime/lib/windows_x86_64_cjnative"
[ -f "$CJC" ] || { echo "[ERROR] cjc 不可用: $CJC"; exit 1; }

# ---- 生成仓颉 harness（stdout 只含聚合指标）----
# 路径由 bash 注入源码，绕开本 SDK 不稳定的 std.process.getArguments()
STAGE_CJ="$(cygpath -m "$STAGE" | sed 's|\\|/|g')"
LIST_CJ="$(cygpath -m "$LIST" | sed 's|\\|/|g')"
cat > "$HDIR/Main.cj" <<CJEOF
package ams.core.media.harness

import std.fs.*
import std.collection.*
import ams.core.media.*

main(): Int64 {
    let stage = "${STAGE_CJ}"
    let listPath = "${LIST_CJ}"
    let listBytes = File.readFrom(listPath)
    let listText = String.fromUtf8(listBytes)
    let lines = listText.split("\n")
    var count: Int64 = 0
    for (ln in lines) {
        if (ln.size > 2) { count = count + 1 }
    }
    println("FILES=" + count.toString())
    var idx: Int64 = 0
    for (ln in lines) {
        if (ln.size <= 2) { continue }
        let name = ln.trimAscii()
        let path = stage + "/" + name
        var fmt = "unknown"; var status: Int64 = -1
        var chars: Int64 = 0; var engine = ""; var errLen: Int64 = 0
        try {
            let data = File.readFrom(path)
            fmt = MediaEngine.sniff(data)
            let r = MediaEngine.process(data, true, false, false, "")
            status = r.ocrStatus
            chars = Int64(r.ocrText.size)
            engine = r.ocrEngine
            errLen = Int64(r.error.size)
        } catch (e: Exception) {
            errLen = 999
        }
        // 只输出聚合指标；绝不输出 ocrText 内容 / 真实文件名
        let row = "ROW|" + idx.toString() + "|" + fmt + "|" + status.toString() + "|" + chars.toString()
        println(row + "|" + engine + "|" + errLen.toString())
        idx = idx + 1
    }
    return 0
}
CJEOF

# ---- 构造链接参数（与 test.sh ALL_LIBS 同构）----
ALL_LIBS=""
for a in "$BUILD_DIR"/lib*.a; do [ -f "$a" ] && ALL_LIBS="$ALL_LIBS $(win_path "$a")"; done
for a in "$BUILD_DIR/drv"/lib*.a; do [ -f "$a" ] && ALL_LIBS="$ALL_LIBS $(win_path "$a")"; done
STDX_ARGS="-L${STDX_DIR}"
for dll in "$STDX_DIR"/libstdx*.dll; do [ -f "$dll" ] && STDX_ARGS="$STDX_ARGS -l:$(basename "$dll")"; done

OUT="$HDIR/harness.exe"
[ -f "$OUT" ] && mv -f "$OUT" "$OUT.old" 2>/dev/null
echo "=== 编译 harness ==="
timeout 300 "$CJC" -O2 -p "$HDIR" \
    --import-path "$BUILD_DIR" --import-path "$STDX_DIR_MSYS" --import-path "$BUILD_DIR/drv" \
    -o "$OUT" --link-options "$ALL_LIBS $STDX_ARGS" > "$HDIR/compile.log" 2>&1
if [ ! -f "$OUT" ]; then
    echo "[FAIL] harness 编译失败："; grep -E "error|Error" "$HDIR/compile.log" | head -12; exit 1
fi
echo "[OK] harness 编译成功"

cp -f "$RUNTIME_DIR"/*.dll "$HDIR/" 2>/dev/null || true
cp -f "$STDX_DIR"/*.dll "$HDIR/" 2>/dev/null || true
cp -f "$BUILD_DIR"/*.dll "$HDIR/" 2>/dev/null || true

echo
echo "=== 运行（真实 ams.core.media，纯内存、不落库）==="
(cd "$HDIR" && ./harness.exe "$(cygpath -m "$STAGE")" "$(cygpath -m "$LIST")")
RC=$?
# 最严格隐私口径：harness 用的序号化副本与编译产物用毕即删，
# 只保留脚本本身（可复现）与用户查看的聚合报告。
rm -rf "$STAGE" "$HDIR"
echo "HARNESS_RC=$RC (临时副本与编译产物已清理)"
exit $RC
