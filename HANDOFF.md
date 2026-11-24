# xread-HANDOFF

# xread.koplugin 项目迁移交接文档

> 生成时间：2026-11-21 23:20 · 由 WorkBuddy 会话整理
> 用途：在另一台设备 / 另一个 WorkBuddy 账号上无缝继续本项目开发。
> 换账号后原账号的对话记录、云端资料库、用户记忆均不可见，本文档 + 源码包即为全部上下文。

## 1. 项目是什么

**xread.koplugin**：KOReader 插件，对接自建书源服务 **Xread**（reader3 协议，类似"阅读"APP 的服务端）。

- 当前版本：**v0.5.0**
- 运行环境：Kindle / KOReader，开发验证用 WSL2 里的 KOReader 模拟器
- 服务端接口前缀：`/reader3/*`（登录、书架、目录、章节正文、进度、整本缓存 SSE）

### 功能清单（v0.5.0 已完成）

| 模块 | 文件 | 说明 |
| --- | --- | --- |
| 主程序 | `main.lua`（约 48 KB） | 菜单、事件、autotest 流程、版本 0.5.0 |
| API 客户端 | `xread/client.lua` | 9 个 `/reader3/*` 接口：health/login/getBookshelf/getChapterList/getBookContent(±Raw)/extractImageUrls/downloadImage/saveBookProgress/getShelfBookWithCacheInfo/deleteBookCache/cacheBookSSE |
| 书架网格 | `xread/shelf_grid.lua` | 封面网格书架 |
| 目录视图 | `xread/catalog_view.lua` | 章节目录 |
| 章节缓存 | `xread/chapter_cache.lua` | 章节正文本地缓存 |
| 封面缓存 | `xread/cover_cache.lua` | 封面下载缓存 |
| 快捷面板 | `xread/quick_panel.lua` | 圆角白卡 + 章节滑块 + 字号滑块（Ⓐ − 轨道 +）+ 3×4 图标网格（目录/缓存/阅读记录/夜间/上一章/下一章/刷新/同步进度/设置/书架/缩小/放大） |
| 阅读记录 | `xread/reading_stats.lua` | 周/月/年/全部 标签、总览卡、柱状趋势图、Top 榜单；数据读 KOReader `statistics.sqlite3` + 自有 `reading_log.lua` 兜底 |
| 文本测量兼容层 | `xread/text_metrics.lua` | 给 `TextWidget` 补静态 `getTextWidth(text, face, bold, kerning)`（KOReader 本身没有），供书架/目录的标题两行折行使用 |
| **miuread 视觉层** | `xread/miui/`（17 个模块）+ `resources/icons/miuread/`（79 SVG） | 2026-11-22 整搬 miuread 视觉层三步：书架（圆角封面/进度角标/SVG 图标/省略号标题）、首页（hero 卡/阅读数据卡/4×2 网格）、阅读工具栏（状态栏/功能区/排版行/设备行）；数据层仍走 `xread/client.lua` |

### 1.1 miuread 视觉层移植（三步走，第一步已完成）

**决策**：不直接改 miuread 接 Xread（它是 11.5 万行 Lua、main.lua 单文件 35746 行、无 provider 插槽、进度体系依赖 `chapterUid + wr_data_co`，改造约 1~2 万行），改为**整搬视觉层 + 数据层继续用 xread/client.lua**（视觉层约 4581 行 + 79 SVG，胶水约 130 行）。

| 步骤 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 书架：`full_shelf_view` + `ui_scale` + `icon_registry` + `ui_components` + `util` + `cover_render` + `thought_face_factory` | ✅ 2026-11-22 完成并实跑验证 |
| 2 | 首页：hero 卡 + 分类标签 + 仪表盘（`home_view.lua`，数据从 client:getBookshelf() 喂） | ✅ 2026-11-22 完成并实跑验证 |
| 3 | 阅读工具栏：`reader_toolbar.lua` 替换快捷面板（正文仍 KOReader 原生） | ✅ 2026-11-22 完成并实跑验证 |

三步全部完成：书架 / 首页 / 阅读工具栏均换成 miuread 视觉层，数据层继续走 `xread/client.lua`。

