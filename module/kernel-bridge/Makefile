obj-m += qdc507_data11_bridge.o

# Android 预编译 GCC 默认启用 -fpic，旧 QDC507 模块加载器不支持 R_ARM_REL32。
ccflags-y += -fno-pic

# 实机 struct module 无条件保留 sig_ok；该厂商 ABI 比公开源码多 4 字节。
ccflags-y += -DCONFIG_MODULE_SIG
