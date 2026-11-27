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

screen_md5() {
    local f="$EMU_LOG_DIR/.probe.png"
    import -window root "$f" 2>/dev/null
    md5sum "$f" 2>/dev/null | cut -d' ' -f1
}

# 等界面真正离开某一个画面。固定 sleep 在后端慢的时候必然错位：
# 目录请求超时重试会把开书拖到 60s 以上，后面每一步点击都会落在旧界面上。
wait_screen_change() {
    local base="$1" limit="${2:-150}" el=0 cur
    while [ "$el" -lt "$limit" ]; do
        cur=$(screen_md5)
        if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
            log "  screen changed @${el}s"
            return 0
        fi
        sleep 3
        el=$((el+3))
    done
    fail "界面在 ${limit}s 内没有变化（预期离开当前画面）"
    return 1
}

emu_settle 8; shot_step "05_bookshelf"
SHELF_MD5=$(screen_md5)
# 源站（wujiwx.info 等）目录接口偶发超时，点书后 45s 没打开就重试，最多 3 次。
# 固定只点一次在源站抖动时必然失败：目录 8s 超时 + 重试也超时 → 书打不开。
OPENED=0
for attempt in 1 2 3; do
    emu_tap 110 300
    for i in $(seq 1 15); do
        grep -q "opening file" "$EMU_LOG" 2>/dev/null && { OPENED=1; break; }
        sleep 3
    done
    [ "$OPENED" = "1" ] && { log "  opening @attempt$attempt"; break; }
    log "  attempt $attempt 未打开书（目录可能超时），重试"
done
wait_screen_change "$SHELF_MD5" 150
emu_settle 6; shot_step "06_reading_ch4"
TB_MD5=$(screen_md5)
emu_tap 536 724; wait_screen_change "$TB_MD5" 45; shot_step "07_toolbar"
CAT_MD5=$(screen_md5)
emu_tap 148 330; wait_screen_change "$CAT_MD5" 60; shot_step "08_catalog"
JUMP_MD5=$(screen_md5)
emu_tap 500 670; wait_screen_change "$JUMP_MD5" 90; emu_settle 6; shot_step "09_after_jump_ch6"
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
