#!/usr/bin/env bash
# =================================================================
#  AMS · 桌面启动器（Linux / macOS）
# =================================================================
#  与 Windows 版共用同一套「失败关闭契约」，见 docs/17 §3.2.3 方案 A：
#    R1 绝不生成/兜底密钥（生成必须显式选择 + 显式落盘 + 备份提示）
#    R2 预检只是提前告知，权威仍是 scripts/start.sh 与 main.cj SEC-001
#    R3 不吞退出码、不自动重启、不静默降级
#    R4 /api/health 只是 liveness，不等于「安全就绪」
#    R5 密钥不进日志 / 明文常驻
#    R6 不改写启动参数、不自动换端口
#    R7 不创建管理员、不改 deployment.env、不碰 /setup
#
#  零新增依赖：只用 bash / coreutils / curl / openssl(可选) / flock。
#  有桌面且存在 zenity 或 yad 时用图形对话框，否则自动退化为文本向导
#  （headless 服务器同样可用）。不引入 JVM、.NET、Python 运行时。
#  行尾必须为 LF、无 BOM。
# =================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="$ROOT/config/application.env"
DEPLOY_ENV="$ROOT/config/deployment.env"
START_SH="$ROOT/scripts/start.sh"
SERVER_BIN="$ROOT/bin/ams-server"
WEB_INDEX="$ROOT/web/index.html"
LOG_DIR="$ROOT/logs"
SERVICE_LOG="$LOG_DIR/ams-server-$(date +%Y%m%d).log"
SELF_LOG="$LOG_DIR/ams-launcher-$(date +%Y%m%d).log"
PID_FILE="$LOG_DIR/ams-server.pid"
LOCK_FILE="$LOG_DIR/ams-launcher.lock"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# ---- 单实例保护 ----
# 先探测 flock 是否支持继承 fd：MSYS/Git Bash 的移植版 flock 会报
# "flock: 9: Bad file descriptor" (rc=65)，此时降级为「无单实例保护」并记日志，
# 绝不能误判成「已有实例在跑」而拒绝启动。真实 Linux 上走标准 fd 锁。
SINGLE_INSTANCE=0
if command -v flock >/dev/null 2>&1; then
    PROBE_LOCK="$(mktemp "${TMPDIR:-/tmp}/ams-flock-probe.XXXXXX" 2>/dev/null || true)"
    if [ -n "$PROBE_LOCK" ]; then
        if ( exec 9>"$PROBE_LOCK"; flock -n 9 ) 2>/dev/null; then
            SINGLE_INSTANCE=1
        fi
        rm -f "$PROBE_LOCK"
    fi
fi
if [ "$SINGLE_INSTANCE" = "1" ]; then
    if exec 9>"$LOCK_FILE" 2>/dev/null; then
        if ! flock -n 9 2>/dev/null; then
            echo "[ERROR] AMS 启动器已在运行（单实例保护）。"
            exit 1
        fi
    else
        SINGLE_INSTANCE=0
    fi
fi

# ---- 脱敏（与 deployment.cj 的 SECRET_KEYS 对齐）----
redact() {
    sed -E 's/(TOKEN_SECRET|KEK|DB_PASSWORD|DB_APP_PASSWORD|MAIL_PASSWORD|S3_SECRET_KEY|S3_ACCESS_KEY|EXPORT_SIGN_KEY|PASSWORD|SECRET|ACCESS_KEY)([[:space:]]*[:=][[:space:]]*)[^ ,;"}]+/\1\2***/Ig'
}

log() { printf '[%s] [launcher] %s\n' "$(date '+%F %T')" "$(printf '%s' "$1" | redact)" >> "$SELF_LOG"; }

# ---- 图形 / 文本自适应 ----
GUI=""
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    if command -v zenity >/dev/null 2>&1;   then GUI="zenity"; fi
    if command -v yad >/dev/null 2>&1 && [ -z "$GUI" ]; then GUI="yad"; fi
fi

