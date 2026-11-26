#!/bin/bash
# 临时复现：返回书架后「立即」点同一本书，验证 reopen 守卫（修复后应能再次打开）
CASE_ID="repro_reopen"
source /root/xread-test/tests/lib/common.sh
RUN_DIR=/root/xread-test/tests/reports/manual-repro
mkdir -p "$RUN_DIR"
export RUN_DIR

case_begin "复现：返回书架立即点同一本书"
# v0.6.1 起原生菜单不再注入阅读X入口，改用 XREAD_AUTOTEST=shelf 直开书架
emu_start "shelf"
emu_wait_mark "mode=shelf done" 120

shot() { sleep 1.5; import -window root "$EMU_LOG_DIR/repro_$1.png" 2>/dev/null; log "  shot $1"; }

emu_settle 6; shot "01_shelf"

OPEN1=$(grep -c "opening file" "$EMU_LOG" 2>/dev/null || echo 0)
# 点第一本书
emu_tap 110 300
for i in $(seq 1 25); do
    C=$(grep -c "opening file" "$EMU_LOG" 2>/dev/null || echo 0)
    [ "$C" -gt "$OPEN1" ] && { log "  book1 opened @$((i*3))s"; break; }
    sleep 3
done
sleep 6; shot "02_reading"

# 呼出工具栏 -> 点书架按钮（906,330）返回书架
emu_tap 536 724; sleep 5
emu_tap 906 330; sleep 10; shot "03_back_shelf"

# 立即再点同一本书
OPEN2=$(grep -c "opening file" "$EMU_LOG" 2>/dev/null || echo 0)
emu_tap 110 300
OK=0
for i in $(seq 1 30); do
    C=$(grep -c "opening file" "$EMU_LOG" 2>/dev/null || echo 0)
    if [ "$C" -gt "$OPEN2" ]; then OK=1; log "  same book reopened @$((i*3))s"; break; fi
    sleep 3
done
sleep 6; shot "04_reopened"

if [ "$OK" = "1" ]; then log "RESULT: REOPEN_OK"; else log "RESULT: REOPEN_FAIL"; fi
assert_no_fatal
case_finish
emu_stop
grep "RESULT:" "$CASE_LOG" || true
