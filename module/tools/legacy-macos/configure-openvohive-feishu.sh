#!/usr/bin/env bash
set -euo pipefail

# 必须由 root 执行，避免配置文件权限不足导致半写入状态。
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本" >&2
  exit 1
fi

config_file="/opt/openvohive/config.yaml"
backup_file="${config_file}.bak.$(date +%Y%m%d-%H%M%S)"

# 修改前创建带时间戳的备份，便于出现问题时恢复。
cp -a "${config_file}" "${backup_file}"

CONFIG_FILE="${config_file}" python3 <<'PY'
import os
import tempfile
from pathlib import Path

import yaml

config_path = Path(os.environ["CONFIG_FILE"])
with config_path.open("r", encoding="utf-8") as source:
    config = yaml.safe_load(source) or {}

# 仅替换 webhook 节点；Telegram、Email 以及其他配置保持原样。
webhook = config.get("webhook")
if not isinstance(webhook, dict):
    webhook = {}
webhook.update(
    {
        "enabled": True,
        "urls": ["http://127.0.0.1:17576/notify"],
        "secret": "",
        "timeout_ms": 5000,
        "retry_max": 1,
        "text_template": "",
        "headers": {},
    }
)
config["webhook"] = webhook

# 在同一目录原子替换，避免写入中断破坏原配置。
fd, temp_name = tempfile.mkstemp(prefix=".config.yaml.", dir=config_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        yaml.safe_dump(config, target, allow_unicode=True, sort_keys=False)
        target.flush()
        os.fsync(target.fileno())
    os.chmod(temp_name, config_path.stat().st_mode & 0o777)
    os.chown(temp_name, config_path.stat().st_uid, config_path.stat().st_gid)
    os.replace(temp_name, config_path)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)
PY

# 验证 YAML 可解析后再重启服务。
CONFIG_FILE="${config_file}" python3 - <<'PY'
import os
import yaml

with open(os.environ["CONFIG_FILE"], "r", encoding="utf-8") as source:
    config = yaml.safe_load(source)
assert config["webhook"]["enabled"] is True
assert config["webhook"]["urls"] == ["http://127.0.0.1:17576/notify"]
print("Webhook 配置校验通过")
PY

systemctl restart openvohive-feishu.service
systemctl restart openvohive.service

echo "配置完成，备份文件：${backup_file}"
systemctl is-active openvohive-feishu.service
systemctl is-active openvohive.service
