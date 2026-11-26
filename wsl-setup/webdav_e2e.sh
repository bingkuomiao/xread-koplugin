#!/bin/bash
# 真实 NAS webdav 端到端热更新验证（纯列目录挑最新）
#
# 做的事：
#   1) 把源码部署到模拟器，并把本地 _meta 版本降级（制造"有新版本"场景）
#   2) 清掉本地残留包，强制完整检查流程
#   3) 启动模拟器 XREAD_AUTOTEST=update，列目录（getWebdavFileList）按包名版本挑最新 zip
#   4) 断言：识别远端版本 -> 判定有新版本 -> 下载整包 -> 增量应用 -> 本地版本变远端版本
#   5) 校验部署目录文件 md5 与源码一致，然后还原部署目录
#
# 用法：bash wsl-setup/webdav_e2e.sh [降级到的版本，默认 0.5.6]

CASE_ID="13_webdav_e2e"
source "$(dirname "$0")/../tests/lib/common.sh"

DOWNGRADE_TO="${1:-0.5.6}"
SETTINGS="/root/.config/koreader/settings/xread.lua"
STATE="/root/.config/koreader/xread_update_manifest.json"

cleanup() { emu_stop 2>/dev/null; return 0; }
trap cleanup EXIT

case_begin "TC-13 真实 NAS webdav 热更新（zip 包模式）"

# 0) 凭据
[ -f "$SETTINGS" ] || { fail "缺少凭据文件 $SETTINGS"; case_finish; exit 1; }
ADDR=$(grep -oP '(?<=\["address"\] = ")[^"]+' "$SETTINGS")
[ -n "$ADDR" ] || { fail "凭据中无 address"; case_finish; exit 1; }
log "  后端: $ADDR"

# 1) 部署源码并降级版本
rm -rf "$DEPLOY"
cp -r "$PLUGIN_SRC" "$DEPLOY" || { fail "部署源码失败"; case_finish; exit 1; }
REMOTE_VER=$(grep -oP '(?<=version = ")[^"]+' "$PLUGIN_SRC/_meta.lua" | head -1)
sed -i "s/version = \"[^\"]*\"/version = \"$DOWNGRADE_TO\"/" "$DEPLOY/_meta.lua"
grep -q "version = \"$DOWNGRADE_TO\"" "$DEPLOY/_meta.lua" || { fail "降级失败"; case_finish; exit 1; }
log "  已降级本地版本: $DOWNGRADE_TO  （远端应为 $REMOTE_VER）"

# 2) 清本地更新状态与残留包，强制全流程
rm -f "$STATE" /root/.config/koreader/xread_update_*.zip
rm -rf /root/.config/koreader/xread_update
log "  已清理本地更新清单、包目录与残留包"

# 3) 跑更新
emu_start "update"
emu_wait_mark "mode=update done" 300

assert_log_contains "remote=$REMOTE_VER" "识别远端版本 $REMOTE_VER"
assert_log_contains "newer=true" "判定有新版本"
assert_log_contains 'via=list' "走列目录挑最新版本"
assert_log_contains "local_version_now=$REMOTE_VER" "本地版本已升到 $REMOTE_VER"
assert_no_fatal

# 4) 应用结果核对
APPLIED=$(grep -oP 'update applied: changed=\K[0-9]+' "$EMU_LOG" | tail -1)
SKIPPED=$(grep -oP 'skipped=\K[0-9]+' "$EMU_LOG" | tail -1)
log "  远端下载文件数: $(grep -oP 'update file \K[0-9]+' "$EMU_LOG" | tail -1)"
log "  应用结果: changed=${APPLIED:-?} skipped=${SKIPPED:-?}"
[ -n "$APPLIED" ] && [ "$APPLIED" -ge 1 ] || fail "没有文件被实际替换（changed=${APPLIED:-空}）"

# 5) 部署目录 md5 与源码比对（抽查 + _meta 版本）
diff_meta=$(grep -oP '(?<=version = ")[^"]+' "$DEPLOY/_meta.lua" | head -1)
[ "$diff_meta" = "$REMOTE_VER" ] && log "  部署 _meta 版本: $diff_meta OK" || fail "部署 _meta 版本异常: $diff_meta"

BAD=0
for f in main.lua xread/updater.lua xread/miui/reader_toolbar.lua resources/icons/miuread/home.svg; do
    a=$(md5sum "$DEPLOY/$f" 2>/dev/null | cut -d' ' -f1)
    b=$(md5sum "$PLUGIN_SRC/$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then log "  md5 OK: $f"; else fail "md5 不一致: $f"; BAD=1; fi
done

# 6) 更新包落盘结构：压缩包与同名解压目录同级留存
PKG_ROOT_DIR="/root/.config/koreader/xread_update"
EXTRACT=$(ls -1dt "$PKG_ROOT_DIR"/*/ 2>/dev/null | head -1 | sed 's:/$::')
if [ -n "$EXTRACT" ]; then
    log "  解压目录: $EXTRACT"
    [ -f "$EXTRACT/_meta.lua" ] && log "  解压目录含 _meta.lua OK" || fail "解压目录缺少 _meta.lua"
    [ -f "$EXTRACT.zip" ] && log "  同名压缩包同级留存 OK" || fail "缺少同名压缩包: $EXTRACT.zip"
    ev=$(grep -oP '(?<=version = ")[^"]+' "$EXTRACT/_meta.lua" 2>/dev/null | head -1)
    [ "$ev" = "$REMOTE_VER" ] && log "  解压目录版本 $ev OK" || fail "解压目录版本异常: $ev"
    cnt=$(find "$EXTRACT" -type f | wc -l)
    [ "$cnt" -ge 100 ] && log "  解压目录文件数 $cnt OK" || fail "解压目录文件数异常: $cnt"
else
    fail "未生成 xread_update 解压目录"
fi
[ -f "$PKG_ROOT_DIR/packages.txt" ] && log "  包索引: $(tr '\n' ' ' < "$PKG_ROOT_DIR/packages.txt")" || fail "缺少 packages.txt 索引"

case_finish

# 7) 还原部署目录为源码原状
rm -rf "$DEPLOY"
cp -r "$PLUGIN_SRC" "$DEPLOY"
log "  部署目录已还原"
