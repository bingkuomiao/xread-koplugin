#!/bin/bash
# 临时验收：正文工具栏 + 正文设置面板
CASE_ID="${CASE_ID:-p_settings}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 正文设置"
emu_start "open" ""
emu_wait_mark "mode=open done" 180
emu_settle 10
emu_shot
mv "$SHOT" "${EMU_LOG_DIR}/${CASE_ID}_book.png" 2>/dev/null
# 点正文中央呼出工具栏
emu_tap 536 724
emu_settle 8
emu_shot
mv "$SHOT" "${EMU_LOG_DIR}/${CASE_ID}_toolbar.png" 2>/dev/null
assert_no_fatal
case_finish
emu_stop
