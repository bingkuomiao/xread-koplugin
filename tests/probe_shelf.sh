#!/bin/bash
# 临时探针：首页 → 更多 → 我的书架 → 截图 → 点返回箭头 → 截图（验证能否回首页）
mkdir -p /root/xread-test/tests/reports/manual
source /root/xread-test/tests/lib/common.sh
export XREAD_NO_UPDATER=1
emu_start "home"
emu_wait_mark "mode=home done" 180
sleep 30
import -window root /tmp/s0_home.png
emu_tap 1005 45; sleep 3          # 更多
emu_tap 536 485; sleep 14         # 我的书架
import -window root /tmp/s1_shelf.png
emu_tap 70 50; sleep 6            # 左上返回箭头
import -window root /tmp/s2_back.png
sleep 3
import -window root /tmp/s3_back2.png
emu_stop
echo PROBE_END
