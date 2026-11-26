#!/bin/bash
pkill -9 -f '[X]vfb'
pkill -9 -f '[l]uajit'
export DISPLAY=:99
Xvfb :99 -screen 0 1072x1448x24 -nolisten tcp >/tmp/xv.log 2>&1 &
sleep 2
cd /opt/koreader || exit 1
EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 \
LIBGL_ALWAYS_SOFTWARE=1 SDL_VIDEODRIVER=x11 \
XREAD_AUTOTEST=opentime XREAD_AUTOTEST_ENTRY=shelf \
timeout 150 ./lib/koreader/koreader.sh /root > /tmp/manual.log 2>&1
echo "EXIT=$?"
grep -n -i "xread\|traceback\|lua error" /tmp/manual.log | head -30
pkill -9 -f '[X]vfb'
