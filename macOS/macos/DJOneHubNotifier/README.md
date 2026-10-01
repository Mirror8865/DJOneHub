# DJOneHubNotifier

DJOneHub 的 macOS 原生通知助手。网页关闭后仍可显示来电和短信：

- 每秒读取来电状态，显示 iOS 风格悬浮卡片。
- “拒接”调用 DJOneHub 挂断接口；“详情”打开管理页面。
- 每三秒读取短信列表，只提醒启动后新收到的短信。
- 不直接访问 USB，不改变短信模式、上网模式或网络切换规则。

## 构建

```bash
./build-app.sh
```

构建脚本会使用项目内缓存、执行内置自检、生成临时签名的 App，并验证签名和 `Info.plist`。

输出位置：

```text
dist/DJOneHubNotifier.app
```

## 验证

```bash
dist/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier --health-check
dist/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier --preview call
dist/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier --preview sms
```

`--health-check` 只输出接口解析状态和条数，不输出号码或短信内容。

## 常驻运行

默认安装位置：

```text
~/Library/Application Support/DJOneHub/notifier/DJOneHubNotifier.app
```

发行包的安装脚本会按当前 macOS 用户目录生成 LaunchAgent，再通过 `launchctl bootstrap` 注册。助手要求 DJOneHub 继续监听 `http://127.0.0.1:7575/`。

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