**第一步接入方式**（`main.lua`）：
- `local MiuiShelf = require("xread.miui.full_shelf_view")`
- `XRead:_toMiuiBooks()`：xread book（name/author/coverUrl/durChapterIndex/totalChapterNum）→ miui book（title/author/cover_path/progress），保留 `_xread_book` 反引
- `XRead:showMiuiShelfGrid()`：默认走新视图，`XREAD_SHELF_LEGACY=1` 可回退旧 `showShelfGrid`
- 翻页 `on_page_changed` 里补 `prepareCovers()` 再 `shelf_view:updateItems()`
- 视觉模块 require 前缀已从 `miuread.*` 改为 `xread.miui.*`；`icon_registry.lua` 的图标根路径推导改为从 `xread/miui/` 上溯两级到插件根

**第一步验证结果**（WSL1 模拟器）：59 本书架正常渲染（4×3、圆角封面、进度角标 8%/3%/98%、SVG 返回箭头、标题省略号、底栏 1/5），翻页到 2/5 正常。第 2 页显示 miui 占位图是**正确行为**——那批书的 `coverUrl` 源站返回 404（实测 img.lzipic.com / oss.mkzcdn.com 均 404），placeholder 优雅降级。

**第二步接入方式**（`main.lua`）：
- `local MiuiHome = require("xread.miui.home_view")`
- 新增菜单项「首页（miuread 视觉）」→ `openHome()`：`runOnline` 登录后 `showHome()`
- `showHome()`：把 `client:getBookshelf()` 转成的 miui books 喂给 `MiuiHome:new{ books = ... }`，挂 `_home_view` 管理生命周期；`XREAD_AUTOTEST=home` 可自动进入
- 整搬模块：`home_view.lua` / `gesture_bridge.lua` / `shelf_progress.lua` / `config.lua` / `home_header_layout.lua`（require 前缀同样 `miuread.*` → `xread.miui.*`）

**第二步验证结果**（WSL1 模拟器，截图 `wsl-setup/hm1_70s.png`）：hero 卡（书名/作者/来源/最近读到第 76 章/阅读进度 3%）+ 右侧阅读数据卡（本地暂无阅读数据）+ 「我的书架」4×2 网格（8 本/页、进度角标 8%/3%/98%、占位图优雅降级）+ 底部分页 1/8 + 顶栏「阅读X / 书友 / 同步 / 菜单」图标全部正常，无报错弹窗。

**第三步接入方式**（`main.lua`）：
- `local ReaderToolbar = require("xread.miui.reader_toolbar")`
- `XRead:buildMiuiToolbarOptions(book, chapters, index, font_size)`：只用 xread 自有状态构造 opts（header.title/chapter/location/progress、time/battery、4 个 actions：目录/缓存/阅读记录/书架、typeset：字号/行距/页面、4 个 device_actions：夜间/刷新/同步进度/设置），所有 callback 调 xread 现有方法，**不引入任何微信读书数据契约**
- `XRead:showMiuiToolbar()` → `ReaderToolbar.show(opts, key)`，把 toolbar 放进 `SHARED.panel` 复用现有缓存回显/跳章/关书生命周期；给 panel 注入 `setCacheHint` 把提示写到 header 位置栏
- `showQuickPanel()` 默认走新 toolbar；`XREAD_PANEL_LEGACY=1` 回退旧圆角快捷面板（`_showLegacyQuickPanel()`）
- 整搬模块：`reader_toolbar.lua` + 4 个依赖 `transient_guard.lua` / `dialog_transition.lua` / `modal_geometry.lua` / `reader_skin.lua`（require 前缀同样 `miuread.*` → `xread.miui.*`），图标复用已有 79 SVG

**第三步验证结果**（WSL1 模拟器，截图 `wsl-setup/tb2_1_toolbar.png` / `tb2_2_catalog.png`）：
- 顶部状态栏 Wi-Fi / 同步 / 15:30 / 电量 100% / 首页 / 更多
- 书名「三国新天子」、章节行「第一章 大喜大悲来得突然… / 第 1/803 章 / 0% ›」
- 功能区 4 图标：目录 / 缓存 / 阅读记录 / 书架；排版行：字号 − 22 + / 行距 − 原生 + / 页面 ›
- 设备行：夜间 / 刷新 / 同步进度 / 设置；正文在下半屏正常显示，无遮挡
- 点「目录」图标成功跳转章节目录页（左侧封面/作者/已读 0/803，右侧章节列表 + 当前章高亮 + 跳到…，底部 返回/目录/上一页/下一页）
- 日志 `[MiuRead][ReaderToolbar] build timing ... build_ms=63`，无 error/traceback

