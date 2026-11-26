#!/bin/bash
# 临时探针：进首页 → 开更多面板 → 截图；可选再点一个条目
mkdir -p /root/xread-test/tests/reports/manual
source /root/xread-test/tests/lib/common.sh
export XREAD_NO_UPDATER=1
emu_start "home"
emu_wait_mark "mode=home done" 180
sleep 30
import -window root /tmp/p1_home.png
emu_tap 1005 45; sleep 3
import -window root /tmp/p2_more.png
if [ -n "$1" ]; then
    emu_tap 400 "$1"; sleep 5
    import -window root /tmp/p3_item.png
fi
emu_stop
echo PROBE_END
