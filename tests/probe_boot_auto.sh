#!/bin/bash
# 临时验收：不开 autotest，模拟真实开机，看「启动管理」是否自动进入
CASE_ID="${CASE_ID:-p_boot_auto}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 开机自动进入"
pkill -9 -f '[X]vfb' 2>/dev/null
pkill -9 -f '[l]uajit' 2>/dev/null
sleep 1
rm -f /tmp/xread_autotest_once /tmp/xread_flow_once /root/.config/koreader/history.lua
sed -i '/\["lastfile"\]/d' /root/.config/koreader/settings.reader.lua 2>/dev/null
export DISPLAY=:99
Xvfb :99 -screen 0 1072x1448x24 -nolisten tcp >/tmp/xread-xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
cd "$KOREADER_DIR" || exit 1
export EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300
export LIBGL_ALWAYS_SOFTWARE=1 SDL_VIDEODRIVER=x11
unset XREAD_AUTOTEST XREAD_AUTOTEST_ONCE XREAD_AUTOTEST_FLOW
timeout 120 ./lib/koreader/koreader.sh /root >"$EMU_LOG" 2>&1 &
EMU_PID=$!
sleep 22
emu_shot
assert_shot 20000
assert_no_fatal
case_finish
emu_stop
