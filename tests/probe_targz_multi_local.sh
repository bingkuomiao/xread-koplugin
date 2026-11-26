#!/bin/bash
# 探针：tar.gz 多文件替换（0.6.6 包体 + 0.6.7 主程序 → 插件目录内 0.6.7 tar.gz）
#   不联网：走 checkLocal / applyLocalPackage，验证「一个包里多个文件都要换」的路径
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
OLD_PKG="${OLD_PKG:-/root/xread-test/publish/xread.koplugin_v0.6.6_20261125-182656.zip}"
SRC_MAIN="${SRC_MAIN:-/root/xread-test/xread.koplugin/main.lua}"
NEW_PKG="${NEW_PKG:-/root/xread-test/publish/plugin/xread.koplugin_v0.6.7_20261125-214505.tar.gz}"

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

[ -f "$NEW_PKG" ] || { echo "NEW_PKG 不存在: $NEW_PKG"; exit 1; }

rm -rf "$DEPLOY_DIR"; mkdir -p "$DEPLOY_DIR"
(cd "$DEPLOY_DIR" && python3 -c "
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall('.')
" "$OLD_PKG")
cp "$SRC_MAIN" "$DEPLOY_DIR/main.lua"     # 0.6.6 包体没有 localupdate 验收模式，借 0.6.7 主程序触发
rm -rf "$DEPLOY_DIR/xread_update"
cp "$NEW_PKG" "$DEPLOY_DIR/"              # 本地更新包：插件目录内
echo "--- deployed (expect 0.6.6) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2
echo "--- local package ---"
ls -l "$DEPLOY_DIR"/xread.koplugin_v*.tar.gz

emu_start "localupdate"
emu_wait_mark "mode=localupdate done" 180
sleep 2

echo "--- installed version (expect 0.6.7) ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2
echo "--- apply log ---"
grep -E "localupdate|applied package" "$EMU_LOG" 2>/dev/null | tail -5
echo "--- errors ---"
grep -iE "traceback|lua error" "$EMU_LOG" 2>/dev/null | head -5
echo "--- extracted dir files ---"
ls "$DEPLOY_DIR/xread_update" 2>/dev/null | head -3
emu_stop
echo PROBE_END
