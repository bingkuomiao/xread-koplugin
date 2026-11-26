# xread.koplugin 进度同步机制 与 WSL2 模拟测试指南

> 更新：2026-11-25 · 配套版本 **v0.6.1**（110 文件，规范包 `xread.koplugin_v0.6.1_<时间>.zip`）
> 用途：① 说明正文阅读中进度同步的实现方案；② 在另一台有 WSL2 的机器上从零搭起模拟测试环境；③ 规范 zip 热更新流程。
> 一键脚本见 `wsl-setup/quickstart.sh` 与 `koplugin一键测试.bat`（放资料库 koplugin 文件夹的测试包内）。

---

## 一、正文里的进度同步是怎么解决的

进度体系只有**章级整数索引**（0 基），存在后端 reader3（书架条目的 `durChapterIndex` 字段）；章内页码则由 KOReader 本地按 .html 文件自行保存（sidecar），两端各管一段，互不干扰。

### 1. 读进度（打开时定位）

- 每次进书架 / 首页 / 目录，都调 `client:getBookshelf()` 拉后端最新书架；
- 打开位置统一由 `openAtChapter(book, chapters, durChapterIndex + 1)` 决定（main.lua :798 / :2104 / :3037）；
- 目录页"当前章"高亮、首页 hero 卡（取 `durChapterIndex` 最大的书）也全部以这个字段为唯一事实来源；
- `getBookshelf(refresh=1)` 带刷新参数可绕过本地 meta_cache（TTL 300s）强制拉后端，配合换书 / 手动刷新使用。

### 2. 写进度（打开正文后上报）

- `openAtChapter` 拼好正文 HTML、确定打开章后，**异步**上报：
  `UIManager:scheduleIn(0.5, function() pcall(self.client:saveBookProgress(book, index - 1)) end)`（main.lua :2209-2214）
  - 延迟 0.5s：不阻塞开书首屏；
  - pcall 包裹：后端挂了 / 网络断了只失败，绝不弹错、不崩书；
  - 接口为 `POST /reader3/saveBookProgress`，参数 `url + index(0基) + name + author`（client.lua :232）。
- 手动兜底：工具栏「同步进度」按钮 → `syncProgress()`（main.lua :3057），立刻按当前章上报一次。

### 3. 关键坑：后台预缓存不写进度

后台静默缓存会往后多抓几十章，但 **`stopBg` 明确不写进度**（main.lua :2293 注释）：

> 进度只按"用户实际打开的章"保存（openAtChapter 里写过一次），这里不能写 end_index，否则只是后台多缓存了几章，进度就会被推到很后面。

这是"缓存了很多章但进度不走"的正确行为，不是 bug。

### 4. 换源时的进度保留

- 后端 `saveBook` 按"同名同作者"替换书架条目，**保留 durChapterIndex**；
- 插件侧 `switchBookSource` 再按当前章标题在新目录里对位，写回新 `durChapterIndex = new_index - 1` 后重开正文。

### 5. 章内页码（本地）

- KOReader 对打开过的 `.html` 文件把页码存本地 sidecar（`settings/`、`history.lua`）；
- 换设备后章内页码回到章首，但**章级进度不丢**——下次打开会按服务器 `durChapterIndex` 重新定位。

---

## 二、WSL2 机器从零搭建模拟测试

### 前提

Windows 10/11，WSL2 正常（有 VT-x 的机器 `wsl --install` 即可，本包原来那台 B950 无 VT-x 才被迫用 WSL1，WSL2 机器无此限制）。

### 第 1 步：装 Ubuntu 发行版

```powershell
# 方式 A（推荐，联网安装）
wsl --install -d Ubuntu

# 方式 B（离线导入，rootfs 包 326MB，从原机 D:\WorkBuddy\2026-11-22-00-23-49\wsl-setup\ubuntu22.04-rootfs.tar.gz 拷贝）
wsl --import Ubuntu D:\WSL\Ubuntu <路径>\ubuntu22.04-rootfs.tar.gz
wsl -d Ubuntu -u root   # rootfs 导入默认 root 登录；wsl --install 装的是普通用户，命令里去掉 -u root 亦可
```

### 第 2 步：装 KOReader 模拟器

- 模拟器整包：**koreader.tar.xz（29MB，已随本指南上传资料库）**；
- 放到 WSL 可访问的位置（如 /mnt/d/...），执行：

```bash
apt update && apt install -y xdotool imagemagick xvfb x11-utils
mkdir -p /opt/koreader
tar -xJf /mnt/d/<路径>/koreader.tar.xz -C /opt/koreader
ls /opt/koreader   # 应看到 bin/ lib/ share/
```

### 第 3 步：部署插件与测试包

上传到资料库 koplugin 文件夹的 **koplugin-test-kit.zip** 解压后包含：

