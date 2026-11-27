#!/bin/bash
# 临时验收：书内夜晚（正文黑）时底部状态栏是否也变深
CASE_ID="${CASE_ID:-p_booknight}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 书内夜晚页脚"
emu_start "open" "book_night"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=book_night done" 60
emu_settle 10
emu_shot
assert_no_fatal
case_finish
emu_stop
