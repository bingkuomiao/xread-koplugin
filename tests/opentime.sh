#!/bin/bash
# 开书耗时对比：同一本书，分别从「我的首页」和「我的书架」进入
# 用法: opentime.sh <home|shelf>
mkdir -p /root/xread-test/tests/reports/manual
source /root/xread-test/tests/lib/common.sh
export XREAD_NO_UPDATER=1
export XREAD_AUTOTEST_ENTRY="$1"
emu_start "opentime"
emu_wait_mark "opentime: chapters_ready" 200
sleep 6
emu_stop
echo PROBE_END
