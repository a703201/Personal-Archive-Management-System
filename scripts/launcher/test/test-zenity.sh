#!/usr/bin/env bash
# =================================================================
#  AMS · 启动器 Linux zenity 桌面 GUI 实测（容器内，Xvfb 虚拟显示）
# =================================================================
#  被测对象：/opt/ams/scripts/launcher/AMS-Launcher.sh（宿主机挂载）
#  目标：在真实 Linux 内核 + 真实 zenity 上，验证
#    1) GUI 自适应检测（有 DISPLAY+zenity → "zenity"；无 DISPLAY → 文本）
#    2) 真实 zenity 对话框渲染（信息框 / 是-否 / 输入框 / 隐藏口令）
#    3) 对话框交互返回码与取值正确（xdotool 真实驱动）
#    4) 完整 zenity 列表菜单渲染并正常退出
#    5) headless 容器（无 DISPLAY）自动降级为文本菜单且不崩溃
#    6) preflight / cfg_set 失败关闭语义（文本层，确定性）
#    7) shellcheck 静态门禁
#  产物：/out/result.log + /out/zenity_*.png（真实渲染物证）
# =================================================================
set -uo pipefail

LAUNCHER="/opt/ams/scripts/launcher/AMS-Launcher.sh"
OUT="${OUT_DIR:-/tmp/ams-gui-test}"
mkdir -p "$OUT"
RESULT="$OUT/result.log"
: > "$RESULT"

PASS_C=0; FAIL_C=0
pass(){ echo "PASS: $1" | tee -a "$RESULT"; PASS_C=$((PASS_C+1)); }
fail(){ echo "FAIL: $1" | tee -a "$RESULT"; FAIL_C=$((FAIL_C+1)); }
info(){ echo "INFO: $1" | tee -a "$RESULT"; }

# ---- 启动虚拟显示器 ----
if [ -n "${DISPLAY:-}" ]; then
    info "启动 Xvfb ${DISPLAY} ..."
    Xvfb "${DISPLAY}" -screen 0 1280x1024x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 1 50); do
        [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] && break
        sleep 0.1
    done
fi

zenity_wid(){
    local i wid
    for i in $(seq 1 80); do
        wid="$(xdotool search --class Zenity 2>/dev/null | head -1)"
        [ -n "$wid" ] && { printf '%s' "$wid"; return 0; }
        sleep 0.2
    done
    return 1
}

# drive <标签> <策略> <函数> [参数...]
# 策略: info | yes | no | entry | secret
drive(){
    local tag="$1" strat="$2" fn="$3"; shift 3
    local out rcfile rc pid wid
    out="$(mktemp)"; rcfile="$(mktemp)"
    ( "$fn" "$@" >"$out" 2>&1; echo $? >"$rcfile" ) &
    pid=$!
    if ! wid="$(zenity_wid)"; then
        fail "$tag: zenity 窗口未出现（GUI 路径未真正渲染）"
        kill "$pid" 2>/dev/null || true
        return 1
    fi
    sleep 0.4
    scrot -u -f "$OUT/zenity_${tag}.png" 2>/dev/null || info "$tag: 截屏失败（scrot 不可用，不影响判定）"
    case "$strat" in
        yes)    xdotool windowactivate --sync "$wid" key Return ;;          # 默认聚焦「是」
        no)     xdotool windowactivate --sync "$wid" key Escape ;;          # 取消 == 否
        entry|secret) xdotool windowactivate --sync "$wid" key ctrl+a;       # 全选默认文本
                        xdotool type --delay 15 "TYPED_VALUE_123"; xdotool key Return ;;
        info)   xdotool windowactivate --sync "$wid" key Return ;;          # 关闭信息框
    esac
    wait "$pid"; rc="$(cat "$rcfile")"
    echo "  [${tag}] rc=${rc} out=[$(cat "$out")]" | tee -a "$RESULT"
    eval "AMS_DLG_${tag}_RC=$rc"
    eval "AMS_DLG_${tag}_OUT=$(printf '%q' "$(cat "$out")")"
}

