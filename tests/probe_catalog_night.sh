#!/bin/bash
# 临时验收：夜间目录页截图（单列，反色后的白底黑字/浅灰底）
CASE_ID="${CASE_ID:-p_catalog_night}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 夜间目录页"
sed -i 's/\["night_mode"\] = false/["night_mode"] = true/' /root/.config/koreader/settings.reader.lua
emu_start "open" "catalog"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=catalog done" 60
emu_settle 12
emu_shot
assert_no_fatal
case_finish
emu_stop
sed -i 's/\["night_mode"\] = true/["night_mode"] = false/' /root/.config/koreader/settings.reader.lua