```
koplugin-test-kit.zip
├── xread.koplugin/                          # 最新源码 v0.6.1（110 文件）
├── xread.koplugin.zip                       # 可直接装真机的插件包
├── publish/xread.koplugin_v0.6.1_*.zip      # 规范命名热更新包
├── publish_update.py                        # 一键发布脚本（生成清单+打包+上传+校验+清理旧包）
├── KOPlugin热更新发布说明.md                # 热更新发布流程（含设备端包留档规则）
├── release.sh                               # 发布出包 + 17 项自动测试
├── tests/                                   # 自动测试用例（TC-01~17）
└── wsl-setup/                               # quickstart.sh / webdav_e2e.sh（真实 NAS 端到端）
```

放到 Windows 下任意目录（如 `D:\koplugin\`），即可在 WSL 内通过 `/mnt/d/koplugin/...` 访问；路径不再硬编码。

```bash
# 部署插件到模拟器
cp -r <解压目录>/xread.koplugin /opt/koreader/lib/koreader/plugins/xread.koplugin
```

**一键自动执行**（Windows PowerShell / Git Bash，把路径改成你的解压目录）：

```powershell
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/wsl-setup/quickstart.sh'
```

脚本依次完成：安装依赖（xdotool/imagemagick/xvfb）→ 校验 KOReader 模拟器 → 写登录凭据 → 部署最新插件 → 跑全套自动回归 → 打印报告路径与 PASS/FAIL 汇总。人工实时操作另用 `manual_test.sh`（浏览器 noVNC）。

### 第 4 步：登录凭据

首次启动进插件设置填：
- 后端地址：`http://192.168.31.51:7777`（须与后端同一局域网）
- 账号：填你自己的后端账号密码（不要用公开示例里的账号）

也可直接写配置文件一步到位：

```bash
mkdir -p ~/.config/koreader/settings
cat > ~/.config/koreader/settings/xread.lua <<'EOF'
return {
    base = "http://<你的后端地址>:7777",
    username = "<你的账号>",
    password = "<你的密码>",
}
EOF
```

### 第 5 步：人工测试（浏览器实时操作）

```powershell
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/<解压目录>/wsl-setup/manual_test.sh'
```

- 终端窗口保持打开，浏览器访问 `http://localhost:6080/vnc.html`；
- 默认直达 miuread 首页；`XREAD_START=shelf|none` 换起点（详见包内 MANUAL_TEST.md）；
- WSL2 若 localhost:6080 连不上（NAT 端口问题）：临时用 WSL IP（`wsl hostname -I`）访问，或在 `%UserProfile%\.wslconfig` 加 `networkingMode=mirrored` 后 `wsl --shutdown` 重启。

### 第 6 步：自动测试 / 发布

```powershell
# 一键（装依赖+部署+回归）
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/wsl-setup/quickstart.sh'

# 发布出包 + 全套 17 项自动测试（大改动后必跑，全 PASS 才交付）
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/release.sh'

# 只验证不重新打包 / 指定用例
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh'
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh --only 12_update_zip 16_filelist_latest 13_package_retention 17_cover_api'

# 真实 NAS 端到端热更新（先上传到服务端；参数=把本地降级到的版本）
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/wsl-setup/webdav_e2e.sh 0.5.9'
```

报告（含截图）在 `tests/reports/<时间戳>/SUMMARY.md`；改代码后重跑启动命令即自动同步源码。
- TC-12 = 列目录模式 zip 热更新全流程（filelist.json + zip + md5 sidecar，含同名解压目录校验）；
- TC-16 = 列目录挑最新（filelist.json 放两个包：高版本 / 时间戳更新的低版本，验证按语义版本挑中高版本、不误装旧包、包内版本裁决）；
- TC-13 = 包留存策略（设备端只保留最近 3 次）；
- TC-17 = 统一封面接口纯 Lua 单测（LuaJIT + mock socket.http，不依赖模拟器/NAS）：验证 `path=<customCoverUrl||coverUrl 原值>`、统一带 accessToken/secureKey/userNS、未登录网络书 URL 正确、Referer 为合法 header、本地书 401 重登重试。
前三者用本地 http.server 模拟，只有 `webdav_e2e.sh` 需连真实 NAS。旧散文件更新用例（原 TC-11）已随老版本兼容代码一并移除。

> 热更新现为纯列目录模式：列 `/plugin` 目录（webdav `getWebdavFileList` / raw `filelist.json`）按包名语义版本挑最新 zip，无 manifest 清单、无回退。发布端 `publish_update.py` 生成 filelist.json + 同名 `.md5` sidecar，服务端保留最近 3 个包。详见 `KOPlugin热更新发布说明.md`。

### 第 7 步：真机触摸全流程 / 全按钮遍历（TC-14~15）

这几个用例**不靠 autotest 钩子直达**，而是从文件管理器用真实触摸一步步走，截图覆盖每个弹窗/新页面。都已在 `tests/cases/` 中，可单独重跑：

