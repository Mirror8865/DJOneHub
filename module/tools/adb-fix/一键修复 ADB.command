#!/bin/bash
set -u

# 双击入口只负责展示结果，实际安全检查与修复逻辑位于同目录脚本中。
script_dir="$(cd "$(dirname "$0")" && pwd)"

clear
echo "DJOneHub QDC507 ADB 修复 v1.0.0"
echo "================================================"
echo "请保持 DJOneHub 正常运行、模块已连接，并确认当前没有通话。"
echo

/bin/bash "${script_dir}/repair-djonehub-adb.sh" --restart
result=$?

echo
if [[ "${result}" -eq 0 ]]; then
  echo "修复流程已完成。请重新打开 DJOneHub，确认 ADB interface 6 错误已消失。"
else
  echo "修复没有完成（退出码 ${result}）。请保留本窗口内容用于排查。"
fi
echo
read -r -p "按 Return 键关闭窗口..." _
exit "${result}"
