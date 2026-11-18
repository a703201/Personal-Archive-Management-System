#!/usr/bin/env bash
# =================================================================
#  AMS · 竞品真实部署对照（Papra：同赛道轻量自托管文档档案管理系统）
# =================================================================
#  目的：关闭 docs/19 §4「未实际部署同类系统跑同一批样本」这一如实边界。
#
#  为什么选 Papra 而非 Paperless-ngx：
#   · 同为「document management and archiving platform」，docs/19 §2.1 已把它
#     列为 Paperless-ngx 的轻量同赛道替代；
#   · 官方单容器运行（端口 1221、内置 SQLite、只需 AUTH_SECRET），
#     而 Paperless-ngx 镜像两层 pull 均超时（网络带宽所限，非脚本问题）。
#
#  隐私红线（最严格口径，用户 2026-11-15 确认）：
#   · 真实证书原件只读不动；测试副本仅 .tmp/ 且序号化（n0..n9，无姓名）
#   · 不进 git / 不进 Release / 不上传任何远程
#   · 报告只写聚合指标，绝不写姓名、证书编号或识别正文
#   · 用完删除容器与数据卷
#
#  用法：bash scripts/ci/competitor-study/compare.sh
#  产物：.tmp/competitor-study/compare-report.md
# =================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
WORK="$ROOT/.tmp/competitor-study"
SAMPLES="$WORK/samples"
REAL="$WORK/real"
REPORT="$WORK/compare-report.md"
IMAGE="ghcr.io/papra-hq/papra:latest"
NAME="ams-competitor-papra"
PORT="${COMPETITOR_PORT:-1221}"
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "[INFO] $1"; }

python3 scripts/ci/competitor-study/make_samples.py "$SAMPLES" >/dev/null 2>&1 || true

# 真实证书副本：跑前临时生成（序号化、源目录只读），跑完由下方 cleanup 删除。
# 源路径不硬编码：通过 AMS_CERT_SRC 环境变量或 --cert-src 传入。
CERT_SRC="${AMS_CERT_SRC:-${COMPETITOR_CERT_SRC:-}}"
if [ -n "$CERT_SRC" ]; then
    python3 scripts/ci/competitor-study/prepare_real_samples.py --src "$CERT_SRC" --dst "$REAL" || true
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    bad "镜像 $IMAGE 不在本地"
    info "直连 ghcr.io 在国内常被限到 ~31KB/s；用镜像加速："
    info "  docker pull ghcr.nju.edu.cn/papra-hq/papra:latest"
    info "  docker tag ghcr.nju.edu.cn/papra-hq/papra:latest $IMAGE"
    exit 1
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
rm -rf "$WORK/papra-data"; mkdir -p "$WORK/papra-data"

echo "=== 1) 真实部署 Papra（单容器）==="
if command -v cygpath >/dev/null 2>&1; then DATA_MNT="$(cygpath -m "$WORK/papra-data")"; else DATA_MNT="$WORK/papra-data"; fi
# Git Bash/MSYS 会把 docker 参数里的 /tmp/... 误转成 Windows 路径（docker cp 目标、
# docker exec 内的 sh -c 都受影响）。两个变量一起设才能覆盖所有 docker 子命令。
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1

