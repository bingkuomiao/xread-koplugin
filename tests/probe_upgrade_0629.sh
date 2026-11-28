#!/bin/bash
# 一次性探针：真实 0.6.29 源码 → 真实 0.6.32 包 的本地升级全流程
# 复现用户「0.6.29 升 0.6.31 报无法写入」的场景，验证 0.6.32 能升上去。
CASE_ID="p_upgrade_0629"
source "$(dirname "$0")/lib/common.sh"

OLD_VER_COMMIT="fa2c0eb"          # v0.6.29
PKG="$ROOT_DIR/_upgrade_probe/xread.koplugin_v0.6.32_20261128-084500.tar.gz"
WORK=/tmp/xread_old29

case_begin "PROBE 0.6.29 → 0.6.32 升级"

rm -rf "$WORK"
mkdir -p "$WORK"
git -C "$ROOT_DIR" archive "$OLD_VER_COMMIT" xread.koplugin | tar -x -C "$WORK"
[ -f "$WORK/xread.koplugin/_meta.lua" ] || { fail "取 0.6.29 源码失败"; case_finish; exit 1; }
grep -q 'version = "0.6.29"' "$WORK/xread.koplugin/_meta.lua" || fail "0.6.29 源码版本不对"

# 部署 0.6.29（模拟用户设备当前状态）
rm -rf "$DEPLOY"
cp -r "$WORK/xread.koplugin" "$DEPLOY"
cp "$PKG" "$DEPLOY/"
log "  已部署 0.6.29，包放入插件目录: $(basename "$PKG")"

rm -f /root/.config/koreader/xread_update_manifest.json
rm -rf /root/.config/koreader/xread_update

emu_start "localupdate"
emu_wait_mark "mode=localupdate done" 180
assert_log_contains 'local_version_now=0\.6\.32' "升级后版本应为 0.6.32"
assert_log_contains 'newer=true' "识别为新版本"

# 新模块必须真的落盘（这是 0.6.31 失败的那批文件）
for f in xread/shared.lua xread/feature_home.lua xread/feature_menus.lua \
         xread/feature_quick_actions.lua xread/feature_book_settings.lua xread/feature_book_cache.lua; do
    [ -f "$DEPLOY/$f" ] || fail "升级后缺少文件：$f"
done
grep -q 'version = "0.6.32"' "$DEPLOY/_meta.lua" || fail "_meta.lua 未更新到 0.6.32"

if grep -aq "无法写入\|无法创建目录" "$EMU_LOG"; then
    fail "升级仍然报写入失败：$(grep -a '无法写入\|无法创建目录' "$EMU_LOG" | tail -2)"
fi
assert_no_fatal

log "  升级成功：版本 0.6.32，6 个新模块均已落盘"
case_finish

# 还原部署目录
emu_stop
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
