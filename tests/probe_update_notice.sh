#!/bin/bash
# 探针 A：自动检查更新发现新版 → 提示（插件目录内放 0.6.8 本地包）
# 探针 B：手动检查更新 → 已是最新版本 回执
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
STAGING=/tmp/xread_auto_pkg
VER="0.6.8-autotest"
PKG_NAME="xread.koplugin_v${VER}_20261125-210500.zip"
PKG_PATH="$DEPLOY_DIR/$PKG_NAME"

cleanup() {
    rm -f "$PKG_PATH"
    emu_stop 2>/dev/null
    return 0
}
trap cleanup EXIT

# --- A：自动提示 ---
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -r "$DEPLOY_DIR"/. "$STAGING/"
sed -i "s/version = \".*\"/version = \"$VER\"/" "$STAGING/_meta.lua"
python3 - "$STAGING" "$PKG_PATH" <<'PY'
import os, sys, zipfile
staging, pkg = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(pkg, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in ["_meta.lua", "main.lua"]:
        z.write(os.path.join(staging, rel.replace("/", os.sep)), rel)
print("auto package:", pkg)
PY
rm -rf "$STAGING"

export XREAD_AUTOTEST_DELAY=0
emu_start "home"
emu_wait_mark "mode=home done" 180
sleep 13           # quietUpdateCheck(10) + 检查耗时，提示显示 6s
import -window root /tmp/a1_auto_notice.png
echo "SHOT_AUTO=/tmp/a1_auto_notice.png"
emu_stop
rm -f "$PKG_PATH"

# --- B：手动检查 → 已是最新 ---
export XREAD_AUTOTEST_DELAY=6
emu_start "updateui"
emu_wait_mark "mode=updateui start" 120
sleep 2
import -window root /tmp/b1_latest.png
echo "SHOT_LATEST=/tmp/b1_latest.png"
emu_stop

cp /tmp/a1_auto_notice.png /tmp/b1_latest.png "${EMU_LOG_DIR}/" 2>/dev/null
grep -iE "traceback|lua error" "$EMU_LOG" | head -5
echo PROBE_END
