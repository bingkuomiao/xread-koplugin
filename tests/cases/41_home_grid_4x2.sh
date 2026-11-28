#!/bin/bash
# TC-41 v0.6.42 首页封面固定 4×2（本地书架仍为竖屏 4 行 / 横屏 3 行）
#   1) 首页几何日志 rows=2 cols=4，封面尺寸回到 v0.6.40 的大图
#   2) 本地书架几何日志仍为 rows=4 或 3，确认未被本次回退波及
CASE_ID="41_home_grid_4x2"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-41 首页封面 4×2"

emu_start "home"
emu_wait_mark "mode=home done" 180
assert_log_contains "home_shelf_geom rows=2 cols=4 " "首页固定 4 列 2 行"
emu_settle 6
emu_shot
assert_shot 20000
cp "$SHOT" "$EMU_LOG_DIR/41_home.png"
assert_no_fatal
emu_stop

emu_start "home" "local_shelf"
emu_wait_mark "flow=local_shelf done" 180
assert_log_contains "full_shelf_geom rows=[34] cols=4 " "本地书架保持 4 列、竖 4/横 3 行"
emu_settle 4
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/41_local.png"
assert_no_fatal
emu_stop

case_finish
