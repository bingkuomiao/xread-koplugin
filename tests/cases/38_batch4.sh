#!/bin/bash
# TC-38 Batch 4 低内存/刷新诊断（v0.6.39）
# 背景：e-ink 的黑闪次数与封面内存占用在 WSL 上测不出来，只能看门限是否生效。
# 预期：① 首页日志输出刷新合并器计数与内存档位；
#       ② 正常档封面预算 16/0；③ XREAD_MEM_TIER=low 时预算 0/16；
#       ④ 全程无致命错误、截图非空。
CASE_ID="38_batch4"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-38 Batch4 刷新合并与封面预算"

# ① 正常内存档
emu_start "home"
emu_wait_mark "mode=home done" 180
emu_settle 6
assert_log_contains '\[XREAD_AUTOTEST\] perf paint req=[0-9]+ issued=[0-9]+ merged=[0-9]+' "刷新合并器计数已输出"
assert_log_contains '\[XREAD_AUTOTEST\] memory tier=normal .* cover_cache=true budget=[0-9]+/[1-9][0-9]*' "正常档封面预算已消耗（总 16）"
log "  normal: $(grep -o '\[XREAD_AUTOTEST\] memory .*' "$EMU_LOG" | head -1)"
log "  perf:   $(grep -o '\[XREAD_AUTOTEST\] perf .*' "$EMU_LOG" | head -1)"
emu_shot
assert_shot 20000
assert_no_fatal
emu_stop

# ② 强制低内存档：封面一律不进 ImageCache
export XREAD_MEM_TIER=low
emu_start "home"
emu_wait_mark "mode=home done" 180
emu_settle 6
assert_log_contains '\[XREAD_AUTOTEST\] memory tier=low .* budget=0/16' "低内存档封面预算 0/16"
log "  low: $(grep -o '\[XREAD_AUTOTEST\] memory .*' "$EMU_LOG" | head -1)"
emu_shot
assert_shot 20000
assert_no_fatal
emu_stop
unset XREAD_MEM_TIER

case_finish
