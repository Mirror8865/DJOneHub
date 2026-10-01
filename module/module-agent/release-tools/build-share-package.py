#!/usr/bin/env python3
"""构建可分享的 QDC507 模块部署包与已签名运行时更新包。"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_ROOT = ROOT / "module"
TOOLS = MODULE_ROOT / "module-agent/release-tools"
PRIVATE_KEY = ROOT / ".release-keys/module-update-ed25519.key"
PUBLIC_KEY = ROOT / ".release-keys/module-update-ed25519.pub"
def read_agent_version() -> str:
    """从源码读取 Agent 版本，避免分享包与实际二进制版本不一致。"""
    source = (MODULE_ROOT / "module-agent/main.go").read_text(encoding="utf-8")
    match = re.search(r'agentVersion\s*=\s*"([0-9]+(?:\.[0-9]+)+)"', source)
    if not match:
        raise RuntimeError("无法从 module-agent/main.go 读取 Agent 版本")
    return match.group(1)


# 发布包版本必须与二进制内置版本一致，禁止借环境变量伪造版本号。
AGENT_VERSION = read_agent_version()
if configured_version := os.environ.get("DJONEHUB_AGENT_VERSION"):
    if configured_version != AGENT_VERSION:
        raise RuntimeError(
            f"DJONEHUB_AGENT_VERSION={configured_version} 与 Agent 实际版本 {AGENT_VERSION} 不一致"
        )
PACKAGE_NAME = f"DJOneHub-QDC507-Module-v{AGENT_VERSION}"
OUTPUT_ROOT = ROOT / "dist" / PACKAGE_NAME
APP_RESOURCES = ROOT / "iPadOS/DJOneHub-iPad/Resources"
AGENT = MODULE_ROOT / "module-agent/qdc507-agent"
BRIDGE = MODULE_ROOT / "kernel-bridge/qdc507_data11_bridge.ko"
VOICE = MODULE_ROOT / "module-agent/pcm-bridge/mavo-pcm-bridge.armv7"
VOICE_SOURCE = Path(
    os.environ.get(
        "DJONEHUB_VOICE_RUNTIME",
        str(Path.home() / "Library/Application Support/DJOneHub/voice-runtime/mavo-0443dfd"),
    )
)
LIBUSB = Path(
    os.environ.get(
        "DJONEHUB_LIBUSB",
        str(Path.home() / "Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib"),
    )
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_files() -> None:
    missing = [path for path in [AGENT, BRIDGE, VOICE, LIBUSB, VOICE_SOURCE / "qdc507_aprv3.ko", VOICE_SOURCE / "qdc507_voice.ko", MODULE_ROOT / "qdc507-adb-probe.py"] if not path.is_file()]
    if missing:
        raise RuntimeError("部署包缺少文件：\n" + "\n".join(str(path) for path in missing))
    if not PRIVATE_KEY.is_file() or not PUBLIC_KEY.is_file():
        raise RuntimeError("缺少发布签名私钥；请先生成 .release-keys/module-update-ed25519.key")


def sign(manifest_path: Path, signature_path: Path) -> None:
    tool = TOOLS / "ed25519-tool.swift"
    subprocess.run(["swift", str(tool), "sign", str(PRIVATE_KEY), str(manifest_path), str(signature_path)], check=True)


def write_update_bundle(output: Path) -> dict[str, object]:
    files = [
        ("qdc507-agent", AGENT, "bin/qdc507-agent", 0o755),
        ("qdc507_data11_bridge.ko", BRIDGE, "kernel/qdc507_data11_bridge.ko", 0o644),
        ("qdc507_aprv3.ko", VOICE_SOURCE / "qdc507_aprv3.ko", "voice-runtime/qdc507_aprv3.ko", 0o644),
        ("qdc507_voice.ko", VOICE_SOURCE / "qdc507_voice.ko", "voice-runtime/qdc507_voice.ko", 0o644),
        ("mavo-pcm-bridge.armv7", VOICE, "voice-runtime/mavo-pcm-bridge.armv7", 0o755),
    ]
    manifest = {
        "format_version": 1,
        "version": AGENT_VERSION,
        "platform": "qdc507-armv7-linux-3.18.44",
        "files": [
            {"name": name, "target": target, "sha256": sha256(source), "size": source.stat().st_size, "mode": mode}
            for name, source, target, mode in files
        ],
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with tempfile.TemporaryDirectory(prefix="djonehub-update-") as temporary:
        manifest_path = Path(temporary) / "manifest.json"
        signature_path = Path(temporary) / "manifest.sig"
        manifest_path.write_bytes(manifest_bytes)
        sign(manifest_path, signature_path)
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    def add_bytes(name: str, payload: bytes, mode: int) -> None:
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        info.mode = mode
                        info.mtime = 0
                        archive.addfile(info, __import__("io").BytesIO(payload))

                    add_bytes("manifest.json", manifest_bytes, 0o644)
                    add_bytes("manifest.sig", signature_path.read_bytes(), 0o644)
                    for name, source, _, mode in files:
                        info = tarfile.TarInfo("payload/" + name)
                        info.size = source.stat().st_size
                        info.mode = mode
                        info.mtime = 0
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)
    return manifest


def patched_probe(destination: Path) -> None:
    source = (MODULE_ROOT / "qdc507-adb-probe.py").read_text(encoding="utf-8")
    source = source.replace("import ctypes\n", "import ctypes\nimport os\n", 1)
    old = 'LIBUSB_PATH = Path(\n    "/Users/jieden/Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib"\n)'
    new = 'LIBUSB_PATH = Path(os.environ.get("DJONEHUB_LIBUSB", str(Path(__file__).resolve().parent / "runtime/libusb-1.0.0.dylib")))'
    if old not in source:
        raise RuntimeError("qdc507-adb-probe.py 的 libusb 路径格式发生变化，拒绝静默打包")
    destination.write_text(source.replace(old, new), encoding="utf-8")


def write_package(manifest: dict[str, object], update_bundle: Path) -> None:
    if OUTPUT_ROOT.exists():
        raise RuntimeError(f"输出目录已存在，为避免覆盖用户文件请先移走：{OUTPUT_ROOT}")
    (OUTPUT_ROOT / "module-agent/voice-runtime").mkdir(parents=True)
    (OUTPUT_ROOT / "module-agent/pcm-bridge").mkdir(parents=True)
    (OUTPUT_ROOT / "kernel-bridge").mkdir(parents=True)
    (OUTPUT_ROOT / "runtime").mkdir(parents=True)
    shutil.copy2(AGENT, OUTPUT_ROOT / "module-agent/qdc507-agent")
    shutil.copy2(MODULE_ROOT / "module-agent/deploy-qdc507-agent.py", OUTPUT_ROOT / "module-agent/deploy-qdc507-agent.py")
    shutil.copy2(BRIDGE, OUTPUT_ROOT / "kernel-bridge/qdc507_data11_bridge.ko")
    shutil.copy2(VOICE, OUTPUT_ROOT / "module-agent/pcm-bridge/mavo-pcm-bridge.armv7")
    shutil.copy2(VOICE_SOURCE / "qdc507_aprv3.ko", OUTPUT_ROOT / "module-agent/voice-runtime/qdc507_aprv3.ko")
    shutil.copy2(VOICE_SOURCE / "qdc507_voice.ko", OUTPUT_ROOT / "module-agent/voice-runtime/qdc507_voice.ko")
    shutil.copy2(LIBUSB, OUTPUT_ROOT / "runtime/libusb-1.0.0.dylib")
    patched_probe(OUTPUT_ROOT / "qdc507-adb-probe.py")
    shutil.copy2(update_bundle, OUTPUT_ROOT / "module-update.djupdate")
    (OUTPUT_ROOT / "install.command").write_text(
        "#!/bin/sh\nset -eu\ncd \"$(dirname \"$0\")\"\nexec python3 module-agent/deploy-qdc507-agent.py --confirm-persistent-deploy\n",
        encoding="utf-8",
    )
    (OUTPUT_ROOT / "install.command").chmod(0o755)
    (OUTPUT_ROOT / "README.txt").write_text(
        f"""DJOneHub QDC507 模块首次部署包 v{AGENT_VERSION}

