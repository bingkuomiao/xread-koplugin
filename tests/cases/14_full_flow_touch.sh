#!/bin/bash
# TC-14 真机触摸全流程：阅读X -> 书架 -> 开书 -> 正文 -> 目录 -> 跳章 -> 正文阅读 -> 返回书架 -> 返回首页
# 每一步（弹窗/新页面）均截图，文件名带步骤序号，便于归档资料库 test 文件夹
CASE_ID="14_full_flow_touch"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-14 真机触摸全流程"
# v0.6.1 起原生菜单不再注入阅读X入口，改用 XREAD_AUTOTEST=shelf 直开书架引导全流程
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120

shot_step() {
    sleep 2
    local f="$EMU_LOG_DIR/step_$1.png"
    import -window root "$f" 2>/dev/null
    log "  STEP $1: $(stat -c %s "$f" 2>/dev/null || echo 0)B"
}

emu_settle 8; shot_step "05_bookshelf"
emu_tap 110 300
for i in $(seq 1 25); do grep -q "opening file" "$EMU_LOG" 2>/dev/null && { log "  opening @$((i*3))s"; break; }; sleep 3; done
sleep 6; shot_step "06_reading_ch4"
emu_tap 536 724; sleep 5; shot_step "07_toolbar"
emu_tap 148 330; sleep 6; shot_step "08_catalog"
emu_tap 500 670; sleep 10; shot_step "09_after_jump_ch6"
emu_tap 900 724; sleep 4; emu_tap 900 724; sleep 4; shot_step "10_reading_next"

TB_BEFORE=$(grep -c "ReaderToolbar" "$EMU_LOG" 2>/dev/null)
emu_tap 536 724; sleep 5
TB_AFTER=$(grep -c "ReaderToolbar" "$EMU_LOG" 2>/dev/null)
if [ "$TB_AFTER" -le "$TB_BEFORE" ]; then
    log "  toolbar not shown ($TB_BEFORE->$TB_AFTER), retry"
    emu_tap 536 724; sleep 5
fi
shot_step "11_toolbar_again"
emu_tap 906 330; sleep 12; shot_step "12_back_bookshelf"
emu_tap 50 78; sleep 8; shot_step "13_back_home"

assert_no_fatal
assert_log_contains "tapped 目录" "目录点击链路"
assert_log_contains "tapped 书架" "书架点击链路"
assert_log_contains "close_book_to_shelf done" "返回书架链路"
assert_log_contains "opening file .*\.html" "小说正文打开"
case_finish
emu_stop