```powershell
# 全流程：阅读X → 书架 → 开小说 → 正文 → 目录 → 跳章 → 正文阅读 → 返回书架 → 返回首页（13 步截图）
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh --only 14_full_flow_touch'
# 首页所有可点击按钮（每个按钮独立会话，互不干扰）
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh --only 15a_home_buttons'
# 阅读工具栏所有按钮
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh --only 15b_toolbar_buttons'
# 首页「更多」页所有菜单项
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/koplugin/tests/run_all.sh --only 15c_more_menu'
```

**真机触摸关键坐标**（Xvfb 屏幕 1072×1448，与截图一致）：

| 界面 | 元素 | 坐标 (x,y) |
| --- | --- | --- |
| （引导）| v0.6.1 起原生菜单无阅读X入口，全流程用 `emu_start "shelf"` 直开书架引导，不再点主菜单 | — |
| 首页顶部 | 阅读X / 昵称 / Wi-Fi / 已连接 / 更多≡ | 75 / 280 / 360 / 490 / 1005，y≈45 |
| 首页功能区 | 更新 / 搜索 / 同步 / 夜晚 / 设置 | x≈90/245/400/555/710，y≈680 |
| 首页 hero | 历史 / 本地阅读 | 455,140 / 595,290 |
| 首页书架 | 书籍封面（第一行）/ 下一页 | y≈930 / 985,1410 |
| 阅读工具栏 | 目录 / 缓存 / 删除 / 书架 | 148/400/652/906，y=330 |
| 阅读工具栏 | 夜间 / 刷新 / 切换 / 设置 | 148/400/652/906，y=560 |
| 目录页 | 章节条目 / 返回 / 上一页 / 下一页 | 列表区 x>260 / 75,1285 / 210,1385 / 800,1385 |

**用例设计要点 / 已踩坑**：

1. 弹窗关闭用 `xdotool key Escape`（搜索框等输入类弹窗 Escape 可能无效，需点「取消」）。批量点击同一界面时，若弹窗未关干净会导致后续点击全落空——**TC-15a~15c 采用「每个按钮独立 emu_start」规避**，慢但可靠。
2. 开书后正文中央点击呼出工具栏；**跳章（switchDocument）会重建触摸分区并清空 `SHARED.txt_path`，导致跳章后点中央没反应**。已在 `onReaderReady()` 中补 `setupCenterTap()` 并在文档就绪时恢复 `SHARED.txt_path = doc.file` 修复（TC-14 第 11 步已覆盖该回归）。
3. 漫画书（`.cbz`，如「灵世英雄」）目录/跳章行为与小说不同；全流程用小说「三国之宅行天下」跑，保证目录→跳章→正文链路可测。
4. 截图命名：`step_`=全流程、`btn_`=首页按钮、`toolbtn_`=工具栏按钮、`menu_`=更多页菜单；归档到 `tests/reports/ui_test_screenshots/` 并上传到资料库 `test` 文件夹（文件名前缀 `test_`）。

---

## 三、WSL1 → WSL2 差异与注意点

| 项 | WSL1（原开发机） | WSL2（新机） |
| --- | --- | --- |
| GUI | 无 WSLg，必须 Xvfb + noVNC | Win11 有 WSLg 可直接弹窗看，但**建议仍走 Xvfb+noVNC**（分辨率锁定 1072×1448 与真机一致，截图脚本全兼容） |
| 网络 | 与 Windows 共享 localhost，端口互通 | 默认 NAT，出站可达 192.168.31.51；入站（6080）可能要 mirrored 模式或用 WSL IP |
| 稳定性 | 偶发 SIGKILL（重跑即可） | 无此问题 |
| 性能 | 开书首屏较慢 | 更快，crengine 首屏 ~8s 的等待可适当缩短 |
| 已踩的坑 | `pkill Xvfb` 后必须 `rm /tmp/.X99-lock`；重启前 `rm -f /root/.config/koreader/history.lua /tmp/xread_autotest_once` | 同样适用（脚本已内置处理） |
| WSL 命令 | `wsl.exe -d Ubuntu -u root -e bash -lc '...'` 必须单引号包路径（Git Bash 会转义 /mnt/d） | 同样适用 |

## 四、常用命令速查

```bash
# 语法快检（部署后单文件）
cd /opt/koreader && ./lib/koreader/luajit -e "local f,e=loadfile('lib/koreader/plugins/xread.koplugin/main.lua'); print(f and 'OK' or e)"

# 手动截图（Xvfb 会话内）
DISPLAY=:99 import -window root /mnt/d/<路径>/manual_shot.png

# 指定用例（用 tests/cases/ 下的文件名，不要带 .sh）
bash tests/run_all.sh --only 02_reading_open 12_update_zip

# 校验服务端热更新包
python3 publish_update.py --check

# 页面截图 14 张（flow=more 等子页）上传资料库用
bash wsl-setup/capture_pages.sh
```
