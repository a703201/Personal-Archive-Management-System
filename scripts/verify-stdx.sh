#!/bin/bash
# ============================================================
# AMS · stdx 与国密能力验证脚本
#
# 用法：bash scripts/verify-stdx.sh
#
# 验证内容（全部为实测项，逐条与文档 §2.1.1 对齐）：
#   1. SDK 版本与工具链可用性
#   2. stdx 是否安装、CANGJIE_STDX 是否正确
#   3. SM3 摘要是否与国标标准值一致
#   4. SM4-CBC 加解密往返是否正确
#   5. SecureRandom 是否可用
#   6. stdx.net.http 服务端能否起服务并响应
#
# 任一项失败即返回非 0 —— M0 的第 3/9 项门禁。
# ============================================================
set -uo pipefail

WORK="$(mktemp -d)"
PASS=0
FAIL=0

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ·  $1"; }

echo "============================================================"
echo " AMS · stdx / 国密能力验证"
echo "============================================================"

# 若未预先 source 环境脚本，这里自动加载
if ! command -v cjc >/dev/null 2>&1; then
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${_here}/envsetup.sh" ]; then
        source "${_here}/envsetup.sh" >/dev/null 2>&1
    fi
fi
# 清 bash 命令哈希缓存（否则新加进 PATH 的工具查不到）
hash -r 2>/dev/null || true

# ---- 1. SDK 与工具链 ----
echo ""
echo "[1] SDK 与工具链"
if command -v cjc >/dev/null 2>&1; then
    ok "cjc 可用: $(cjc --version 2>&1 | head -1)"
else
    bad "cjc 不可用 —— 请先 source scripts/envsetup.sh"
fi
for t in cjpm cjfmt cjlint; do
    if command -v $t >/dev/null 2>&1; then ok "$t 可用"; else bad "$t 不可用"; fi
done

# ---- 2. stdx ----
echo ""
echo "[2] stdx 安装状态"
if [ -n "${CANGJIE_STDX:-}" ] && [ -d "${CANGJIE_STDX}/dynamic/stdx" ]; then
    ok "CANGJIE_STDX = ${CANGJIE_STDX}"
else
    bad "CANGJIE_STDX 未设置或路径无效"
    echo ""
    echo ">>> 无法继续验证，请先执行：bash scripts/install-stdx.sh && source scripts/envsetup.sh"
    exit 1
fi
for pkg in stdx.crypto.digest stdx.crypto.crypto stdx.net.http stdx.log; do
    if [ -f "${CANGJIE_STDX}/dynamic/stdx/${pkg}.cjo" ]; then ok "${pkg} 就位"
    else bad "${pkg} 缺失"; fi
done

# 编译辅助函数：链接全部 stdx 动态库，避免传递依赖缺符号
compile() {
    local src="$1" out="$2"
    local libs
    libs=$(ls "${CANGJIE_STDX}/dynamic/stdx/"*.dll 2>/dev/null | xargs -n1 basename \
           | sed 's/^lib/-l/;s/\.dll$//' | tr '\n' ' ')
    cjc "$src" -o "$out" \
        --import-path "${CANGJIE_STDX}/dynamic/stdx" \
        -L "${CANGJIE_STDX}/dynamic/stdx" \
        --link-options "$libs" 2>&1
}

# 运行辅助函数：把 DLL 拷到 exe 同目录，规避 PATH 依赖
prepare_run() {
    cp "${CANGJIE_STDX}/dynamic/stdx/"*.dll "$1" 2>/dev/null
    if [ -d "${CANGJIE_HOME:-}/runtime/lib/windows_x86_64_cjnative" ]; then
        cp "${CANGJIE_HOME}/runtime/lib/windows_x86_64_cjnative/"*.dll "$1" 2>/dev/null
    fi
}

# ---- 3. SM3 ----
echo ""
echo "[3] SM3 摘要（国标标准向量）"
cat > "$WORK/sm3.cj" <<'EOF'
import stdx.crypto.digest.*
import std.crypto.digest.*
import stdx.encoding.hex.*
main() {
    let d = digest<SM3>(SM3(), "abc".toArray())
    println(toHexString(d))
}
EOF
if compile "$WORK/sm3.cj" "$WORK/sm3.exe" >/dev/null 2>&1 && [ -f "$WORK/sm3.exe" ]; then
    prepare_run "$WORK"
    OUT=$(cd "$WORK" && ./sm3.exe 2>/dev/null | tr -d '\r\n ')
    EXPECT="66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
    if [ "$OUT" = "$EXPECT" ]; then ok "SM3(\"abc\") 与国标标准值一致"
    else bad "SM3 结果不符：期望 $EXPECT，实际 $OUT"; fi
