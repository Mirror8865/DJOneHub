#!/usr/bin/env bash
set -euo pipefail

# 必须以 root 身份运行，驱动动态 ID 和 udev 规则都需要管理员权限。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

vendor_id="2ca3"
product_id="4006"
rule_file="/etc/udev/rules.d/99-dji-baiwang.rules"

# 加载串口与 QMI 驱动；模块已加载时该操作也是安全的。
modprobe option
modprobe qmi_wwan

# 注册当前模块的厂商 ID，使现有设备立即生成串口与 QMI 控制口。
if [[ -w /sys/bus/usb-serial/drivers/option1/new_id ]]; then
  echo "${vendor_id} ${product_id}" > /sys/bus/usb-serial/drivers/option1/new_id || true
fi
if [[ -w /sys/bus/usb/drivers/qmi_wwan/new_id ]]; then
  echo "${vendor_id} ${product_id}" > /sys/bus/usb/drivers/qmi_wwan/new_id || true
fi

# 持久规则：以后插入同型号模块时自动注册两个驱动，无需再次手动执行。
cat > "${rule_file}" <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2ca3", ATTR{idProduct}=="4006", RUN+="/bin/sh -c 'echo 2ca3 4006 > /sys/bus/usb-serial/drivers/option1/new_id'", RUN+="/bin/sh -c 'echo 2ca3 4006 > /sys/bus/usb/drivers/qmi_wwan/new_id'"
RULE

chmod 0644 "${rule_file}"
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor="${vendor_id}" --attr-match=idProduct="${product_id}" || true
sleep 3

# 驱动出现后重启管理服务，让 OpenVoHive 重新扫描新模块。
systemctl restart openvohive.service
sleep 3

echo "=== USB ==="
lsusb -d "${vendor_id}:${product_id}"
echo "=== 设备节点 ==="
ls -l /dev/cdc-wdm* /dev/ttyUSB* 2>&1 || true
echo "=== 网卡 ==="
ip -brief link | grep -E 'wwan|enp|lo'
echo "=== OpenVoHive ==="
systemctl is-active openvohive.service
