#!/bin/bash
set -u

# 只读检查不会写入模块配置，也不会重启模块。
script_dir="$(cd "$(dirname "$0")" && pwd)"

clear
echo "DJOneHub QDC507 ADB 状态检查 v1.0.0"
echo "================================================"
echo

/bin/bash "${script_dir}/repair-djonehub-adb.sh" --check
result=$?

echo
read -r -p "按 Return 键关闭窗口..." _
exit "${result}"
