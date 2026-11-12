#!/bin/bash
# ============================================================
# AMS · ams-kit 发布包接入验证（方案 A 的持续验收闸门）
#
# 目的：模拟**外部接入方**——只拿发布包里的 `.cjo` 与 `.a`，
# 不引用仓库 `build/` 下任何其它产物，编译链接并运行一个最小程序。
# 若能跑通，即证明：
#   ① 依赖闭包完整（无缺失符号）；
#   ② 接口快照 .cjo 可被 cjc 直接消费；
#   ③ 静态库确实可用，不只是「文件存在」。
#
# 用法：
#   bash scripts/ci/verify-kit-package.sh [包目录]
#   默认包目录：dist/ams-kit-<KIT_VERSION>-windows-x86_64
#
# 退出码：0=编译+运行+断言全通过；非 0=失败（日志见 /tmp/ams_kit_verify.log）
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PKG_DIR="${1:-}"
if [ -z "$PKG_DIR" ]; then
    KIT_VERSION="$(grep -oE 'public let KIT_VERSION: String = "[^"]+"' \
        "$ROOT/packages/ams-kit/src/kit.cj" | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/')"
    PKG_DIR="dist/ams-kit-${KIT_VERSION}-windows-x86_64"
fi
if [ ! -d "$PKG_DIR/cjo" ] || [ ! -d "$PKG_DIR/lib" ]; then
    echo "[ERROR] 包目录不完整（缺 cjo/ 或 lib/）: $PKG_DIR" >&2
    echo "        先跑：bash scripts/package-kit.sh" >&2
    exit 2
fi

# ---- SDK 定位（与 build.sh / test.sh 同款探测）----
CANGJIE_HOME="${CANGJIE_HOME:-E:/Cangjie}"
CJC="${CANGJIE_HOME}/bin/cjc.exe"
STDX_WIN="${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}/dynamic/stdx"
if [ ! -f "$CJC" ] || [ ! -d "$STDX_WIN" ]; then
    echo "[ERROR] 找不到仓颉 SDK 或 stdx：CJC=$CJC STDX=$STDX_WIN" >&2
    exit 2
fi

win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
msys_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else echo "$1"; fi; }

PKG_WIN="$(win_path "$ROOT/$PKG_DIR")"
PKG_MSYS="$(msys_path "$PKG_WIN")"
STDX_MSYS="$(msys_path "$STDX_WIN")"

WORK="$ROOT/.tmp/kit-verify"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
LOG=/tmp/ams_kit_verify.log

# ---- 消费者源码：只 import 发布包暴露的 ams.kit + 其公开依赖 ----
cat > "$WORK/main.cj" <<'CJEOF'
package kitconsumer

import std.collection.*
import ams.kit.*
import ams.crypto.provider.*

main(): Int64 {
    let p = newCryptoProvider()
    let toks = tokenizeForSearch("档案管理系统")
    let seg = highlightJson("清华大学硕士学位证书", "硕士")
    let mask = maskValue("市公安局", 2)
    let mapping = HashMap<String, String>()
    mapping["姓名"] = "title"
    let tpl = CsvColumnTemplate(["姓名"], mapping, HashMap<String, String>())
    let chain = newAuditChain(p)
    let genesis = auditGenesisHash()
    match (p.digest("abc".toArray(), DigestAlgorithm.Sm3)) {
        case CryptoResult.Ok(d) => println("SM3_BYTES=${d.size}")
        case CryptoResult.Err(_) => println("SM3_BYTES=0")
    }
    println("KIT_VERSION=${KIT_VERSION}")
    println("TOKENS=${toks.size}")
    println("HIGHLIGHT_LEN=${seg.size}")
    println("MASK_LEN=${mask.size}")
    println("TPL_HAS_TITLE=${tpl.hasField("title")}")
    println("GENESIS=${genesis.size}")
    return 0
}
CJEOF

# ---- 运行时 DLL 与 exe 同目录（test.sh 同款：否则 exe 静默退出）----
cp "$STDX_WIN"/*.dll "$WORK/" 2>/dev/null || true
RUNTIME_DIR="${CANGJIE_HOME}/runtime/lib/windows_x86_64_cjnative"
[ -d "$RUNTIME_DIR" ] && cp "$RUNTIME_DIR"/*.dll "$WORK/" 2>/dev/null || true

# ---- 链接参数：包内全部 .a（用 group 让 lld 自行解析相互依赖）----
LIBS=""
for a in "$PKG_DIR"/lib/*.a; do
    [ -f "$a" ] && LIBS="$LIBS $(win_path "$ROOT/$a")"
done
STDX_LIBS="-L${STDX_WIN}"
for d in "$STDX_WIN"/libstdx*.dll; do
    [ -f "$d" ] && STDX_LIBS="$STDX_LIBS -l:$(basename "$d")"
done

echo "=== 外部消费者编译链接 ===" | tee "$LOG"
echo "  包   : $PKG_WIN" | tee -a "$LOG"
echo "  库数 : $(echo "$LIBS" | wc -w)" | tee -a "$LOG"

"$CJC" -O2 "$WORK/main.cj" \
    --import-path "${PKG_MSYS}/cjo" \
    --import-path "${STDX_MSYS}" \
    --output-type exe \
    -o "$WORK/kit_consumer.exe" \
    --link-options "--start-group ${LIBS} --end-group ${STDX_LIBS}" \
    >> "$LOG" 2>&1
LINK_RC=$?
if [ "$LINK_RC" -ne 0 ] || [ ! -f "$WORK/kit_consumer.exe" ]; then
    echo "[FAILED] 编译链接失败 (rc=$LINK_RC)，日志末尾：" >&2
    tail -25 "$LOG" >&2
    exit 1
fi

# ---- 运行并断言 ----
OUTPUT="$(cd "$WORK" && ./kit_consumer.exe 2>&1)"
RUN_RC=$?
echo "$OUTPUT" | tee -a "$LOG"
echo "RUN_RC=$RUN_RC" | tee -a "$LOG"

FAIL=0
check() {
    if ! echo "$OUTPUT" | grep -qF "$1"; then
        echo "[FAILED] 缺少期望输出: $1" >&2
        FAIL=1
    fi
}
check "KIT_VERSION=0.1.0-alpha"
check "SM3_BYTES=32"
check "GENESIS=32"
check "TPL_HAS_TITLE=true"
check "HIGHLIGHT_LEN="
if ! echo "$OUTPUT" | grep -qE '^TOKENS=[1-9][0-9]*$'; then
    echo "[FAILED] 分词返回 0 个 token" >&2
    FAIL=1
fi
if [ "$RUN_RC" -ne 0 ]; then
    echo "[FAILED] 消费者程序非零退出" >&2
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo ""
echo "[OK] 发布包接入验证通过：依赖闭包完整、.cjo 可用、静态库可链接、SM3 真跑通。"
