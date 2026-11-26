#!/bin/bash
# 探针（不进套件）：①书架返回按钮是否回首页 ②书架 vs 首页开书计时
CASE_ID="${CASE_ID:-probe_066}"
source "$(dirname "$0")/lib/common.sh"

REPORT="$EMU_LOG_DIR"
case_begin "探针：书架返回 + 开书计时"

poll_opening() {  # poll_opening <超时秒> -> 输出耗时，找不到输出 timeout
    local limit="${1:-120}" t0="$2" elapsed=0
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

# ---------- 会话1：书架返回按钮 ----------
log "===== S1 书架返回按钮 ====="
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120
emu_settle 8
import -window root "$REPORT/s1_back_before.png" 2>/dev/null
emu_tap 50 78
sleep 12
import -window root "$REPORT/s1_back_after.png" 2>/dev/null
log "S1 shots: before=$(stat -c %s "$REPORT/s1_back_before.png" 2>/dev/null) after=$(stat -c %s "$REPORT/s1_back_after.png" 2>/dev/null)"
grep -n "showHome\|home build\|on_back\|error\|Error" "$EMU_LOG" | tail -10 > "$REPORT/s1_log_tail.txt" || true
emu_stop

# ---------- 会话2：书架点第一本书（计时） ----------
log "===== S2 书架开书计时 ====="
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120
sleep 4
TAP_LINE=$(wc -l < "$EMU_LOG")
T0=$(date +%s.%N)
emu_tap 110 300
ELAPSED_SHELF=$(poll_opening 150 "$T0")
log "S2 shelf tap->opening: ${ELAPSED_SHELF}s"
sleep 15
import -window root "$REPORT/s2_shelf_open.png" 2>/dev/null
# 记录 tap 前行号之后的新日志（判断缓存命中与后台任务竞争）
tail -n +$((TAP_LINE+1)) "$EMU_LOG" > "$REPORT/s2_after_tap.log"
grep -E "chapters_cache_hit|prefetch|fetchAndStore|cover|getChapterList|opening file" "$REPORT/s2_after_tap.log" | head -20 > "$REPORT/s2_markers.txt" || true
emu_stop

# ---------- 会话3：首页点继续阅读（同一本书，缓存已热） ----------
log "===== S3 首页开书计时（同一本书） ====="
emu_start "home"
emu_wait_mark "mode=home done" 120
sleep 4
TAP_LINE=$(wc -l < "$EMU_LOG")
T0=$(date +%s.%N)
emu_tap 595 290
ELAPSED_HOME=$(poll_opening 150 "$T0")
log "S3 home tap->opening: ${ELAPSED_HOME}s"
sleep 15
import -window root "$REPORT/s3_home_open.png" 2>/dev/null
tail -n +$((TAP_LINE+1)) "$EMU_LOG" > "$REPORT/s3_after_tap.log"
grep -E "chapters_cache_hit|prefetch|fetchAndStore|cover|getChapterList|opening file" "$REPORT/s3_after_tap.log" | head -20 > "$REPORT/s3_markers.txt" || true
emu_stop

log "===== 汇总 ====="
log "S2 shelf: ${ELAPSED_SHELF}s | S3 home: ${ELAPSED_HOME}s"
case_finish
emu_stop
