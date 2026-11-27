#!/bin/bash
# TC-21 夜晚按钮：正文只切当前书籍，首页切全局；复现「正文点完首页点不动」
CASE_ID="21_night_buttons"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-21 夜晚按钮作用域与连续切换"

# 固定初始状态：全局日间、书籍未单独设置夜晚
sed -i 's/\["night_mode"\] = true/["night_mode"] = false/' /root/.config/koreader/settings.reader.lua 2>/dev/null
find /root/.config/koreader/xread_books -name 'metadata.html.lua' -type f -exec sed -i '/xread_book_night/d' {} \; 2>/dev/null || true

emu_start "open" "night_seq"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=night_seq book done" 60
emu_wait_mark "flow=night_seq home1 done" 60
emu_wait_mark "flow=night_seq home2 done" 60
emu_settle 8
emu_shot

assert_log_contains 'book_night=true global_night=false' '正文按钮只切书籍，不改全局'
assert_log_contains '\[XREAD_AUTOTEST\] global_night=true' '首页按钮切到全局夜晚'
assert_log_contains '\[XREAD_AUTOTEST\] global_night=false' '首页按钮切回全局日间'
assert_shot 20000
assert_no_fatal

case_finish
emu_stop
