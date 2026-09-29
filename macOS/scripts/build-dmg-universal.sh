#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-v1.2.10}
DMG_NAME="DJOneHub-macOS-universal-${VERSION}.dmg"
DMG="${ROOT_DIR}/dist/${DMG_NAME}"
CHECKSUM="${DMG}.sha256"
NOTIFIER_SRC="${ROOT_DIR}/macos/DJOneHubNotifier"
BUILD_ROOT="${TMPDIR:-/tmp}/djonehub-macos-package-universal"
# 镜像暂存必须位于本地临时卷，避免文档文件提供器把 Finder 属性写入已签名 App。
STAGE="${BUILD_ROOT}/dmg-stage-universal"
DMG_TEMP="${BUILD_ROOT}/${DMG_NAME}"

echo "==> 1/4 构建通用主程序（arm64 + x86_64）"
"${ROOT_DIR}/scripts/package-macos-universal.sh" "${VERSION}"

echo "==> 2/4 构建通用通知助手"
mkdir -p "${BUILD_ROOT}/local-cache/clang" "${BUILD_ROOT}/local-cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/local-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_ROOT}/local-cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="${BUILD_ROOT}/local-cache/swiftpm"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
  echo "A full Xcode installation is required to build the Intel notifier slice." >&2
  exit 1
fi
cd "${NOTIFIER_SRC}"
swift build --disable-sandbox -c release
"${NOTIFIER_SRC}/.build/release/DJOneHubNotifier" --self-test

# SwiftPM on an Apple-Silicon host normally emits only the native slice. Build
# the Intel slice explicitly, including the two local C targets used by the
# notifier. This avoids claiming a universal app while silently shipping arm64.
INTEL_ROOT="${BUILD_ROOT}/notifier-x86_64"
rm -rf "${INTEL_ROOT}"
mkdir -p "${INTEL_ROOT}/module-cache"
cat > "${INTEL_ROOT}/CModemBridge.modulemap" <<EOF
module CModemBridge { header "${NOTIFIER_SRC}/Sources/CModemBridge/include/CModemBridge.h" export * }
EOF
cat > "${INTEL_ROOT}/CUACProbe.modulemap" <<EOF
module CUACProbe { header "${NOTIFIER_SRC}/Sources/CUACProbe/include/CUACProbe.h" export * }
EOF
xcrun clang -target x86_64-apple-macosx13.0 -O2 -fmodules \
  -fmodules-cache-path="${INTEL_ROOT}/module-cache" \
  -fmodule-map-file="${INTEL_ROOT}/CModemBridge.modulemap" \
  -I Sources/CModemBridge/include -c Sources/CModemBridge/ModemBridge.c \
  -o "${INTEL_ROOT}/ModemBridge.o"
xcrun clang -target x86_64-apple-macosx13.0 -O2 -fmodules \
  -fmodules-cache-path="${INTEL_ROOT}/module-cache" \
  -fmodule-map-file="${INTEL_ROOT}/CUACProbe.modulemap" \
  -I Sources/CUACProbe/include -c Sources/CUACProbe/CUACProbe.c \
  -o "${INTEL_ROOT}/CUACProbe.o"
