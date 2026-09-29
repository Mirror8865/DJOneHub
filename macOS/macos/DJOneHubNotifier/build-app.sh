#!/bin/zsh

set -eu

root="${0:A:h}"
build_root="${root}/.build"
output_root="${root}/dist"
app="${output_root}/DJOneHubNotifier.app"
cache_root="${build_root}/local-cache"

cd "${root}"
mkdir -p "${cache_root}/clang" "${cache_root}/swiftpm"
export CLANG_MODULE_CACHE_PATH="${cache_root}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="${cache_root}/swiftpm"
swift build --disable-sandbox -c release
"${build_root}/release/DJOneHubNotifier" --self-test

rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "${build_root}/release/DJOneHubNotifier" "${app}/Contents/MacOS/DJOneHubNotifier"
cp "${root}/Info.plist" "${app}/Contents/Info.plist"
cp "${root}/Resources/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
chmod 755 "${app}/Contents/MacOS/DJOneHubNotifier"
# 清理 Finder 元数据，避免严格验签把复制后的 App 误判为篡改。
xattr -cr "${app}"
codesign --force --deep --sign - "${app}"
# 同上：仅清理 App 根目录的文件提供器元数据，保留代码签名所需资源。
xattr -d com.apple.FinderInfo "${app}" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "${app}" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "${app}"
plutil -lint "${app}/Contents/Info.plist"

print -r -- "${app}"
