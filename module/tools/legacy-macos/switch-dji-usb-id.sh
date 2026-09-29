#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限访问模块 AT 串口。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

at_port="/dev/ttyUSB2"
expected_current='0X2CA3,0X4006,1,1,1,1,1,0,0'
target_config='0X2C7C,0X0125,1,1,1,1,1,0,0'

# 写入前再次读取并严格核验，防止模块状态变化时误写。
current_response="$(printf 'AT+QCFG="USBCFG"?\n' | timeout 6 socat -T 3 - "${at_port},crnl" 2>&1 || true)"
printf '%s\n' "${current_response}"
normalized_response="$(tr '[:lower:]' '[:upper:]' <<<"${current_response}" | tr -d '[:space:]')"
if [[ "${normalized_response}" != *"${expected_current}"* ]]; then
  echo "当前 USBCFG 与预期不一致，已拒绝写入" >&2
  exit 1
fi

# 仅替换 VID/PID，其余七个接口开关完全保持当前值。
write_response="$(printf 'AT+QCFG="USBCFG",0x2C7C,0x0125,1,1,1,1,1,0,0\n' | timeout 6 socat -T 3 - "${at_port},crnl" 2>&1 || true)"
printf '%s\n' "${write_response}"
if ! grep -q '^OK' <<<"${write_response}"; then
  echo "USB 标识写入未返回 OK，停止重启" >&2
  exit 1
fi

# 写入后再次查询持久配置，确认目标值确实生效。
verify_response="$(printf 'AT+QCFG="USBCFG"?\n' | timeout 6 socat -T 3 - "${at_port},crnl" 2>&1 || true)"
printf '%s\n' "${verify_response}"
normalized_verify="$(tr '[:lower:]' '[:upper:]' <<<"${verify_response}" | tr -d '[:space:]')"
if [[ "${normalized_verify}" != *"${target_config}"* ]]; then
  echo "写入后的 USBCFG 校验失败，停止重启" >&2
  exit 1
fi

echo "USB 标识写入并校验成功，正在重启模块……"
# 重启模块使新 USB 标识生效；命令发出后串口断开属于正常现象。
printf 'AT+CFUN=1,1\n' | timeout 4 socat -T 2 - "${at_port},crnl" 2>&1 || true
echo "请等待模块重新枚举，然后在 UTM 中重新直通 2c7c:0125。"
