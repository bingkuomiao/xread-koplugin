#!/bin/bash
# 探针3：首页 hero「继续阅读」卡片开书计时（修正坐标）
CASE_ID="${CASE_ID:-probe3_066}"
source "$(dirname "$0")/lib/common.sh"

REPORT="$EMU_LOG_DIR"
case_begin "探针3：首页hero开书计时"

poll_opening() {
    local limit="${1:-150}" t0="$2" elapsed=0
    while [ "$elapsed" -lt "$limit" ]; do
        if grep -q "opening file" "$EMU_LOG" 2>/dev/null; then
            local t1=$(date +%s.%N)
            awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}'
            return 0
        fi
        sleep 0.5
        elapsed=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%d", b-a}')
    done
    echo "timeout"
}

emu_start "home"
emu_wait_mark "mode=home done" 120
emu_settle 4
import -window root "$REPORT/s3_home_before.png" 2>/dev/null
T0=$(date +%s.%N)
# hero 卡片中下部（书名/进度区域），避开右上角「历史›」与左侧封面
emu_tap 250 360
ELAPSED_HOME=$(poll_opening 150 "$T0")
log "S3 hero tap->opening: ${ELAPSED_HOME}s"
sleep 12
import -window root "$REPORT/s3_home_after.png" 2>/dev/null
grep -E "chapters_cache_hit|prefetch|opening file" "$EMU_LOG" | tail -8 > "$REPORT/s3_markers.txt" || true
emu_stop

log "===== 汇总: S3 hero=${ELAPSED_HOME}s ====="
case_finish
emu_stop
