#!/bin/bash
# 探针：自动进入指定页面 → 可选点击 → 每 0.4s 截一帧，用于量测开书耗时
# 用法: probe.sh <mode:home|shelf|open|none> <outprefix> [tapx tapy]
MODE="$1"
PRE="$2"
TX="$3"
TY="$4"
mkdir -p /root/xread-test/tests/reports/manual
source /root/xread-test/tests/lib/common.sh
export XREAD_NO_UPDATER=1
export XREAD_AUTOTEST_DELAY=8
if [ "$MODE" = "none" ]; then
    emu_start ""
else
    emu_start "$MODE"
fi
sleep 40
import -window root "/tmp/${PRE}_0before.png"
if [ -n "$TX" ]; then
    emu_tap "$TX" "$TY"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        import -window root "/tmp/${PRE}_${i}.png"
        sleep 0.4
    done
fi
emu_stop
echo END
