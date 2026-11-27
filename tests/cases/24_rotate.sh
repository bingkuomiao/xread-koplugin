#!/bin/bash
# TC-24 横竖屏旋转
# 步骤：mode=home + flow=rotate，切横屏重建首页，再切回竖屏重建
# 预期：两次重建都完成、不崩；日志记录两次的屏幕尺寸供比对
# 说明：模拟器（SDL）对旋转的支持与真机不完全一致，这里只硬断言「两次重建都完成」，
#       尺寸是否真的互换记录下来人工核对，避免把 emulator 差异算成插件缺陷。
CASE_ID="24_rotate"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-24 横竖屏旋转"
emu_start "home" "rotate"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=rotate landscape=" 180
emu_wait_mark "flow=rotate done portrait=" 180
emu_settle 8
emu_shot
assert_shot 20000
# 横屏重建后首页必须仍然活着（不能出现「关掉就不回来」）
assert_log_contains "flow=rotate done portrait=[0-9]+x[0-9]+" "竖屏重建完成"
assert_no_fatal

case_finish
emu_stop
