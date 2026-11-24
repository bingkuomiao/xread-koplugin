#!/bin/bash
# TC-04 章节目录
# 步骤：进书后 flow=catalog 自动打开目录页
# 预期：flow=catalog 标记；目录页截图正常（截图保留供人工复核章节列表/高亮）
CASE_ID="04_catalog"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-04 章节目录"
emu_start "open" "catalog"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=catalog done" 60
emu_settle 10
emu_shot
assert_shot 20000
assert_no_fatal

case_finish
emu_stop