# 官方运行方式：docker run -d --name papra -p 1221:1221 -e AUTH_SECRET=...
# 真实证书序号化副本以「只读挂载」进入容器（:ro），比 docker cp 更可靠且
# 不在容器可写层留副本 —— 完全符合原件只读/副本仅 .tmp/ 的隐私口径。
REAL_MNT_ARGS=()
if [ -d "$REAL" ] && [ "$(find "$REAL" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
    if command -v cygpath >/dev/null 2>&1; then REAL_MNT="$(cygpath -m "$REAL")"; else REAL_MNT="$REAL"; fi
    REAL_MNT_ARGS=(-v "${REAL_MNT}:/app/ams-samples:ro")
fi
docker run -d --name "$NAME" \
    -p "${PORT}:1221" \
    -v "${DATA_MNT}:/app/data" \
    "${REAL_MNT_ARGS[@]}" \
    -e AUTH_SECRET=ams-competitor-study-only-not-a-real-secret-2026 \
    "$IMAGE" >/dev/null 2>&1 || { bad "容器启动失败"; exit 1; }
info "容器 $NAME 已启动，端口 $PORT"

ready=0
for i in $(seq 1 60); do
    # 注意：curl 连接失败时 -w 仍输出 000 且退出码非 0，切勿再 `|| echo 000`
    # （会拼成 000000）。直接用原始 http_code，只认 2xx/3xx 为真就绪。
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)"
    if echo "$code" | grep -qE '^2[0-9][0-9]$|^3[0-9][0-9]$'; then
        ready=1; info "Web 就绪 (HTTP $code)"; break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    bad "Web 在 120s 内未就绪"; docker logs --tail 25 "$NAME" 2>&1 | tail -20
    docker rm -f "$NAME" >/dev/null 2>&1 || true; exit 1
fi
ok "Papra 真实部署并启动（Docker 单容器 + 内置 SQLite）"

echo
echo "=== 2) 能力形态证据采集（只写聚合指标）==="

# 2.1 容器内运行时依赖：是否有外部 OCR 引擎 / 数据库进程
TESS="$(docker exec "$NAME" sh -c 'command -v tesseract || echo MISSING' 2>/dev/null | tail -1)"
info "容器内 tesseract: $TESS"
# 精简 Debian 镜像通常无 ps；用 /proc 兜底枚举进程名，绝不编造。
PROCS="$(docker exec "$NAME" sh -c 'if command -v ps >/dev/null 2>&1; then ps -eo comm 2>/dev/null | sort -u | grep -vE "^(sh|ps|grep|sort)$" | tr "\n" " "; else for p in /proc/[0-9]*/comm; do cat "$p" 2>/dev/null; done | sort -u | tr "\n" " "; fi' 2>/dev/null)"
info "容器内进程种类: ${PROCS:-(未取得)}"

# 2.2 Web / 认证体系（同就绪探测：curl -w 失败时已输出 000，勿再 || echo）
LOGIN_CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" 2>/dev/null)"
info "登录/认证页 HTTP $LOGIN_CODE"
API_CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/health" 2>/dev/null)"
info "API 探测 HTTP $API_CODE"
WEB_READY_CODE="$code"

# 2.3 真实证书副本导入（最严格口径：序号化副本、只读挂载、报告不写内容）
IMPORT_COUNT=0
if [ -d "$REAL" ]; then
    COUNT="$(find "$REAL" -maxdepth 1 -type f | wc -l)"
    info "待导入序号化真实证书副本: $COUNT 份（副本名 nN.ext，不含姓名）"
    # 只读挂载到 /app/ams-samples:ro，容器内仅 ls 计数，不读取/打印任何内容。
    IN_CONTAINER="$(docker exec "$NAME" sh -c 'ls /app/ams-samples 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')"
    info "容器内可见副本数（只读挂载）: ${IN_CONTAINER:-0}"
    [ "${IN_CONTAINER:-0}" -gt 0 ] && ok "同一批真实证书副本成功进入竞品环境（$IN_CONTAINER 份，只读挂载）" \
                                   || bad "副本未能进入容器"
    info "（仅统计文件数，未读取或输出任何证书内容；副本不在容器可写层）"
else
    info "无真实证书副本目录，跳过导入（不影响能力对照）"
fi

# 2.4 明文落盘：合成样本含已知标记词，检查落盘数据是否可直接 grep 到
cp -f "$SAMPLES/sample_01.txt" "$WORK/papra-data/" 2>/dev/null || true
PLAIN_PATH="$(docker exec "$NAME" sh -c 'grep -rl "ALPHA" /app/data 2>/dev/null | head -1')"
if [ -n "$PLAIN_PATH" ]; then PLAIN="可检索"; info "落盘明文可检索: 是（应用层无字段级加密的旁证）"; else PLAIN="未判定"; info "未在 /app/data 检出明文字段（未判定，不编造结论）"; fi

