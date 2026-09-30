# DJOneHub for macOS（Universal）

适用于 Apple Silicon 与 Intel Mac（macOS 13 及以上）。

## 安装

1. 完整解压 ZIP。
2. 在终端进入解压后的目录，执行：

   ```sh
   ./install
   ```

3. 打开 DJOneHub App，或执行 `djonehub start`。

程序仅监听 `127.0.0.1:7575`。macOS 首次通话会要求麦克风权限。

## 平台说明

- 后端、App 与 libusb 包含 arm64 + x86_64。
- Apple Silicon 已在开发机验证；Intel Mac 尚未真机验证。
- 发行包未包含或镜像任何模块侧双向通话运行时。首次在 App「设置 → 语音运行时」确认后，App 会从固定的上游官方来源获取指定版本，逐个校验 SHA-256 并保存到本机；后续不会重复下载。
- 短信、4G 网络、GPS、来电提醒、通话状态与控制仍可使用。双向通话还取决于模块型号、固件、SIM、运营商和上游运行时是否仍可用。

完整边界见仓库根目录 `OPEN_SOURCE_SCOPE.md`。

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
