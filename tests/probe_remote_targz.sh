#!/bin/bash
# 探针：远端 tar.gz 热更新全链路
#   1) 把模拟器里的插件降级成 0.6.6（代码用当前工作区，只改 _meta 版本号）
#   2) XREAD_AUTOTEST=updateui → 关于本机·检查更新 → 远端列目录挑最新包（tar.gz）
#   3) 唯一确认框 → 点「更新并重启」→ 安装进度 → 自动重启
#   4) 校验 _meta.lua 变成远端版本、xread_update 留档目录存在、无 traceback
# 用法：bash tests/probe_remote_targz.sh [confirm|full]
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
STEP="${1:-confirm}"
SRC_REPO="${SRC_REPO:-/mnt/d/WorkBuddy/2026-11-24-23-40-18/xread-koplugin}"
STAGE=/tmp/xread_downgrade

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

# ---- 1) 降级部署：当前代码 + 版本号 0.6.6 ----
rm -rf "$STAGE"
cp -r "$DEPLOY_DIR" "$STAGE"
sed -i 's/version = ".*"/version = "0.6.6"/' "$STAGE/_meta.lua"
rm -rf "$STAGE/xread_update"
find "$STAGE" -maxdepth 1 \( -name 'xread.koplugin_v*.zip' -o -name 'xread.koplugin_v*.tar.gz' \) -delete
rm -rf "$DEPLOY_DIR"
cp -r "$STAGE" "$DEPLOY_DIR"
rm -rf "$STAGE"
echo "--- deployed version ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -2
rm -rf "$DEPLOY_DIR/xread_update"

# ---- 2) 起模拟器跑「检查更新」 ----
emu_start "updateui"
emu_wait_mark "mode=updateui start" 180
sleep 8
import -window root /tmp/rt1_confirm.png
echo "SHOT1=/tmp/rt1_confirm.png"

if [ "$STEP" = "full" ]; then
    emu_tap "${TAP_OK_X:-730}" "${TAP_OK_Y:-884}"
    sleep 3
    import -window root /tmp/rt2_progress.png
    echo "SHOT2=/tmp/rt2_progress.png"
    sleep 8
    import -window root /tmp/rt3_after.png
    echo "SHOT3=/tmp/rt3_after.png"
fi

echo "--- installed meta version ---"
grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -3
echo "--- xread_update store ---"
ls -1 "$DEPLOY_DIR/xread_update" 2>/dev/null | head
echo "--- package file kept? ---"
ls -1 "$DEPLOY_DIR"/xread.koplugin_v*.tar.gz 2>/dev/null
echo "--- emu log marks ---"
grep -iE "xread update|update available|installed|via=|无法|失败" "$EMU_LOG" 2>/dev/null | tail -8
grep -iE "traceback|lua error" "$EMU_LOG" 2>/dev/null | head -5
emu_stop
echo PROBE_END
