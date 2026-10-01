#!/bin/sh
set -eu

# 使用无空格的临时目录，规避旧版 Kbuild 对项目路径中空格的解析缺陷。
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KERNEL_SOURCE=${KERNEL_SOURCE:-/private/tmp/djonehub-msm-3.18}
KERNEL_OUTPUT=${KERNEL_OUTPUT:-/private/tmp/djonehub-kernel-out-x86}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/private/tmp/djonehub-arm-linux-androideabi-4.9}
HOST_INCLUDE=${HOST_INCLUDE:-/private/tmp/djonehub-host-include}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/djonehub-data11.XXXXXX")

cleanup() {
	# BUILD_DIR 由 mktemp 创建且不能为空，只删除本次构建产生的临时目录。
	if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
		rm -rf -- "$BUILD_DIR"
	fi
}
trap cleanup EXIT HUP INT TERM

if [ ! -d "$KERNEL_SOURCE" ] || [ ! -d "$KERNEL_OUTPUT" ]; then
	echo "错误：缺少内核源码或输出目录" >&2
	exit 1
fi

if [ ! -x "$TOOLCHAIN_DIR/bin/real-arm-linux-androideabi-gcc" ]; then
	echo "错误：找不到匹配 QDC507 固件的 GCC 4.9 交叉编译器" >&2
	exit 1
fi

cp "$SCRIPT_DIR/qdc507_data11_bridge.c" "$BUILD_DIR/"
cp "$SCRIPT_DIR/Makefile" "$BUILD_DIR/"

# 显式指定 LOCALVERSION=，确保 vermagic 是 3.18.44 而不是 3.18.44+。
make -C "$KERNEL_SOURCE" \
	O="$KERNEL_OUTPUT" \
	M="$BUILD_DIR" \
	ARCH=arm \
	CROSS_COMPILE="$TOOLCHAIN_DIR/bin/arm-linux-androideabi-" \
	CC="$TOOLCHAIN_DIR/bin/real-arm-linux-androideabi-gcc" \
	HOSTCC="arch -x86_64 /usr/bin/clang" \
	HOST_EXTRACFLAGS="-I$HOST_INCLUDE -fno-pie -DKBUILD_NO_NLS" \
	HOSTLDFLAGS="-Wl,-no_pie" \
	LOCALVERSION= \
	KBUILD_MODPOST_WARN=1 \
	modules

cp "$BUILD_DIR/qdc507_data11_bridge.ko" "$SCRIPT_DIR/"
echo "已生成：$SCRIPT_DIR/qdc507_data11_bridge.ko"
