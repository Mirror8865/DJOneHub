#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限读取模块串口。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

# 只查询 USB 组合配置，不写入、不重启模块。
printf 'AT+QCFG="USBCFG"?\n' | timeout 6 socat -T 3 - /dev/ttyUSB2,crnl
