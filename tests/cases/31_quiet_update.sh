#!/usr/bin/env bash
# TC-31 后台静默检查更新（未登录起步）
# 背景：列目录 /plugin 需要有效 token，未登录时后端返回 400 NEED_LOGIN；
# 首页走本地缓存渲染时恰好还没登录，这一轮会白跑且整个会话不再提示更新。
# 断言：能走到检查完成并输出 local/remote 版本，日志里没有「quiet update check failed」。
CASE_ID="31_quiet_update"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-31 静默检查更新"

emu_start "home"
emu_wait_mark "mode=home done" 180
emu_wait_mark "update_checked newer=" 90
emu_settle 4
emu_shot
assert_shot 20000
assert_log_contains "update_checked newer=(true|false)" "更新检查已执行完成"
if grep -aq "quiet update check failed" "$EMU_LOG"; then
    fail "静默检查更新仍然失败：$(grep -a 'quiet update check failed' "$EMU_LOG" | tail -1)"
fi
assert_no_fatal

case_finish
emu_stop
