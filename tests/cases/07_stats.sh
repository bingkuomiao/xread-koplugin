#!/bin/bash
# TC-07 阅读记录
# 步骤：进书后 flow=stats 自动打开 reading_stats
# 预期：flow=stats 标记；无 loadData 未定义等历史缺陷；截图正常
CASE_ID="07_stats"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-07 阅读记录"
emu_start "open" "stats"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=stats done" 60
emu_settle 10
emu_shot
assert_shot 20000
assert_no_fatal

if grep -qi 'reading stats failed' "$EMU_LOG" 2>/dev/null; then
    fail "阅读记录面板加载失败（reading stats failed）"
fi

case_finish
emu_stop
