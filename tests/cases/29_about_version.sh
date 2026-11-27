#!/bin/bash
# TC-29 关于本机显示后端版本
# 步骤：mode=home 打开首页 → 更多面板 → 关于本机
# 预期：后端版本从「检测中」更新为具体版本号（如 v1.0.48.x），不是「未知」
# 回归点：showAboutPanel 不能走 _scheduleNetJob（弹层让路会把请求永久挂起），
#         未登录时须静默补登录再取 getVersionUpdate。
CASE_ID="29_about_version"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-29 关于本机后端版本"
emu_start "home"
emu_wait_mark "mode=home done" 180
emu_settle 8
emu_tap 1005 45; sleep 4     # 开更多面板
emu_tap 400 950; sleep 12    # 点「关于本机」（第5项）
emu_wait_mark "about_server_version" 40
assert_log_contains "about_server_version v[0-9]" "后端版本已获取到具体版本号"
assert_no_fatal
emu_shot

case_finish
emu_stop
