#!/bin/bash
# 临时验收：进书后按 FLOW 打开指定面板并截图
# 用法：FLOW=book_settings bash tests/probe_flow.sh
CASE_ID="${CASE_ID:-p_${FLOW}}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE flow=$FLOW"
emu_start "open" "$FLOW"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=${FLOW} done" 90
emu_settle 12
emu_shot
assert_no_fatal
case_finish
emu_stop
