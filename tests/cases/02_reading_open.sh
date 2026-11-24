#!/bin/bash
# TC-02 点书开书 / 阅读正文
# 步骤：XREAD_AUTOTEST=open 自动打开第一本可读的书
# 预期：mode=open 标记 + opening file 日志；正文截图正常
CASE_ID="02_reading_open"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-02 开书进入正文"
emu_start "open"
emu_wait_mark "mode=open done" 180
emu_settle 10
emu_shot
assert_shot 20000
# 正文已改为 HTML（.html）；最近在读可能是漫画（.cbz），三者都算开书成功
assert_log_contains 'opening file .*/xread_books/.*\.(html|txt|cbz)' '书籍正文文件已打开'
assert_no_fatal

case_finish
emu_stop
