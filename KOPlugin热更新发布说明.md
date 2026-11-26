# xread.koplugin 热更新发布说明（纯列目录挑最新）

> 适用：飞牛 fpk 后端 + KOReader 阅读X插件。最后更新：2026-11-25
> 目标：**把规范命名的 zip 包放进服务端 plugin 目录，真机「关于本机 → 检查更新」即自动挑最新版本安装；手动放包与 `publish_update.py` 发布完全兼容。没有 manifest 清单，目录里的包本身就是唯一事实来源。**

---

## 一、服务端目录与文件

NAS（飞牛应用）上的 WebDAV 用户目录（真实路径由 `XREAD_NAS_REMOTE_DIR` 指定）：

```
/vol1/@appdata/xread/data/webdav/<用户名>/plugin/
├── xread.koplugin_v<版本>_<时间戳>.tar.gz           ← 规范命名的完整插件包（唯一更新入口，0.6.7 起默认格式）
├── xread.koplugin_v<版本>_<时间戳>.tar.gz.md5       ← 同名 md5 sidecar（强校验，发布脚本自动带）
├── xread.koplugin_v<旧版本>_<旧时间戳>.tar.gz        ← 保留的历史包（供按版本挑最新，最多 3 个；.zip/.tgz 同样兼容）
├── filelist.json                                   ← 目录索引（仅 raw 模式/静态托管用，webdav 模式不读）
└── ...
```

> **服务端保留最近 3 个规范包**（`REMOTE_KEEP_PACKAGES=3`）：插件列目录后按包名语义版本挑最新，历史包留着不影响判断，还便于人工回退。更早的包由 `publish_update.py` 自动清理。设备端历次包单独留档，见第四节。
> **没有 `manifest2.json`**——包名里的版本 + 包内 `_meta.lua` 就是全部依据，不需要任何清单文件。

两种取包方式（都带鉴权，token 失效 401/403 自动重登一次，不依赖后端版本）：

```
列目录：GET /reader3/getWebdavFileList?path=/plugin&accessToken=<token>
下  载：GET /reader3/getWebdavFile?path=/plugin/<文件>&accessToken=<token>
```

- **唯一流程**：`check()` 列目录 → 过滤出文件名含语义版本的 `xread.koplugin_v*.tar.gz`（兼容 `.zip`/`.tgz`） → 按包名语义版本（相同则 `lastModified`）挑最新 → 下载 → size/md5 校验 → 包内 `_meta.lua` 版本为最终裁决（绝不装旧包/同版本包）。**用户只要把新包丢进目录即可，无需维护清单。**
- 列目录失败（未开 WebDAV / 安全模式关闭 / 路径不存在）会明确报错提示，不再有静默回退；下载整包后按文件级 md5 增量替换（`ffi/archiver` 基于 libarchive，zip/tar.gz/tgz 同一解包接口）。

## 二、压缩包命名规范

```
xread.koplugin_v<版本号>_<YYYYMMDD-HHMMSS>.tar.gz
例：xread.koplugin_v1.0.0_20261125-120000.tar.gz
（`.zip` / `.tgz` 同样识别，插件端按 libarchive 统一解包）
```

- 插件名：`xread.koplugin`
- 版本号：与插件 `_meta.lua` 的 `version` 一致
- 时间：打包时刻（24 小时制），保证唯一、可追溯
- zip 内部根就是插件目录内容（`main.lua`、`_meta.lua`、`xread/…`），解压后直接覆盖插件根目录

## 三、每次发新版本怎么做

### 方式 A：手动放包（最简单，推荐给"别人打好包"的场景）

1. 拿到规范命名的包：`xread.koplugin_v<版本>_<时间戳>.tar.gz`（或 `.zip`/`.tgz`；版本号必须高于线上，且**文件名版本要与包内 `_meta.lua` 的 version 一致**——文件名版本用于“挑最新”，包内版本用于“最终裁决”）。
2. 用任意 WebDAV 客户端把它上传进服务端 `plugin/` 目录（可选：同时上传同名 `.md5` sidecar 做强校验）。
3. 完事——真机检查更新会自动列目录挑到这个最新版本。无需改任何清单、无需跑脚本。

> 只要文件名里的版本号最高，哪怕它的 `lastModified` 不是最新，也会被挑中；反之若一个包时间戳最新但版本更低，不会被误装。

