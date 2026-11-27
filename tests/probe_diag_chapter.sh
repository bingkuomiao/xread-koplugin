#!/bin/bash
# 诊断：开书位置 vs 目录跳章后的章节号/文档范围/TOC 条目
# 用法：XREAD_DIAG_JUMP=487 XREAD_AUTOTEST_BOOK=仙河风暴 bash tests/probe_diag_chapter.sh
CASE_ID="${CASE_ID:-p_diag}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE 目录跳章诊断"
emu_start "open" "diag_chapter"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=diag_chapter done" 120
emu_settle 8
emu_shot
assert_log_contains "XREAD_DIAG" "诊断输出"
assert_no_fatal
grep -F "[XREAD_DIAG]" "$EMU_LOG" | tail -10 | tee -a "$CASE_LOG"
case_finish
emu_stop
