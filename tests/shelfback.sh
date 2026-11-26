#!/bin/bash
# 书架返回首页验收
mkdir -p /root/xread-test/tests/reports/manual
source /root/xread-test/tests/lib/common.sh
export XREAD_NO_UPDATER=1
rm -f /root/.config/koreader/xread_books/*.html
emu_start "shelfback"
sleep 90
import -window root /tmp/sb_after.png
grep 'shelfback' "$EMU_LOG" | tail -5
emu_stop
echo PROBE_END
