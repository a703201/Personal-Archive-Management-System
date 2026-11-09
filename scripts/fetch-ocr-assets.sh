#!/bin/bash
# ============================================================
# AMS · 准备外部 PP-OCRv5 引擎的原生资产
#
# 把 onnxruntime 动态库 + 头文件、PP-OCRv5 mobile 模型 + 字典落地到
# build/linux/，供：
#   · build-linux.sh    —— 编译 ocr_bridge.c（真推理桥接）
#   · Dockerfile.prebuilt —— 一同打进运行镜像（/app/bin）
#
# 资产来源（按优先级）：
#   1) 本地 $AMS_OCR_SRC（默认 .tmp/spike-ort，即「真推理 spike」的产物目录）
#   2) 网络下载（仅 onnxruntime 有稳定的 GitHub Release 直链；
#       模型若本地缺失则给出明确指引，不在脚本里猜测模型 URL）
#
# 产物布局（均落在 build/linux/）：
#   libams_ocr.so      —— 由 build-linux.sh 生成（本脚本只备料）
#   libonnxruntime.so  —— 本脚本解压
#   include/onnxruntime_c_api.h —— 本脚本解压（仅编译期需要）
#   ocr_models/PP-OCRv5_mobile_{det,rec}.onnx
#   ocr_models/PP-OCRv5_mobile_rec.dict.json
#
# 注：build/ 、 .tmp/ 均被 .gitignore 忽略，资产不进版本库。
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${AMS_OCR_SRC:-$ROOT/.tmp/spike-ort}"
DEST="$ROOT/build/linux"
mkdir -p "$DEST/ocr_models" "$DEST/include"

echo "=== 准备外部 PP-OCRv5 资产 ==="
echo "  来源 : $SRC"
echo "  落地 : $DEST"
echo ""

missing=0

# ---- 1) onnxruntime 动态库 + 头文件 ----
# ⚠️ onnxruntime 的 SONAME 是 libonnxruntime.so.1，官方包里
# lib/libonnxruntime.so 是符号链接（.so -> .so.1 -> .so.1.19.2）。
# 必须用 cp -L 拷真实文件 + 自建 .so / .so.1 链接，否则：
#   · 链接 ams-server 时 ld 找不到 libonnxruntime.so.1（NEEDED），
#     报 OrtGetApiBase@VERS_1.19.2 undefined；
#   · 运行期动态链接器同样找不到 libonnxruntime.so.1（LD_LIBRARY_PATH 下）。
if [ -f "$DEST/libonnxruntime.so.1.19.2" ] && [ -f "$DEST/include/onnxruntime_c_api.h" ]; then
    echo "[SKIP] libonnxruntime.so.1.19.2 + 头文件 已存在"
else
    tgz="$SRC/onnxruntime-linux-x64-1.19.2.tgz"
    if [ -f "$tgz" ]; then
        echo "--- 解压 onnxruntime（本地 $tgz）---"
        tmpd="$(mktemp -d)"
        tar -xzf "$tgz" -C "$tmpd" || { echo "[ERROR] 解压 $tgz 失败"; rm -rf "$tmpd"; exit 1; }
        ortdir="$(find "$tmpd" -maxdepth 2 -type d -name 'onnxruntime-linux-x64-*' | head -1)"
        [ -z "$ortdir" ] && ortdir="$(find "$tmpd" -maxdepth 1 -type d -name 'onnxruntime*' | head -1)"
        # 优先官方真实文件，退而求其次拷贝 lib 下的 .so（均 cp -L 解引用，避免拷成悬空链接）
        if [ -e "$ortdir/lib/libonnxruntime.so.1.19.2" ]; then
            cp -L "$ortdir/lib/libonnxruntime.so.1.19.2" "$DEST/libonnxruntime.so.1.19.2"
        elif [ -e "$ortdir/lib/libonnxruntime.so" ]; then
            cp -L "$ortdir/lib/libonnxruntime.so" "$DEST/libonnxruntime.so.1.19.2"
        else
            echo "[ERROR] $tgz 内未找到 onnxruntime 动态库"
            rm -rf "$tmpd"; exit 1
        fi
        ln -sf libonnxruntime.so.1.19.2 "$DEST/libonnxruntime.so.1"
        ln -sf libonnxruntime.so.1 "$DEST/libonnxruntime.so"
        cp "$ortdir/include/onnxruntime_c_api.h" "$DEST/include/" 2>/dev/null || \
            cp "$ortdir"/include/*.h "$DEST/include/" 2>/dev/null
        echo "OK -> lib + 头文件"
        rm -rf "$tmpd"
    else
        echo "[INFO] 本地未找到 onnxruntime 压缩包，尝试网络下载..."
        url="https://github.com/microsoft/onnxruntime/releases/download/v1.19.2/onnxruntime-linux-x64-1.19.2.tgz"
        if command -v curl >/dev/null 2>&1; then
            curl -fSL "$url" -o /tmp/ort.tgz || { echo "[ERROR] 下载 onnxruntime 失败"; exit 1; }
            tmpd="$(mktemp -d)"
            tar -xzf /tmp/ort.tgz -C "$tmpd"
            ortdir="$(find "$tmpd" -maxdepth 2 -type d -name 'onnxruntime-linux-x64-*' | head -1)"
            if [ -e "$ortdir/lib/libonnxruntime.so.1.19.2" ]; then
                cp -L "$ortdir/lib/libonnxruntime.so.1.19.2" "$DEST/libonnxruntime.so.1.19.2"
            else
                cp -L "$ortdir/lib/libonnxruntime.so" "$DEST/libonnxruntime.so.1.19.2"
            fi
            ln -sf libonnxruntime.so.1.19.2 "$DEST/libonnxruntime.so.1"
            ln -sf libonnxruntime.so.1 "$DEST/libonnxruntime.so"
            cp "$ortdir/include/onnxruntime_c_api.h" "$DEST/include/"
            rm -rf "$tmpd" /tmp/ort.tgz
            echo "OK -> lib + 头文件（已下载）"
        else
            echo "[ERROR] 未找到 curl，无法下载 onnxruntime。请手动放置："
            echo "        $DEST/libonnxruntime.so.1.19.2（+ libonnxruntime.so.1 / .so 链接）"
            echo "        $DEST/include/onnxruntime_c_api.h"
            missing=1
        fi
    fi
fi

# ---- 2) PP-OCRv5 mobile 模型 + 字典 ----
for f in PP-OCRv5_mobile_det.onnx PP-OCRv5_mobile_rec.onnx PP-OCRv5_mobile_rec.dict.json; do
    if [ -f "$DEST/ocr_models/$f" ]; then
        echo "[SKIP] $f 已存在"
    elif [ -f "$SRC/models/$f" ]; then
        cp "$SRC/models/$f" "$DEST/ocr_models/$f"
        echo "OK -> ocr_models/$f"
    else
        echo "[ERROR] 未找到模型 $f（本地 $SRC/models/ 与 $DEST/ocr_models/ 均无）"
        echo "        请先运行「真推理 spike」或将其放入 $SRC/models/"
        missing=1
    fi
done

echo ""
if [ "$missing" -ne 0 ]; then
    echo "[FAILED] 部分资产缺失，外部 OCR 引擎将无法启用（运行期自动回退内置三路）"
    exit 1
fi
echo "[OK] 资产就绪：$DEST/（libonnxruntime.so + ocr_models/*）"
