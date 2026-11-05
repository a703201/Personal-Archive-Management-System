#!/bin/bash
# ============================================================
# AMS · SMTP 投递循环（随运行镜像分发）
# ------------------------------------------------------------
# 后端把待发邮件写成 .eml（头部 X-AMS-* 携带本次 SMTP 参数），
# 本脚本用 curl 的 smtps/smtp 协议真实投递，成功后移出队列。
#
# 为什么不让仓颉直接发：SDK 的 std.net / stdx.net.tls API 在本工具链
# 未提供源码级文档，手写 TLS+SMTP 风险高；运行镜像已内置 curl 且
# 原生支持 smtp/smtps，走子进程外的文件交接最稳、且配置可热更新。
#
# 启动：由 Dockerfile 的 CMD 在后台拉起；未启用邮件时脚本低频等待，
# 不会产生任何网络请求。
# ============================================================
set -u

SPOOL="${AMS_MAIL_SPOOL_DIR:-/app/data-mail/spool}"
CONFIG="${AMS_CONFIG_DIR:-/app/config}/deployment.env"
mkdir -p "$SPOOL/sent" "$SPOOL/failed"

mail_enabled() {
    grep -q '^MAIL_ENABLED=true' "$CONFIG" 2>/dev/null
}

send_one() {
    local f="$1"
    local to subject host port user pass from secure
    to=$(sed -n 's/^X-AMS-To: //p' "$f" | head -1)
    subject=$(sed -n 's/^X-AMS-Subject: //p' "$f" | head -1)
    host=$(sed -n 's/^X-AMS-Smtp-Host: //p' "$f" | head -1)
    port=$(sed -n 's/^X-AMS-Smtp-Port: //p' "$f" | head -1)
    user=$(sed -n 's/^X-AMS-Smtp-User: //p' "$f" | head -1)
    pass=$(sed -n 's/^X-AMS-Smtp-Password: //p' "$f" | head -1)
    from=$(sed -n 's/^X-AMS-Smtp-From: //p' "$f" | head -1)
    secure=$(sed -n 's/^X-AMS-Smtp-Secure: //p' "$f" | head -1)

    [ -n "$to" ] && [ -n "$host" ] && [ -n "$from" ] || return 1
    port="${port:-465}"
    secure="${secure:-ssl}"

    # RFC 5322 报文：只保留标准头 + 正文，绝不把 X-AMS-Smtp-Password 发给收件人
    local msg
    msg=$(mktemp)
    {
        printf 'From: %s\r\n' "$from"
        printf 'To: %s\r\n' "$to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n'
        sed '1,/^$/d' "$f"
    } > "$msg"

    local url
    if [ "$secure" = "starttls" ]; then
        url="smtp://${host}:${port}"
    else
        url="smtps://${host}:${port}"
    fi

    local auth_args=()
    [ -n "$user" ] && auth_args=(--user "${user}:${pass}")

    local rc=0
    curl -sS --max-time 30 --url "$url" --ssl-reqd \
        --mail-from "$from" --mail-rcpt "$to" \
        "${auth_args[@]}" --upload-file "$msg" >/dev/null 2>&1 || rc=1
    rm -f "$msg"
    return "$rc"
}

echo "[mail-spool] watching $SPOOL"
while true; do
    if ! mail_enabled; then
        sleep 10
        continue
    fi
    shopt -s nullglob
    for f in "$SPOOL"/*.eml; do
        [ -f "$f" ] || continue
        if send_one "$f"; then
            mv -f "$f" "$SPOOL/sent/" 2>/dev/null || rm -f "$f"
            echo "[mail-spool] sent $(basename "$f")"
        else
            mv -f "$f" "$SPOOL/failed/" 2>/dev/null || rm -f "$f"
            echo "[mail-spool] failed $(basename "$f")"
        fi
    done
    shopt -u nullglob
    sleep 3
done
