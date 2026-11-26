#!/bin/bash
# 探针：检查更新 → 唯一确认框 → 安装进度 → 自动重启（本地包，不联网）
# 用法：bash tests/probe_update_ui.sh [step]
#   step=confirm 只截确认框；step=full 点「更新并重启」走完整流程
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
STAGING=/tmp/xread_ui_pkg
VER="0.6.8-uitest"
PKG_NAME="xread.koplugin_v${VER}_20261125-210000.zip"
PKG_PATH="$DEPLOY_DIR/$PKG_NAME"
STEP="${1:-confirm}"

cleanup() {
    rm -f "$PKG_PATH"
    emu_stop 2>/dev/null
    return 0
}
trap cleanup EXIT

# 构造更高版本的本地包（只放 _meta.lua / main.lua / updater.lua，够验证链路）
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -r "$DEPLOY_DIR"/. "$STAGING/"
sed -i "s/version = \".*\"/version = \"$VER\"/" "$STAGING/_meta.lua"
python3 - "$STAGING" "$PKG_PATH" <<'PY'
import os, sys, zipfile
staging, pkg = sys.argv[1], sys.argv[2]
picks = ["_meta.lua", "main.lua", "xread/updater.lua"]
with zipfile.ZipFile(pkg, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in picks:
        z.write(os.path.join(staging, rel.replace("/", os.sep)), rel)
print("probe package:", pkg, os.path.getsize(pkg), "bytes")
PY
rm -rf "$STAGING"
[ -f "$PKG_PATH" ] || { echo "PKG BUILD FAILED"; exit 1; }

emu_start "updateui"
emu_wait_mark "mode=updateui start" 120
sleep 6
import -window root /tmp/u1_confirm.png
echo "SHOT1=/tmp/u1_confirm.png"

if [ "$STEP" = "full" ]; then
    emu_tap "${TAP_OK_X:-838}" "${TAP_OK_Y:-820}"
    sleep 3
    import -window root /tmp/u2_progress.png
    echo "SHOT2=/tmp/u2_progress.png"
    sleep 6
    import -window root /tmp/u3_after.png
    echo "SHOT3=/tmp/u3_after.png"
    echo "--- installed meta ---"
    grep -n 'version' "$DEPLOY_DIR/_meta.lua" | head -3
    echo "--- store ---"
    ls "$DEPLOY_DIR/xread_update" 2>/dev/null
fi

cp /tmp/u1_confirm.png "${EMU_LOG_DIR}/probe_u1_confirm.png" 2>/dev/null
grep -iE "traceback|lua error" "$EMU_LOG" | head -5
emu_stop
echo PROBE_END
