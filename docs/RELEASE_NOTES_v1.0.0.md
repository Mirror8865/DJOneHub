# DJOneHub v1.0.0

`v1.0.0` 是本仓库首次整理后的 GitHub 发布版本。

## 鸣谢

- 感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发。
- 感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj) 的大力支持。
- 感谢 [Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB)。
- 感谢 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i)。

## 支持小店

这是我的微信小程序，售卖咖啡豆和茶叶；如果你喜欢这个项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

## 包含内容

- Mac 客户端与后台源码：`1.2.10 (19)`
- iPhone/iPad 客户端源码：`0.7.6 (42)`，最低支持 iOS/iPadOS 16.1
- QDC507 Agent 源码：`0.3.21`
- QDC507 独立诊断、配置和修复工具源码

## Release 附件

私有 Release 附件为 `module-update-0.3.21.djupdate`。它是 Agent `0.3.21` 的实际模块更新包，而不是 `v1.0.0` 模块包；详见 [release-assets/README.md](../release-assets/README.md)。

SHA-256：

```text
b3554ad426a623e18dead9b80cfc3356d41f70934b99d0531dcf8dd3e2a17e2b
```

同时提供以下兼容 iOS/iPadOS 16.1 及更高版本的未签名 IPA：

- `DJOneHub-iPhone-v0.7.6-build42-unsigned.ipa`
- `DJOneHub-iPad-v0.7.6-build42-unsigned.ipa`

两者均由当前 `0.7.6 (42)` 源码构建，分别限制为 iPhone 或 iPad 设备族，且不含签名、Provisioning Profile 或 `_CodeSignature`。它们**不能直接安装**；使用前必须由下载者使用自己的 Apple 开发者证书重签，或通过自己授权的侧载方式安装。

SHA-256：

```text
DJOneHub-iPhone-v0.7.6-build42-unsigned.ipa  5a8194fffb9b4b0102392e486c6a926ff2c7754cbe1ef35bbd1b51f52738a336
DJOneHub-iPad-v0.7.6-build42-unsigned.ipa    9392e75c219fa3f0eeaab5974e81d574a075bf5349bee83f498744859544e0df
```

`build41` IPA 仍作为历史附件保留，仅适用于 iOS/iPadOS 16.3 及更高版本；需要 16.1 兼容性的用户请下载 `build42`。

## 未包含内容

WebUSB 刷写器、ESP32 实验、测试固件 `0.3.45`/`0.4.2`、历史安装包、回滚备份与敏感资料均不包含在本发布中。

## 免责声明

本项目及本 Release 仅用于学习、研究与合法的非商业用途。不得用于非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为。使用者应自行确认设备授权范围，并承担不当使用造成的后果。
