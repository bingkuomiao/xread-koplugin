#!/bin/bash
# 探针2（不进套件）：验证修复后 书架返回/开书计时/冷缓存预取
CASE_ID="${CASE_ID:-probe2_066}"
source "$(dirname "$0")/lib/common.sh"

REPORT="$EMU_LOG_DIR"
case_begin "探针2：修复验证"

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

# ---------- S1 书架返回按钮 ----------
log "===== S1 书架返回按钮 ====="
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120
emu_settle 6
import -window root "$REPORT/s1_back_before.png" 2>/dev/null
emu_tap 50 78
sleep 12
import -window root "$REPORT/s1_back_after.png" 2>/dev/null
log "S1 shots: before=$(stat -c %s "$REPORT/s1_back_before.png" 2>/dev/null) after=$(stat -c %s "$REPORT/s1_back_after.png" 2>/dev/null)"
emu_stop

# ---------- S2 书架开书（热缓存） ----------
log "===== S2 书架开书计时 ====="
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120
sleep 4
T0=$(date +%s.%N)
emu_tap 110 300
ELAPSED_SHELF=$(poll_opening 150 "$T0")
log "S2 shelf tap->opening: ${ELAPSED_SHELF}s"
sleep 12
emu_stop

# ---------- S3 首页继续阅读（同一本书） ----------
log "===== S3 首页开书计时 ====="
emu_start "home"
emu_wait_mark "mode=home done" 120
sleep 4
T0=$(date +%s.%N)
emu_tap 595 290
ELAPSED_HOME=$(poll_opening 150 "$T0")
log "S3 home tap->opening: ${ELAPSED_HOME}s"
sleep 12
emu_stop

# ---------- S5 冷缓存：书架显示后等预取，再点书 ----------
log "===== S5 冷缓存+预取后开书 ====="
wsl_probe_cold() { :; }
rm -rf /root/.config/koreader/xread_books/meta /root/.config/koreader/xread_books/chapters
emu_start "shelf"
emu_wait_mark "mode=shelf done" 180
log "  waiting 30s for catalog prefetch..."
sleep 30
grep -c "prefetch chapters done" "$EMU_LOG" > "$REPORT/s5_prefetch_count.txt" || echo 0 > "$REPORT/s5_prefetch_count.txt"
T0=$(date +%s.%N)
emu_tap 110 300
ELAPSED_COLD=$(poll_opening 150 "$T0")
log "S5 cold+prefetch tap->opening: ${ELAPSED_COLD}s"
grep -E "prefetch|chapters_cache_hit|opening file" "$EMU_LOG" | head -30 > "$REPORT/s5_markers.txt" || true
sleep 10
emu_stop

log "===== 汇总 ====="
log "S2 shelf(热): ${ELAPSED_SHELF}s | S3 home(热): ${ELAPSED_HOME}s | S5 cold+prefetch: ${ELAPSED_COLD}s | prefetch_count=$(cat "$REPORT/s5_prefetch_count.txt" 2>/dev/null)"
case_finish
emu_stop
