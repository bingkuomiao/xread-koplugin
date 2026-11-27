#!/bin/bash
# TC-28 低内存档位（XREAD_MEM_TIER=low）
# 步骤：mode=home + flow=memory_info，强制低内存档位
# 预期：tier=low、首页图层缓存降到 1 层、封面不进全局 ImageCache；首页仍能正常打开
CASE_ID="28_memory_low"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-28 低内存档位"
export XREAD_MEM_TIER=low
emu_start "home" "memory_info"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=memory_info tier=low" 150
emu_settle 8
emu_shot
assert_shot 20000
assert_log_contains "flow=memory_info tier=low .* layers=1 cover_cache=false" "低内存策略生效（1 层 + 不复用全局封面缓存）"
assert_no_fatal

case_finish
emu_stop