msg_info() {
    if [ "$GUI" = "zenity" ];  then zenity --info --title="AMS" --text="$1" >/dev/null 2>&1
    elif [ "$GUI" = "yad" ];   then yad --info --title="AMS" --text="$1" >/dev/null 2>&1
    else printf '[INFO] %s\n' "$1"; fi
}
msg_error() {
    if [ "$GUI" = "zenity" ];  then zenity --error --title="AMS" --text="$1" >/dev/null 2>&1
    elif [ "$GUI" = "yad" ];   then yad --error --title="AMS" --text="$1" >/dev/null 2>&1
    else printf '[ERROR] %s\n' "$1" >&2; fi
}
ask_yesno() {
    if [ "$GUI" = "zenity" ]; then zenity --question --title="AMS" --text="$1" >/dev/null 2>&1; return $?
    elif [ "$GUI" = "yad" ];  then yad --question --title="AMS" --text="$1" >/dev/null 2>&1; return $?
    else read -r -p "$1 [y/N] " _a; [ "${_a,,}" = "y" ] || [ "${_a,,}" = "yes" ]; fi
}
prompt_value() {
    local label="$1" def="${2:-}" out=""
    if [ "$GUI" = "zenity" ]; then
        out="$(zenity --entry --title="AMS" --text="$label" --entry-text="$def" 2>/dev/null)" || return 1
    elif [ "$GUI" = "yad" ]; then
        out="$(yad --entry --title="AMS" --text="$label" --entry-text="$def" 2>/dev/null)" || return 1
    else
        read -r -p "$label [$def]: " out; out="${out:-$def}"
    fi
    printf '%s' "$out"
}
prompt_secret() {
    local label="$1" out=""
    if [ "$GUI" = "zenity" ]; then
        out="$(zenity --entry --title="AMS" --text="$label" --hide-text 2>/dev/null)" || return 1
    elif [ "$GUI" = "yad" ]; then
        out="$(yad --entry --title="AMS" --text="$label" --hide-text 2>/dev/null)" || return 1
    else
        # 终端（tty）下用 -s 隐藏输入；非 tty（管道 / 脚本化 / 自动化测试）
        # 下 read -s 在部分移植环境会错位吞行，故退回普通 read。
        # 注意：read -s 后的换行必须写 stderr，否则会被 $(...) 捕获进返回值，
        # 导致 config 里出现 KEY=<换行>VALUE。
        if [ -t 0 ]; then
            read -r -s -p "$label: " out; echo >&2
        else
            read -r -p "$label: " out
        fi
    fi
    printf '%s' "$out"
}

# ---- 配置读写（只碰 config/application.env）----
cfg_get() {
    [ -f "$CONFIG" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" | tail -1
}
cfg_set() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp "${CONFIG}.XXXXXX")" || return 1
    [ -f "$CONFIG" ] || : > "$CONFIG"
    awk -v k="$key" -v v="$val" '
        BEGIN { found=0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"
}
get_port() { local p; p="$(cfg_get AMS_HTTP_PORT)"; [ -n "$p" ] && printf '%s' "$p" || printf '8080'; }

