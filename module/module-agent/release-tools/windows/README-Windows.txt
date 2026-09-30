DJOneHub QDC507 模块 Windows 首次部署包
=======================================

这是作者 macOS 首次部署包 (install.command) 的 Windows 等价版本。
部署到模块里的内容、逐项 SHA-256 校验、失败回滚逻辑与 macOS 版完全一致,
区别只有两点: 底层传输从 libusb 换成 Google 官方 platform-tools 的 adb.exe,
以及附带了自动下载 platform-tools 的 .bat 引导脚本。

使用条件
--------
- Windows 10 / 11 (x64 / arm64 均可)。
- Python 3.8 或更高版本 (https://www.python.org/downloads/windows/ , 安装时勾选
  "Add python.exe to PATH")。其余依赖由脚本自动安装:
    * Android platform-tools (adb.exe) -> 自动从 dl.google.com 下载
    * pyserial -> 自动用 pip 安装 (仅装到当前用户)
- 模块通过支持数据传输的 USB 线直连电脑。若 Windows 没有出现 COM 口,
  请先安装模块 (Quectel MDM9607 平台) 的 Windows 串口驱动。
- 已验证的模块: Baiwang QDC507, USB ID 2c7c:0125, 固件 QDC507GLEFM21_*。

使用步骤
--------
0. 把整个压缩包全部解压到一个目录 (不要在压缩包里直接双击), 路径不要带奇怪符号。

1. 双击 Setup-Only.bat
   自动下载 platform-tools 到本目录的 platform-tools\, 并安装 pyserial。
   这一步不碰模块, 只准备本机环境。第一次执行 Deploy-Module.bat 时也会自动做同样的事。

2. 双击 Write-USBConfig.bat
   默认是"只读预检": 连上模块的 AT 串口, 打印型号/固件/当前 USB 组合并备份,
   不写入任何内容。确认打印出来的确实是 QDC507 后, 再执行:
       Write-USBConfig.bat --write
   它会写入作者客户端使用的目标组合 0x2C7C,0x0125,1,1,1,1,1,1,1, 然后:
       - 先备份原组合到 usbcfg-rollback\ (时间戳 + latest 各一份)
       - 写入后立刻回读; 回读不一致 -> 立即写回原值, 并且不重启
       - 回读一致才重启 (AT+CFUN=1,1), 重启后重新校验
       - 重启后仍不是目标值 -> 自动恢复原配置
   写入前会拒绝在通话中写入。串口不认识时可用 --port COM8 指定。

3. 等模块重新枚举 (约 10-30 秒), 双击 Deploy-Module.bat
   复用作者原始部署器 module-agent\deploy-qdc507-agent.py, 只把传输层换成 adb.exe。
   模块身份校验 (uid=0 / armv7l / Linux 3.18.44)、USB 组合校验、原厂服务 PID 校验、
   通话校验、目标路径摘要校验、原子 mv、/data 空间校验、失败自动回滚全部保持作者原样。
   部署完成时终端会打印每个文件在模块内的 SHA-256 校验结果。

4. 部署成功后, 把模块插到已安装并授权 DJOneHub 的 iPhone / iPad 上使用。

回滚
----
- 恢复 USB 组合 (回到写入前状态):
      双击 Restore-USBConfig.bat
      或 Write-USBConfig.bat --restore
  默认使用 usbcfg-rollback\usbcfg-latest.json; 也可用
      Restore-USBConfig.bat --restore-file "D:\...\usbcfg-before-20260930-123000.json"
- 移除已部署的 Agent 与启动钩子 (模块恢复成空白状态, 适合首次部署的模块):
      platform-tools\adb.exe shell "set -e; /etc/init.d/djonehub_agent stop || true; mount -o remount,rw /dev/ubi0_0 /; rm -f /etc/rc5.d/S99zz_djonehub_agent /etc/init.d/djonehub_agent; rm -rf /data/djonehub; sync; mount -o remount,ro /dev/ubi0_0 /"

安全边界
--------
- Write-USBConfig.bat 默认只读, 只有显式加 --write 才会写入模块。
- 每一步都可回滚: USB 组合有 usbcfg-rollback\ 备份, 部署有失败自动回滚。
- 本包不会刷写模块固件、不会覆盖原厂服务; 部署前后原厂 ql_manager_server 不被重启。
- iPhone / iPad 上没有 ADB 与内核写入权限, 首次刷写必须在电脑 (macOS 或 Windows) 上完成。

常见问题
--------
- "未找到 QDC507 AT 串口": 模块没被识别为 AT 口。换一根支持数据的 USB 线,
  装好串口驱动, 或用 --port 指定; 已经写入过 USB 组合的模块 AT 口会变成另一个 COM 号。
- "adb 未发现已授权的模块设备": 第 2 步还没做, 或模块还没重新枚举; 先重跑第 2 步。
- 杀毒软件报 module-agent\deploy-qdc507-agent.py: 该文件只是 Python 脚本,
  会被某些安全软件误判; 请把本目录加入信任区后重新解压。
- 只想看当前状态不想部署: 直接跑
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action usbcfg
  以及
      powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 -Action deploy --inspect-startup-hooks

限制: 仅限 PolyForm Noncommercial License 允许的非商业用途。
DJOneHub 是非官方第三方项目, 与 DJI / Quectel / 运营商 / eSIM 供应商均无关联。