# ============================================================
# AMS · 容器镜像（多阶段构建）
#
# 设计要点：
#   1. builder 阶段在 Linux 容器内跑 scripts/build-linux.sh
#      （即本仓库的 Linux 版 cjc 子包构建，与 Windows 的 build.sh 对应）。
#   2. web 阶段用 Node 构建前端 SPA（web/dist）。
#   3. runtime 阶段只保留：ams-server 可执行文件 + 仓颉运行时 .so
#      + stdx 动态库 .so + 前端静态产物 + 配置模板。
#
# ⚠️ 仓颉 SDK（Linux 版）准备方式（二选一，通过 build arg 控制）：
#   A. 自举基础镜像：团队内先做一个含 Cangjie 1.2.x 的镜像，
#      用 --build-arg BASE_IMAGE=your-registry/cangjie:1.2.0-linux 传入，
#      跳过下面的下载步骤（推荐，避免每次拉 250MB）。
#   B. 下载直链：--build-arg CANGJIE_SDK_URL=<Linux SDK 直链>
#      --build-arg CANGJIE_STDX_URL=<Linux stdx 直链>。
#      官方 Linux SDK 直链同样可能需要自举（参考 Windows 侧
#      scripts/ci/publish-toolchain.sh）。
#
# 构建示例：
#   docker build -t ams:1.0.0 \
#     --build-arg CANGJIE_SDK_URL=https://.../cangjie-1.2.0-linux.tar.gz \
#     --build-arg CANGJIE_STDX_URL=https://.../cangjie-stdx-linux.tar.gz \
#     -f deploy/docker/Dockerfile .
# ============================================================
ARG BASE_IMAGE=ubuntu:22.04
ARG CANGJIE_VERSION=1.2.0
ARG NODE_VERSION=20

# ---------------- builder（后端） ----------------
FROM ${BASE_IMAGE} AS builder
ARG CANGJIE_VERSION
ARG CANGJIE_SDK_URL=""
ARG CANGJIE_STDX_URL=""

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils build-essential \
    && rm -rf /var/lib/apt/lists/*

# 若提供直链则下载并安装到 /opt/cangjie 与 /opt/cangjie-stdx；
# 否则要求 BASE_IMAGE 已自带（下面的探测失败会明确报错）。
RUN if [ -n "$CANGJIE_SDK_URL" ]; then \
        echo "下载 Cangjie SDK：$CANGJIE_SDK_URL" && \
        curl -fSL "$CANGJIE_SDK_URL" -o /tmp/cj.tar.gz && \
        mkdir -p /opt/cangjie && tar -xzf /tmp/cj.tar.gz -C /opt/cangjie --strip-components=1 && \
        rm -f /tmp/cj.tar.gz ; \
    fi
RUN if [ -n "$CANGJIE_STDX_URL" ]; then \
        echo "下载 stdx：$CANGJIE_STDX_URL" && \
        curl -fSL "$CANGJIE_STDX_URL" -o /tmp/stdx.tar.gz && \
        mkdir -p /opt/cangjie-stdx && tar -xzf /tmp/stdx.tar.gz -C /opt/cangjie-stdx --strip-components=1 && \
        rm -f /tmp/stdx.tar.gz ; \
    fi

ENV CANGJIE_HOME=/opt/cangjie
ENV PATH="/opt/cangjie/bin:${PATH}"

# 校验工具链存在
RUN test -x /opt/cangjie/bin/cjc || { echo "ERROR: /opt/cangjie/bin/cjc 不存在，请检查 BASE_IMAGE 或 CANGJIE_SDK_URL"; exit 1; }

WORKDIR /src
COPY . /src

# opengauss-driver 已 vendored 在 tools/vendor/opengauss-driver，
# build-linux.sh 会在需要时自动编译它。
RUN bash scripts/build-linux.sh

# ---------------- web（前端 SPA） ----------------
FROM node:${NODE_VERSION}-bookworm-slim AS web
WORKDIR /web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# ---------------- runtime（运行期） ----------------
FROM ubuntu:22.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# 应用目录
WORKDIR /app

# 后端可执行文件 + 运行时/ stdx 动态库（必须与二进制同目录或于 LD_LIBRARY_PATH）
COPY --from=builder /src/build/ams-server /app/bin/ams-server
COPY --from=builder /src/build/*.so /app/bin/
# 驱动静态库无需拷贝（已链接进 exe）；但若服务器运行期依赖任何 .so，上面的通配已覆盖。

# 前端静态产物
COPY --from=web /web/dist /app/web

# 配置模板（不含密钥）
COPY deploy/config /app/config
COPY LICENSE /app/LICENSE
COPY README.md /app/README.md

# 运行期环境变量（默认本地开发值；生产务必覆盖）
ENV AMS_HTTP_HOST=0.0.0.0 \
    AMS_HTTP_PORT=8080 \
    AMS_DB_HOST=db \
    AMS_DB_PORT=15432 \
    AMS_DB_NAME=ams \
    AMS_DB_USER=gaussdb \
    AMS_DB_PASSWORD=changeme \
    AMS_TOKEN_SECRET=change-me-in-production-at-least-32-bytes \
    AMS_KEK=change-me-in-production \
    AMS_WEB_DIR=/app/web

EXPOSE 8080

# 健康检查：就绪探针打 /api/health
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fSs http://127.0.0.1:8080/api/health || exit 1

# 启动服务端（一个进程同时提供 /api/* 与前端 SPA）
CMD ["/app/bin/ams-server"]
