#!/bin/zsh
set -u

# DJOneHub macOS 权限修复：只处理软件实际需要的通讯录、麦克风和后台启动。
# macOS 不允许普通脚本静默授权；本脚本只重置损坏记录并触发官方授权流程。

bundle_id="com.jamie.djonehub.notifier"
agent_label="com.jamie.djonehub"
notifier_label="com.jamie.djonehub-notifier"
notifier_app="$HOME/Library/Application Support/DJOneHub/notifier/DJOneHubNotifier.app"
backend_binary="$HOME/Library/Application Support/DJOneHub/runtime/bin/djonehub-macos"
agent_plist="$HOME/Library/LaunchAgents/com.jamie.djonehub.plist"
notifier_plist="$HOME/Library/LaunchAgents/com.jamie.djonehub-notifier.plist"
check_only=0

if [[ "${1:-}" == "--check-only" ]]; then
  check_only=1
elif [[ $# -ne 0 ]]; then
  echo "用法：$(basename -- "$0") [--check-only]" >&2
  exit 64
fi

pause_before_exit() {
  if [[ -t 0 ]]; then
    echo
    read -r "answer?按回车键关闭窗口……"
  fi
}

fail() {
  echo "失败：$1" >&2
  pause_before_exit
  exit 1
}

echo "DJOneHub macOS 权限检查与修复"
echo "--------------------------------"

# 修复包面向当前用户，不使用 sudo，也不会修改系统 TCC 数据库。
[[ -d "$notifier_app" ]] || fail "未找到 DJOneHub 通知助手，请先安装 DJOneHub v1.2.9。"
[[ -x "$backend_binary" ]] || fail "未找到 DJOneHub 后台程序，请重新安装完整版本。"
[[ -f "$agent_plist" && -f "$notifier_plist" ]] || fail "LaunchAgent 配置不完整，请重新安装 DJOneHub。"

installed_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$notifier_app/Contents/Info.plist" 2>/dev/null || true)
[[ "$installed_bundle_id" == "$bundle_id" ]] || fail "通知助手 Bundle ID 异常：${installed_bundle_id:-未知}"

contacts_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSContactsUsageDescription' "$notifier_app/Contents/Info.plist" 2>/dev/null || true)
microphone_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$notifier_app/Contents/Info.plist" 2>/dev/null || true)
[[ -n "$contacts_reason" ]] || fail "安装包缺少 NSContactsUsageDescription。"
[[ -n "$microphone_reason" ]] || fail "安装包缺少 NSMicrophoneUsageDescription。"

if /usr/bin/codesign --verify --deep --strict "$notifier_app" >/dev/null 2>&1; then
  echo "✓ 通知助手签名完整"
else
  fail "通知助手签名已损坏；继续重置权限也不会稳定生效，请重新安装官方包。"
fi

if /bin/launchctl print "gui/$(id -u)/$agent_label" >/dev/null 2>&1; then
  echo "✓ 后台服务已加载"
else
  echo "! 后台服务未加载，修复阶段会重新启动"
fi
if /bin/launchctl print "gui/$(id -u)/$notifier_label" >/dev/null 2>&1; then
  echo "✓ 通知助手已加载"
else
  echo "! 通知助手未加载，修复阶段会重新启动"
fi

if /usr/bin/curl --max-time 3 -fsS http://127.0.0.1:7575/api/health >/dev/null 2>&1; then
  echo "✓ DJOneHub 本机服务正常"
else
  echo "! DJOneHub 本机服务暂时不可用"
fi

echo
echo "软件实际需要：通讯录、麦克风、允许后台运行。"
echo "软件不需要：摄像头、屏幕录制、辅助功能、输入监控、完全磁盘访问。"

if [[ "$check_only" -eq 1 ]]; then
  echo
  echo "仅检查模式完成，没有修改任何授权记录。"
  pause_before_exit
  exit 0
fi

echo
echo "接下来会清除 DJOneHub 以前的‘允许/拒绝’记录，让 macOS 重新询问。"
echo "这不会读取或修改通讯录内容，也不会直接打开麦克风。"
read -r "confirmation?输入 YES 后继续："
[[ "$confirmation" == "YES" ]] || fail "用户取消。"

# 先停止通知助手，避免它在 TCC 重置过程中立即发起旧会话请求。
/bin/launchctl bootout "gui/$(id -u)/$notifier_label" >/dev/null 2>&1 || true

contacts_reset=0
microphone_reset=0
if /usr/bin/tccutil reset AddressBook "$bundle_id" >/dev/null 2>&1; then
  contacts_reset=1
  echo "✓ 已重置通讯录授权记录"
else
  echo "! 无法重置通讯录记录，请稍后在系统设置中手动检查"
fi
if /usr/bin/tccutil reset Microphone "$bundle_id" >/dev/null 2>&1; then
  microphone_reset=1
  echo "✓ 已重置麦克风授权记录"
else
  echo "! 无法重置麦克风记录，请稍后在系统设置中手动检查"
fi

# 后台与通知助手分别恢复；不重启 4G 模块，不会改 SIM、eSIM 或 USB 参数。
if ! /bin/launchctl print "gui/$(id -u)/$agent_label" >/dev/null 2>&1; then
  /bin/launchctl bootstrap "gui/$(id -u)" "$agent_plist" >/dev/null 2>&1 || true
fi
/bin/launchctl bootstrap "gui/$(id -u)" "$notifier_plist" >/dev/null 2>&1 || true
/usr/bin/open "$notifier_app" >/dev/null 2>&1 || true

echo
echo "请处理屏幕上的‘通讯录’弹窗并选择“允许”。"
/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts' >/dev/null 2>&1 || true
echo "通讯录处理完成后回到此窗口。"
read -r "continue_answer?按回车键继续打开麦克风设置……"

/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone' >/dev/null 2>&1 || true
echo
echo "麦克风权限只会在接通电话、DJOneHub 首次启动通话音频时弹出。"
echo "请拨打或接听一次测试电话，在弹窗中选择“允许”；若列表已有 DJOneHub，请打开开关。"

# 最后打开后台项目页面，便于确认 DJOneHub 没有被用户手动禁用。
read -r "background_answer?按回车键继续检查后台项目……"
/usr/bin/open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension' >/dev/null 2>&1 || true

echo
if [[ "$contacts_reset" -eq 1 && "$microphone_reset" -eq 1 ]]; then
  echo "✓ 权限记录修复完成"
else
  echo "! 修复已完成，但有授权记录无法自动重置，请按上面的设置页手动开启"
fi
echo "✓ DJOneHub 服务已恢复；本脚本没有修改模块、SIM 或网络配置"
pause_before_exit
