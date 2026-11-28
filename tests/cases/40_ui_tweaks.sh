#!/bin/bash
# TC-40 v0.6.41 五项修正的可自动验收部分
#   1) 本地书架点书：先保持书架盖住首页（keep_shelf=true），阅读器就绪后才关（reader_ready）
#   2) 目录四个按钮黑底白字（catalog_buttons 日志 + 截图人工复核）
#   3) 漫画图片提取单测（comic_detect_test.lua，6 项）
#   4) 首页封面维持 4×2，本地书架多显示一行（home_shelf_geom / full_shelf_geom 日志 rows）
#   5) 封面无百分比角标（geom 日志 progress_badge=off + 截图人工复核）
CASE_ID="40_ui_tweaks"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-40 v0.6.41 UI 修正"

# --- 漫画判定单测（纯 Lua，不需要模拟器） ---
LT=$(/opt/koreader/lib/koreader/luajit "$TESTS_DIR/comic_detect_test.lua" 2>&1)
if echo "$LT" | grep -q "6 passed, 0 failed"; then
    log "  comic_detect_test: 6 passed"
else
    fail "漫画判定单测未通过: $LT"
fi

# --- 本地书架点书不闪首页 ---
# 用专用 flow 直接触发 on_select，避免依赖点击坐标和假 EPUB 能否打开
emu_start "home" "local_open"
emu_wait_mark "flow=local_open invoked" 180
emu_settle 6
assert_log_contains "local_open keep_shelf=true" "点书时书架仍盖着首页（不闪首页）"
assert_log_contains "local_open reader_ready close_shelf=1" "阅读器就绪后才关书架"
assert_no_fatal
emu_stop

# --- 目录按钮黑底白字 ---
emu_start "open" "catalog"
emu_wait_mark "flow=catalog done" 180
emu_settle 4
cp "$EMU_LOG" "$EMU_LOG_DIR/40_catalog.emu.log"
assert_log_contains "catalog_buttons back_bg=Color8\(0\) order_bg=Color8\(0\) nav_bg=black" "目录四个按钮均为黑底"
emu_settle 3
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/40_catalog.png"
assert_no_fatal
emu_stop

# --- 书架行数与角标日志 ---
emu_start "home"
emu_wait_mark "mode=home done" 180
assert_log_contains "home_shelf_geom rows=2 cols=4 " "首页书架固定 4×2"
assert_log_contains "home_shelf_geom .* progress_badge=off" "首页封面无进度角标"
emu_settle 4
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/40_home.png"
assert_no_fatal
emu_stop

emu_start "home" "local_shelf"
emu_wait_mark "flow=local_shelf done" 180
assert_log_contains "full_shelf_geom rows=[34] " "本地书架至少 3 行"
assert_log_contains "full_shelf_geom .* progress_badge=off" "本地封面无进度角标"
emu_settle 4
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/40_local.png"
assert_no_fatal
emu_stop

case_finish
