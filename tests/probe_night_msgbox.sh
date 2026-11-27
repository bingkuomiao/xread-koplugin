#!/bin/bash
# 临时验收：夜间模式下的统一提示框 / 确认框（反色后应为 黑底白字白边）
# 用法：FLOW=msgbox bash tests/probe_night_msgbox.sh
#       FLOW=msgconfirm CASE_ID=p_night_cfm bash tests/probe_night_msgbox.sh
FLOW="${FLOW:-msgbox}"
CASE_ID="${CASE_ID:-p_night_$FLOW}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 夜间 flow=$FLOW"
sed -i 's/\["night_mode"\] = false/["night_mode"] = true/' /root/.config/koreader/settings.reader.lua
emu_start "open" "$FLOW"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=$FLOW done" 60
emu_settle 12
emu_shot
assert_no_fatal
case_finish
emu_stop
sed -i 's/\["night_mode"\] = true/["night_mode"] = false/' /root/.config/koreader/settings.reader.lua
