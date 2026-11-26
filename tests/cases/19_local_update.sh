#!/bin/bash
# TC-19 本地包热更新（v0.6.4+）：规范包放插件目录内 → checkLocal 直接发现并安装
# 前置：无（不联网，不依赖 NAS）
# 预期：checkLocal 发现插件目录内更新包 → applyLocalPackage 解压增量替换 → 本地版本变为测试版本
#       且源包被挪入 xread_update/ 留存；插件同级目录的包不再被扫描
CASE_ID="19_local_update"
source "$(dirname "$0")/../lib/common.sh"

VER="0.8.0-localtest"
DEPLOY_DIR="${DEPLOY%/}"                      # 插件目录（plugins/xread.koplugin/）
PKG_DIR="$(dirname "$DEPLOY")"               # 插件同级目录（plugins/，应不再被扫描）
PKG_NAME="xread.koplugin_v${VER}_20261125-170000.zip"
PKG_PATH="$DEPLOY_DIR/$PKG_NAME"             # v0.6.4 起：更新包固定放插件目录内

cleanup() {
    rm -f "$PKG_PATH" "$FAKE_PATH"
    emu_stop 2>/dev/null
    return 0
}
trap cleanup EXIT

case_begin "TC-19 本地包热更新（插件目录内）"

rm -f /root/.config/koreader/xread_update_manifest.json
rm -rf /root/.config/koreader/xread_update

# 构造本地更新包：取部署目录源码，版本改成测试版本，打成规范 zip 放插件目录内
STAGING=/tmp/xread_local_pkg_staging
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -r "$DEPLOY"/. "$STAGING/" || { fail "构造本地包失败"; case_finish; exit 1; }
sed -i "s/version = \".*\"/version = \"$VER\"/" "$STAGING/_meta.lua"

python3 - "$STAGING" "$PKG_PATH" <<'PY'
import hashlib, os, sys, zipfile
staging, pkg_path = sys.argv[1], sys.argv[2]
picks = ["_meta.lua", "main.lua", "xread/updater.lua"]
with zipfile.ZipFile(pkg_path, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in picks:
        z.write(os.path.join(staging, rel.replace("/", os.sep)), rel)
print("local test package:", pkg_path, os.path.getsize(pkg_path), "bytes",
      "md5", hashlib.md5(open(pkg_path, "rb").read()).hexdigest())
PY
rm -rf "$STAGING"

[ -f "$PKG_PATH" ] || { fail "本地包未生成: $PKG_PATH"; case_finish; exit 1; }

# 负向验证：同级目录放一个更高版本的包，v0.6.4 起不再被扫描
FAKE_NAME="xread.koplugin_v9.9.9-fake_20261125-170000.zip"
FAKE_PATH="$PKG_DIR/$FAKE_NAME"
cp "$PKG_PATH" "$FAKE_PATH"
sed -i "s/$VER/9.9.9-fake/" /dev/null 2>/dev/null # 占位；版本在包名里，包内 _meta 不改也不影响（包名版本仅用于挑最新）

emu_start "localupdate"
emu_wait_mark "mode=localupdate done" 120
assert_log_contains 'via=local' "走本地包模式"
assert_log_contains 'remote=0\.8\.0-localtest' "本地包版本识别"
assert_log_contains 'newer=true' "判定有新版本"
assert_log_contains 'local_version_now=0\.8\.0-localtest' "本地解压后版本已更新"
assert_no_fatal

# 留存结构：解压目录在 xread_update/，源包挪入同目录
PKG_STORE=/root/.config/koreader/xread_update
EXPECT_DIR="$PKG_STORE/${PKG_NAME%.zip}"
[ -d "$EXPECT_DIR" ] && log "  解压目录留存 OK: $EXPECT_DIR" || fail "未生成解压目录: $EXPECT_DIR"
[ -f "$PKG_STORE/$PKG_NAME" ] && log "  源包已挪入 xread_update 留存 OK" || fail "源包未挪入留存目录"
[ -f "$PKG_PATH" ] && fail "源包仍在插件目录内（应已挪走）" || log "  插件目录内已清理 OK"
# 同级目录的 9.9.9-fake 包必须未被识别（本地版本应停在 0.8.0-localtest）
grep -q "9\.9\.9-fake" "$EMU_LOG_DIR/$CASE_ID.emu.log" && fail "同级目录包被误扫描" || log "  同级目录不再被扫描 OK"

case_finish

# 还原部署目录（apply 把文件改成了测试版本）
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
emu_stop
