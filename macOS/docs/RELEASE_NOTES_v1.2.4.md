# DJOneHub v1.2.4

## 本次更新

- macOS 通话媒体路径改为 MaVo UAC 音频策略：8 kHz 模块通道由原生 Swift 音频服务承载。
- 通话录音恢复为独立旁路写入，修复录音时间轴卡顿问题。
- 新增本机号码读取，兼容 `AT+CNUM` 前置空字段返回。
- 短信读取后自动清理模块存储，可在 App 内开关。
- 重新整理独立 macOS App 的拨号、通话、短信、通讯录、设置与系统提醒体验。
- 保留 4G、GPS、eSIM、AT 调试、网络策略与来电记录能力。

## 发布边界

v1.2.4 公开 Release 不包含模块侧通话运行时，也不承诺下载后即可双向通话。详情见根目录 [OPEN_SOURCE_SCOPE.md](../OPEN_SOURCE_SCOPE.md)。

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
