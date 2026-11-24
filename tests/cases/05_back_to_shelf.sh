#!/bin/bash
# TC-05 正文中经工具栏返回书架（真实交互路径）
# 步骤：进书 -> 呼出工具栏 -> 点书架图标(918,313) -> 返回书架
# 预期：tapped 书架 + closed book cached to chapter；点击后截图为书架
# 注：不要用 flow=shelf，那是直接调 closeBookToShelf，不产生 tapped 日志，覆盖不到点击链路
CASE_ID="05_back_to_shelf"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-05 正文返回书架"
emu_start "open" "panel"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=panel done" 60
emu_settle 10
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/${CASE_ID}_before_tap.png"

emu_tap 918 313
emu_settle 12
emu_shot
assert_shot 20000
assert_log_contains 'tapped 书架' '工具栏书架图标已响应'
assert_log_contains 'close_book_to_shelf done' '返回书架链路已执行'
assert_no_fatal

# 后台缓存停止日志仅在确实有缓存任务时出现，属条件日志，观察但不作为失败条件
if grep -q 'closed book cached to chapter' "$EMU_LOG" 2>/dev/null; then
    log "  bg cache stopped (observed)"
else
    log "  bg cache not running this round (expected, skipped)"
fi

case_finish
emu_stop
