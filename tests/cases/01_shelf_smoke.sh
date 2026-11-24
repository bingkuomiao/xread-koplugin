#!/bin/bash
# TC-01 书架加载冒烟
# 前置：后端可达、xread.lua 凭据有效
# 步骤：XREAD_AUTOTEST=shelf 自动打开书架
# 预期：mode=shelf 标记出现；截图为书架网格；无未捕获异常/图片格式错误
CASE_ID="01_shelf_smoke"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-01 书架加载冒烟"
emu_start "shelf"
emu_wait_mark "mode=shelf done" 180
emu_settle 10
emu_shot
assert_shot 20000
assert_no_fatal

fmt=$(grep -c 'format error' "$EMU_LOG" 2>/dev/null || echo 0)
unhandled=$(grep -c 'UNHANDLED EXCEPTION' "$EMU_LOG" 2>/dev/null || echo 0)
log "  format_error=$fmt unhandled=$unhandled"
[ "$fmt" -gt 0 ] && fail "出现 $fmt 次图片格式错误（封面魔数校验未拦住）"

case_finish
emu_stop
