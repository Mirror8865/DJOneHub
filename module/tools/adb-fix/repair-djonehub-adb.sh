#!/usr/bin/env bash
set -euo pipefail

# 为带 QADBKEY 锁的 QDC507 解锁 ADB，并且只修改 USBCFG 的 ADB 位。
# 该脚本拒绝在通话中、USB 配置不匹配或回读失败时重启模块。

readonly API_BASE="${DJONEHUB_API_BASE:-http://127.0.0.1:7575}"
readonly SOURCE_CONFIG='0X2C7C,0X125,1,1,1,1,1,0,1'
readonly TARGET_CONFIG='0X2C7C,0X125,1,1,1,1,1,1,1'
readonly PACKAGE_VERSION='1.0.0'

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1" >&2
    exit 1
  }
}

json_operation() {
  local operation="$1"
  local raw_json="$2"
  /usr/bin/osascript -l JavaScript -e '
    function run(argv) {
      const operation = argv[0];
      const value = JSON.parse(argv[1]);
      const interfaces = value.usb_device && Array.isArray(value.usb_device.interfaces)
        ? value.usb_device.interfaces
        : [];
      const hasADB = interfaces.some(item =>
        item.number === 6 && (item.subclass === 66 || item.protocol === 1)
      );

      switch (operation) {
      case "at-response":
        if (typeof value.response === "string") return value.response;
        throw new Error(value.error || "AT 请求失败");
      case "no-active-call":
        return String(value.active === null);
      case "health-ok":
        return String(value.ok === true);
      case "adb-active":
        return String(hasADB);
      case "target-ready":
        return String(
          value.ok === true &&
          value.usb_device.vendor_id === "2c7c" &&
          value.usb_device.product_id === "0125" &&
          hasADB
        );
      case "qdc507":
        return String(typeof value.firmware === "string" && value.firmware.includes("QDC507"));
      default:
        throw new Error("未知 JSON 操作");
      }
    }
  ' "${operation}" "${raw_json}"
}

make_at_payload() {
  /usr/bin/osascript -l JavaScript -e '
    function run(argv) {
      return JSON.stringify({command: argv[0]});
    }
  ' "$1"
}

normalize_at_response() {
  tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]' | sed 's/0X0125/0X125/g'
}

run_at() {
  local command="$1"
  local payload raw response
  payload="$(make_at_payload "${command}")"
  raw="$(curl -sS -X POST "${API_BASE}/api/at" \
    -H 'Content-Type: application/json' \
    --data-binary "${payload}")"
  response="$(json_operation at-response "${raw}")"
  printf '%s' "${response}"
}

read_usb_config() {
  run_at 'AT+QCFG="USBCFG"' | normalize_at_response
}

save_usb_backup() {
  local current="$1"
  local backup_dir backup_path
  backup_dir="${HOME}/Library/Application Support/DJOneHub/module-backups"
  backup_path="${backup_dir}/usb-before-qadbkey-fix-$(date '+%Y%m%d-%H%M%S').txt"
  mkdir -p "${backup_dir}"
  (
    umask 077
    printf 'DJOneHub QDC507 ADB Fix %s\n' "${PACKAGE_VERSION}" >"${backup_path}"
    printf 'created_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"${backup_path}"
    printf 'original_usbcfg=%s\n' "${current}" >>"${backup_path}"
  )
  printf '%s' "${backup_path}"
}

wait_for_backend() {
  local attempt health
  for attempt in {1..90}; do
    health="$(curl -sS --max-time 2 "${API_BASE}/api/health" 2>/dev/null || true)"
    if [[ "$(json_operation target-ready "${health}" 2>/dev/null || true)" == true ]]; then
      printf '%s' "${health}"
      return 0
    fi
    sleep 1
  done
  return 1
}

