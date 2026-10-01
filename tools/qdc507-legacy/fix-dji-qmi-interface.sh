#!/usr/bin/env bash
set -euo pipefail

# 必须以 root 身份运行，USB 驱动解绑与绑定需要管理员权限。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

rule_file="/etc/udev/rules.d/99-dji-baiwang.rules"
backup_file="${rule_file}.bak.$(date +%Y%m%d-%H%M%S)"

# 保留旧规则备份，再改为精确到接口的持久绑定。
if [[ -f "${rule_file}" ]]; then
  cp -a "${rule_file}" "${backup_file}"
fi

cat > "${rule_file}" <<'RULE'
# DJI Baiwang 2ca3:4006：接口 0-3 为串口，接口 4 为 QMI 数据接口。
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="2ca3", ATTR{idProduct}=="4006", RUN+="/sbin/modprobe option", RUN+="/sbin/modprobe qmi_wwan"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTRS{idVendor}=="2ca3", ATTRS{idProduct}=="4006", ATTR{bInterfaceNumber}=="04", RUN+="/bin/sh -c 'echo %k > /sys/bus/usb/drivers/option/unbind 2>/dev/null || true; echo %k > /sys/bus/usb/drivers/qmi_wwan/bind'"
RULE

chmod 0644 "${rule_file}"
udevadm control --reload-rules
modprobe option
modprobe qmi_wwan

# 定位当前 2ca3:4006 设备的第 4 号接口，避免写死 USB 总线路径。
qmi_interface=""
for interface_path in /sys/bus/usb/devices/*:1.4; do
  [[ -e "${interface_path}" ]] || continue
  device_path="$(dirname "${interface_path}")/$(basename "${interface_path}" | cut -d: -f1)"
  if [[ "$(cat "${device_path}/idVendor" 2>/dev/null || true)" == "2ca3" ]] && \
     [[ "$(cat "${device_path}/idProduct" 2>/dev/null || true)" == "4006" ]]; then
    qmi_interface="$(basename "${interface_path}")"
    break
  fi
done

if [[ -z "${qmi_interface}" ]]; then
  echo "未找到 DJI 模块的 QMI 接口" >&2
  exit 1
fi

# 释放假串口接口，然后精确绑定到 qmi_wwan。
if [[ -L "/sys/bus/usb/devices/${qmi_interface}/driver" ]]; then
  current_driver="$(basename "$(readlink -f "/sys/bus/usb/devices/${qmi_interface}/driver")")"
  if [[ "${current_driver}" == "option" ]]; then
    echo "${qmi_interface}" > /sys/bus/usb/drivers/option/unbind
  fi
fi
echo "${qmi_interface}" > /sys/bus/usb/drivers/qmi_wwan/bind
sleep 3

systemctl restart openvohive.service
sleep 5

echo "=== QMI 接口 ==="
readlink -f "/sys/bus/usb/devices/${qmi_interface}/driver"
echo "=== 设备节点 ==="
ls -l /dev/cdc-wdm* /dev/ttyUSB* 2>&1
echo "=== 网卡 ==="
ip -brief link | grep -E 'wwan|enp|lo'
echo "=== OpenVoHive ==="
systemctl is-active openvohive.service
