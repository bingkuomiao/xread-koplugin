#!/usr/bin/env python3
"""打包 WSL2 模拟测试资料包（koplugin-test-kit-v<版本>.zip）

内容：插件源码 + 真机安装包 + 规范热更新包 + 发布脚本 + 两份文档 + tests/ + wsl-setup/
用法：python3 make_test_kit.py
产物：dist/koplugin-test-kit-v<版本>.zip
"""

import os
import re
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")

# 目录/文件 -> zip 内路径前缀（None 表示按原相对路径）
INCLUDE_DIRS = ["xread.koplugin", "tests", "wsl-setup"]
INCLUDE_FILES = [
    "xread.koplugin.zip",
    "publish_update.py",
    "make_test_kit.py",
    "release.sh",
    "KOPlugin热更新发布说明.md",
    "WSL2模拟测试指南.md",
]

SKIP_DIRS = {"__pycache__", "reports", ".git"}
SKIP_EXT = {".pyc"}


def plugin_version():
    with open(os.path.join(ROOT, "xread.koplugin", "_meta.lua"), encoding="utf-8") as fh:
        m = re.search(r'version\s*=\s*"([^"]+)"', fh.read())
    if not m:
        raise SystemExit("无法从 _meta.lua 读取版本号")
    return m.group(1)


def latest_publish_zip():
    pdir = os.path.join(ROOT, "publish")
    if not os.path.isdir(pdir):
        return []
    zips = [f for f in os.listdir(pdir) if f.startswith("xread.koplugin_v") and f.endswith(".zip")]
    zips.sort(key=lambda f: os.path.getmtime(os.path.join(pdir, f)), reverse=True)
    return [os.path.join(pdir, f) for f in zips[:1]]


def add_file(zf, path, arcname):
    if os.path.splitext(path)[1] in SKIP_EXT:
        return 0
    zf.write(path, arcname)
    return 1


def main():
    ver = plugin_version()
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"koplugin-test-kit-v{ver}.zip")
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for d in INCLUDE_DIRS:
            base = os.path.join(ROOT, d)
            if not os.path.isdir(base):
                continue
            for root, dirs, files in os.walk(base):
                dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
                for f in files:
                    p = os.path.join(root, f)
                    arc = os.path.relpath(p, ROOT).replace(os.sep, "/")
                    count += add_file(zf, p, arc)
        for f in INCLUDE_FILES:
            p = os.path.join(ROOT, f)
            if os.path.isfile(p):
                count += add_file(zf, p, f)
        # 规范热更新包（发布用的那个）
        for p in latest_publish_zip():
            count += add_file(zf, p, "publish/" + os.path.basename(p))
        # 清单，便于对照服务端结构
        p = os.path.join(ROOT, "publish", "plugin", "manifest2.json")
        if os.path.isfile(p):
            count += add_file(zf, p, "publish/plugin/manifest2.json")
    print(f"打包完成: {out}（{count} 文件，{os.path.getsize(out)} 字节，版本 v{ver}）")


if __name__ == "__main__":
    main()