### 方式 B：publish_update.py 一键发布

1. 改代码后升版本号：编辑 `xread.koplugin/_meta.lua` 的 `version = "0.6.1",`（必须比线上大）。
2. 在有 Python3 + ssh 的电脑上（项目根目录）执行：

```bash
# 源码打包（默认 tar.gz；--format zip / tgz 可选）+ md5 sidecar + 目录索引 + 上传 NAS + 线上校验
python3 publish_update.py --notes "本次更新说明" --ssh root@192.168.31.51 --ssh-port 2233
# 已有规范包时直接发布：
python3 publish_update.py --zip xread.koplugin_v0.6.7_20261125-214505.tar.gz \
    --ssh root@192.168.31.51 --ssh-port 2233
```

脚本自动：识别包内版本 → 规范命名 → 生成 `<包名>.md5`（强校验）与 `filelist.json`（raw/静态托管索引）→ tar.gz 字节流经 ssh 上传（fnOS 禁用 scp；**不用 shell 管道**，避免 Windows 下二进制流传输出问题）→ 保留最近 3 个包、清理更旧的 → 设置属主 `docker-xread` → 线上校验（列目录挑中包 + size/md5 + 包内版本一致性）。**不生成 manifest2.json。**

### 3. 真机点击更新

KOReader → 顶部菜单「工具 → 阅读X · 更多 → 关于本机 → 检查更新」→ 确认 → 自动下载并应用 → 重启生效。
（书架/首页显示后也会静默检查，发现新版仅提示一次，不打扰。）

## 四、插件端热更新流程

```
检查更新
  └─ GET getWebdavFileList?path=/plugin（raw 模式为 <root>filelist.json）
       ├─ 过滤出文件名含语义版本的 xread.koplugin_v*.tar.gz（兼容 .zip/.tgz）
       ├─ 按包名语义版本排序（相同则 lastModified），挑最新 → via=list
       ├─ 语义版本号比较：远端 > 本地？（否则提示已是最新）
       └─ 失败或无候选 → 明确报错（无清单回退路径）
                 ↓ 确认更新
        下载规范包（一次请求，tar.gz/zip/tgz 自适应）
          ├─ 校验 size + md5（md5 取 <包名>.md5 sidecar）
          ├─ 用 KOReader 自带 ffi/archiver 解压（不依赖外部 unzip）
          ├─ 落到 <数据目录>/xread_update/<包名>/（与压缩包同名同级）
          ├─ 逐文件 md5 与本地比对：相同跳过，不同写 .xup_tmp 后原子替换
          ├─ 版本裁决：包内 _meta.lua 版本须高于本地、且与文件名版本一致，
          │            否则整包拒绝（绝不装旧包/错包）
          └─ 全部成功才完成安装；失败保留已下载包与解压目录，下次重试
```

- 增量：虽然下载的是一个整包（当前约 190KB），但**只写变化的文件**，不重复写入 100 多个相同文件；
- 安全：路径校验禁 `..` 与隐藏文件；md5 不符不替换；绝不回退安装旧版本；
- 无弹窗静默检查在插件启动时进行，交互入口在「关于本机」。

### 更新包在设备上的落盘位置

每次更新的压缩包与解压目录都**按包名单独留档**，同级存放，多次更新不会互相覆盖、事后能分辨是哪一版：

```
<KOReader 数据目录>/xread_update/
├── packages.txt                                  ← 已安装包名索引（按时间先后，只留最近 3 条）
├── xread.koplugin_v<版本>_<时间戳>.tar.gz          ← 下载到的原始压缩包（zip/tgz 同）
└── xread.koplugin_v<版本>_<时间戳>/                ← 与压缩包同名、同级的解压目录（完整 110 文件）
    ├── _meta.lua
    ├── main.lua
    └── xread/…
```

- 目录名 = 压缩包名去掉扩展名（`.tar.gz`/`.zip`/`.tgz`），两者**同级**；想确认某次更新装了什么，直接进对应目录看即可；
- 只为最近 **3 次**更新留档（含压缩包与解压目录），更早的自动清理，避免占满设备存储；
- 更新失败时**压缩包与解压目录都保留**（不写本地清单，下次重试），便于排查；
- 更新完成的提示只显示变更/跳过文件数与「正在重启 KOReader…」，不再在提示里显示留存目录（目录仍按上述规则保留，可进 `xread_update/` 查看）。

