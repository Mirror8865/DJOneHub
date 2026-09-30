#!/usr/bin/env python3
"""在 Windows 上复用作者原始部署器的全部安全检查, 只把底层传输换成 adb.exe.

原始 deploy-qdc507-agent.py 一字不改地导入执行; 本文件只做三件事:
  1. 指定打包自带的语音运行时目录 (DJONEHUB_VOICE_RUNTIME)
  2. 用 adb.exe 版 DeployTransport 替换 macOS 的 libusb 版
  3. 把命令行参数原样交给原始 main()

因此模块身份校验(uid=0/armv7l/3.18.44)、USB 组合校验、原厂服务 PID 校验、通话校验、
目标路径摘要校验、原子 mv、/data 空间校验、失败自动回滚全部保持作者原样.

用法(通常由 Deploy-Module.bat 调用):
    python deploy_qdc507_windows.py --confirm-persistent-deploy
    python deploy_qdc507_windows.py --inspect-startup-hooks
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import secrets
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def resolve_module_agent_directory() -> Path:
    """定位作者原始部署器: 优先打包布局, 其次源码树布局."""
    packaged = HERE / "module-agent"
    if (packaged / "deploy-qdc507-agent.py").is_file():
        return packaged
    if len(HERE.parents) >= 2:
        source = HERE.parents[1]
        if (source / "deploy-qdc507-agent.py").is_file():
            return source
    raise RuntimeError(
        "找不到 module-agent/deploy-qdc507-agent.py; "
        "请完整解压分享包后再运行, 不要只单独复制本文件."
    )


MODULE_DIR = resolve_module_agent_directory()
ORIGINAL = MODULE_DIR / "deploy-qdc507-agent.py"
VOICE_RUNTIME = MODULE_DIR / "voice-runtime"


def resolve_adb() -> str:
    """定位 adb.exe: 环境变量 > 包内 platform-tools > PATH."""
    candidates = [os.environ.get("DJONEHUB_ADB", "")]
    candidates += [
        str(HERE / "platform-tools" / "adb.exe"),
        str(HERE / "platform-tools" / "adb"),
    ]
    candidates.append(shutil.which("adb") or "")
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    raise RuntimeError(
        "找不到 adb.exe; 请先运行 Setup-Only.bat 自动下载 platform-tools, "
        "或用环境变量 DJONEHUB_ADB 指定 adb.exe 的完整路径."
    )


class AdbDeployTransport:
    """用 platform-tools 的 adb.exe 提供与 macOS 版相同的 open/shell/push/pull 语义."""

    def __init__(self, _probe_module=None) -> None:
        self._adb = resolve_adb()
        self._serial: str | None = None

    def _run(self, args, timeout_seconds=60):
        command = [self._adb] + (["-s", self._serial] if self._serial else []) + list(args)
        return subprocess.run(command, capture_output=True, timeout=timeout_seconds)

    def open(self) -> None:
        self._run(["start-server"], 60)
        listing = self._run(["devices"], 60).stdout.decode("utf-8", "replace")
        serials = []
        for line in listing.splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1].strip() == "device":
                name = parts[0].strip()
                serials.append("" if name.startswith("(") else name)
        if not serials:
            raise RuntimeError(
                "adb 未发现已授权的模块设备; 请确认 USB 线支持数据传输、"
                "已用 Write-USBConfig.bat 写入目标 USB 组合, 并在提示时允许 USB 调试."
            )
        if len(serials) > 1:
            raise RuntimeError(f"adb 发现多个设备, 无法确定目标: {serials}")
        self._serial = serials[0] or None

    def close(self) -> None:
        return None

    def _push_bytes(self, data: bytes, remote_path: str, timeout_seconds: int = 600) -> None:
        import tempfile

        handle, local_path = tempfile.mkstemp(prefix="djonehub-push-")
        try:
            with os.fdopen(handle, "wb") as stream:
                stream.write(data)
            completed = self._run(["push", local_path, remote_path], timeout_seconds)
            if completed.returncode != 0:
                raise RuntimeError(
                    "adb push 失败: " + completed.stderr.decode("utf-8", "replace")[-500:]
                )
        finally:
            try:
                os.unlink(local_path)
            except OSError:
                pass

    def shell(self, command: str, timeout_seconds: int = 20) -> str:
        """与 macOS 版逐字相同的包装方式: 随机标记 + 严格退出码, 非零即抛错."""
        token = secrets.token_hex(12)
        marker = f"__DJONEHUB_STATUS_{token}_"
        wrapped = (
            f"{{ {command}; }}; code=$?; " f"printf '\\n{marker}%u__\\n' \"$code\"\n"
        ).encode("utf-8")
        remote = f"/data/local/tmp/.djonehub_cmd_{token}.sh"
        try:
            self._push_bytes(wrapped, remote, timeout_seconds + 120)
            completed = self._run(["shell", f"sh {remote}"], timeout_seconds + 120)
            output = completed.stdout.decode("utf-8", errors="replace")
            if completed.stderr:
                output += completed.stderr.decode("utf-8", errors="replace")
        finally:
            self._run(["shell", f"rm -f {remote}"], 30)
        position = output.rfind(marker)
        if position < 0:
            raise RuntimeError(
                "模块 shell 未返回退出状态; "
                f"command={command[:240]!r} output={output[-500:]!r}"
            )
        status = int(output[position + len(marker):].split("__", 1)[0])
        clean = output[:position].rstrip()
        if status != 0:
            raise RuntimeError(f"模块命令失败({status}): {clean[-5000:]}")
        return clean

    def push(self, data: bytes, remote_path: str, mode: int) -> None:
        """与 macOS 版相同: 先写调用方给定的临时路径, 权限显式设置."""
        if not remote_path.startswith("/") or "," in remote_path or "\x00" in remote_path:
            raise ValueError("ADB push 目标路径无效")
        self._push_bytes(data, remote_path)
        self.shell(f"chmod {mode:o} {shlex.quote(remote_path)}")

    def pull(self, remote_path: str) -> bytes:
        import tempfile

        if not remote_path.startswith("/") or "\x00" in remote_path:
            raise ValueError("ADB pull 源路径无效")
        handle, local_path = tempfile.mkstemp(prefix="djonehub-pull-")
        os.close(handle)
        try:
            completed = self._run(["pull", remote_path, local_path], 300)
            if completed.returncode != 0:
                raise RuntimeError(
                    "adb pull 失败: " + completed.stderr.decode("utf-8", "replace")[-500:]
                )
            with open(local_path, "rb") as stream:
                return stream.read()
        finally:
            try:
                os.unlink(local_path)
            except OSError:
                pass


def load_original():
    if not ORIGINAL.is_file():
        raise RuntimeError(f"原始部署器缺失: {ORIGINAL}")
    digest = hashlib.sha256(ORIGINAL.read_bytes()).hexdigest()
    spec = importlib.util.spec_from_file_location("djonehub_deploy_original", ORIGINAL)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载原始部署器")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module, digest


def main() -> int:
    os.environ.setdefault("DJONEHUB_VOICE_RUNTIME", str(VOICE_RUNTIME))
    # 先把 adb 路径打印出来, 出问题时用户能一眼看到用的是哪一个 adb.exe.
    print(f"adb: {resolve_adb()}", flush=True)
    module, digest = load_original()
    module.DeployTransport = AdbDeployTransport
    module.load_probe_module = lambda: None
    print(f"复用作者原始部署器 (sha256 {digest[:16]}), 传输层 = adb.exe", flush=True)
    return module.main()


if __name__ == "__main__":
    raise SystemExit(main())