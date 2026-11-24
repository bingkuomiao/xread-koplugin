#!/bin/bash
# TC-06 miuread 风格首页
# 步骤：XREAD_AUTOTEST=home 自动打开首页
# 预期：mode=home 标记；hero 卡/阅读数据/书架网格截图正常
CASE_ID="06_home"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-06 首页"
emu_start "home"
emu_wait_mark "mode=home done" 180
emu_settle 12
emu_shot
assert_shot 20000
assert_no_fatal

case_finish
emu_stop