xcrun swiftc -O -target x86_64-apple-macosx13.0 -sdk "$(xcrun --show-sdk-path)" \
  -Xcc -fmodules-cache-path="${INTEL_ROOT}/module-cache" \
  -Xcc -fmodule-map-file="${INTEL_ROOT}/CModemBridge.modulemap" \
  -Xcc -fmodule-map-file="${INTEL_ROOT}/CUACProbe.modulemap" \
  -I Sources/CModemBridge/include -I Sources/CUACProbe/include \
  Sources/DJOneHubNotifier/*.swift "${INTEL_ROOT}/ModemBridge.o" "${INTEL_ROOT}/CUACProbe.o" \
  -framework CoreAudio -framework CoreFoundation -framework IOKit -framework AVFoundation \
  -framework AppKit -framework UserNotifications -framework Contacts \
  -o "${INTEL_ROOT}/DJOneHubNotifier"
rm -f "${BUILD_ROOT}/DJOneHubNotifier-universal"
lipo -create "${NOTIFIER_SRC}/.build/release/DJOneHubNotifier" "${INTEL_ROOT}/DJOneHubNotifier" \
  -output "${BUILD_ROOT}/DJOneHubNotifier-universal"
file "${BUILD_ROOT}/DJOneHubNotifier-universal" | cut -c1-120
for arch in arm64 x86_64; do
  lipo "${BUILD_ROOT}/DJOneHubNotifier-universal" -verify_arch "${arch}"
done

echo "==> 3/4 组装安装目录"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/DJOneHubNotifier.app/Contents/MacOS" "${STAGE}/DJOneHubNotifier.app/Contents/Resources"
ditto --norsrc --noextattr --noqtn --noacl "${ROOT_DIR}/dist/release/DJOneHub-macOS-universal-${VERSION}" "${STAGE}/djonehub"
cp "${BUILD_ROOT}/DJOneHubNotifier-universal" "${STAGE}/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier"
cp "${NOTIFIER_SRC}/Info.plist" "${STAGE}/DJOneHubNotifier.app/Contents/Info.plist"
cp "${NOTIFIER_SRC}/Resources/AppIcon.icns" "${STAGE}/DJOneHubNotifier.app/Contents/Resources/AppIcon.icns"
chmod 755 "${STAGE}/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier"
# Finder 扩展属性会让 codesign --strict 将有效程序误判为被修改，签名前必须清理。
xattr -cr "${STAGE}/DJOneHubNotifier.app"
codesign --force --deep --sign - "${STAGE}/DJOneHubNotifier.app"
# 文件提供器可能在签名时重新附加根目录属性；它们不属于签名资源，必须在验签前移除。
xattr -d com.apple.FinderInfo "${STAGE}/DJOneHubNotifier.app" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "${STAGE}/DJOneHubNotifier.app" 2>/dev/null || true
codesign --verify --deep --strict "${STAGE}/DJOneHubNotifier.app"
plutil -lint "${STAGE}/DJOneHubNotifier.app/Contents/Info.plist"
for binary in \
  "${STAGE}/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier" \
  "${STAGE}/djonehub/bin/djonehub-macos" \
  "${STAGE}/djonehub/lib/libusb-1.0.0.dylib"
do
  for arch in arm64 x86_64; do
    lipo "${binary}" -verify_arch "${arch}"
  done
done
cp "${ROOT_DIR}/scripts/dmg/安装 DJOneHub.command" "${STAGE}/安装 DJOneHub.command"
cp "${ROOT_DIR}/scripts/dmg/卸载 DJOneHub.command" "${STAGE}/卸载 DJOneHub.command"
cp "${ROOT_DIR}/scripts/dmg/使用说明.txt" "${STAGE}/使用说明.txt"
chmod 755 "${STAGE}/安装 DJOneHub.command" "${STAGE}/卸载 DJOneHub.command"

if find "${STAGE}" -type f \( -name '*.ko' -o -name '*.armv7' \) | grep -q .; then
  echo "Public DMG unexpectedly contains a module-side runtime." >&2
  exit 1
fi

echo "==> 4/4 生成 DMG"
rm -f "${DMG_TEMP}" "${DMG}" "${CHECKSUM}"
# 先在本地临时卷生成并校验，避免同步目录占用输出文件时生成损坏 DMG。
hdiutil create -volname "DJOneHub" -srcfolder "${STAGE}" -ov -format UDZO "${DMG_TEMP}"
hdiutil verify "${DMG_TEMP}"
cp "${DMG_TEMP}" "${DMG}"
(
  cd "$(dirname -- "${DMG}")"
  shasum -a 256 "$(basename -- "${DMG}")" >"$(basename -- "${CHECKSUM}")"
)

echo
echo "完成：${DMG}"
echo "校验：${CHECKSUM}"
