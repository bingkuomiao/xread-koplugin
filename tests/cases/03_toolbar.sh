#!/bin/bash
# TC-03 miuread 阅读工具栏
# 步骤：进书后 flow=panel 自动呼出工具栏
# 预期：flow=panel 标记 + ReaderToolbar build 日志；工具栏截图正常
CASE_ID="03_toolbar"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-03 阅读工具栏"
emu_start "open" "panel"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=panel done" 60
emu_settle 10
emu_shot
assert_shot 20000
assert_log_contains '\[MiuRead\]\[ReaderToolbar\].*build' '工具栏已构建'
assert_no_fatal

case_finish
emu_stop
