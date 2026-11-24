#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
publish_update.py — 生成 xread.koplugin 在线热更新包并发布到 NAS（飞牛 fpk 部署）

【发布目录（服务端）】
  /var/apps/xread/var/data/webdav/bingkuomiao/plugin/
    manifest2.json                                  # 指向规范 zip
    xread.koplugin_v<版本>_<YYYYMMDD-HHMMSS>.zip    # 规范命名的完整插件包（热更新用）

【插件端】GET /reader3/getWebdavFile?path=/plugin/<文件>&accessToken=<token>
  读 manifest2.json → 下载 zip → 校验 md5 → 解压覆盖插件目录（增量跳过同 md5 文件）

【命名规范】xread.koplugin_v<版本号>_<YYYYMMDD-HHMMSS>.zip
  例：xread.koplugin_v0.5.7_20261124-115500.zip

用法（在 xread-migration 目录下）：
    python3 publish_update.py                       # 源码 → 规范 zip + manifest2.json
    python3 publish_update.py --notes "修复xxx"     # 带更新说明
    python3 publish_update.py --zip <规范zip路径>   # 用已有 zip 发布
    python3 publish_update.py --ssh <用户>@<NAS地址> --ssh-port <端口>   # 生成并上传
    python3 publish_update.py --check               # 校验线上 manifest 与包内全部文件 md5

【凭据配置（不进版本库）】
    NAS 地址/账号/密码/发布目录从环境变量或本地 .publish_env 读取：
      XREAD_NAS_HOST / XREAD_NAS_USER / XREAD_NAS_PASS / XREAD_NAS_REMOTE_DIR
    .publish_env 已加入 .gitignore，格式见 .publish_env.example。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_SRC = os.path.join(HERE, "xread.koplugin")
PUBLISH_DIR = os.path.join(HERE, "publish")
PUBLISHED_PLUGIN = os.path.join(PUBLISH_DIR, "plugin")
REMOTE_KEEP_PACKAGES = 1     # 服务端只留当前规范包（manifest2 指向的那个），历史包自动清理
FILE_VERSION_RE = re.compile(r'version\s*=\s*["\']([^"\']+)["\']')
ZIP_NAME_RE = re.compile(r'xread[._-]?koplugin[_-]v?(\d+\.\d+\.\d+)[_-](\d{8})[_-]?(\d{4,6})', re.I)
EXCLUDE_EXT = (".xup_tmp",)


def load_env_file(path):
    """读本地 KEY=VALUE 配置（不进版本库），环境变量优先"""
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


_LOCAL_ENV = load_env_file(os.path.join(HERE, ".publish_env"))


def setting(name, default=""):
    return os.getenv(name) or _LOCAL_ENV.get(name) or default


REMOTE_DIR = setting("XREAD_NAS_REMOTE_DIR")
NAS_HOST = setting("XREAD_NAS_HOST")
NAS_USER = setting("XREAD_NAS_USER")
NAS_PASS = setting("XREAD_NAS_PASS")


def require_credentials():
    missing = [k for k, v in (("XREAD_NAS_HOST", NAS_HOST), ("XREAD_NAS_USER", NAS_USER),
                              ("XREAD_NAS_PASS", NAS_PASS), ("XREAD_NAS_REMOTE_DIR", REMOTE_DIR))
               if not v]
    if missing:
        raise SystemExit("缺少 NAS 凭据配置：" + ", ".join(missing)
                         + "（用环境变量或本地 .publish_env 提供，见 .publish_env.example）")


def read_version_from_text(text):
    m = FILE_VERSION_RE.search(text or "")
    return m.group(1) if m else None


def read_version(path=None):
    path = path or os.path.join(PLUGIN_SRC, "_meta.lua")
    with open(path, encoding="utf-8") as fh:
        return read_version_from_text(fh.read()) or "0.0.0"


def package_name(version, stamp=None):
    stamp = stamp or time.strftime("%Y%m%d-%H%M%S")
    return f"xread.koplugin_v{version}_{stamp}.zip"


def md5_bytes(data):
    return hashlib.md5(data).hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_plugin_files(root):
    """返回 [(绝对路径, zip内相对路径)]，路径均为插件根相对"""
    out = []
    for base, dirs, fs in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in sorted(fs):
            if f.endswith(EXCLUDE_EXT):
                continue
            p = os.path.join(base, f)
            out.append((p, os.path.relpath(p, root).replace(os.sep, "/")))
    out.sort(key=lambda x: x[1])
    return out


