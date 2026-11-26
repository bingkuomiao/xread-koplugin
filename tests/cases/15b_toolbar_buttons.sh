#!/bin/bash
# TC-15b 阅读工具栏所有可点击按钮：flow=panel 直达工具栏，每个按钮独立会话截图
CASE_ID="15b_toolbar_buttons"
source "$(dirname "$0")/../lib/common.sh"

probe_tb() {  # probe_tb <按钮名> <x> <y> [等待]
    local name="$1" x="$2" y="$3" wait="${4:-5}"
    emu_start "open" "panel"
    emu_wait_mark "mode=open done" 180
    emu_wait_mark "flow=panel done" 60
    emu_settle 6
    emu_tap "$x" "$y"; sleep "$wait"
    local f="$EMU_LOG_DIR/toolbtn_$name.png"
    import -window root "$f" 2>/dev/null
    log "  TB $name @$x,$y: $(stat -c %s "$f" 2>/dev/null || echo 0)B"
    emu_stop
}

case_begin "TC-15b 工具栏按钮遍历（独立会话）"
# 工具栏初始态
emu_start "open" "panel"; emu_wait_mark "mode=open done" 180; emu_wait_mark "flow=panel done" 60; emu_settle 6
import -window root "$EMU_LOG_DIR/toolbtn_00_toolbar.png" 2>/dev/null
log "  TB 00_toolbar: $(stat -c %s "$EMU_LOG_DIR/toolbtn_00_toolbar.png")B"
emu_stop

probe_tb "01_catalog" 148 330 6
probe_tb "02_cache" 400 330 6
probe_tb "03_delete" 652 330 5
probe_tb "04_shelf" 906 330 10
probe_tb "05_font_minus" 185 480 4
probe_tb "06_font_plus" 400 480 4
probe_tb "07_line_minus" 590 480 4
probe_tb "08_native_plus" 810 480 4
probe_tb "09_night" 148 560 4
probe_tb "10_refresh" 400 560 10
probe_tb "11_switch" 652 560 8
probe_tb "12_settings" 906 560 5
probe_tb "13_top_home" 80 42 8
probe_tb "14_top_conn" 250 42 5
probe_tb "15_top_more" 970 42 5

assert_no_fatal
case_finish
emu_stop
