#!/bin/bash
# 验收：首页后端不可达 → 居中卡片「取消 / 修改」→ 点「修改」跳地址管理
CASE_ID="${CASE_ID:-p_soft_edit}"
source "$(dirname "$0")/lib/common.sh"

case_begin "PROBE soft_edit"
emu_start "open" "soft_down"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=soft_down done" 90
sleep 2
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/${CASE_ID}_before.png"
# 卡片底部「修改」按钮（1072x1448 屏幕坐标）
emu_tap 711 858
sleep 5
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/${CASE_ID}_after.png"
assert_no_fatal
case_finish
emu_stop
