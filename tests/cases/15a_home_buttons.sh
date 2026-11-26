#!/bin/bash
# TC-15a 首页所有可点击按钮：每个按钮独立启动模拟器，截图后关闭，互不干扰
CASE_ID="15a_home_buttons"
source "$(dirname "$0")/../lib/common.sh"

# 独立会话点击一个按钮并截图
probe() {  # probe <按钮名> <x> <y> [等待]
    local name="$1" x="$2" y="$3" wait="${4:-5}"
    emu_start "home"
    emu_wait_mark "mode=home done" 180
    emu_settle 8
    emu_tap "$x" "$y"; sleep "$wait"
    local f="$EMU_LOG_DIR/btn_$name.png"
    import -window root "$f" 2>/dev/null
    log "  BTN $name @$x,$y: $(stat -c %s "$f" 2>/dev/null || echo 0)B"
    emu_stop
}

case_begin "TC-15a 首页按钮遍历（独立会话）"
# 首页初始态单独截一次
emu_start "home"; emu_wait_mark "mode=home done" 180; emu_settle 8
import -window root "$EMU_LOG_DIR/btn_00_home.png" 2>/dev/null
log "  BTN 00_home: $(stat -c %s "$EMU_LOG_DIR/btn_00_home.png")B"
emu_stop

probe "01_update" 90 680 10
probe "02_search" 245 680 5
probe "03_sync" 400 680 8
probe "04_night" 555 680 4
probe "05_settings" 710 680 5
probe "06_nickname" 280 45 5
probe "07_connstatus" 490 45 5
probe "08_more" 1005 45 5
probe "09_history" 455 140 5
probe "10_localread" 595 290 5
probe "11_bookcover" 400 930 12
probe "12_readingx_title" 75 45 5

assert_no_fatal
case_finish
emu_stop
