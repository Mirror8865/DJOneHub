# 公开发布范围

## 仓库与 Release 包含

- DJOneHub 后端、macOS SwiftUI App、Windows 控制台与部署脚本。
- 短信、网络、GPS、eSIM、来电提醒、通话状态与控制功能。
- MaVo v0.1.2 的 MIT 许可 UAC 探测、调制解调器桥接和 macOS 音频适配源码，并保留署名与许可证声明。

## 仓库与 Release 不包含

- `qdc507_aprv3.ko`
- `qdc507_voice.ko`
- `mavo-pcm-bridge.armv7`
- 任何包含上述文件的安装包、Git 历史或附件。

前两项内核模块当前缺少可核对的对应源码或明确再分发依据，因此不作为公开发行物的一部分。

## 外置运行时

公开源码与 Release 不内置、镜像或自动下载模块侧通话运行时。macOS App 仅会在用户一次明确确认后，直接从固定的上游官方来源取得指定版本，并校验每个文件的 SHA-256 后缓存到本机；后续模块重启可复用本机缓存，无需重复下载。DJOneHub 不保证上游文件持续可用，也不保证双向语音在所有硬件/固件上可用。

请不要向本项目提交、上传或请求分发上述运行时文件。

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
