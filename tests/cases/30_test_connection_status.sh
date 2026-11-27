#!/bin/bash
# TC-30 测试连接成功后顶部状态立即变「已连接」
# 步骤：mode=home + flow=test_conn，先制造「已断开」，再点「测试连接」
# 预期：测试连接成功后 _health_ok 立即变 true，顶部 header 同步变「已连接」，
#       而不是等下一轮 60s 心跳或手动刷新（回归点：testConnection 成功分支的 header 回写）
CASE_ID="30_test_connection_status"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-30 测试连接顶部状态"
emu_start "home" "test_conn"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=test_conn disconnected" 60
emu_wait_mark "flow=test_conn done" 60
assert_log_contains "flow=test_conn health_ok=true" "测试连接成功后连接状态已置为已连接"
assert_no_fatal
# 截一张图：顶部状态应从「已断开」翻成「已连接」
sleep 2
emu_shot

case_finish
emu_stop
