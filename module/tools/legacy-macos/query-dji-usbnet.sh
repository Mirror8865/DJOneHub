#!/usr/bin/env bash
set -euo pipefail

# 必须以 root 身份运行，因为 QMI 控制口和串口默认仅 root 可访问。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

# 依次探测现有串口，避免不同模块的 AT 口编号发生变化。
for port in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
  [[ -e "${port}" ]] || continue
  echo "=== 尝试 ${port} ==="
  response="$(printf 'AT+QCFG="usbnet"?\r\n' | timeout 5 socat -T 3 - "${port},raw,echo=0" 2>&1 || true)"
  printf '%s\n' "${response}"
  if grep -q '+QCFG:.*usbnet' <<<"${response}"; then
    echo "AT_PORT=${port}"
    exit 0
  fi
done

echo "所有串口均未返回 USBNET 配置" >&2
exit 1
