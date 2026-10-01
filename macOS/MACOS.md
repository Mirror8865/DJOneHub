# DJOneHub for macOS

This branch adds a native macOS service for the DJI Cellular Dongle / Quectel
EG25-G. It does not require UTM for AT-mode management.

## Current scope

- Automatic discovery of DJI (`2ca3`) and Quectel (`2c7c`) USB serial ports
- Modem, SIM, operator, registration and signal status
- Receive and send SMS through the modem AT port
- Execute explicit AT commands
- Read and switch physical eUICC profiles through AT APDU transport
- Local management page at `http://127.0.0.1:7575`
- Packaged Universal release containing Apple Silicon and Intel binaries

The cellular data interface remains managed by macOS. This allows macOS to use
the dongle as its network connection while DJOneHub uses a separate USB serial
interface for management.

## Downloaded release

The Universal DMG contains the backend, SwiftUI App, libusb runtime, licenses,
installer and uninstaller. It does not require Go, Homebrew or a separately
installed libusb on the user's Mac.

From the extracted release directory:

```sh
./djonehub start
```

The terminal remains attached to the service and the management page opens
automatically. Press `Control+C` to stop it, or run `./djonehub stop` from another
terminal in the same directory. Logs are stored in
`~/Library/Logs/DJOneHub/djonehub.log`.

## Build from source

Requirements:

- macOS 13 or newer
- Go 1.26 or newer

```sh
./scripts/build-dmg-universal.sh v1.0.0-rc1
```

Release outputs:

- `dist/DJOneHub-macOS-universal-v1.0.0-rc1.dmg`
- `dist/DJOneHub-macOS-universal-v1.0.0-rc1.dmg.sha256`

The packaging script downloads the official libusb source archive, verifies its
SHA-256, builds it for macOS 13 or newer and bundles the resulting runtime.

## Run

Connect the modem and run:

```sh
./dist/djonehub-macos
```

If automatic discovery picks no AT port, inspect `/dev/cu.*` and pass it:

```sh
./dist/djonehub-macos -port /dev/cu.usbmodemXXXX
```

The server only listens on localhost by default. Open:

```text
http://127.0.0.1:7575
```

## Demo without hardware

To explore the management page before buying the module, run:

```sh
./dist/djonehub-macos -demo
```

Then open `http://127.0.0.1:7575`. Demo mode provides simulated modem status,
SMS messages, AT command responses and eSIM profiles. It does not access a real
SIM, send messages or switch a physical eSIM profile.

## Launch at login

```sh
./scripts/install-macos.sh
```

Logs are written to `~/Library/Logs/DJOneHub`.

## Platform limitations

- Native QMI/MBIM control, Linux udev and network-namespace orchestration are
  excluded from this macOS entry point.
- eSIM behavior depends on the physical eUICC and modem firmware. Profile
  switching must be verified with real hardware.
- The release uses an ad-hoc signature rather than an Apple Developer ID. On
  first run, macOS may require approval in Privacy & Security.

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