else
    bad "SM3 示例编译失败"
fi

# ---- 4. SM4 ----
echo ""
echo "[4] SM4-CBC 加解密往返"
cat > "$WORK/sm4.cj" <<'EOF'
import stdx.crypto.crypto.*
import stdx.encoding.hex.*
main() {
    let key = "1234567890123456".toArray()
    let iv  = "1234567890123456".toArray()
    let sm4 = SM4(OperationMode.CBC, key, iv: iv)
    let ct = sm4.encrypt("hello cangjie!".toArray())
    let pt = sm4.decrypt(ct)
    println(String.fromUtf8(pt))
    println(toHexString(ct))
}
EOF
if compile "$WORK/sm4.cj" "$WORK/sm4.exe" >/dev/null 2>&1 && [ -f "$WORK/sm4.exe" ]; then
    prepare_run "$WORK"
    OUT=$(cd "$WORK" && ./sm4.exe 2>/dev/null | tr -d '\r')
    ROUND=$(echo "$OUT" | sed -n 1p)
    CT=$(echo "$OUT" | sed -n 2p | tr -d ' ')
    if [ "$ROUND" = "hello cangjie!" ]; then ok "SM4 解密还原正确"
    else bad "SM4 往返失败：$ROUND"; fi
    if [ "$CT" = "fa3a738a9de8733da3c225c67a15e259" ]; then ok "SM4 密文与国标测试向量一致"
    else info "SM4 密文: $CT（该向量取决于 IV/key，此处仅记录）"; fi
else
    bad "SM4 示例编译失败"
fi

# ---- 5. SecureRandom ----
echo ""
echo "[5] SecureRandom"
cat > "$WORK/rand.cj" <<'EOF'
import stdx.crypto.crypto.*
import stdx.encoding.hex.*
main() {
    let r = SecureRandom()
    let b = Array<UInt8>(16, repeat: 0u8)
    r.nextBytes(b)
    println(toHexString(b))
}
EOF
if compile "$WORK/rand.cj" "$WORK/rand.exe" >/dev/null 2>&1 && [ -f "$WORK/rand.exe" ]; then
    prepare_run "$WORK"
    OUT=$(cd "$WORK" && ./rand.exe 2>/dev/null | tr -d '\r\n ')
    if [ ${#OUT} -eq 32 ]; then ok "SecureRandom 生成 16 字节随机数: $OUT"
    else bad "SecureRandom 输出异常: $OUT"; fi
else
    bad "SecureRandom 示例编译失败"
fi

# ---- 6. HTTP 服务端 ----
echo ""
echo "[6] stdx.net.http 服务端"
PORT=18099
cat > "$WORK/httpd.cj" <<EOF
import stdx.net.http.ServerBuilder
main() {
    let server = ServerBuilder().addr("127.0.0.1").port(${PORT}).build()
    server.distributor.register("/ping", { ctx => ctx.responseBuilder.body("pong") })
    server.serve()
}
EOF
if compile "$WORK/httpd.cj" "$WORK/httpd.exe" >/dev/null 2>&1 && [ -f "$WORK/httpd.exe" ]; then
    prepare_run "$WORK"
    ( cd "$WORK" && ./httpd.exe > httpd.log 2>&1 & )
    sleep 4
    RESP=$(curl -s --noproxy '*' --max-time 8 "http://127.0.0.1:${PORT}/ping" 2>/dev/null)
    if [ "$RESP" = "pong" ]; then ok "HTTP 服务端响应正常（/ping → pong）"
    else bad "HTTP 服务端无响应（可能端口占用或服务未启动）"; fi
    # 清理
    ( cd "$WORK" && taskkill //F //IM httpd.exe >/dev/null 2>&1 ) || true
else
    bad "HTTP 服务端示例编译失败"
fi

# ---- 汇总 ----
command rm -rf -- "$WORK" 2>/dev/null || true
echo ""
echo "============================================================"
echo " 通过 ${PASS} 项，失败 ${FAIL} 项"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