使用条件：macOS、Python 3、支持数据传输的 USB 线、已验证的 QDC507（USB ID 2c7c:0125）。

首次配置：
1. 退出 Mac 版 DJOneHub，避免 USB ADB 接口被占用。
2. 保持模块为 Mac 完整模式并接入 Mac。
3. 双击 install.command，按终端提示完成一次性部署。
4. 部署成功后，将模块插入已安装并授权 DJOneHub 的 iPhone 或 iPad。

也可以在 Mac 版 DJOneHub 的「设置 → 通话支持 → 首次刷写模块」中选择本包内的 install.command；App 会二次确认后交给终端运行。

部署器会校验模块身份、原厂服务 PID、语音运行时 SHA-256 和 Agent 启动探针；任何一项不匹配都会拒绝写入。
更新包 module-update.djupdate 由内嵌 Ed25519 公钥验证，App 可在无通话时自动安装并在启动失败时回滚。

重要边界：本包只在 Mac 上运行一次。iPhone/iPad 没有 ADB、任意 USB 控制与内核写入权限，不能对全新模块执行首次刷写；模块完成本包部署后，移动端才可自动检查版本、切换手机直连模式和修复后续配置。

限制：仅限 PolyForm Noncommercial License 允许的非商业用途。请确认语音内核文件具有再分发授权。
""",
        encoding="utf-8",
    )
    info = {"version": AGENT_VERSION, "platform": manifest["platform"], "public_key": base64.b64encode(PUBLIC_KEY.read_bytes()).decode()}
    (OUTPUT_ROOT / "EmbeddedModuleUpdate.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    checksum_lines = []
    for path in sorted(item for item in OUTPUT_ROOT.rglob("*") if item.is_file() and item.name != "SHA256SUMS"):
        checksum_lines.append(f"{sha256(path)}  {path.relative_to(OUTPUT_ROOT)}")
    (OUTPUT_ROOT / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")


def sync_app_resources(manifest: dict[str, object], update_bundle: Path) -> None:
    """同步 App 内置更新，保证首次接入检测到的新版本一定有对应升级包。"""
    APP_RESOURCES.mkdir(parents=True, exist_ok=True)
    shutil.copy2(update_bundle, APP_RESOURCES / "module-update.djupdate")
    info = {
        "version": AGENT_VERSION,
        "platform": manifest["platform"],
        "public_key": base64.b64encode(PUBLIC_KEY.read_bytes()).decode(),
    }
    (APP_RESOURCES / "EmbeddedModuleUpdate.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="构建 QDC507 首次部署包与模块更新包")
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="输出目录；默认写入 dist/DJOneHub-QDC507-Module-v<版本>",
    )
    parser.add_argument(
        "--skip-app-resource-sync",
        action="store_true",
        help="只生成 Mac 首次部署包，不改动 iPhone/iPad App 内嵌更新资源",
    )
    return parser.parse_args()


def main() -> None:
    global OUTPUT_ROOT
    args = parse_args()
    if args.output_dir:
        OUTPUT_ROOT = args.output_dir.expanduser().resolve()
    require_files()
    OUTPUT_ROOT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="djonehub-package-") as temporary:
        update_bundle = Path(temporary) / "module-update.djupdate"
        manifest = write_update_bundle(update_bundle)
        write_package(manifest, update_bundle)
        # 生成给首次用户的 Mac 包时不应碰已签名 App 的资源；App 发布流程会显式同步。
        if not args.skip_app_resource_sync:
            sync_app_resources(manifest, update_bundle)
    print(f"已生成分享包：{OUTPUT_ROOT}")
    print(f"签名更新包：{OUTPUT_ROOT / 'module-update.djupdate'}")


if __name__ == "__main__":
    main()
