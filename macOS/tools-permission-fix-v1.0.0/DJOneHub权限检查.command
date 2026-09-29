#!/bin/zsh
set -u

# 复用主修复脚本的只读模式，避免维护两套容易漂移的权限判断。
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_directory/DJOneHub权限修复.command" --check-only
