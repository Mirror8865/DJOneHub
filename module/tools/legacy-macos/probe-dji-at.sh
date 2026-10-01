#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限访问模块串口。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

# 使用此前已成功读取 ATI 的 crnl 参数，逐端口验证 AT 通道。
for port in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
  [[ -e "${port}" ]] || continue
  echo "=== ${port} / ATI ==="
  ati_response="$(printf 'ATI\n' | timeout 6 socat -T 3 - "${port},crnl" 2>&1 || true)"
  printf '%s\n' "${ati_response}"
  if grep -q '^OK' <<<"${ati_response}"; then
    echo "=== ${port} / USBNET ==="
    printf 'AT+QCFG="usbnet"?\n' | timeout 6 socat -T 3 - "${port},crnl" 2>&1 || true
    echo "AT_PORT=${port}"
    exit 0
  fi
done

echo "未找到可响应的 AT 串口" >&2
exit 1
