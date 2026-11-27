#!/bin/bash
# TC-25 布局边界数据
# 步骤：mode=home + flow=layout_edge，用假 books（超长书名/空作者/无封面/进度 0/13 本）开全屏书架
# 预期：不崩、不越界，卡片按页分栏正常
CASE_ID="25_layout_edge"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-25 布局边界数据"
emu_start "home" "layout_edge"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=layout_edge done ok=true n=13" 180
emu_settle 8
emu_shot
assert_shot 20000
assert_no_fatal

case_finish
emu_stop