main() {
  local call_status current challenge_response challenge crypt_hash unlock_key
  local unlock_response write_response readback restart_response health status backup_path
  local action="${1:-}"
  local adb_active=false

  [[ "$#" -le 1 ]] || {
    echo "用法：$0 [--check|--restart]" >&2
    exit 64
  }
  case "${action}" in
  ''|--check|--restart) ;;
  *)
    echo "用法：$0 [--check|--restart]" >&2
    exit 64
    ;;
  esac

  for command in curl openssl osascript sed; do
    require_command "${command}"
  done

  health="$(curl -fsS "${API_BASE}/api/health")" || {
    echo "DJOneHub 后端不可用：${API_BASE}" >&2
    exit 1
  }
  [[ "$(json_operation health-ok "${health}")" == true ]] || {
    echo "DJOneHub 尚未识别到可用模块" >&2
    exit 1
  }
  status="$(curl -fsS "${API_BASE}/api/status")"
  [[ "$(json_operation qdc507 "${status}")" == true ]] || {
    echo "当前设备不是已验证的 QDC507，拒绝执行修复" >&2
    exit 1
  }
  if [[ "$(json_operation adb-active "${health}")" == true ]]; then
    adb_active=true
  fi

  # 避免在通话期间重枚举 USB，防止正在进行的呼叫失去控制通道。
  call_status="$(curl -fsS "${API_BASE}/api/calls/status")"
  [[ "$(json_operation no-active-call "${call_status}")" == true ]] || {
    echo "模块正在通话，拒绝修改 USB 配置" >&2
    exit 1
  }

  current="$(read_usb_config)"
  if [[ "${action}" == "--check" ]]; then
    if [[ "${current}" == *"${TARGET_CONFIG}"* && "${adb_active}" == true ]]; then
      echo "检查通过：ADB interface 6 已启用"
      return 0
    fi
    if [[ "${current}" == *"${SOURCE_CONFIG}"* ]]; then
      echo "检查结果：模块尚未启用 ADB，需要运行一键修复"
      return 2
    fi
    echo "检查结果：USBCFG 不属于此修复包支持的配置：${current}" >&2
    return 3
  fi

  if [[ "${current}" == *"${TARGET_CONFIG}"* ]]; then
    echo "ADB 配置已经启用，无需重复写入"
  elif [[ "${current}" == *"${SOURCE_CONFIG}"* ]]; then
    backup_path="$(save_usb_backup "${current}")"
    echo "原始 USB 配置已备份：${backup_path}"
    challenge_response="$(run_at 'AT+QADBKEY?')"
    challenge="$(sed -nE 's/.*\+QADBKEY:[[:space:]]*([0-9]{8}).*/\1/p' <<<"${challenge_response}" | head -n 1)"
    [[ "${challenge}" =~ ^[0-9]{8}$ ]] || {
      echo "模块没有返回有效的 QADBKEY 挑战码" >&2
      exit 1
    }

    # Quectel QADBKEY 使用挑战码作为 MD5-crypt salt，响应只取摘要前 15 位。
    crypt_hash="$(openssl passwd -1 -salt "${challenge}" SH_adb_quectel)"
    unlock_key="$(awk -F '\\$' '{print substr($4, 1, 15)}' <<<"${crypt_hash}")"
    [[ "${unlock_key}" =~ ^[./0-9A-Za-z]{15}$ ]] || {
      echo "QADBKEY 响应计算失败" >&2
      exit 1
    }

    unlock_response="$(run_at "AT+QADBKEY=\"${unlock_key}\"")"
    [[ "$(normalize_at_response <<<"${unlock_response}")" == *OK ]] || {
      echo "模块拒绝 QADBKEY 解锁" >&2
      exit 1
    }
    unset unlock_key crypt_hash
    echo "QADBKEY 解锁已确认"

    write_response="$(run_at 'AT+QCFG="USBCFG",0x2C7C,0x0125,1,1,1,1,1,1,1')"
    [[ "$(normalize_at_response <<<"${write_response}")" == *OK ]] || {
      echo "模块拒绝写入 ADB USB 配置" >&2
      exit 1
    }

    readback="$(read_usb_config)"
    [[ "${readback}" == *"${TARGET_CONFIG}"* ]] || {
      echo "USB 配置回读未确认，已停止且不会重启模块" >&2
      exit 1
    }
    echo "ADB 配置回读已确认"
  else
    echo "当前 USBCFG 不属于已知安全源配置，拒绝写入：${current}" >&2
    exit 1
  fi

  if [[ "${action}" != "--restart" ]]; then
    if [[ "${adb_active}" == true ]]; then
      echo "修复已生效：USB ADB interface 6 已枚举"
    else
      echo "配置已就绪；使用 --restart 执行一次受控模块重启"
    fi
    return 0
  fi

  # 已经生效时保持幂等，不为重复执行脚本再次打断 USB 服务。
  if [[ "${adb_active}" == true ]]; then
    echo "修复已生效：无需重复重启模块"
    return 0
  fi

  echo "正在重启模块并等待 USB 重新枚举..."
  restart_response="$(run_at 'AT+CFUN=1,1' 2>/dev/null || true)"
  unset restart_response
  # 给 USB 旧枚举留出下线时间，避免把重启前缓存状态误判为恢复完成。
  sleep 3
  health="$(wait_for_backend)" || {
    echo "模块重启后 90 秒内未恢复，请重新插拔模块后再检查" >&2
    exit 1
  }

  # ADB 在目标组合中应为 interface 6，subclass 66 是 Android Debug Bridge。
  [[ "$(json_operation target-ready "${health}")" == true ]] || {
    echo "模块已恢复，但 USB interface 6 仍不是 ADB" >&2
    exit 1
  }
  echo "修复完成：USB ADB interface 6 已枚举"
}

main "$@"
