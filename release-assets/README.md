# 发布附件：QDC507 Agent 0.3.21

此目录仅用于在本机暂存正式发布包，不会被 Git 提交。

待上传至私有 GitHub Release 的文件：

- 文件名：`module-update-0.3.21.djupdate`
- Agent 版本：`0.3.21`
- 平台：`qdc507-armv7-linux-3.18.44`
- SHA-256：`b3554ad426a623e18dead9b80cfc3356d41f70934b99d0531dcf8dd3e2a17e2b`

上传前在仓库根目录执行：

```sh
shasum -a 256 release-assets/module-update-0.3.21.djupdate
```

输出必须与上面的 SHA-256 完全一致。该包带有签名清单；签名私钥不在本仓库，也绝不能上传。

若需要构建 iPhone/iPad App，上传或下载后还须复制该文件到：

```text
iPadOS/DJOneHub-iPad/Resources/module-update.djupdate
```

该副本同样受 Git 忽略，只用于本地 Xcode 打包。

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
