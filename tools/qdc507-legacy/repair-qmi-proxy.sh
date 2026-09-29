#!/usr/bin/env bash
set -euo pipefail

# 需要 root 权限管理 OpenVoHive 和遗留的 qmi-proxy 进程。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

systemctl stop openvohive.service

# 仅结束可执行文件确认为 /usr/libexec/qmi-proxy 的遗留进程，避免误杀同名程序。
for pid in $(pgrep -x qmi-proxy || true); do
  executable="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  if [[ "${executable}" == "/usr/libexec/qmi-proxy" ]]; then
    echo "结束遗留 qmi-proxy：PID ${pid}"
    kill "${pid}" 2>/dev/null || true
  fi
done

# 等待代理释放 QMI 控制口和抽象 socket。
for _ in {1..20}; do
  if ! pgrep -x qmi-proxy >/dev/null; then
    break
  fi
  sleep 0.25
done

if pgrep -x qmi-proxy >/dev/null; then
  echo "qmi-proxy 未正常退出，拒绝继续" >&2
  systemctl start openvohive.service
  exit 1
fi

echo "QMI 控制口占用检查："
fuser -v /dev/cdc-wdm0 2>&1 || true

systemctl start openvohive.service
sleep 12

echo "=== 服务状态 ==="
systemctl is-active openvohive.service
echo "=== 新模块日志 ==="
journalctl -u openvohive.service --since "20 seconds ago" --no-pager | grep -E 'dji_4g_2|QMI: modem|设备 SIM 身份|backend' || true
