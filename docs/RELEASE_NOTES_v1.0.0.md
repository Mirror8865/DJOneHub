# DJOneHub v1.0.0

`v1.0.0` 是本仓库首次整理后的 GitHub 发布版本。

## 包含内容

- Mac 客户端与后台源码：`1.2.10 (19)`
- iPhone/iPad 客户端源码：`0.7.6 (41)`
- QDC507 Agent 源码：`0.3.21`
- QDC507 独立诊断、配置和修复工具源码

## Release 附件

私有 Release 附件为 `module-update-0.3.21.djupdate`。它是 Agent `0.3.21` 的实际模块更新包，而不是 `v1.0.0` 模块包；详见 [release-assets/README.md](../release-assets/README.md)。

SHA-256：

```text
b3554ad426a623e18dead9b80cfc3356d41f70934b99d0531dcf8dd3e2a17e2b
```

同时提供以下 iOS/iPadOS 未签名 IPA：

- `DJOneHub-iPhone-v0.7.6-build41-unsigned.ipa`
- `DJOneHub-iPad-v0.7.6-build41-unsigned.ipa`

两者均由当前 `0.7.6 (41)` 源码构建，分别限制为 iPhone 或 iPad 设备族，且不含签名、Provisioning Profile 或 `_CodeSignature`。它们**不能直接安装**；使用前必须由下载者使用自己的 Apple 开发者证书重签，或通过自己授权的侧载方式安装。

SHA-256：

```text
DJOneHub-iPhone-v0.7.6-build41-unsigned.ipa  f8efbe3fd387751330b9a0718ad10213552b3f15238af7762c3d0332eee46a51
DJOneHub-iPad-v0.7.6-build41-unsigned.ipa    88114752578ed5548174274a74084fef2a953443607e9b40328a2085a3254d44
```

## 未包含内容

WebUSB 刷写器、ESP32 实验、测试固件 `0.3.45`/`0.4.2`、历史安装包、回滚备份与敏感资料均不包含在本发布中。

## 免责声明

本项目及本 Release 仅用于学习、研究与合法的非商业用途。不得用于非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为。使用者应自行确认设备授权范围，并承担不当使用造成的后果。

## 鸣谢

- 小红书博主「小吴折腾AI」的一同开发。
- XUXU 的大力支持。
