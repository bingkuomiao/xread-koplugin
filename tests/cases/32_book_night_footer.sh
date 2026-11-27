#!/bin/bash
# TC-32 书内夜晚：正文黑的时候页脚也要变深（不能留一条白）
# 回归点：_applyReaderChromeNight 必须把 footer_content 底色和文字色一起按源色翻转。
CASE_ID="32_book_night_footer"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-32 书内夜晚页脚"
emu_start "open" "book_night"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=book_night done" 60
emu_settle 8
emu_shot
assert_log_contains "chrome_night dark=true" "页脚按夜晚源色翻黑"
assert_no_fatal
case_finish
emu_stop