# ---- 探针 ----
health_ok()   { curl -fsS --max-time 2 "http://127.0.0.1:$(get_port)/api/health" >/dev/null 2>&1; }
root_html_ok(){ curl -fsS --max-time 2 "http://127.0.0.1:$(get_port)/" 2>/dev/null | grep -qi '<html\|id="app"'; }
port_free() {
    # bash 的 /dev/tcp 探测，零额外依赖；占用即视为不可用（绝不自动换端口）
    # 能连上 => 已被占用 => 不可用(1)；连不上 => 端口空闲 => 可用(0)
    if (exec 3<>"/dev/tcp/127.0.0.1/$(get_port)") 2>/dev/null; then
        return 1
    fi
    return 0
}
log_has_failure() {
    [ -f "$SERVICE_LOG" ] || return 1
    tail -200 "$SERVICE_LOG" 2>/dev/null | grep -qiE \
        '生产模式拒绝启动|至少需要 32 字节|拒绝以默认密钥启动|db\.unavailable|StorageFailure|缺少 config/application.env'
}
log_tail() {
    { [ -f "$SELF_LOG" ] && cat "$SELF_LOG"; [ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG"; } 2>/dev/null \
        | tail -60 | redact
}

# ---- 预检：只读，绝不补默认值 ----
preflight() {
    local issues=()
    [ -f "$CONFIG" ]     || issues+=("缺少 config/application.env（请从模板复制并填写）")
    [ -f "$START_SH" ]   || issues+=("缺少 scripts/start.sh（发布包不完整）")
    [ -f "$SERVER_BIN" ] || issues+=("缺少 bin/ams-server（发布包不完整）")
    [ -f "$WEB_INDEX" ]  || issues+=("缺少 web/index.html：前端页面将不可用")
    for k in AMS_TOKEN_SECRET AMS_KEK AMS_DB_PASSWORD; do
        [ -n "$(cfg_get "$k")" ] || issues+=("$k 未显式配置（启动器不会为你生成或兜底）")
    done
    local bytes; bytes="$(printf '%s' "$(cfg_get AMS_TOKEN_SECRET)" | wc -c)"
    if [ -n "$(cfg_get AMS_TOKEN_SECRET)" ] && [ "$bytes" -lt 32 ]; then
        issues+=("AMS_TOKEN_SECRET 只有 $bytes 字节，服务端要求 >= 32 字节")
    fi
    port_free || issues+=("端口 $(get_port) 已被占用（启动器不会自动改用其它端口）")
    [ -f "$DEPLOY_ENV" ] && issues+=("注意：config/deployment.env 已存在，其优先级高于 application.env")
    [ "${#issues[@]}" -eq 0 ] && return 0
    printf '%s\n' "${issues[@]}"
}

# ---- 启动：调用 start.sh（唯一权威入口），仅追加输出重定向 ----
start_service() {
    local issues blocking i
    mapfile -t issues < <(preflight)
    blocking=()
    for i in "${issues[@]}"; do
        case "$i" in
            注意：*|缺少\ web/*) ;;
            *) blocking+=("$i") ;;
        esac
    done
    if [ "${#blocking[@]}" -gt 0 ]; then
        local msg="预检未通过，未拉起任何进程："
        for i in "${blocking[@]}"; do msg="$msg
 - $i"; done
        msg_error "$msg"
        log "预检失败，拒绝启动：${blocking[*]}"
        return 1
    fi
    if [ "${#issues[@]}" -gt 0 ]; then msg_info "非阻断提示：${issues[*]}"; fi

    # start.sh 以 exec 结尾，故记录的是服务进程自身 PID
    nohup bash "$START_SH" >> "$SERVICE_LOG" 2>&1 &
    echo $! > "$PID_FILE"
    # 让服务进程在启动器退出（选 0）后继续存活：脱离当前 shell 的作业表，
    # 避免 bash 退出时向它发 SIGHUP。disown 在关闭作业控制时可能报错，忽略即可。
    disown 2>/dev/null || true
    log "已调用 scripts/start.sh（PID=$!），等待就绪"
    msg_info "服务已启动（PID=$!）。可用「查看状态」确认 /api/health。"
    return 0
}

stop_service() {
    [ -f "$PID_FILE" ] || { msg_info "服务未启动。"; return 0; }
    local pid; pid="$(cat "$PID_FILE")"
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$PID_FILE"; msg_info "服务已不在运行。"; return 0; fi

    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        # 显式标记为强制终止，绝不伪装成正常停止
        kill -KILL "$pid" 2>/dev/null || true
        log "优雅停止超时，已强制终止 PID=$pid（强制终止，非正常停止）"
        msg_error "优雅停止超时，已强制终止（非正常停止）。"
    else
        log "服务已优雅停止 PID=$pid"
        msg_info "服务已优雅停止。"
    fi
    rm -f "$PID_FILE"
}

show_status() {
    # 只输出文本：文本模式直接显示，GUI 模式由调用方 pipe 到 zenity --text-info
    # （若此处再调 msg_info 会重复弹窗）
    local pid="" state
    [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE")"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        state="状态：未启动（或进程已退出）。启动器不会自动重启，请查看日志。"
    elif log_has_failure; then
        state="状态：启动失败（日志含拒绝启动 / 凭据错误）。"
    elif health_ok && root_html_ok; then
        state="状态：运行中（接口存活 + 前端可达）。"
    elif health_ok; then
        state="状态：进程存活，但前端页面不可达。"
    else
        state="状态：启动中或 /api/health 未响应（仅 liveness 探针）。"
    fi
    printf '%s\n\n--- 最近日志（已脱敏）---\n' "$state"
    log_tail
}

new_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -d '\n'
    else
        head -c 48 /dev/urandom | base64 | tr -d '\n'
    fi
}

# ---- 配置向导：显式生成 + 显式落盘 + 备份提示 ----
config_wizard() {
    msg_info "向导只写 config/application.env：不写 deployment.env、不创建管理员。
数据库 / SMTP / 管理员请由浏览器中的 /setup 向导完成。
启动器绝不为你生成或兜底任何密钥。"
    local k v
    for k in AMS_DB_HOST AMS_DB_PORT AMS_DB_NAME AMS_DB_USER AMS_HTTP_HOST AMS_HTTP_PORT; do
        v="$(prompt_value "$k" "$(cfg_get "$k")")" || return 0
        cfg_set "$k" "$v"
    done
    v="$(prompt_secret 'AMS_DB_PASSWORD（数据库真实口令，不可生成）')" || return 0
    cfg_set AMS_DB_PASSWORD "$v"

    for k in AMS_TOKEN_SECRET AMS_KEK; do
        if ask_yesno "是否为 $k 生成 48 字节随机密钥？
· 仅在你显式选择后生成
· 生成后只显示一次，请立即复制到密码管理器备份
· 必须再确认才会写入 config/application.env"; then
            v="$(new_secret)"
            msg_info "$k 已生成，请立即复制备份（本工具不会再次明文显示、不写日志）：
$v"
            if ask_yesno "确认把上面这个 $k 写入 config/application.env？
该文件含明文密钥，请设置文件权限 (chmod 600) 并备份原文件。"; then
                cfg_set "$k" "$v"
                chmod 600 "$CONFIG" 2>/dev/null || true
                log "$k 已显式写盘（值不记录）"
            fi
        else
            v="$(prompt_secret "$k（手动输入）")" || return 0
            cfg_set "$k" "$v"
        fi
    done
    log '配置向导完成（键值不记录）'
    msg_info "配置已保存。服务端 SEC-001 仍是最终判定者，请再执行「启动」。"
}

open_browser() {
    local url="http://127.0.0.1:$(get_port)/"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
    else msg_info "请手动打开浏览器访问 $url"; fi
}

main_menu() {
    echo
    echo "================ AMS · 启动器 ================"
    echo "  1) 启动服务        2) 停止服务        3) 重启"
    echo "  4) 查看状态/日志   5) 打开浏览器      6) 配置向导"
    echo "  0) 退出（不会自动停止服务）"
    echo "=============================================="
    read -r -p "请选择: " c
    case "$c" in
        1) start_service ;;
        2) stop_service ;;
        3) stop_service; sleep 1; start_service ;;
        4) show_status ;;
        5) open_browser ;;
        6) config_wizard ;;
        0) echo "已退出启动器（服务保持原状态，未自动停止）。"; exit 0 ;;
        *) msg_error "无效选择: $c" ;;
    esac
}

# 仅当「直接执行」（而非被 source）时才进入交互主循环：
# 这样既支持 ./AMS-Launcher.sh 直接运行，也允许测试脚本 `source` 本文件后
# 单独调用函数（ask_yesno / prompt_value / cfg_set / preflight 等）做单元/集成验证，
# 不会因 source 而意外弹出菜单。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$SINGLE_INSTANCE" = "0" ]; then
        log "flock fd 锁在此环境不可用，已降级为无单实例保护（不影响失败关闭语义）"
    fi
    log "启动器已就绪（未自动启动服务）"
    # 桌面环境：有 zenity 才用图形菜单；yad 只用于弹窗提示，菜单仍走文本
    # （避免为 yad 单独维护一套 --list 参数）。headless 服务器直接用文本菜单。
    if [ "$GUI" = "zenity" ]; then
        while true; do
            act="$(zenity --list --title="AMS · 启动器" --text="选择操作" \
                  --column="操作" --column="说明" \
                  "start" "启动服务" "stop" "停止服务" "restart" "重启" \
                  "status" "查看状态/日志" "browser" "打开浏览器" \
                  "config" "配置向导" "exit" "退出（不停止服务）" 2>/dev/null)" || break
            case "$act" in
                start)   start_service ;;
                stop)    stop_service ;;
                restart) stop_service; sleep 1; start_service ;;
                status)  show_status | zenity --text-info --title="AMS · 状态" --width=700 --height=400 >/dev/null 2>&1 ;;
                browser) open_browser ;;
                config)  config_wizard ;;
                *)       break ;;
            esac
        done
        echo "已退出启动器（服务保持原状态，未自动停止）。"
    else
        while true; do main_menu; done
    fi
fi