## 五、当前方案与验证

**当前方案（唯一，无历史兼容路径）**
- 更新入口只有服务端 `plugin/` 目录里的规范包：`xread.koplugin_v<版本>_<时间戳>.tar.gz`（`.zip`/`.tgz` 同样识别），放包即发布；
- 插件列目录（webdav `getWebdavFileList` / raw `filelist.json`）按包名语义版本挑最新（支持 `-test` 等后缀），不按上传时间；
- 下载后校验 size + 同名 `.md5` sidecar，以包内 `_meta.lua` 版本做最终裁决（须高于本地且与文件名一致），文件级 md5 增量替换；
- 发布端 `publish_update.py` 只产规范包（**v0.6.7 起默认 tar.gz**，`--format zip/tgz` 可选）+ `.md5` sidecar + `filelist.json`，服务端保留最近 3 个包；无 manifest 清单、无回退、无旧散文件升级路径。

**包格式与本地更新（v0.6.2 / v0.6.4 起）**
- 包格式：`zip` / `tar.gz` / `tgz` 三种均可（KOReader ffi/archiver 基于 libarchive，自动识别）；
- 本地更新（不联网）：把规范命名的更新包（`xread.koplugin_v<版本>_<时间>.zip|.tar.gz|.tgz`）放到**插件目录内**（v0.6.4 起不再扫描同级目录），再点「更多 → 关于本机 → 检查更新」：**先从服务端列目录检查，服务端不可用或无更高版本时才安装本地包**；安装后源包挪入 `xread_update/` 留存。

**真机端到端验证（2026-11-25，真实 NAS）**
- 上传单个规范包并清理旧包后，`python3 publish_update.py --check` 列目录挑中该包、size/md5/包内版本一致；
- 模拟器本地降级到 v0.5.9 → 走 `getWebdavFileList` 列目录 → 识别远端 v0.6.0 → 下载 110 文件 → 增量应用（changed=1、skipped=109）→ 本地升到 v0.6.0；
- main.lua / updater.lua 等文件 md5 与源码一致，同名 zip 与解压目录落盘、110 文件、包索引齐全；`webdav_e2e.sh` 结果 **PASS**。

**v0.6.1 发布（2026-11-25）**
- 移除 KOReader 原生菜单全部「阅读X」注入（`registerToMainMenu`、`addToMainMenu`、菜单排序钩子一并删除），原生菜单恢复纯净；
- 已打包上传 `xread.koplugin_v0.6.1_20261125-154535.zip`（110 文件，md5 `9fccaa46…`），线上 `--check` 校验通过，包内版本与文件名一致。

**v0.6.2 / v0.6.3 发布（2026-11-25）**
- v0.6.2：更新包支持 tar.gz/tgz 格式（zip/tar.gz/tgz 通用），TC-18 实测 PASS；
- v0.6.3：新增本地更新包（规范命名即可被「检查更新」安装，无需联网），TC-19 实测 PASS；
- 线上已发布 `xread.koplugin_v0.6.3_20261125-170752.zip`（110 文件，md5 `4ffef28d…`），`--check` 校验通过。

**v0.6.4 发布（2026-11-25）**
- 恢复原生菜单「阅读X」入口（用户决定加回）：`addToMainMenu` + `registerToMainMenu` + 排序钩子（排在微信读书之后；微信读书未装时置顶），子菜单与之前一致（我的首页/我的书架/地址管理/账号管理/测试连接/关于本机）；
- 本地更新包固定放**插件目录内**（不再扫描同级目录）；检查更新顺序改为**先远端后本地**；
- TC-19 重写（插件目录内放包 + 同级目录负向验证）实测 PASS；模拟器冒烟验证菜单入口与子菜单截图确认；
- 线上已发布 `xread.koplugin_v0.6.4_20261125-172200.zip`（110 文件，191885 字节，md5 `bc0bd3de…`），`--check` 校验通过。

**v0.6.5 修复（2026-11-25）**
- 修首页点「更多」/点标题死机：`showMoreListPanel` 标题行用了 `HorizontalGroup` 但没 require（正文里碰巧有全局残留，首页里是 nil → Lua 崩溃黑屏）；补 require 并全量审计各面板 require；
- 首页左上角「阅读X」点击恢复原行为（呼出 KOReader 原生菜单）。

