#!/bin/bash
# TC-36 英雄卡片长书名排版（v0.6.34）
# 背景：书名原来和右上角刷新图标抢同一行，可用宽度被扣掉一截，
#       「三国之蜀汉我做主」这种 8 字书名会折成「三国之蜀汉我做」+「主」，
#       第二行只有一个字，看着像排版坏了。
# 预期：flow=hero_title 把书名换成长标题后重排成功（ok=true）；
#       截图人工复核：书名在刷新图标下一行、完整一行、不与作者/简介重叠。
#       （「是否真的一行放得下」取决于字体宽度，脚本不做 OCR 断言。）
CASE_ID="36_hero_title"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-36 英雄卡长书名排版"
emu_start "home" "hero_title"
emu_wait_mark "flow=hero_title done" 180
assert_log_contains "flow=hero_title done ok=true" "长书名重排完成"
emu_settle 5
emu_shot
assert_shot 20000
assert_no_fatal
case_finish
emu_stop
