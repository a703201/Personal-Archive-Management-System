#!/bin/bash
# ============================================================
# AMS · 短信投递循环（随运行镜像分发；FR-NTF-005）
# ------------------------------------------------------------
# 后端 SpoolSmsProvider 把待发短信写成 sms-*.job：
#   X-AMS-Sms-Phone: <手机号>
#   <空行>
#   <短信正文（换行已由仓颉侧 oneLine 压平为空格）>
# 本脚本轮询 *.job，用 curl 把 {phone,text,appKey,...} 以 JSON POST
# 到 SMS_GATEWAY_URL；HTTP 2xx 移入 sent/，否则移入 failed/。
#
# 与仓颉侧「不引入网络库」一致：签名 / 模板 / 鉴权等协议细节全部交给
# 网关侧可配置字段，脚本只发通用 JSON POST，不编造供应商协议。
#
# [安全与可观测性]
#   · gateway 强制 https://（loopback http 仅允许本机网关），因为 appSecret
#     随 JSON 明文发送；非合规配置 FATAL 退出，绝不静默发出明文请求。
#   · 投递失败把 .job 移入 failed/，并写 *.reason（脱敏）+ 输出 ERROR 日志。
#     ams-server 写完 .job 即返回，无法同步感知本进程结果，故该日志/目录
#     是这条链路唯一的可观测抓手，生产须配套告警。
#
# 配置：读 deployment.env，同时允许环境变量覆盖（AMS_SMS_XXX 或同名
#   SMS_XXX）；未设置则取脚本内默认值。未启用时低频等待，不发任何请求。
# 启动：由 Dockerfile 的 CMD 在后台拉起。
# ============================================================
set -euo pipefail

SPOOL="${AMS_SMS_SPOOL_DIR:-./data-sms/spool}"
CONFIG="${AMS_CONFIG_DIR:-/app/config}/deployment.env"
mkdir -p "$SPOOL/sent" "$SPOOL/failed"

# 读取一个配置：先按优先级尝试若干环境变量（非空即用），
# 再回退 deployment.env 里的文件键，最后用默认值。
# 用法：cfg <文件键> <默认值> <环境变量名...>
cfg() {
    local key="$1" default_val="$2"
    shift 2
    local name val file_val
    for name in "$@"; do
        val="${!name:-}"
        if [ -n "$val" ]; then
            printf '%s' "$val"
            return 0
        fi
    done
    file_val=$(sed -n "s/^${key}=//p" "$CONFIG" 2>/dev/null | head -1) || true
    file_val=$(printf '%s' "$file_val" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$file_val" ]; then
        printf '%s' "$file_val"
    else
        printf '%s' "$default_val"
    fi
}

# JSON 字符串最小转义：控制字符压成空格，转义反斜杠与双引号。
# 换行 / 回车已由仓颉侧 oneLine 压平，这里再做一次兜底。
json_escape() {
    printf '%s' "$1" | tr '\011\015\012' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 网关 URL 安全门禁：凭据（appSecret）随 JSON 明文发往网关，故只允许 https；
# 本机自托管网关可用 loopback http 显式豁免（不会跨网络）。
# 非合规配置一律 FATAL 退出，绝不静默发出含凭据的明文请求。
gateway_is_safe() {
    case "$1" in
        https://*) return 0 ;;
        http://localhost|http://localhost:*|http://localhost/*) return 0 ;;
        http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*) return 0 ;;
        *) return 1 ;;
    esac
}

LAST_HTTP="000"

send_one() {
    local f="$1" gateway="$2" app_key="$3" app_secret="$4" sign_name="$5" template_id="$6"
    local phone text payload http
    phone=$(sed -n 's/^X-AMS-Sms-Phone: //p' "$f" | head -1 | tr -d '\r') || true
    text=$(sed '1,/^$/d' "$f") || true
    [ -n "$phone" ] && [ -n "$text" ] || return 1

    payload=$(printf '{"phone":"%s","text":"%s","appKey":"%s","appSecret":"%s","signName":"%s","templateId":"%s"}' \
        "$(json_escape "$phone")" \
        "$(json_escape "$text")" \
        "$(json_escape "$app_key")" \
        "$(json_escape "$app_secret")" \
        "$(json_escape "$sign_name")" \
        "$(json_escape "$template_id")")

    http=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-binary "$payload" "$gateway") || http="000"
    LAST_HTTP="$http"
    [[ "$http" =~ ^2[0-9][0-9]$ ]]
}

echo "[sms-spool] watching $SPOOL"
while true; do
    if [ "$(cfg SMS_ENABLED false AMS_SMS_ENABLED SMS_ENABLED)" != "true" ]; then
        sleep 10
        continue
    fi

    gateway=$(cfg SMS_GATEWAY_URL "" AMS_SMS_GATEWAY_URL SMS_GATEWAY_URL)
    if [ -n "$gateway" ] && ! gateway_is_safe "$gateway"; then
        echo "[sms-spool] FATAL: SMS_GATEWAY_URL must use https:// (loopback http allowed only for a local gateway); refusing to send credentials over plaintext" >&2
        echo "[sms-spool] FATAL: current value = $gateway" >&2
        exit 1
    fi
    app_key=$(cfg SMS_APP_KEY "" AMS_SMS_APP_KEY SMS_APP_KEY)
    app_secret=$(cfg SMS_APP_SECRET "" AMS_SMS_APP_SECRET SMS_APP_SECRET)
    sign_name=$(cfg SMS_SIGN_NAME "" AMS_SMS_SIGN_NAME SMS_SIGN_NAME)
    template_id=$(cfg SMS_TEMPLATE_ID "" AMS_SMS_TEMPLATE_ID SMS_TEMPLATE_ID)

    if [ -n "$gateway" ]; then
        shopt -s nullglob
        for f in "$SPOOL"/*.job; do
            [ -f "$f" ] || continue
            name=$(basename "$f")
            if send_one "$f" "$gateway" "$app_key" "$app_secret" "$sign_name" "$template_id"; then
                mv -f "$f" "$SPOOL/sent/" 2>/dev/null || rm -f "$f"
                echo "[sms-spool] sent $name"
            else
                mv -f "$f" "$SPOOL/failed/" 2>/dev/null || rm -f "$f"
                # 失败原因落盘：只记脱敏信息（绝不写 appSecret / 手机号 / 正文）。
                # ams-server 写完 .job 即返回，无法同步感知本进程的投递结果，
                # 故 failed/*.reason + ERROR 日志是这条链路唯一的可观测抓手。
                printf 'file=%s\nhttp=%s\nat=%s\nhint=gateway delivery failed; .job moved to failed/. ams-server cannot observe this asynchronously; alert on [sms-spool] ERROR\n' \
                    "$name" "$LAST_HTTP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    > "$SPOOL/failed/${name}.reason" 2>/dev/null || true
                echo "[sms-spool] ERROR failed $name http=$LAST_HTTP (see failed/${name}.reason)" >&2
            fi
        done
        shopt -u nullglob
    fi
    sleep 3
done