**v0.6.6 修复（2026-11-25）**
- 书籍设置「设置字体」不再死机：字体列表改用 `cre.getFontFaces()`（点号调用，原写法不存在）；
- 首页「最近阅读」书持久化（`last_book_url`），跨重启仍指向最后打开的书；
- 目录跳章闪回首页：切换文档前先收掉底层首页/书架视图；
- 后台缓存完成不再弹窗。

**v0.6.7 发布（2026-11-25）**
- 更多面板精简为 6 项：我的书架 / 地址管理 / 账号管理 / 缓存管理 / 翻页管理 / 关于本机（去掉「我的首页」「阅读记录」）；
- 默认缓存章数确认为 **3**（含当前章），首页「设置 → 阅读偏好 → 默认缓存章数」与阅读器「设置」面板都可改（1-200）；
- 书架返回首页：首页改单实例（反复进出不再叠出多份首页），返回时优先唤醒栈内首页（瞬间回首页），没有则重建并带失败提示；
- 书架点书变慢：开书前统一取消排队中的目录预取/封面下载、停掉首页心跳（这些都是同步阻塞请求，会和开书抢 UI 线程）；预取上限降到 6 本、间隔 2s；
- 新增 TC-20（书架返回首页）与 `XREAD_AUTOTEST=shelfback|opentime` 验收模式。
- 提示策略（自动检查更新 / 热更新安装 / 测试连接全部保留并完善）：
  - 自动检查更新：首页建好后错峰查一次（一次会话只查一次，不再依赖目录预取状态），发现新版弹一次通知「发现新版本 x → y，到「更多 → 关于本机 → 检查更新」安装」；正在看书时先攒着，回首页再提示，不糊在正文上；
  - 热更新安装：`正在更新 67%（18/27） main.lua` 逐文件进度（按时间节流 150ms，避免刷屏拖慢写盘）；完成后提示变更/跳过文件数并自动重启；
  - 测试连接：成功回报「地址 + 耗时」，失败回报「地址 + 耗时 + 原因」。
- **更新只确认一次**：确认框合并为「更新并重启」（写明立即安装 + 装完自动重启），确认后直接安装并自动重启 KOReader；只有自动重启失败才提示手动重启。
- 手动「检查更新」有回执：已是最新版本会明确提示；服务端与本地都没有包时提示「检查更新失败 + 原因」，不再静默无反应。
- 错误文案统一洗白：去掉 `client.lua:141:` 这类源码位置和整条 URL，常见网络错误映射成中文（无法连接服务器／连接超时／地址无法解析／网络不可达）。
- 更新请求加超时：列目录 10s、下载 30s，后端不可达时不会把首页同步拖死。
- **发布包格式改为 tar.gz**：`publish_update.py` 默认 `--format targz`（`zip`/`tgz` 可选），产物 `xread.koplugin_v<版本>_<时间戳>.tar.gz` + `.md5` sidecar；插件端 0.6.2 起即支持该格式（libarchive 统一解包）。
- 发布上传改为 **Python 打包 + 写 ssh stdin**（不再用 `tar | ssh` shell 管道）：Windows 下经 cmd.exe 转交二进制流曾出现「远端目录空、退出码仍 0」，改为字节流直传并对返回做 `UPLOAD_OK` 断言。
- `--check` 线上列目录修正为 **GET** `getWebdavFileList`（POST 会 405，旧逻辑会误落到 filelist.json）。
- 实测（2026-11-25，真实 NAS + 模拟器）：
  - 线上发布 `xread.koplugin_v0.6.7_20261125-214505.tar.gz`（165831 字节 / 110 文件，md5 `49c6ab19…`），`--check` 通过；
  - 远端 tar.gz 端到端：模拟器降级 0.6.6 → 检查更新识别「0.6.6 → 0.6.7」→ 唯一确认框 → 下载校验解压 → 自动重启，`_meta.lua` 升到 0.6.7；
  - 解压目录 110 个文件逐个 md5 与包内一致（0 不符）；
  - 本地 tar.gz 多文件替换：`changed=2 skipped=108`，版本 0.6.6 → 0.6.7。
