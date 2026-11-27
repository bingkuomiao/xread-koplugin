#!/bin/bash
# TC-26 全屏书架翻页
# 步骤：mode=home + flow=shelf_paging，30 本假书 → 第 1 页 → 第 2 页 → 第 3 页 → 回第 2 页
# 预期：每页重建都成功，页数正确，旧 widget 树释放后不崩（Batch 4 的封面内存回收路径）
CASE_ID="26_shelf_paging"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-26 全屏书架翻页"
emu_start "home" "shelf_paging"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=shelf_paging open ok=true" 180
emu_wait_mark "flow=shelf_paging done page=2" 180
emu_settle 8
emu_shot
assert_shot 20000
# 30 本、每页 12 张（4 列 x 3 行）= 3 页
assert_log_contains "flow=shelf_paging open ok=true pages=3" "页数=3"
assert_no_fatal

case_finish
emu_stop