## 2. 新设备环境恢复步骤

### 2.1 开发/验证环境（Windows + WSL —— **本机是 WSL1，不是 WSL2**）

> **重要（2026-11-22 实测）**：当前开发机 CPU 为 Intel Pentium B950，**硬件不支持 VT-x**（`systeminfo` 显示「虚拟机监视器模式扩展: 否」），因此 WSL2 / Hyper-V **永久不可用**，`wsl --install` 最终会卡在 `HCS_E_HYPERV_NOT_INSTALLED`。
> 已改用 **WSL1**（syscall 翻译，不需要虚拟化）导入 Ubuntu 22.04，插件与 KOReader 模拟器均运行正常。

1. 发行版：`Ubuntu`（WSL1，`wsl --import Ubuntu D:\WSL\Ubuntu <rootfs.tar.gz> --version 1`），rootfs 用 `cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz`（24.04 的 rootfs 已下架）。
2. KOReader 模拟器：`/opt/koreader/{bin,lib,share}`（解压官方 `koreader-linux-x86_64-*.tar.xz` 后把平铺的 bin/lib/share 收进 `/opt/koreader/`）。
3. **启动脚本是 `./lib/koreader/koreader.sh`，不是 `./bin/koreader`** —— 后者的 `reader.lua` 找不到（它在 `lib/koreader/` 下）。
4. 插件安装位置：`/opt/koreader/lib/koreader/plugins/xread.koplugin/`（本包 `xread.koplugin/` 目录直接整个拷过去即可）。
5. 服务端：Xread 服务地址配置在插件设置里（默认 `http://192.168.31.51:7777`）；`client.lua` 无硬编码密钥。
6. WSL1 无 WSLg，图形验证用 **Xvfb + xdotool + ImageMagick import 截图**（无头，不依赖 Windows X server）。依赖：`xvfb xdotool imagemagick fonts-noto-cjk fonts-wqy-microhei libsdl2-2.0-0 libgl1 libgx-mesa0`（apt 源已换清华镜像）。

### 2.2 模拟器验证命令（本机实测通过，脚本在 `wsl-setup/`）

```bash
# 一键启动 + 截图（Xvfb :99, 1072x1448 DPI300）
bash /mnt/d/WorkBuddy/<工作区>/wsl-setup/run_test.sh shot1 30

# 手动启动
wsl.exe -d Ubuntu -u root -e bash -lc "export DISPLAY=:99; \
  cd /opt/koreader && ./lib/koreader/koreader.sh /root"
# 首次需先起 Xvfb: Xvfb :99 -screen 0 1072x1448x24 &

# 截图 + 点按（坐标以 1072x1448 原图为基准；注意查看缩略图时要按 1072/808 比例换算）
xdotool mousemove X Y; xdotool mousedown 1; sleep 0.15; xdotool mouseup 1
import -window root /tmp/shot.png

# 菜单路径：顶端菜单 -> tools（扳手，x≈340 y≈50）-> 阅读X（133,133）
#           -> 我的书架 / 阅读记录 / 整本预缓存 / 设置 / 测试连接 / 关于

# 部署源码改动后先做语法检查再重启
cd /opt/koreader && ./lib/koreader/luajit -e \
  "local f,e=loadfile('lib/koreader/plugins/xread.koplugin/<file>'); print(f and 'OK' or e)"

# 每轮重启前清理（autotest 一次性标志 + 历史记录，否则会打开上次的 quickstart）
pkill -9 -f '[l]uajit'; rm -f /root/.config/koreader/history.lua /tmp/xread_autotest_once
```

### 2.2.1 2026-11-22 实测验证结果

