#!/bin/bash
# 探针：真·跨版本 tar.gz 热更新（0.6.6 安装包 → 远端 0.6.7 tar.gz）
#   1) 用已发布的 0.6.6 zip 覆盖部署（真实旧版本，全量 110 文件都要替换）
#   2) XREAD_AUTOTEST=updateui → 检查更新 → 确认 → 安装 → 自动重启
#   3) 校验：_meta 变 0.6.7、变更文件数、main.lua md5 与远端包一致、无 traceback
# 用法：TAP_OK_X=... TAP_OK_Y=... bash tests/probe_remote_targz_full.sh
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
OLD_PKG="${OLD_PKG:-/root/xread-test/publish/xread.koplugin_v0.6.6_20261125-182656.zip}"
WANT_MAIN_MD5="${WANT_MAIN_MD5:-}"     # 远端包内 main.lua 的 md5（可选，留空只打印）

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

[ -f "$OLD_PKG" ] || { echo "OLD_PKG 不存在: $OLD_PKG"; exit 1; }

# ---- 1) 部署真实 0.6.6 ----
rm -rf "$DEPLOY_DIR"; mkdir -p "$DEPLOY_DIR"
(cd "$DEPLOY_DIR" && python3 -c "
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall('.')
" "$OLD_PKG")
rm -rf "$DEPLOY_DIR/xread_update"
echo "--- deployed version (expect 0.6.6) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2

# ---- 2) 检查更新 → 确认 → 安装 ----
emu_start "updateui"
emu_wait_mark "mode=updateui start" 180
sleep 8
import -window root /tmp/f1_confirm.png
echo "SHOT1=/tmp/f1_confirm.png"
emu_tap "${TAP_OK_X:-732}" "${TAP_OK_Y:-816}"
sleep 4
import -window root /tmp/f2_progress.png
echo "SHOT2=/tmp/f2_progress.png"
sleep 10
import -window root /tmp/f3_after.png
echo "SHOT3=/tmp/f3_after.png"

# ---- 3) 校验 ----
echo "--- installed version (expect 0.6.7) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2
echo "--- main.lua md5 ---"
md5sum "$DEPLOY_DIR/main.lua" | awk '{print $1}'
[ -n "$WANT_MAIN_MD5" ] && echo "expected: $WANT_MAIN_MD5"
echo "--- apply log ---"
grep -E "applied package|update installed" "$EMU_LOG" 2>/dev/null | tail -3
echo "--- errors ---"
grep -iE "traceback|lua error" "$EMU_LOG" 2>/dev/null | head -5
emu_stop
echo PROBE_END
