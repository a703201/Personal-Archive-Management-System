#!/bin/bash
# ============================================================
# AMS · 仓颉 SDK 开发副本安装脚本
#
# 用途：在仓库内 tools/cangjie/ 放一份**开发专用的仓颉编译器副本**。
#   - 好处：① 团队成员克隆后无需各自安装 SDK；② 路径不含空格，
#           避开 Windows 上的一类路径问题。
#   - 代价：约 945 MB 二进制，**已由 .gitignore 屏蔽**，不会进仓库。
#
# 用法：
#   bash scripts/install-sdk.sh                # 从 E:/Cangjie 复制
#   bash scripts/install-sdk.sh <源目录>       # 从指定目录复制
#
# 注意：
#   - 本机 cjpm 1.0.5 在 Windows 上 build 阶段会崩溃（堆损坏 0xC0000374），
#     与 SDK 位置无关（副本放在仓库内也一样崩）。故本地构建用 scripts/build.sh
#     （cjc 版），cjpm 留给 CI。
#   - stdx 扩展库用 scripts/install-stdx.sh 装到仓库外（E:/CangjieLibs），
#     不放进仓库（体积大且与 SDK 版本强绑定）。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${1:-E:/Cangjie}"
DEST="tools/cangjie"

echo "=== AMS · 安装仓颉 SDK 开发副本 ==="
echo "  源目录 : ${SRC}"
echo "  目标   : ${ROOT}/${DEST}"
echo ""

if [ ! -f "${SRC}/bin/cjc.exe" ]; then
    echo "[ERROR] 源目录不是有效的仓颉 SDK（缺少 bin/cjc.exe）：${SRC}"
    echo "        可用候选："
    echo "          E:/Cangjie"
    echo "          E:/Program Files (x86)/Cangjie"
    exit 1
fi

if [ -d "$DEST" ]; then
    # 不用 rm -rf（safe-bin 会拦截含盘符前缀的删除），
    # 改用 mv 保留旧副本，确认新副本可用后由用户自行清理。
    OLD="${DEST}.old.$(date +%Y%m%d-%H%M%S)"
    echo "[INFO] 目标已存在，先移走旧副本 -> ${OLD}"
    mv -f "$DEST" "$OLD"
fi

mkdir -p "$(dirname "$DEST")"
echo "[1/2] 复制中（约 945 MB，需要十几秒）..."
cp -r "$SRC" "$DEST"

echo "[2/2] 验证..."
if [ ! -f "${DEST}/bin/cjc.exe" ]; then
    echo "[ERROR] 复制后缺少 bin/cjc.exe"
    exit 1
fi

# ---- 补齐 MinGW 运行库（1.2.0 SDK 的已知缺件）----
# 现象：SDK 1.2.0 的 libcangjie-runtime.dll 依赖
#       libgcc_s_seh-1.dll / libwinpthread-1.dll / libssp-0.dll，
#       但官方 Windows 包**未附带**这三个文件。
# 后果：编译器加载 unittest 宏宿主时 dlopen 失败，
#       报 "could not load the dynamic library ... libcangjie-runtime.dll"
#       与 "could not find the create task method: RunCJTask"，
#       表现为所有 @Test 用例无法编译（看起来像代码问题，实为环境缺件）。
#
# 处理：从本机已有的 MinGW 运行库（Git for Windows 自带）补齐。
# 关键：**必须放到 ${DEST}/bin/（与 cjc.exe 同目录）**——
#   Windows 的 DLL 搜索顺序里，「exe 所在目录」优先于「PATH」，
#   而依赖 DLL 的搜索只按被加载 DLL 自己的目录 + exe 目录 + PATH 走；
#   只放到 runtime/ 目录不够（那是 runtime.dll 自己被加载的路径，
#   依赖查找不会回到那里），只改 PATH 也不够（Git Bash 的 PATH 用 ':' 分隔，
#   Windows 风格的 "E:/..." 会被切坏）。
echo ""
echo "[补齐] MinGW 运行库（SDK 1.2.0 已知缺件）..."
MINGW_CANDIDATES=(
    "/c/Program Files/Git/mingw64/bin"
    "/usr/bin"
    "${MINGW_BIN:-}"
)
for need in libgcc_s_seh-1.dll libwinpthread-1.dll libssp-0.dll; do
    if [ -f "${DEST}/bin/${need}" ]; then
        continue
    fi
    found=""
    for cand in "${MINGW_CANDIDATES[@]}"; do
        [ -z "$cand" ] && continue
        if [ -f "${cand}/${need}" ]; then
            found="$cand"
            break
        fi
    done
    if [ -n "$found" ]; then
        cp "${found}/${need}" "${DEST}/bin/" && echo "      ✅ ${need}  <- ${found}"
    else
        echo "      ⚠️  未找到 ${need}（若 @Test 宏报 RunCJTask 错误，需手动补齐到 tools/cangjie/bin/）"
    fi
done

VERSION="$("${DEST}/bin/cjc.exe" --version 2>&1 | head -1)"
FILES=$(find "$DEST" -type f | wc -l)
SIZE=$(du -sh "$DEST" | cut -f1)

echo "      版本   : ${VERSION}"
echo "      文件数 : ${FILES}"
echo "      体积   : ${SIZE}"
echo ""
echo "=== 安装完成 ==="
echo ""
echo "下一步："
echo "  1. source scripts/envsetup.sh   # 环境会优先使用仓库内副本"
echo "  2. bash scripts/build.sh         # 构建"
echo "  3. bash scripts/test.sh          # 单元测试"
echo ""
echo "[提醒] ${DEST}/ 已写入 .gitignore，不会被提交到远程仓库。"
echo "       团队成员克隆后执行本脚本即可获得一致的编译环境。"