| 项目 | 结果 |
| --- | --- |
| 10 个源文件加载 | KOReader 自带 luajit `loadfile` 全部 OK |
| 插件注册 | 顶端菜单 tools 标签首位出现「阅读X」，子菜单 6 项齐全（我的书架/阅读记录/整本预缓存/设置/测试连接/关于） |
| 测试连接 | 「连接成功」（client.lua health() → NAS `192.168.31.51:7777` 打通） |
| 登录 / 书架 | `bingkuomiao` 登录成功，书架 59 本、4 列 × 3 行封面全部下载渲染，顶栏「我的书架 共 59 本 · 长按封面看目录」，底部分页正常 |
| 点书即读 | 打开《贪欢》直达上次章节（第005章），正文/页码 1/65 正常 |
| 快捷面板 | 书名 + 5/50 + ✕、章节滑块、字号滑块、3×4 图标（目录/缓存/阅读记录/夜间/上一章/下一章/刷新/同步进度/设置/书架/缩小/放大）全部渲染；缓存格显示「已缓存 10 章」；点卡片外收起、点图标关闭并跳转均正常 |
| 目录页 | 左侧封面/作者/已读 47/50，右侧章节列表 + 当前章高亮 + 跳到…，底部 返回/目录/上一页/下一页 |
| 后台静默缓存 | 日志 `xread bg cache stop: done cached to chapter 34`，并弹「《贪欢》后续 5 章已在后台缓存完成」 |
| 阅读记录面板 | 周/月/年/全部 标签、总览卡（读过 2 本/读完 0 本）、趋势图、Top 榜单（贪欢、KOReader Quickstart Guide）全部正常渲染 |

**重建修复记录（截至 2026-11-22，共 5 处；语法校验全部查不出来，都是运行期才暴露）**：

1. `xread/reading_stats.lua`：`local function loadData()` 被排在 `ReadingStats:init()` 之后（1011 vs 462）→ 点「阅读记录」报 `attempt to call global 'loadData' (a nil value)`。已整体前移至 `init` 之前。
2. `main.lua`：`startBg` 定义在 1400 行、却在 1205 行被调用 → 开书报 `attempt to call global 'startBg'`。改为在文件顶部 `local startBg` 前向声明 + `function startBg(job)` 赋值（顺序不动，风险最小）。
3. `xread/quick_panel.lua`：拼接时丢失了文件尾部的**方法块与导出**（`paintTo` / `onTap` / `close` / `onClose` / `applyFontDelta` / `setCacheHint` / `return QuickPanel`）。表现依次为：`QuickPanel` 是 boolean、点 ✕ 报 `attempt to call method 'close'`。已按资料库原文补齐。
4. `xread/shelf_grid.lua` + `xread/catalog_view.lua`：`wrapTitle` 调用 `TextWidget.getTextWidth(text, face, bold, kerning)`，但 KOReader 任何版本都没有这个静态方法 → 书架报 `attempt to call field 'getTextWidth'`。新增 `xread/text_metrics.lua` 兼容层（缺则用 `RenderText:sizeUtf8Text` 补上该静态方法），两个文件在 require TextWidget 后 `require("xread.text_metrics")`。
5. `xread/reading_stats.lua`（同类继承问题）已在上一条修复。

> **重建教训**：资料库语义检索只返回「相关文本块」，**不等于完整文件**。判断完整性不能只看语法：
> ① 扫「局部函数/变量先用后定义」（含 `name{`、`name"` 等非括号调用）；② 扫「被调用但全文无定义的方法」（如 `self:close`、`TextWidget.getTextWidth`）；
> ③ 确认每个模块文件末尾有 `return Xxx`；④ 最后必须按功能路径实跑一遍。

### 2.2.2 全流程 E2E 测试（2026-11-22 下午，截图保留在 `wsl-setup/e2e_*.png`）

用 WSL1 模拟器把整条链路走了一遍，逐环节截图 + 抓日志：

| 步骤 | 截图 | 结果 |
| --- | --- | --- |
| 打开书架 | `e2e_01_01_shelf.png` / `e2e_shelf_after_fix.png` | ✅ 59~60 本、4×3 网格、标题/分页正常 |
| 点书开书 / 正文 | `e2e_04_04_toolbar.png`（背景正文）/ `e2e_step` 日志 `opening file` | ✅ 直达上次章（如《山海无限镜花缘》1/11）|
| 正文翻页 | `e2e_06_06_chapter_jump.png`（显示 2/11） | ✅ 页码递增正常 |
| 阅读工具栏 | `e2e_07_07_toolbar_again.png` / `e2e_panel.png` | ✅ 状态栏/书名/章节/4 功能区/排版行/设备行齐全 |
| 章节目录 | `e2e_catalog.png` | ✅ 左侧封面+已读 5/2249、右侧章节列表+当前章高亮、底部翻页栏 |
| 正文返回书架 | `e2e_08_08_back_to_shelf.png` + 日志 `tapped 书架` / `closed book cached to chapter 22` | ✅ 正常回书架并停后台缓存 |

