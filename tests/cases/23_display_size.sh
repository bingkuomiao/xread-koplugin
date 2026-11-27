#!/bin/bash
# TC-23 界面字号三档（standard / compact / large）
# 步骤：mode=home + flow=display_size，依次切三档并重建首页
# 预期：三档都能重建完成，无溢出/崩溃；结束后恢复 standard
CASE_ID="23_display_size"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-23 界面字号三档"
emu_start "home" "display_size"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=display_size mode=standard" 150
emu_wait_mark "flow=display_size mode=compact" 150
emu_wait_mark "flow=display_size mode=large" 150
emu_wait_mark "flow=display_size done" 150
emu_settle 8
emu_shot
assert_shot 20000
# 三档都必须在 1072x1448 上跑出正确尺寸
assert_log_contains "flow=display_size mode=large sw=1072 sh=1448" "large 档屏幕尺寸正确"
assert_no_fatal

case_finish
emu_stop
