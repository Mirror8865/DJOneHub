# DJOneHub v1.2.8 Public Release Architecture

## Product goal

Prepare a reviewable public-source v1.2.8 package. It contains all redistributable
application code and desktop deployment, but never redistributes module-side
voice runtime binaries.

## macOS architecture

- `cmd/djonehub-macos`: local Go backend, embedded web console, modem/SMS/eSIM,
  network policy, GPS, call control, module-side voice setup, CoreAudio routing
  and recording.
- `macos/DJOneHubNotifier`: independent SwiftUI desktop application for calls,
  recents, SMS, contacts, settings, native notifications and menu-bar status.
- First-module onboarding is a local, confirmation-gated workflow: inspect the
  USB composition read-only, snapshot the original tuple, enable the supported
  USB audio composition, wait for re-enumeration, then verify AT/4G/SMS/voice
  readiness. Factory and known legacy-UAC tuples share this workflow. A failed
  voice-verification step restores the captured tuple, exits the active state,
  and reports the result explicitly.
- A complete UAC tuple may retain either the original DJI VID/PID or the
  Quectel VID/PID. Both are read-only recognized as ready-capable; neither is
  rewritten solely to change USB identity.
- Release format: one Universal DMG containing arm64 + x86_64 backend and
  SwiftUI App, installer, uninstaller, notices and checksums. No `.ko` or
  `.armv7` module-side runtime file may be included.

## Windows architecture

- Reuse the Go backend and embedded web assets where they are genuinely
  cross-platform.
- Provide a Windows desktop launcher and installer package, not a bare backend
  binary.
- Keep platform capability reporting explicit. macOS-only CoreAudio, ADB USB
  access, USB AT/eSIM and network-service automation must not be represented as
  working on Windows until equivalent Windows implementations and hardware
  validation exist.
- Release format target: amd64 application bundle with launcher, backend,
  install/uninstall scripts, notices and checksums.

## Boundaries

- Local service listens on `127.0.0.1:7575` only.
- No firmware flashing is added by this release work.
- USB composition writes are never automatic merely because a module is
  inserted: the App must show the discovered state and require a single
  explicit "Initialize" confirmation for an uninitialized module.
- No public push, tag or GitHub Release before Jamie approves the local review
  package.
- Failed audio-bridge experiments are excluded from the release candidate.
- The MaVo MIT audio adaptation remains source-visible. The module-side runtime
  is external to the repository and release archive. After one explicit App
  confirmation, DJOneHub may fetch only a pinned upstream MaVo artifact URL
  (Raw endpoint, then GitHub Contents API fallback, then one Raw retry),
  verify each file's SHA-256, cache it locally and deploy it transiently to the
  connected module. The public package never mirrors or embeds that runtime.

## Validation model

- Source tests and cross-compilation are required for every target.
- Binary architecture, code-signing state, dependency closure and archive
  checksums are verified locally.
- Apple Silicon runtime is tested on the current Mac.
- Intel macOS and Windows remain explicitly unverified until tested on matching
  hardware/OS; packaging success is not runtime proof.

## MaVo parity audio route

- The public MIT-licensed MaVo v0.1.2 implementation is the verified reference
  for QDC507 call media on macOS.
- Keep DJOneHub call control, SMS, networking, UI and recordings. Replace only
  the module UAC/media route with the reference model: bind the UAC pair by
  VID/PID/location, lock both endpoints to 8 kHz mono, normalize callback data
  to bounded PCM16 SPSC rings, and hand downlink playback to AVAudioEngine.
- Validate UAC before dialing, but start the module D4/UAC voice route and host
  audio only after CLCC reports one active voice call. Stop host audio before
  stopping the module route.
- First-use setup must enable the ADB and UAC composition required by the
  module-side runtime, then explicitly enable IMS and verify VoLTE capability
  after restart. Values are read back before each restart.
- The previous CoreAudio router remains in Git history as the rollback point;
  it is not mixed with the new media path at runtime.
- The binding implementation rules and acceptance gate are fixed in
  [mavo-audio-parity-contract.md](mavo-audio-parity-contract.md). This contract
  takes precedence over any local audio optimization.

---

## 鸣谢、支持与免责声明

感谢小红书博主 [「小吴折腾AI」](https://xhslink.cn/o/70Ecv4YqEvk) 的一同开发，感谢 [XUXU](https://xhslink.cn/o/AYJ2PKK9tyj)、[Jamie（@没错jamie就是我）](https://xhslink.cn/o/2CbGt9pN3AB) 与 [JieDen](https://xhslink.cn/o/5WQkSOfgE3i) 的支持。

我的微信小程序售卖咖啡豆和茶叶；如果你喜欢本项目，欢迎扫码支持，感谢大家。

![咖啡豆与茶叶小程序二维码](https://raw.githubusercontent.com/wzz04810-debug/DJOneHub/main/docs/assets/coffee-tea-miniprogram-qr.jpg)

本项目仅用于学习、研究与合法的非商业用途。严禁将本项目、其源码、脚本或发布附件用于任何非法、侵权、规避安全限制、未经授权访问设备或违反运营商及平台规则的行为；不当使用造成的后果由使用者自行承担。