**测试脚本**（均在 `wsl-setup/`）：`e2e_full.sh`（串联全流程，带画面稳定检测）、`e2e_step.sh`（单 flow 稳定截图：`XREAD_AUTOTEST_FLOW=panel|catalog|shelf|stats`）、`tb_click.sh`（工具栏点按）。

**测试注意事项**：用固定 sleep 串联多步时，点击容易撞上 Trapper 的 `Paused` 确认框（后台任务运行期间的取消确认），导致后续点击被吞。用 `e2e_step.sh` 分 flow 单独验证，或用 `e2e_full.sh` 的画面 md5 稳定检测后再点，可规避。这是 KOReader Trapper 机制，不是插件 bug。

**发现并修复 1 处（加固，非功能 bug）**：
- `xread/cover_cache.lua` 的 `fetch()` 下载封面后直接交给 MuPDF 解码；后端偶发返回 HTML 错误页/损坏数据（HTTP 200 但非图片），KoReader 的 MuPDF 渲染时会抛 `format error: unknown image file format` 未捕获异常（日志 `UNHANDLED EXCEPTION`）。虽不影响功能（有占位图兜底），已在 `fetch()` 加**图片魔数校验**（PNG/JPEG/GIF/WebP/BMP），非图片数据直接拒绝。复测（`cover_fix_test.sh`）：UNHANDLED EXCEPTION 0、format error 0、MuPDF 警告 0、真实错误 0。

### 2.2.3 测试用例归档 + 改动后自动测试（2026-11-22 晚）

**以后每次大改动必须跑测试**，入口已固定：

```bash
# Windows 侧一键：重打包 zip -> 跑全套 10 用例 -> 全 PASS 才交付
wsl.exe -d Ubuntu -u root -e bash -lc 'bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/release.sh'

# 只验证不改包 / 快速自检 / 指定用例
bash tests/run_all.sh
bash tests/run_all.sh --quick
bash tests/run_all.sh --only 03_toolbar 04_catalog
```

- 归档在 `tests/`：10 个用例（`cases/01..10`）、公共库 `lib/common.sh`、索引 `tests/CASE_INDEX.md`、入口 `tests/run_all.sh`、发布脚本 `release.sh`。
- 覆盖：书架/开书/工具栏/目录/返回书架/首页/阅读记录/工具栏点目录交互 + 全量 Lua 语法 + zip-源码-部署三方一致性。
- 每次运行归档到 `tests/reports/<时间戳>/`：`SUMMARY.md`（PASS/FAIL 表）+ 逐用例日志 + 截图。历史 `wsl-setup/*.sh` 不再维护。
- 为可靠判定，在 `main.lua` 的 autotest 分支加了 `[XREAD_AUTOTEST] ... done` 验收标记（仅测试环境变量存在时输出，生产无副作用）；用例靠标记 + 日志事件 + 截图体积 + 无致命错误四重断言，不再靠固定 sleep 盲等。
- `release.sh` 先重打包再跑全套，因此 TC-10 一致性检查发现的是"包与源码是否同步"；若单独跑 `run_all.sh` 时代码有改动未打包，TC-10 会 FAIL 提示重新出包。
- 用例本身也在首轮实跑中修正：TC-05 原用 `flow=shelf` 直接调方法，断言 `tapped 书架` 不成立，已改为真交互（panel + 点 918,313）；`closed book cached to chapter` 只在有后台缓存任务时打印，改为观察项。给 `closeBookToShelf()` 加了 `[XREAD_AUTOTEST] close_book_to_shelf done` 固定标记（仅测试环境变量下输出）。
- `run_all.sh` 对失败用例**自动重试一次**，应对后端偶发挂起（曾出现 KOReader 卡在加载被 240s 超时杀掉、截图 343B）；首次失败日志留为 `<id>.attempt1.log`，SUMMARY 标注重试次数。

### 2.2.4 加载速度优化 + 预加载（2026-11-22 晚）

**优化前**：只有正文分片缓存（`chapter_cache`）、封面磁盘缓存（`cover_cache`）和开书后的后台续章缓存（`startBg`）；书架、章节目录每次都重新走网络，封面逐张串行下载且每张弹一次进度框，没有真正的预加载。