- 复测（2026-11-25 22:14，NAS 账号重建后重新发布并复跑，当时文案为旧版）：
  - 重新上传 `xread.koplugin_v0.6.7_20261125-214505.tar.gz`，远端 165831 字节、`md5sum` 与本地一致，`.md5` sidecar 33 字节（`\n` 结尾）、`filelist.json` 单包条目 size/md5 正确；
  - `--check` 再通过：线上挑中该包，包内版本 0.6.7 与文件名一致；
  - 远端端到端复跑：0.6.6 → 0.6.7，`changed 1 skipped 109`，留档 `xread_update/xread.koplugin_v0.6.7_20261125-214505/`，自动重启回文件管理器，无 traceback。

**v0.6.8 发布（2026-11-25）**
- 按钮点击闪现 KOReader 页面：统一改为「同一 UI tick 内完成关书/换页」——开书不再提前关首页/书架（阅读器全屏覆盖），正文「首页/书架」与首页「更新/返回」都不再留 0.15s/0.4s 延时；书架返回不再 `setDirty("all","full")`。模拟器逐帧监视：ReaderUI → miuread_home / miuread_full_shelf、home → shelf → home 的中间帧均无敌克管理器。
- 账号管理：改用户名/密码/地址后统一清旧 token 按新账号重登，换账号清旧书架缓存；首页昵称、阅读工具栏、地址管理、封面下载、更新检查全部跟着新账号走。
- 关闭按钮统一样式：新增 `xread/ui_common.lua`，所有弹出页（更多/地址/账号/书籍设置/阅读记录/快捷面板）右上角统一为「圆形浅灰底 + 居中 ✕」并贴右上角。
- 按钮语义按后端核实并修正：
  - 首页「更新」= 从后端重新拉书架写本地缓存并重建首页（此前误先关首页导致闪现）；
  - 首页「同步」= 把插件本地进度中比后端新的条目批量推到后端，再拉回最新书架；
  - 正文「缓存」= 后端 `cacheBookSSE`（`count=0`，整本缓存到服务器），长按换书；本地后续章节预取仍由开书后台任务负责；
  - 正文「删除」= 直接删除当前这本书（后端书架 + 本地章节/目录缓存），不再让用户从书单里重新选。
- 新增 `xread/ui_common.lua`，发布包 111 文件。
- 实测（2026-11-26，真实 NAS + 模拟器）：
  - 线上发布 `xread.koplugin_v0.6.8_20261126-002251.tar.gz`（167977 字节 / 111 文件，md5 `6e8f6efc31bc0a89abf68cb2cb7a6604`），远端 md5/sidecar/filelist 一致，`--check` 通过；
  - 远端端到端：模拟器降级 0.6.6 → 检查更新 → 唯一确认框「更新并重启」→ 装完自动重启，`_meta.lua` 0.6.8，`changed 1 skipped 110`；
  - 逐帧窗口监视：正文 → 首页为 `ReaderUI → miuread_home`，正文 → 书架为 `ReaderUI → miuread_full_shelf`，书架返回为 `home → shelf → home`，中间没有 KOReader 文件管理器帧。

**v0.6.9 发布（2026-11-26）**
- 更多面板移除「缓存管理」：菜单项、`showCacheManage`/`showCacheLevels`、autotest `more_cache` 分支全部清除；面板现为 5 项（我的书架 / 地址管理 / 账号管理 / 翻页管理 / 关于本机）。正文「缓存」按钮与后台整本缓存不受影响。
- 升级提示简化：
  - 自动发现新版（首页通知）：统一为「发现可用新版本，请检查更新」；
  - 手动检查更新无新版：「当前 &lt;版本&gt; 已是最新版本」；有新版确认框改为「新版本 &lt;版本&gt; 已就绪，请尽快更新」；
  - 安装完成提示去掉「更新包已留存」一句，只显示变更/跳过文件数与「正在重启 KOReader…」（留存目录仍保留，见第四节）。
- 实测：更多面板截图确认无缓存管理；手动检查更新回执截图为「当前 0.6.8 已是最新版本」。

