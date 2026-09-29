# DJOneHub QDC507 ADB 修复包

版本：1.0.0

## 解决的问题

适用于 DJOneHub 通话时出现以下错误的情况：

```text
USB ADB interface (6/adb) not found on 2c7c:0125
```

部分 Baiwang QDC507 固件会接受 DJOneHub 写入的 USB 配置，但在回读时把 ADB 位恢复为 `0`。该固件需要先完成 `AT+QADBKEY` 挑战解锁，才能持久启用 ADB interface 6。

## 适用范围

- macOS 13 或更新版本。
- 已安装并正在运行 DJOneHub，已验证版本为 `1.2.9 (18)`。
- 模块型号包含 `QDC507`。
- USB 设备为 `2c7c:0125`。
- 当前配置必须严格匹配此模块的已知修复前或修复后配置。

不符合上述条件时，脚本会拒绝写入。不要为了通过检查而手工修改脚本中的设备标识或 USB 配置。

## 使用方法

1. 结束正在进行的通话，但保持模块连接和 DJOneHub 运行。
2. 可先双击 `检查修复状态.command` 执行只读检查。
3. 双击 `一键修复 ADB.command`。
4. 等待模块重启并重新枚举，窗口显示修复完成后再关闭。
5. 重新打开 DJOneHub，确认不再提示 ADB interface 6 缺失。

如果 macOS 提示无法验证开发者，请先确认 ZIP 的 SHA-256 与发布者提供的值一致，然后在 Finder 中右键 `.command` 文件并选择“打开”。也可以前往“系统设置 → 隐私与安全性”，在确认文件可信后选择“仍要打开”。不要使用来源不明的命令绕过 Gatekeeper。

## 脚本会做什么

- 通过本机 `127.0.0.1:7575` 调用 DJOneHub API。
- 确认当前没有通话，并核对 QDC507 型号与 USB 配置。
- 将原始 `USBCFG` 保存到：

  ```text
  ~/Library/Application Support/DJOneHub/module-backups/
  ```

- 在内存中计算一次性 QADBKEY 响应，不把响应写入日志或备份。
- 只把 USB 配置中的 ADB 位从 `0` 改为 `1`，其他字段保持不变。
- 写入后立即回读；未严格匹配目标值时不会重启模块。
- 受控重启模块，并验证 `interface 6 / subclass 66 / protocol 1` 已枚举。

脚本不会刷写固件、修改 SIM/eSIM、读取短信或通讯录，也不会上传数据。

## 安全与限制

- 修复脚本仅接受两组已知的精确配置，不对未知模块猜测写入。
- 重复运行是幂等的：ADB 已生效时不会重复写入或重启。
- 本工具只修复 ADB interface 6，不处理其他问题。
- 这是社区修复工具，与 DJI、Baiwang、Quectel 和 DJOneHub 官方没有隶属关系。

## 文件校验

ZIP 同目录提供 `.sha256` 文件。在终端中可运行：

```bash
shasum -a 256 -c DJOneHub-QDC507-ADB-Fix-v1.0.0.zip.sha256
```

## 许可证

本修复包使用 MIT License，详见 `LICENSE`。