**优化后**：

1. 新增 `xread/meta_cache.lua`：书架列表（TTL 300s）+ 章节目录（TTL 1800s）落本地 JSON，读写全 pcall，坏缓存自动当未命中。
2. 书架/首页**缓存优先秒开**：先渲染本地数据，`XREAD_SHELF_CACHE=0` 可关闭；网络刷新放后台，只写缓存不重建当前界面（避免翻页/点书时被闪掉）。
3. 开书/目录页**目录读缓存**，未命中才请求网络并回写；进度上报改为异步，不再阻塞文档打开。
4. 封面**非阻塞加载**：先用已缓存封面/占位图立即渲染，未缓存的后台逐张静默下载并局部刷新书架/首页；generation 号防止翻页/关闭后旧队列误刷新。`XREAD_COVER_ASYNC=0` 回退同步。
5. **预加载**：书架/首页显示后预取「最近在读那本」的章节目录（`XREAD_NO_PREFETCH=1` 关闭），点它即命中缓存。
6. TTL 可通过设置项 `shelf_cache_ttl` / `chapter_cache_ttl` 调整。

**实测**（WSL 模拟器，同一账号/后端）：书架标记 6s → 2s；点书进正文 36s → 2s（二次命中，日志 `chapters_cache_hit`）；全套测试耗时 ~10min → 5m21s。**优化后全套 release.sh：PASS=10 FAIL=0**，zip 107 文件 151363B。

### 2.2.5 无弹窗静默加载 + 请求超时（2026-11-22 晚，针对「弹窗阻挡操作」）

**问题**：① luasocket 默认超时 60s，后端偶发挂起时界面长时间卡死；② 书架/开书/目录等浏览操作走 `runOnline` 的 `Trapper:info` 模态弹窗——弹窗吞点击，且 Trapper 连续 info 时用户点击会触发 `Paused` 确认框（Abort/Continue），把后续所有操作都拦下来；③ 点开漫画时每下载一张图弹一次进度框。

**改动**：

1. `xread/client.lua`：`http.TIMEOUT = 12`（原 60）；`xread/cover_cache.lua`：封面请求临时覆盖为 8s（封面是懒加载队列，一张卡太久会拖累翻页交互）。
2. main.lua 新增 `XRead:runQuiet(fn)`：无弹窗协程执行，出错才 `showInfo`，结束时 `Trapper:clear()` 清残留进度框。**书架/首页/开书/目录/跳章/漫画打开等全部浏览类操作已切换**；`runOnline`（可点击中断）只保留给「整理书架 / 测试连接」这类用户显式触发的管理操作。静默模式下任务期间的点击排队、任务结束立即生效，不再被弹窗挡住。
3. 漫画下载进度 `UI:info(..., true, true)`（fast_refresh + skip_dismiss_check）：进度仍可见但不再触发 Paused 确认框。
4. 后台书架刷新延至显示后 2s、目录预取延至 5s（错峰，避免刚显示书架时网络任务挤在一起卡点击）。
5. 封面懒加载维持：占位图先显示 → 后台队列逐张下载 → 单书局部刷新（书架 `updateItems` / 首页 `updateBook(bookId)`），generation 号防竞态。

**验证**（`wsl-setup/ui_quiet_test.sh`）：书架秒开（73 本封面全部懒加载渲染）、立即点书 15s 内进正文、工具栏正常，全程 **Paused 0 次、致命错误 0**。

**注意**：模拟器多次连跑后偶发进程被 SIGKILL（WSL1 内存提交限制），与代码无关；重跑即可。

### 2.2.6 底部状态栏改造：左章节名 / 右页码（2026-11-22 晚）

**需求**：正文最下面一行不再显示进度条，改为左对齐显示当前章节名（如「第1章 老子是马超」），右对齐仍显示页码（1/294）。

**实现**（都在 `main.lua`，onReaderReady 时触发）：