**v0.6.10 发布（2026-11-26）**
- 最近阅读卡片按微信读书样式重排封面右侧信息：作者 · 书源 / 阅读至 N% · 上次阅读时间 / 来源 · 共 N 章 / 上次读到第 X 章 / 简介（多行），文字统一高对比色；
- 卡片右上角「历史 ›」改为刷新图标 ↻：只刷新这一张 hero 卡（`MiuiHome.update_hero`），不重建整页、不打断 30s 心跳与封面重试循环；拉书架强制 `getBookshelf(true)` 并写回缓存；局部刷新失败才退回整页重建。与现有「更新」按钮（整页重建）职责分离，不冲突；
- 正文工具栏新增「下载」按钮（目录 / 缓存 / 下载 / 删除 / 书架）：把整本书导出为 EPUB 到 KOReader/Kindle 本地文档目录（Kindle 上是 `/mnt/us/documents`，其它平台用 `Device.home_dir`/`getDefaultDir`，兜底数据目录）。后端无整本下载接口，按目录逐章 `getBookContent`，优先命中本地章节缓存；带进度提示，完成后回报路径/章数/大小；
- 新增 `xread/book_export.lua`（EPUB 打包：mimetype/container.xml/content.opf/toc.ncx/content.html），发布包 112 文件。
- 实测：首页截图确认分行排版与刷新图标；点击刷新后首页正常无报错；正文工具栏「下载」确认框文案正确；导出单测生成 1922 字节 EPUB，zip 结构完整（mimetype/opf/ncx 齐全）。

## 六、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 检查更新提示"已是最新" | ① 版本号没升；② 服务端没放更高版本包；③ 文件名版本与包内 `_meta.lua` 版本不一致（按文件名挑、按包内版本裁决）；④ 包名里没有语义版本（不会被识别） |
| 提示"无法列出更新目录" | 未开 WebDAV / 安全模式关闭 / `plugin` 路径不存在 / 后端无 `getWebdavFileList`；账号密码变了导致 401（插件自动重登一次） |
| 挑到的包不是最新上传的 | 列目录按**文件名语义版本**优先，`lastModified` 只作同版本兜底；确认新包文件名里的版本号确实更高 |
| 误装了旧包/错包 | 不会发生：下载后以包内 `_meta.lua` 版本为最终裁决，不高于本地或与文件名不符则整包拒绝 |
| 老插件（v0.5.7 前）更新失败 | 老版本升级兼容代码已移除，需手动安装新版插件 |
| 提示固件不支持 zip 解压 | 需要 KOReader 内置 `ffi/archiver`（ArchiveViewer 插件依赖，正常固件都有） |
| 上传失败 | fnOS 禁 scp；脚本用 tar over ssh。确认 SSH 端口（本机 2233）与 root 权限 |

## 七、相关文件

| 文件 | 作用 |
|---|---|
| `xread.koplugin/xread/updater.lua` | 插件端：列目录挑最新、zip 下载/校验/解压/文件级 md5 增量替换、包内版本裁决（无 manifest） |
| `publish_update.py` | 发布端：规范命名、生成 filelist.json/.md5、打包、上传、线上列目录校验 |
| `_meta.lua` | 版本号唯一事实来源 |
| `tests/cases/12_update_zip.sh` | 列目录模式 zip 更新全流程（本地 http.server，不依赖 NAS） |
| `tests/cases/16_filelist_latest.sh` | 列目录挑最高语义版本（时间戳更新的低版本不误装）、包内版本裁决 |
| `tests/cases/13_package_retention.sh` | 设备端包留存策略：预置 4 个历史包，验证只保留最近 3 次 |
| `wsl-setup/webdav_e2e.sh` | 真实 NAS 端到端：本地降级 → 走 webdav 列目录更新 → 校验版本/文件/落盘结构 |
| `release.sh` | 重打包 + 全套回归 + 生成发布目录 |

## 八、验证命令

```bash
# 校验线上目录挑中的最新包（size/md5/包内版本，不下载源码）
python3 publish_update.py --check

# 本地模拟更新全流程（WSL Ubuntu）：列目录更新 + 挑最新 + 包留存
bash tests/run_all.sh --only 12_update_zip 16_filelist_latest 13_package_retention

# 真实 NAS 端到端（需先 python3 publish_update.py --ssh ... 上传）
bash wsl-setup/webdav_e2e.sh 0.5.7     # 参数=把本地降级到的版本

# 查看线上目录清单（浏览器或登录 token 后接口）
# GET /reader3/getWebdavFileList?path=/plugin&accessToken=<登录token>
```
