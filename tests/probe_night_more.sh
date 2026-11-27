#!/bin/bash
CASE_ID="${CASE_ID:-p_night_more}"
source "/mnt/d/WorkBuddy/2026-11-24-23-40-18/xread-koplugin/tests/lib/common.sh"
case_begin "PROBE 夜间更多面板"
sed -i 's/\["night_mode"\] = false/["night_mode"] = true/' /root/.config/koreader/settings.reader.lua
emu_start "open" "more"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=more done" 60
emu_settle 10
emu_shot
assert_no_fatal
case_finish
emu_stop
sed -i 's/\["night_mode"\] = true/["night_mode"] = false/' /root/.config/koreader/settings.reader.lua