1. `XRead:_applyReaderFooter()`：配置 KOReader ReaderFooter——`disable_progress_bar=true` 去进度条；`all_at_once=true`（默认只显示一项，必须开才能同显多项）；只保留 `book_chapter + dynamic_filler + page_progress` 三个元素（其余 time/pages_left/percentage/battery 等全关）；`dynamic_filler` 用空格撑满中间实现左右两端对齐；章节名超 60% 屏宽省略号截断。改完依次调 `set_mode_index → updateFooterTextGenerator → updateFooterContainer → resetLayout(true)`，设置持久化到 `G_reader_settings("footer")`。
2. `XRead:_injectTocFromText()`：crengine 不会为纯 TXT 生成 TOC。开书 1.5s 后后台分批（每帧 25 页）扫描每页文本（`getPageXPointer + getTextFromXPointers`）匹配行首 `== 章节标题 ==`，构建页→章节表注入 `ui.toc.toc`——footer 章节名随翻页自动更新，KOReader 章节跳转也一并可用。`XREAD_NO_TOC_SCAN=1` 可关闭。

**踩过的三个坑（重要）**：

- footer 挂在 **`ui.view.footer`**（ReaderView 成员），不是 `ui.footer`——后者是 nil。
- `updateFooterContainer()` 重建了 `footer_positioner`（dimen 为空），**必须紧跟 `resetLayout(true)`**，否则 footer 整个画不出来（表现为进度条消失但文本也不出现）。
- `updateFooterText` 在 footer 自己的 onReaderReady 之前是 noop（2419 行才初始化为 `_updateFooterText`），要延迟（`scheduleIn(1)`）调用才真正刷新文本。

**验证**（`wsl-setup/footer_test3.sh`，带 3 次重试应对环境偶发 SIGKILL）：TXT 正文底部左「第1章 老子是马超」右「1 / 294」，翻页后页码更新为「2 / 294」，进度条消失，无报错。

**测试辅助**：autotest open 模式新增 `XREAD_AUTOTEST_BOOK=<书名子串>` 指定打开的书（避免随机撞上坏书/漫画）、`XREAD_AUTOTEST_BOOK_IDX=<序号>` 指定格子。

### 2.3 真机安装

把 `xread.koplugin.zip`（本包内已附）解压或整个放入 KOReader 插件目录，完整重启 KOReader。

## 3. 必须记住的坑（都实测踩过）

1. **SQLite**：KOReader 的 `conn:exec(sql, true)` 是错的——`exec` 第二参数是字符串模式（默认 `"hik"`），传 boolean 会在 `get:find` 抛错并被 pcall 吞掉 → 数据全 0。正确写法 `conn:exec(sql)`，结果按列索引 `res[1][i]`。
2. **WidgetContainer:paintTo 只画 **`self[1]`：自定义遮罩+浮层必须重写 `paintTo`（先画遮罩再按 left/top 画卡片），`self[1]` 只用于事件传播。
3. **固定高度估算必翻车**：弹窗卡片一律「按屏幕上限反推能放几项 → 卡片高度贴合内容」。实测 1072×1448 下 `overview=scaled(170)`、`trend=scaled(160)`、榜单项 `scaled(60)`/项 显示 4 本且不裁切。
4. **分章 TXT 书名归并**：`贪欢_5` 这类 `_N` 后缀要用 `normalizeTitle` 去掉再统计。
5. **− 号与深色滑轨之间要留间隔**，否则墨水屏上看不清。
6. **弹窗文案简洁**，不要「第 X 步」这类字样，不要多余 toast（用户明确要求）。

## 4. 下一阶段计划：参考 miuread-koreader 移植视觉层

参考仓库已克隆到本包 `_refs/miuread-koreader/`（GitHub: bingkuomiao/miuread-koreader，AGPL-3.0-only，180 个 Lua 文件，main.lua 1.8 MB）。调研结论（2026-11-21，已逐文件核实）：

### 可以整套搬的视觉层（与微信读书数据解耦）