echo "================ AMS 启动器 zenity GUI 实测 ================"
info "zenity 版本: $(zenity --version 2>&1)"
info "DISPLAY=${DISPLAY:-<unset>}"

# ---- 0) GUI 检测（两个形态）----
GUI_ZENITY="$(DISPLAY=:99 bash -c 'source "'"$LAUNCHER"'" >/dev/null 2>&1; echo "$GUI"')"
[ "$GUI_ZENITY" = "zenity" ] && pass "GUI 检测: 有 DISPLAY+zenity → \"$GUI_ZENITY\"" || fail "GUI 检测: 期望 zenity，实得 \"$GUI_ZENITY\""

GUI_TEXT="$(env -u DISPLAY -u WAYLAND_DISPLAY bash -c 'source "'"$LAUNCHER"'" >/dev/null 2>&1; echo "$GUI"')"
[ -z "$GUI_TEXT" ] && pass "GUI 检测: 无 DISPLAY → 空（文本模式）" || fail "GUI 检测: 无 DISPLAY 仍选 GUI=\"$GUI_TEXT\""

# ---- 1) 失败关闭（文本层，确定性，不依赖显示）----
SB="$(mktemp -d)"
printf 'AMS_HTTP_PORT=8080\n' > "$SB/config.env"
# 覆盖路径全局，避免触碰只读挂载的 /opt/ams
CONFIG="$SB/config.env"; START_SH="$SB/start.sh"; SERVER_BIN="$SB/bin"; WEB_INDEX="$SB/web"; DEPLOY_ENV="$SB/deploy.env"
touch "$START_SH" "$SERVER_BIN" "$WEB_INDEX"
export CONFIG START_SH SERVER_BIN WEB_INDEX DEPLOY_ENV
iss="$(preflight)"
echo "$iss" | grep -q 'AMS_TOKEN_SECRET 未显式配置' && pass "preflight: 缺 TOKEN_SECRET 被识别" || fail "preflight: 未识别缺 TOKEN_SECRET"
echo "$iss" | grep -q 'AMS_KEK 未显式配置'        && pass "preflight: 缺 KEK 被识别"        || fail "preflight: 未识别缺 KEK"
echo "$iss" | grep -q 'AMS_DB_PASSWORD 未显式配置' && pass "preflight: 缺 DB_PASSWORD 被识别" || fail "preflight: 未识别缺 DB_PASSWORD"
# 补齐三密钥
cfg_set AMS_TOKEN_SECRET "$(printf 'A%.0s' $(seq 1 40))"
cfg_set AMS_KEK          "$(printf 'B%.0s' $(seq 1 40))"
cfg_set AMS_DB_PASSWORD  "dbpass"
iss2="$(preflight)"
[ -z "$iss2" ] && pass "preflight: 补齐三密钥后 0 问题" || fail "preflight: 补齐后仍存在问题 -> $iss2"
grep -q '^AMS_TOKEN_SECRET=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA$' "$CONFIG" \
    && pass "cfg_set: 键值独占一行、值与键同行" || fail "cfg_set: 写盘格式异常"
# 短令牌应被预检拦截（>=32 字节）
cfg_set AMS_TOKEN_SECRET "short"
printf '%s' "$(preflight)" | grep -q '只有 5 字节' \
    && pass "preflight: 短令牌(5B)被拦截" || { cfg_set AMS_TOKEN_SECRET "$(printf 'A%.0s' $(seq 1 40))"; fail "preflight: 短令牌未被拦截"; }

