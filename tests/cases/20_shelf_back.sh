#!/bin/bash
# TC-20 书架返回首页（v0.6.7+）：首页 → 我的书架 → 点左上返回，必须回到首页且书架已关闭
# 覆盖：书架盖在首页上不叠层、返回时唤醒已存在的首页（不重建）、书架视图被正确置空
CASE_ID="20_shelf_back"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-20 书架返回首页"
emu_start "shelfback"
emu_wait_mark "mode=shelfback done" 240
emu_settle 6
emu_shot
assert_shot 20000
assert_log_contains "shelfback: shelf_open=true" "书架已打开"
assert_log_contains "shelfback: home_alive=true" "返回后首页仍在（单实例）"
assert_log_contains "shelf_closed=true" "书架视图已关闭"
assert_no_fatal
case_finish
emu_stop
