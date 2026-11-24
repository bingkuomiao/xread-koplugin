#!/bin/bash
# TC-08 工具栏「目录」图标点击交互
# 步骤：呼出工具栏 -> 点目录图标(118,313) -> 进入章节目录
# 预期：tapped 目录 日志；点击后截图正常，无 Paused 框拦截
CASE_ID="08_toolbar_catalog_tap"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-08 工具栏点目录"
emu_start "open" "panel"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=panel done" 60
emu_settle 10
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/${CASE_ID}_before_tap.png"

emu_tap 118 313
emu_settle 8
emu_shot
assert_shot 20000
assert_log_contains 'tapped 目录' '目录图标点击已响应'
assert_no_fatal

case_finish
emu_stop
