#!/bin/bash
# xread.koplugin 一键自动测试（在 WSL Ubuntu 内运行）
# 用法：bash /mnt/d/<解压目录>/wsl-setup/quickstart.sh [--quick] [--no-apt]
# 自动完成：安装依赖 → 校验/解压 KOReader 模拟器 → 写后端凭据 → 部署插件 → 全套回归 → 打印报告
set -u

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUICK=0
NO_APT=0
for arg in "$@"; do
    [ "$arg" = "--quick" ] && QUICK=1
    [ "$arg" = "--no-apt" ] && NO_APT=1
done

say() { echo "[quickstart] $*"; }

say "测试包目录: $KIT_DIR"

if [ "$NO_APT" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    say "安装/检查依赖..."
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xdotool imagemagick xvfb x11-utils python3 curl zip unzip openssh-client 2>/dev/null \
        || say "apt 安装未完全成功（若依赖已存在可忽略）"
fi

if [ ! -f /opt/koreader/lib/koreader/koreader.sh ]; then
    if [ -f "$KIT_DIR/koreader.tar.xz" ]; then
        say "解压 KOReader 模拟器..."
        mkdir -p /opt/koreader
        tar -xJf "$KIT_DIR/koreader.tar.xz" -C /opt/koreader
    else
        say "错误：未找到 /opt/koreader/lib/koreader/koreader.sh"
        say "请把资料库中的 koreader.tar.xz 放到 $KIT_DIR/ 后重跑"
        exit 1
    fi
fi
say "KOReader 模拟器: OK"

mkdir -p /root/.config/koreader/settings
if [ ! -f /root/.config/koreader/settings/xread.lua ]; then
    BASE="${XREAD_TEST_HOST:-http://192.168.31.51:7777}"
    USER="${XREAD_TEST_USER:-}"
    PASS="${XREAD_TEST_PASS:-}"
    if [ -z "$USER" ] || [ -z "$PASS" ]; then
        say "未设置 XREAD_TEST_USER/XREAD_TEST_PASS，跳过凭据写入（请首次启动时在插件设置里填写）"
    else
        cat > /root/.config/koreader/settings/xread.lua <<EOF
return {
    base = "$BASE",
    username = "$USER",
    password = "$PASS",
}
EOF
        say "已写入后端凭据（环境变量 XREAD_TEST_HOST/USER/PASS）"
    fi
else
    say "保留已有后端凭据"
fi

rm -rf /opt/koreader/lib/koreader/plugins/xread.koplugin
cp -r "$KIT_DIR/xread.koplugin" /opt/koreader/lib/koreader/plugins/xread.koplugin
say "插件已部署"

if [ "$QUICK" -eq 1 ]; then
    say "快速检查（语法 + 交付包一致性）"
    bash "$KIT_DIR/tests/run_all.sh" --quick
else
    say "运行全套自动回归（12 项，约 15 分钟）"
    bash "$KIT_DIR/release.sh"
fi
RC=$?

LATEST="$(find "$KIT_DIR/tests/reports" -name SUMMARY.md -type f 2>/dev/null | sort | tail -1)"
say "报告: ${LATEST:-未生成}"
[ -n "$LATEST" ] && tail -6 "$LATEST"
if [ "$RC" -eq 0 ]; then
    say "RESULT: PASS"
else
    say "RESULT: FAIL（请把报告发给技术支持）"
fi
exit "$RC"
