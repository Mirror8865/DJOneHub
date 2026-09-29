#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限访问模块 AT 串口。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

at_port="/dev/ttyUSB2"

# 重启前再次回读；模块会把 0x0125 规范化显示为 0x125。
response="$(printf 'AT+QCFG="USBCFG"?\n' | timeout 6 socat -T 3 - "${at_port},crnl" 2>&1 || true)"
printf '%s\n' "${response}"
normalized="$(tr '[:lower:]' '[:upper:]' <<<"${response}" | tr -d '[:space:]')"
if [[ "${normalized}" != *'0X2C7C,0X125,1,1,1,1,1,0,0'* ]] && \
   [[ "${normalized}" != *'0X2C7C,0X0125,1,1,1,1,1,0,0'* ]]; then
  echo "USB 标识未通过校验，拒绝重启" >&2
  exit 1
fi

echo "USB 标识校验通过，正在重启模块……"
# 模块重启后串口立即断开，因此 socat 的断连提示属于正常现象。
printf 'AT+CFUN=1,1\n' | timeout 4 socat -T 2 - "${at_port},crnl" 2>&1 || true
echo "重启命令已发送，请等待约 20 秒。"