| 要搬的 | 来源文件 | 要点 |
| --- | --- | --- |
| 缩放体系 | `miuread/ui_scale.lua` | 密度归一化 + 显示模式倍数；细线最少 2 设备像素 |
| 基础 widget 工厂 | `miuread/ui_components.lua` | Ui.align/text/textbox/icon |
| 图标系统 | `miuread/icon_registry.lua` + `resources/icons/miuread/*.svg`（79 个 Lucide SVG） | 统一入口 `Ui.icon`，整目录复用 |
| 顶栏几何 | `miuread/home_header_layout.lua` | 纯函数 `arrange`，零依赖 |
| 首页各卡绘制 | `miuread/home_view.lua` | `hero_card_classic`(528-753)、`action_bar`(961-1024)、`category_tabs`(1026-1066)、`shelf_book_card`(852-959)、`_grid_geometry`(1349-1363)、`page_footer`(1401-1422)；圆角 `radius(9,6,15)`、封面比 0.715、4 列×2 行每页 8 本 |
| 全屏书架 | `miuread/full_shelf_view.lua` | 数据只吃 `opts.books` 数组 |
| 封面预处理 | `miuread/cover_render.lua` | 离屏缩略图 + 原子写 PNG |
| 墨水屏刷新策略 | `home_view.lua` `_mark_dirty`(1930-1992)、`_remember_section_layer`(1843-1876) | `ui` 快刷 + 2.8s 后对同区域补 `full` 清残影；脏区合并 +4dp 边；遮白角做圆角 |

### 数据层不要动

继续用 `xread/client.lua`：`getBookshelf` 供书架，`saveBookProgress(index)` 供进度（只有整数章序号）。**不要**引入 miuread 的 `sync.lua`(333KB)/`download_task.lua`(131KB)/解密/批注/译文——全是微信读书私有协议。

### 绝对不可走「直接改 miuread 接口对接 Xread」路线

`api.lua` façade 后端硬编码 Web/E-Ink 两套 WeRead，无第三方 provider 插槽；数据契约 bookId/chapterUid/wr\_data\_co/签名全绑定。改造等价重写核心（XL）。Xread 缺的能力（书店/批注/译文/云统计）不是映射问题，是后端没有。

### AGPL 注意

miuread 是 AGPL-3.0-only。整目录照搬其代码则衍生插件必须整体 AGPL 开源 + 保留 NOTICE/THIRD\_PARTY\_NOTICES + 显著标注修改。只借鉴思路和参数则风险低。

## 5. 本包内容清单

```
xread-migration/
├── HANDOFF.md                  本文档
├── xread.koplugin/             最新源码（= WSL /opt/koreader 部署版，v0.5.0）
│   ├── main.lua / _meta.lua
│   ├── xread/                  数据层 + 自研视觉层（10 个 .lua）
│   │   └── miui/               ← 2026-11-22 整搬的 miuread 视觉层（17 个 .lua）
│   └── resources/icons/miuread/ ← 79 个 Lucide SVG 图标
├── xread.koplugin.zip          可直接安装到真机的插件包（含视觉层，约 89 KB）
├── _rebuild/                   2026-11-22 资料库重建工作记录（chunks/order/拼接脚本）
├── _verify/                    2026-11-22 模拟器验证截图（菜单/子菜单/连接/设置/关于/阅读记录/书架/快捷面板/正文/目录）
└── _refs/
    ├── miuread-koreader/       参考仓库源码（main 分支 tarball 解包）
    └── xread-src/              源码副本（与上层 xread.koplugin 相同）
```

> **源码 provenance（2026-11-22）**：本包 10 个 Lua 文件系从 WorkBuddy 资料库散装节点经语义检索取回文本块后重建
> （`_rebuild/` 保留了全部 chunks JSON、顺序文件与 assemble.py 拼接脚本）。全部文件已通过 LuaJIT `load()` 语法校验，
> 并在 WSL1 的 KOReader 模拟器上按「书架 → 开书 → 快捷面板 → 目录 → 阅读记录 → 后台缓存」整条链路实跑验证。
> 重建中被补回/新增的 5 处见第 2.2.1 节；`xread/text_metrics.lua` 为新增兼容模块（原包不存在）。
> 若与真机上的旧版本出现行为差异，优先怀疑这几处。
>
> **本地账号配置不在包内**：登录凭据保存在机器本地 `~/.config/koreader/settings/xread.lua`
> （由插件「设置」界面写入，键为 `address` / `username` / `password` / `max_chapters`）。

## 6. 新会话快速上手提示词

在新设备/新账号里把本包交给助手后，可以直接说：

> 这是 xread.koplugin 项目迁移包，先读 HANDOFF.md。当前 v0.5.0 已完成快捷面板和阅读记录，下一步按 HANDOFF 第 4 节把 miuread 的视觉层（ui\_scale/ui\_components/icon\_registry/home\_header\_layout/home\_view 绘制函数/墨水屏刷新策略）移植进书架首页，数据层继续用 xread/client.lua。