def build_zip_from_source(version):
    """源码 → 规范 zip（zip 根就是插件目录内容，便于热更新解压）"""
    name = package_name(version)
    path = os.path.join(PUBLISH_DIR, name)
    os.makedirs(PUBLISH_DIR, exist_ok=True)
    files = collect_plugin_files(PLUGIN_SRC)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for p, rel in files:
            z.write(p, rel)
    print(f"生成规范包: {path}（{len(files)} 文件，{os.path.getsize(path)} 字节）")
    return path, len(files)


def normalize_zip(zip_path):
    """已有 zip → 规范命名（支持安装格式 xread.koplugin/ 前缀与热更新格式）"""
    if not os.path.isfile(zip_path):
        raise SystemExit(f"zip 不存在: {zip_path}")
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        meta = next((n for n in names if n.endswith("/_meta.lua") or n == "_meta.lua"), None)
        if not meta:
            raise SystemExit("zip 内找不到 _meta.lua，无法识别版本")
        version = read_version_from_text(z.read(meta).decode("utf-8", "replace"))
        if not version:
            raise SystemExit("zip 内 _meta.lua 没有 version 字段")
    m = ZIP_NAME_RE.search(os.path.basename(zip_path))
    stamp = (m.group(2) + "-" + m.group(3)) if m else time.strftime("%Y%m%d-%H%M%S")
    name = package_name(version, stamp)
    target = os.path.join(PUBLISH_DIR, name)
    os.makedirs(PUBLISH_DIR, exist_ok=True)
    if os.path.abspath(zip_path) != os.path.abspath(target):
        shutil.copy2(zip_path, target)
    print(f"采用规范包: {target}（版本 {version}，{len(names)} 条目）")
    return target, version


def package_file_entries(zip_path):
    """读 zip 内文件清单：path/size/md5（供线上校验与客户端 files_count）"""
    entries = []
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            rel = info.filename.replace("\\", "/")
            if rel.startswith("xread.koplugin/"):
                rel = rel[len("xread.koplugin/"):]
            if rel.startswith("./") or ".." in rel.split("/"):
                continue
            data = z.read(info)
            entries.append({"path": rel, "size": len(data), "md5": md5_bytes(data)})
    entries.sort(key=lambda it: it["path"])
    return entries


