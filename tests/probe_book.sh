#!/bin/bash
# 临时验收：只打开正文并截图（用于看排版：缩进/页尾页码）
CASE_ID="${CASE_ID:-p_book}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 正文排版"
emu_start "open" ""
emu_wait_mark "mode=open done" 180
emu_settle 12
emu_shot
assert_no_fatal
case_finish
emu_stop