# ---- 2) 真实 zenity 渲染 + 交互（需显示）----
if [ -n "${DISPLAY:-}" ]; then
    export DISPLAY
    set +u   # 放宽未绑定变量检查，便于驱动测试
    source "$LAUNCHER" >/dev/null 2>&1   # GUI 已在此环境求值为 zenity
    [ "$GUI" = "zenity" ] && pass "source: 当前环境 GUI=$GUI，进入图形驱动" || fail "source: GUI=$GUI 非 zenity"

    drive "info"   info   msg_info   "AMS GUI 实测：zenity 信息框渲染正常"
    drive "yesno_yes" yes ask_yesno  "请点「是」以验证 Yes 返回 0"
    [ "${AMS_DLG_yesno_yes_RC:-1}" = "0" ] && pass "ask_yesno(是): 返回 0" || fail "ask_yesno(是): 期望 0，实得 ${AMS_DLG_yesno_yes_RC:-?}"
    drive "yesno_no"  no  ask_yesno  "请点「否 / 取消」以验证 No 返回 1"
    [ "${AMS_DLG_yesno_no_RC:-0}" = "1" ] && pass "ask_yesno(否): 返回 1" || fail "ask_yesno(否): 期望 1，实得 ${AMS_DLG_yesno_no_RC:-?}"
    drive "entry"  entry  prompt_value "输入测试（清掉默认后输入）" "默认值"
    [ "${AMS_DLG_entry_OUT:-}" = "TYPED_VALUE_123" ] && pass "prompt_value: 取值正确" || fail "prompt_value: 期望 TYPED_VALUE_123，实得 [${AMS_DLG_entry_OUT:-}]"
    drive "secret" secret prompt_secret "口令测试（隐藏输入）"
    [ "${AMS_DLG_secret_OUT:-}" = "TYPED_VALUE_123" ] && pass "prompt_secret: 取值正确(隐藏生效)" || fail "prompt_secret: 期望 TYPED_VALUE_123，实得 [${AMS_DLG_secret_OUT:-}]"

    # 完整 zenity 列表菜单渲染
    ( DISPLAY=:99 "$LAUNCHER" >/tmp/menu.log 2>&1 ) &
    MPID=$!
    if wid="$(zenity_wid)"; then
        sleep 0.4
        scrot -u -f "$OUT/zenity_menu.png" 2>/dev/null || info "menu: 截屏失败"
        xdotool windowactivate --sync "$wid" key Escape   # 取消列表 -> 循环退出
        for _ in $(seq 1 50); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.2; done
        if kill -0 "$MPID" 2>/dev/null; then fail "menu: 进程未退出"; kill "$MPID" 2>/dev/null || true
        else pass "menu: zenity 列表菜单真实渲染并正常退出"; fi
    else
        fail "menu: 未出现 zenity 列表窗口"
        kill "$MPID" 2>/dev/null || true
    fi
    set -u
else
    info "无 DISPLAY，跳过 zenity 渲染驱动（应在 headless 阶段用另一形态覆盖）"
fi

# ---- 3) headless 容器形态：无 DISPLAY 自动降级文本菜单 ----
( env -u DISPLAY -u WAYLAND_DISPLAY bash -c 'printf "0\n" | "'"$LAUNCHER"'"' ) >/tmp/headless.log 2>&1
HRC=$?
grep -q '已退出启动器' /tmp/headless.log \
    && pass "headless: 无 DISPLAY 自动进入文本菜单并正常退出(rc=$HRC)" \
    || fail "headless: 文本菜单异常 (rc=$HRC) -> $(head -3 /tmp/headless.log)"

# ---- 4) 静态门禁 ----
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$LAUNCHER" >/tmp/sc.log 2>&1; then
        pass "shellcheck: 无 warning/error"
    else
        fail "shellcheck: 有问题"; tee -a "$RESULT" < /tmp/sc.log >/dev/null
    fi
else
    info "shellcheck 未安装，跳过（宿主机可另跑）"
fi

# ---- 收尾 ----
[ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
echo "----------------------------------------------------------" | tee -a "$RESULT"
echo "结果: PASS=$PASS_C FAIL=$FAIL_C" | tee -a "$RESULT"
echo "产物: $OUT (result.log + zenity_*.png)" | tee -a "$RESULT"
[ "$FAIL_C" -eq 0 ]
