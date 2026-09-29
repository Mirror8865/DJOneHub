# DJOneHub

DJI 4G 模块的 Mac、iPhone/iPad 与 QDC507 Agent 源码，以及用于诊断和修复 QDC507 USB/QMI/ADB 状态的辅助工具。

当前仓库首发版本为 `v1.0.0`。这是 GitHub 项目版本；各组件保留其真实独立版本，避免发布包与源码版本被错误伪造。

当前源码基线：

- Mac 客户端与后台：`1.2.10 (19)`
- iPhone/iPad 客户端：`0.7.6 (41)`
- QDC507 Agent：`0.3.21`

## 目录

- `macOS/`：Mac 客户端与后台 Go 源码。
- `iPadOS/`：iPhone/iPad Swift/Xcode 工程。
- `module/`：QDC507 Agent、内核桥接和构建工具。
- `tools/qdc507-legacy/`：独立诊断、配置、USB/QMI/ADB 修复工具的源码与脚本。
- `docs/release/`：本次正式基线的发布说明。
- `release-assets/`：仅在本地暂存、等待上传至私有 GitHub Release 的发布包；二进制不会被 Git 跟踪。

## 发布策略

源码仓库建议设为 **Private**。正式模块更新包 `module-update-0.3.21.djupdate` 不进入 Git 历史，应作为对应 Release 的附件上传；其校验值和操作说明见 [release-assets/README.md](release-assets/README.md)。

在构建 iPhone/iPad App 前，先从该 Release 下载包并放到 `iPadOS/DJOneHub-iPad/Resources/module-update.djupdate`。该路径被 Xcode 作为 App 资源引用，但文件受 Git 忽略，以免二进制进入源码历史。

本仓库刻意不包含 WebUSB 刷写器、ESP32 实验、测试固件、历史 IPA/DMG/ZIP、回滚备份、路由器备份及无关资料。

## 安全边界

不得提交私钥、部署令牌、Apple provisioning profile 或构建归档。`.gitignore` 只是最后一道防线，上传前仍须执行一次敏感信息审查。