def write_publish(zip_path, version, notes, files_count):
    """写 publish/plugin/：manifest2.json + zip（无散文件）"""
    # 整体重建发布目录，杜绝旧格式散文件/旧包残留被一起上传
    if os.path.isdir(PUBLISHED_PLUGIN):
        shutil.rmtree(PUBLISHED_PLUGIN)
    os.makedirs(PUBLISHED_PLUGIN, exist_ok=True)
    shutil.copy2(zip_path, os.path.join(PUBLISHED_PLUGIN, os.path.basename(zip_path)))

    file_entries = package_file_entries(zip_path)
    blob = open(zip_path, "rb").read()
    stamp = ZIP_NAME_RE.search(os.path.basename(zip_path))
    build_stamp = (stamp.group(2) + stamp.group(3)) if stamp else time.strftime("%Y%m%d%H%M%S")
    manifest_new = {
        "version": version,
        "build": build_stamp,
        "notes": notes or "",
        "package": os.path.basename(zip_path),
        "package_size": len(blob),
        "package_md5": md5_bytes(blob),
        "files_count": len(file_entries),
        "files": file_entries,
    }
    with open(os.path.join(PUBLISHED_PLUGIN, "manifest2.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest_new, fh, ensure_ascii=False, indent=1)
    print(f"更新目录: {PUBLISHED_PLUGIN}")
    print(f"  manifest2.json → {manifest_new['package']}（md5 {manifest_new['package_md5']}）")
    return manifest_new


def upload(ssh_target, ssh_port):
    """fnOS 禁 scp，用 tar over ssh 流式上传"""
    if not os.path.isdir(PUBLISHED_PLUGIN):
        raise SystemExit("请先生成发布目录")
    cmd = (f'tar cf - -C "{PUBLISHED_PLUGIN}" . | '
           f'ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_target} '
           f'"mkdir -p {REMOTE_DIR} && '
           f'find {REMOTE_DIR} -mindepth 1 -maxdepth 1 ! -name manifest2.json '
           f'! -name \'xread.koplugin_v*.zip\' -exec rm -rf {{}} + && '
           f'tar xf - -C {REMOTE_DIR} && '
           f'chown -R docker-xread:docker-xread {REMOTE_DIR} && echo UPLOAD_OK"')
    print("上传:", cmd)
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        raise SystemExit(f"上传失败（exit {rc}）")
    cleanup_remote(ssh_target, ssh_port)
    check_online(ssh_target.split("@")[-1])


def cleanup_remote(ssh_target, ssh_port):
    """服务端只保留当前规范包，历史包自动清理（同名同版本多次发布会堆积，事后分不清）"""
    remote = (f'cd {REMOTE_DIR} && ls -1t xread.koplugin_v*.zip 2>/dev/null '
              f'| tail -n +{REMOTE_KEEP_PACKAGES + 1} | xargs -r rm -f')
    cmd = f'ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_target} "{remote}"'
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        print("  （服务端旧包清理跳过）")
        return
    list_cmd = (f'ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_target} '
                f'"cd {REMOTE_DIR} && ls -1 xread.koplugin_v*.zip 2>/dev/null"')
    kept = subprocess.run(list_cmd, shell=True, capture_output=True, text=True).stdout.strip()
    if kept:
        print(f"服务端保留包: {', '.join(kept.splitlines())}")


def check_online(host):
    """登录后端，经 getWebdavFile 校验线上 manifest2.json 与规范 zip 包"""
    import urllib.parse
    import urllib.request

    def post(url, obj):
        req = urllib.request.Request(url, data=json.dumps(obj).encode(),
                                     headers={"Content-Type": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=15).read())

    def fetch(path, token):
        q = urllib.parse.quote(path)
        url = (f"http://{host}:7777/reader3/getWebdavFile?path={q}"
               f"&accessToken={urllib.parse.quote(token)}")
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()

    try:
        require_credentials()
        login = post(f"http://{host}:7777/reader3/login",
                     {"isLogin": True, "username": NAS_USER, "password": NAS_PASS, "code": ""})
        token = login["data"]["accessToken"]
        raw = fetch("/plugin/manifest2.json", token)
        m = json.loads(raw.decode("utf-8"))
    except Exception as e:
        print(f"线上 manifest2.json 不可用: {e}")
        print(f"请把 {PUBLISHED_PLUGIN} 的全部内容上传到 NAS 的 {REMOTE_DIR}/")
        sys.exit(1)

    print(f"线上清单: v{m.get('version')} build={m.get('build')} "
          f"包={m.get('package')}（{m.get('package_size')} 字节）")
    bad = 0
    blob = fetch("/plugin/" + m["package"], token)
    if len(blob) != m["package_size"] or md5_bytes(blob) != m["package_md5"]:
        print(f"  校验不符: {m['package']}")
        bad += 1
    else:
        # 逐文件核对包内条目（读 zip 内存，不再逐个请求散文件）
        import io
        with zipfile.ZipFile(io.BytesIO(blob)) as z:
            entries = {i.filename.replace("\\", "/"): z.read(i)
                       for i in z.infolist() if not i.is_dir()}
        for it in m.get("files", []):
            data = entries.get(it["path"])
            if data is None or len(data) != it["size"] or md5_bytes(data) != it["md5"]:
                print(f"  包内条目校验不符: {it['path']}")
                bad += 1
    if bad:
        print(f"\n{bad} 项异常，请重新上传")
        sys.exit(1)
    print(f"\n规范 zip + 包内 {len(m.get('files', []))} 个文件校验通过，插件端可直接检查更新")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notes", default="", help="更新说明")
    ap.add_argument("--zip", default=None, help="用已有 zip 发布（自动识别版本并规范命名）")
    ap.add_argument("--ssh", default=None, help="NAS ssh 目标，如 root@<NAS地址>")
    ap.add_argument("--ssh-port", type=int, default=2233)
    ap.add_argument("--check", action="store_true", help="只校验线上 manifest")
    args = ap.parse_args()

    if args.check:
        check_online(NAS_HOST)
        return

    if args.zip:
        zip_path, version = normalize_zip(args.zip)
        count = len(zipfile.ZipFile(zip_path).namelist())
    else:
        version = read_version()
        zip_path, count = build_zip_from_source(version)
    write_publish(zip_path, version, args.notes, count)

    if args.ssh:
        upload(args.ssh, args.ssh_port)
    else:
        print("\n未配置 --ssh，手动上传方式：")
        print(f"  将 {PUBLISHED_PLUGIN} 的全部内容拷到 NAS 的 {REMOTE_DIR}/")
        print("  或用: python3 publish_update.py --ssh root@<NAS地址> --ssh-port <端口>")
        print(f"  上传后执行: python3 publish_update.py --check")


if __name__ == "__main__":
    main()
