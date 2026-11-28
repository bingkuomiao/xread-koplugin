#!/bin/bash
# 探针：测试连接回执（成功/失败各一次）
# 提示是常驻卡片（v0.6.33 起不自动消失，需点「知道了」/✕），
# 截图时机不再需要精算，XREAD_AUTOTEST_DELAY 只用于等业务请求回来
set -u
source "$(dirname "$0")/lib/common.sh"

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

export XREAD_AUTOTEST_DELAY=8

XDG_XREAD=/root/.config/koreader/settings/xread.lua
ADDR_BACKUP=$(grep -o '\["address"\] = "[^"]*"' "$XDG_XREAD" | head -1)
echo "address backup: $ADDR_BACKUP"

emu_start "healthui"
emu_wait_mark "mode=healthui start" 120
sleep 1
import -window root /tmp/h1_ok.png
echo "SHOT_OK=/tmp/h1_ok.png"
emu_stop

# 失败场景：不可达端口
sed -i 's#\["address"\] = "[^"]*"#["address"] = "http://127.0.0.1:7799"#' "$XDG_XREAD"
grep -n '"address"' "$XDG_XREAD" | head -2

emu_start "healthui"
emu_wait_mark "mode=healthui start" 120
sleep 1
import -window root /tmp/h2_fail.png
echo "SHOT_FAIL=/tmp/h2_fail.png"
emu_stop

# 还原地址
if [ -n "$ADDR_BACKUP" ]; then
    sed -i "s#\[\"address\"\] = \"[^\"]*\"#$ADDR_BACKUP#" "$XDG_XREAD"
    echo "address restored: $(grep -o '\[\"address\"\] = \"[^\"]*\"' "$XDG_XREAD" | head -1)"
fi

cp /tmp/h1_ok.png /tmp/h2_fail.png "${EMU_LOG_DIR}/" 2>/dev/null
grep -iE "traceback|lua error" "$EMU_LOG" | head -5
echo PROBE_END
