#!/bin/bash
# 发布出包：重打包 zip -> 跑全套自动测试 -> 全 PASS 才交付
# 每次大改动后执行本脚本（在 WSL Ubuntu 内）：
#   wsl.exe -d Ubuntu -u root -e bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/release.sh
# 若只想验证不改包：bash tests/run_all.sh

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR" || exit 1

echo "== [1/2] repack zip =="
python3 - <<'PY'
import zipfile, os
src = 'xread.koplugin'
out = 'xread.koplugin.zip'
files = []
for root, dirs, fs in os.walk(src):
    for f in fs:
        p = os.path.join(root, f)
        files.append((p, os.path.relpath(p, src).replace(os.sep, '/')))
files.sort(key=lambda x: x[1])
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for p, rel in files:
        z.write(p, rel)
print(f'packed {len(files)} files, {os.path.getsize(out)} bytes')
PY

# 同步源码到模拟器部署目录（测试与三方一致性都基于最新源码）
DEPLOY=/opt/koreader/lib/koreader/plugins/xread.koplugin
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
echo "deployed to $DEPLOY"

echo "== [2/2] full auto tests =="
bash "$ROOT_DIR/tests/run_all.sh"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "== RELEASE OK: $ROOT_DIR/xread.koplugin.zip =="

    # 生成在线热更新发布包（publish/plugin/：manifest2.json + 规范 zip）
    # 上传到 NAS：python3 publish_update.py --ssh <用户>@192.168.31.51 --ssh-port <端口>
    #   或手动把 publish/plugin/ 内容拷到 NAS 的 /var/apps/xread/var/data/assets/plugin/
    echo "== [3/3] build online-update publish package =="
    python3 "$ROOT_DIR/publish_update.py" || true
else
    echo "== RELEASE BLOCKED: tests failed =="
fi
exit "$RC"
