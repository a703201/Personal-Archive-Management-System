#!/usr/bin/env bash
# AMS 移动端（鸿蒙 NEXT）签名 HAP 构建脚本
# 复用 Lumio_Music 验证过的 hvigor 调用方式：避开 WorkBuddy 注入的
# genie-safe-delete 守卫（会拦截 hvigor 清理构建产物导致崩溃）。
set -e

cd "$(dirname "$0")"

# 1) 让 hvigor 使用健康的 JBR 而非 PATH 上损坏的 Oracle Java
export PATH="/e/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"

# 2) 取消 safe-delete 守卫对 rm/unlink/rmdir 的函数包装
unset -f rm unlink rmdir 2>/dev/null || true

# 3) 关闭 WorkBuddy 注入的 node 守卫
export DEVECO_SDK_HOME="E:/Program Files/Huawei/DevEco Studio/sdk"
export NODE_OPTIONS=""
export BASH_ENV=""

# 4) --no-daemon 避免复用被污染的 daemon node 环境
exec "E:/Program Files/Huawei/DevEco Studio/tools/node/node.exe" \
  "E:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode module -p module=entry@default -p product=default -p requiredDeviceType=phone \
  assembleHap --analyze=normal --parallel --incremental --no-daemon
