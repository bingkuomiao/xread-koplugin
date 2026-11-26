#!/bin/bash
# 探针：0.6.6 包体 + 0.6.7 主程序 → 远端 tar.gz 更新应替换多个文件
#   （只用来确认「多文件替换」路径；单文件场景已由 probe_remote_targz.sh 覆盖）
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
OLD_PKG="${OLD_PKG:-/root/xread-test/publish/xread.koplugin_v0.6.6_20261125-182656.zip}"
SRC_MAIN="${SRC_MAIN:-/root/xread-test/xread.koplugin/main.lua}"

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

rm -rf "$DEPLOY_DIR"; mkdir -p "$DEPLOY_DIR"
(cd "$DEPLOY_DIR" && python3 -c "
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall('.')
" "$OLD_PKG")
# 0.6.6 包体没有 updateui 验收模式；换上 0.6.7 的 main.lua 以便自动触发，版本仍标 0.6.6
cp "$SRC_MAIN" "$DEPLOY_DIR/main.lua"
rm -rf "$DEPLOY_DIR/xread_update"
echo "--- deployed version (expect 0.6.6) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2

emu_start "updateui"
emu_wait_mark "mode=updateui start" 180
sleep 8
import -window root /tmp/m1_confirm.png
echo "SHOT1=/tmp/m1_confirm.png"
emu_tap "${TAP_OK_X:-732}" "${TAP_OK_Y:-816}"
sleep 4
import -window root /tmp/m2_progress.png
echo "SHOT2=/tmp/m2_progress.png"
sleep 10
import -window root /tmp/m3_after.png
echo "SHOT3=/tmp/m3_after.png"

echo "--- installed version (expect 0.6.7) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2
echo "--- apply log ---"
grep -E "applied package|update installed" "$EMU_LOG" 2>/dev/null | tail -3
echo "--- errors ---"
grep -iE "traceback|lua error" "$EMU_LOG" 2>/dev/null | head -5
emu_stop
echo PROBE_END
