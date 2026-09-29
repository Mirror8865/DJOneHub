# 仓库范围与审计结论

本候选仓库只纳入经过确认的正式源码基线和 QDC507 维护工具：

| 类别 | 处理 |
| --- | --- |
| Mac、iPhone/iPad、QDC507 Agent 源码 | 保留 |
| QDC507 独立诊断和修复源码/脚本 | 保留，归入 `tools/qdc507-legacy/` |
| 正式模块包 `0.3.21` | 仅作为 Private Release 附件，本地暂存 |
| WebUSB 刷写器 `0.1.0` | 排除 |
| ESP32-S3 屏幕、USB、HomePod 歌词实验 | 排除 |
| 测试固件 `0.3.45`、`0.4.2` | 排除 |
| 历史 IPA、DMG、ZIP、回滚包、构建产物 | 排除 |
| r3p/OpenWrt 备份与咖啡菜单文件 | 排除 |
| 更新签名私钥、环境令牌、Apple provisioning profile | 排除且禁止上传 |

正式源码对应的发布清单见 [v0.7.6-full-20260821.md](release/v0.7.6-full-20260821.md)。