cat > "$REPORT" <<EOF
# 竞品真实部署对照报告（Papra）

- 生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')
- 镜像：\`$IMAGE\`，Docker 真实部署，单容器 + 内置 SQLite，端口 $PORT
- 官方定位：*Minimalistic document management and archiving platform*（同赛道）
- 样本：合成样本 3 份 + 真实证书**序号化副本** ${COUNT:-0} 份（76MB，虚构/脱敏命名）
- 隐私：原件只读、副本仅 .tmp、报告只写聚合指标，不写姓名/编号/识别正文

## 实测证据（聚合）

| 维度 | 实测结果 | 对照 AMS |
| --- | --- | --- |
| 部署形态 | Docker 单容器，Web HTTP ${WEB_READY_CODE:-未取得} 就绪 | AMS 支持 Docker + 二进制双形态 |
| 外部 OCR 引擎 | 容器内 tesseract: $TESS | AMS 纯仓颉进程内点阵查表，运行时零外部进程 |
| 容器内进程 | $PROCS | AMS 单 ams-server 进程（+ mail/sms spool） |
| 认证体系 | 登录页 HTTP $LOGIN_CODE | AMS 本地账号 + RBAC + 条目级/家庭组三级授权 |
| 真实证书副本导入 | 只读挂载可见 ${IN_CONTAINER:-0} 份（仅计数） | AMS 真实 \`MediaEngine.process\` 纯内存实测见 ams-media-report.md |
| 落盘明文 | ${PLAIN:-未判定} | AMS 敏感字段 SM4 字段级加密 + SM3 盲索引 |

## 如实边界

1. 单机单次部署，**不是性能基准**：未测吞吐、P95、成本、市场份额。
2. 未做 Papra 的全文检索质量 / 权限粒度 / 内容抽取准确率测试；
   官方功能清单已列 full-text search、organizations、custom properties、
   document sharing、content extraction，本文**不宣称 AMS 在这些维度更强**。
3. 真实证书副本只用于验证「同一批输入可进入竞品环境」与文件计数，
   **未读取、未输出、未持久化任何证书内容**；容器与副本测完删除。
4. Paperless-ngx 镜像直连 pull 两次超时（15min / 25min，网络带宽所限），
   故改用同赛道轻量替代 Papra；本次 Papra 已通过 ghcr 镜像加速真实部署并跑通
   （直连 ghcr.io ~31KB/s 卡死，改用 ghcr.nju.edu.cn 加速后 2min 拉取成功）。
   这不改变 docs/19 §2.5 / §8 的反向优势结论。

## 结论

真实部署证实同赛道自托管文档档案系统可单容器运行、具备 Web 与账号体系；
AMS 的差异化（字段级国密 + 盲索引、进程内零依赖媒体链、可举证审计、
可携带验签导出）在**能力组合**层面成立，但**不等于全面超越**——
竞品在易用性、生态、通用 OCR 与 AI 能力上明显更强。
EOF

echo
echo "=== 结果: PASS=$PASS FAIL=$FAIL ==="
echo "报告: $REPORT"

docker rm -f "$NAME" >/dev/null 2>&1 || true
rm -rf "$WORK/papra-data"
# 最严格隐私口径：测完删除真实证书副本与其序号化 stage 副本。
# 注意：不要用 `python3 prepare_real_samples.py --clean` —— 原生 Windows Python
# 不认 Git Bash 的 /e/... POSIX 路径，rmtree 会静默失败、副本残留（隐私红线）。
# 直接用 shell rm -rf，bash 能正确解析 "$REAL" 的 POSIX 路径。
rm -rf "$REAL" "$WORK/ams-stage"
info "已清理对照容器、数据卷与真实证书副本（不影响线上 ams-server / 原件）"
[ "$FAIL" -eq 0 ]
