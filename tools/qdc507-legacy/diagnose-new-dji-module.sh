#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限访问 QMI 控制口与 AT 串口。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

# 诊断期间临时释放设备；脚本退出时无条件恢复 OpenVoHive。
systemctl stop openvohive.service
trap 'systemctl start openvohive.service' EXIT
sleep 2

echo "=== AT IMEI ==="
printf 'AT+CGSN\n' | timeout 6 socat -T 3 - /dev/ttyUSB2,crnl 2>&1 || true

echo "=== AT SIM ICCID ==="
printf 'AT+QCCID\n' | timeout 6 socat -T 3 - /dev/ttyUSB2,crnl 2>&1 || true

echo "=== QMI 服务 ==="
timeout 12 qmicli -d /dev/cdc-wdm0 --dms-get-ids 2>&1 || true

echo "=== QMI SIM ==="
timeout 12 qmicli -d /dev/cdc-wdm0 --uim-get-card-status 2>&1 || true

echo "=== QMI 注册 ==="
timeout 12 qmicli -d /dev/cdc-wdm0 --nas-get-serving-system 2>&1 || true

echo "=== 诊断结束，将恢复 OpenVoHive ==="
