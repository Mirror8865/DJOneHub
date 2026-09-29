#!/usr/bin/env bash
set -euo pipefail

# 必须以 root 身份运行，OpenVoHive 配置文件仅管理员可写。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

config_file="/opt/openvohive/config.yaml"
backup_file="${config_file}.bak.$(date +%Y%m%d-%H%M%S)"

# 新模块身份来自刚才对实体模块的 AT+CGSN 只读探测。
new_id="dji_4g_2"
new_name="DJI 4G 模块 2"
new_imei="863212060992838"

# 修改前完整备份，便于一键回退。
cp -a "${config_file}" "${backup_file}"

CONFIG_FILE="${config_file}" NEW_ID="${new_id}" NEW_NAME="${new_name}" NEW_IMEI="${new_imei}" python3 <<'PY'
import os
import tempfile
from pathlib import Path

import yaml

config_path = Path(os.environ["CONFIG_FILE"])
with config_path.open("r", encoding="utf-8") as source:
    config = yaml.safe_load(source) or {}

devices = config.get("devices")
if devices is None:
    devices = []
if not isinstance(devices, list):
    raise SystemExit("devices 配置不是列表，拒绝修改")

new_id = os.environ["NEW_ID"]
new_imei = os.environ["NEW_IMEI"]

# 设备 ID 或 IMEI 已存在时安全退出，避免重复添加。
for device in devices:
    if not isinstance(device, dict):
        continue
    if str(device.get("id", "")).strip() == new_id:
        raise SystemExit(f"设备 ID 已存在，未重复添加：{new_id}")
    if str(device.get("modem_imei", "")).strip() == new_imei:
        raise SystemExit("新模块 IMEI 已存在，未重复添加")

# 仅持久化身份和后端；运行时路径由 OpenVoHive 按 IMEI 自动解析。
devices.append(
    {
        "id": new_id,
        "name": os.environ["NEW_NAME"],
        "modem_imei": new_imei,
        "device_backend": "qmi",
    }
)
config["devices"] = devices

# 同目录原子替换，避免断电或异常导致半写配置。
fd, temp_name = tempfile.mkstemp(prefix=".config.yaml.", dir=config_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        yaml.safe_dump(config, target, allow_unicode=True, sort_keys=False)
        target.flush()
        os.fsync(target.fileno())
    old_stat = config_path.stat()
    os.chmod(temp_name, old_stat.st_mode & 0o777)
    os.chown(temp_name, old_stat.st_uid, old_stat.st_gid)
    os.replace(temp_name, config_path)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)
PY

# 重新读取验证：旧设备仍存在，且新设备恰好一条。
CONFIG_FILE="${config_file}" NEW_ID="${new_id}" python3 <<'PY'
import os
import yaml

with open(os.environ["CONFIG_FILE"], "r", encoding="utf-8") as source:
    config = yaml.safe_load(source) or {}
devices = config.get("devices") or []
assert len(devices) >= 2, "设备条目不足两条"
assert sum(1 for item in devices if item.get("id") == os.environ["NEW_ID"]) == 1
print(f"设备配置校验通过：共 {len(devices)} 条")
PY

systemctl restart openvohive.service
sleep 10

echo "配置完成，备份文件：${backup_file}"
systemctl is-active openvohive.service
journalctl -u openvohive.service -n 25 --no-pager
