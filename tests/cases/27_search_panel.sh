#!/bin/bash
# TC-27 搜索加书入口
# 步骤：mode=home + flow=search_panel，打开搜索输入框后关闭
# 预期：输入框正常弹出（栈顶非空）、可关闭，不发任何网络请求
CASE_ID="27_search_panel"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-27 搜索加书入口"
emu_start "home" "search_panel"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=search_panel done ok=true" 180
# 搜框会停留 14s 再自动关闭，这里先截图，不能等 emu_settle（会超过关闭时间）
sleep 4
emu_shot
assert_shot 20000
# 之后才断言「确实弹出过、栈顶非空」
emu_wait_mark "flow=search_panel top=" 120
assert_log_contains "flow=search_panel top=[^ ]+ shown=true" "搜索框已弹出"
assert_no_fatal

case_finish
emu_stop
