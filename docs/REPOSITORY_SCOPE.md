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

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
