#!/bin/bash
# 临时验收：目录页（单列，日/夜）截图
CASE_ID="${CASE_ID:-p_catalog}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 目录页单列"
emu_start "open" "catalog"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=catalog done" 60
emu_settle 12
emu_shot
mv "$SHOT" "${RUN_DIR}/${CASE_ID}_day.png" 2>/dev/null
assert_no_fatal
case_finish
emu_stop
