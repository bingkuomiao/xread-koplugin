#!/bin/bash
# TC-33 目录跳章后章节号必须落在本文档范围内
# 回归点：pageChapterIndex 以前在「TOC 条目数 ≠ 文档章数」时按全书比例换算，
#         换文档瞬间会算出 349 / 299 这种完全不存在的章节号，菜单里显示的章节
#         和正文对不上（用户反馈的「目录跳转异常」）。
CASE_ID="33_catalog_jump_range"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-33 目录跳章章节号"
emu_start "open" "diag_chapter"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=diag_chapter done" 120
emu_settle 8
emu_shot
assert_log_contains "after_jump_[0-9]+ index=[0-9]+" "跳章后打印了章节号"
if grep -qE "chapter_index_out_of_range" "$EMU_LOG" 2>/dev/null; then
    fail "章节号越界: $(grep -E 'chapter_index_out_of_range' "$EMU_LOG" | head -2 | tr '\n' ' ')"
else
    log "  no chapter index out of range"
fi
assert_no_fatal
case_finish
emu_stop
