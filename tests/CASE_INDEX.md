# xread.koplugin 测试用例归档

> 目的：每次大改动后跑同一套用例，结果可比对、截图可回溯。
> 所有脚本在 **WSL Ubuntu** 内运行，路径以本目录（`xread-migration/tests/`）为基准。

## 目录结构

```
tests/
├── CASE_INDEX.md          本文件：用例索引 + 判定规则 + 坐标基准
├── lib/common.sh          公共库：模拟器启停、验收标记等待、断言、截图
├── cases/01..36/*.sh      独立用例（12=zip 更新，13=包留存策略，16=按版本挑最新，17=封面单测，18=tar.gz 更新，19=本地包更新，31=静默检查更新，34=更新器建目录，35=提示卡不自动消失，36=英雄卡长书名；11 旧散文件用例已移除）
├── reports/<时间戳>/      每次运行归档：SUMMARY.md + 逐用例日志 + 截图
└── run_all.sh             统一入口（--full / --quick / --only）
```

## 用例清单

| ID | 名称 | 触发方式 | 核心断言 | 耗时 |
|---|---|---|---|---|
| 01_shelf_smoke | 书架加载 + 封面防御 | `XREAD_AUTOTEST=shelf` | `mode=shelf` 标记、截图>20KB、0 图片格式错误、无致命异常 | ~90s |
| 02_reading_open | 开书进正文 | `XREAD_AUTOTEST=open` | `mode=open` 标记、`opening file` 日志、正文截图 | ~90s |
| 03_toolbar | 阅读工具栏 | `open` + `FLOW=panel` | `flow=panel` 标记、`ReaderToolbar build` 日志 | ~90s |
| 04_catalog | 章节目录 | `open` + `FLOW=catalog` | `flow=catalog` 标记、目录截图（章节列表/当前章高亮人工复核） | ~90s |
| 05_back_to_shelf | 正文返回书架 | `open` + `FLOW=panel` + 点(918,313) | `tapped 书架`、`close_book_to_shelf done`、点击前后截图（后台缓存停止日志仅条件出现，不作失败条件） | ~100s |
| 06_home | miuread 首页 | `XREAD_AUTOTEST=home` | `mode=home` 标记、hero 卡/网格截图 | ~90s |
| 07_stats | 阅读记录 | `open` + `FLOW=stats` | `flow=stats` 标记、无 `reading stats failed` | ~90s |
| 08_toolbar_catalog_tap | 工具栏点目录 | `open` + `FLOW=panel` + 点击 | `tapped 目录` 日志、点击前后两张截图 | ~100s |
| 09_syntax | 全量 Lua 语法 | LuaJIT `loadfile` | 部署目录所有 `.lua` 可解析 | <5s |
| 10_package_consistency | 交付包一致性 | md5 | zip / 源码 / WSL 部署三方逐文件匹配 | <5s |
| 12_update_zip | 列目录模式 zip 热更新全流程 | `update` + filelist.json + zip + md5 sidecar（无 manifest） | `via=list`、`newer=true`、下载 zip 解压后本地版本变为测试版本；同名 zip 与解压目录同级留存 | ~90s |
| 13_package_retention | 设备端更新包留存与清理 | `update` + filelist.json（1 包）+ 预置 4 个历史包 | 新包落 `xread_update/<包名>/`；索引只留 3 条；最旧 p1/p2 的目录与 zip 被清理，p3/p4 保留 | ~90s |
| 16_filelist_latest | 列目录按版本挑最新（不按时间） | `update` + filelist.json（2 包，无 version 字段）+ md5 sidecar | `via=list`、按包名语义版本挑中高版本（`remote=0.7.1-test`）而非时间戳更新的低版本、包内版本裁决后本地版本更新、不误装旧包 | ~90s |
| 17_cover_api | 统一封面接口（本地/网络书通用） | 纯 Lua 单测（LuaJIT + mock socket.http） | `path=<customCoverUrl||coverUrl 原值>`、统一带 accessToken/secureKey/userNS、未登录网络书 URL 正确、Referer 为合法 header、本地书 401 重登后用新 token 重试 | <5s |
| 18_targz_update | tar.gz 包热更新全流程（v0.6.2+） | `update` + filelist.json + tar.gz + md5 sidecar | `via=list`、识别 .tar.gz 包名版本、下载解压后本地版本变为测试版本；同名 tar.gz 与解压目录同级留存 | ~90s |
| 19_local_update | 本地包热更新（v0.6.4+，不联网） | `localupdate` + 规范 zip 放插件目录内（同级目录负向验证不扫描） | `via=local`、本地包版本识别、解压后本地版本变为测试版本；源包挪入 xread_update 留存、插件目录清理；同级目录 9.9.9 包未被识别 | ~30s |
| 20_shelf_back | 书架返回首页 | `home` + 进入书架 + 点左上返回 | 回到首页、书架已关闭、不叠层 | ~90s |
| 21_night_buttons | 夜晚按钮作用域 | `home` / `open` 分别点夜晚 | 正文只切当前书、首页切全局，两者互不干扰 | ~120s |
| 22_home_hero_cache | hero 封面 / 刷新 / 缓存章节单选 / 翻章章节名同步 | `home` + 多个 flow | hero 封面正常、缓存单选四档互斥、翻章后章节名同步 | ~180s |
| 23_display_size | 界面字号三档 | `home` + `FLOW=display_size` + `XREAD_UI_SCALE` | compact/standard/large 三档重建均不溢出、不崩 | ~120s |
| 24_rotate | 横竖屏旋转 | `home` + `FLOW=rotate` | 两次重建都完成，尺寸记录在日志供人工核对 | ~120s |
| 25_layout_edge | 布局边界数据 | `home` + `FLOW=layout_edge`（假 books，不联网） | 超长书名/空作者/无封面/进度 0/跨页均不重叠 | ~90s |
| 26_shelf_paging | 全屏书架翻页 | `home` + `FLOW=shelf_paging` | 30 本 3 页前进后退不崩（Batch 4 封面内存回收主验收） | ~120s |
| 27_search_panel | 搜索加书入口 | `home` + `FLOW=search_panel` | 输入框 + 取消/搜索按钮弹出并可关闭，不发请求 | ~90s |
| 28_memory_low | 低内存档位 | `home` + `XREAD_MEM_TIER=low` | `tier=low` + `layers=1` + `cover_cache=false`，首页正常打开 | ~90s |
| 29_about_version | 关于本机后端版本 | `home` + 点更多 → 关于本机 | 「检测中」变为具体版本号，无 `showAboutPanel failed` | ~90s |
| 30_test_connection_status | 测试连接状态回写 | `home` + `FLOW=test_conn` | 成功后顶部立即变「已连接」，不等 60s 心跳 | ~90s |
| 31_quiet_update | 后台静默检查更新 | `home` | `update_checked newer=` 出现，无 `quiet update check failed` | ~90s |
| 32_book_night_footer | 书内夜晚页脚配色 | `open` + `FLOW=book_night` | `chrome_night dark=true`，页脚不留白条 | ~90s |
| 33_catalog_jump_range | 目录跳章范围 | `open` + `FLOW=diag_chapter` | `after_jump_<n> index=<n>` 落在当前文档范围，无 `chapter_index_out_of_range` | ~90s |
| 34_updater_ensure_dir | 更新器建目录 | `home` + `FLOW=updater_ensure_dir` | 相对/绝对路径都能建出 `a/b`，mode=directory | ~60s |
| 35_notice_no_auto_dismiss | 提示卡不自动消失（v0.6.33） | `home` + `FLOW=notice_demo` | 弹卡后静置 12s 无 `notice_closed`；点「知道了」后才出现同 id 关闭标记 | ~90s |
| 36_hero_title | 英雄卡长书名排版（v0.6.34） | `home` + `FLOW=hero_title`（书名换成「三国之蜀汉我做主」） | `flow=hero_title done ok=true`；截图人工复核书名在刷新图标下一行且完整 | ~90s |

## 运行方式

从 Windows 调用（推荐）：

```bash
# 大改动后发布：先重打包 zip，再跑全套，全 PASS 才交付
wsl.exe -d Ubuntu -u root -e bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/release.sh

# 只验证不改包
wsl.exe -d Ubuntu -u root -e bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/tests/run_all.sh

# 快速自检（改了 Lua 但不想跑模拟器）
wsl.exe -d Ubuntu -u root -e bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/tests/run_all.sh --quick

# 只跑某几个用例
wsl.exe -d Ubuntu -u root -e bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/tests/run_all.sh --only 03_toolbar 04_catalog
```

在 WSL 内直接跑：

```bash
bash /mnt/d/WorkBuddy/2026-11-22-00-23-49/xread-migration/tests/run_all.sh
```

## 判定规则

- **失败自动重试一次**：后端偶发挂起/环境抖动（如 KOReader 卡在加载被 240s 超时杀掉、截图 343B）会导致单次失败，`run_all.sh` 自动重跑该用例一次再判定；首次失败日志保留为 `<id>.attempt1.log`，SUMMARY 中标注"已重试2次"。

## autotest 环境变量

- `XREAD_AUTOTEST` = `shelf|open|home`：启动模式
- `XREAD_AUTOTEST_FLOW` = `panel|catalog|stats|shelf|home|cache|panel_stats`：进书后自动动作
- `XREAD_AUTOTEST_ONCE=1`：一次性触发（防重入）
- `XREAD_AUTOTEST_BOOK=<书名子串>`：open 模式优先打开指定书（书架顺序随机，避免撞上坏书/漫画）
- `XREAD_AUTOTEST_BOOK_IDX=<序号>`：open 模式指定打开第几本
- `XREAD_NO_TOC_SCAN=1`：关闭 footer 章节名 TOC 扫描
- 回退开关：`XREAD_SHELF_LEGACY=1`（旧书架）/ `XREAD_PANEL_LEGACY=1`（旧快捷面板）/ `XREAD_SHELF_CACHE=0` / `XREAD_COVER_ASYNC=0` / `XREAD_NO_PREFETCH=1`
- 每个用例 PASS 需同时满足：

1. 插件输出 `[XREAD_AUTOTEST] <tag> done` 验收标记（证明动作真执行了，不是靠截图体积猜）；
2. 截图文件 > 20KB（18KB 左右是 KOReader 卡在启动的失败态）；
3. 日志无 `UNHANDLED EXCEPTION` / `attempt to index nil` / `traceback` 等致命错误；
4. 用例专属断言（如 `tapped 目录`、`closed book cached to chapter`）。

**不算失败的环境噪音**：后端偶发 `bg cache chapter failed: 500`、源站损坏封面导致的 `failed rendering image (MuPDF)`（已有占位图 + 封面魔数校验兜底，TC-01 单独检查格式错误计数）。

## 坐标基准（1072×1448 原图，左上角 0,0）

| 元素 | 坐标 | 备注 |
|---|---|---|
| 工具栏「目录」图标 | (118, 313) | 功能区第 1 格 |
| 工具栏「书架」图标 | (918, 313) | 功能区第 4 格 |
| 书架第 1 本书封面中心 | (146, 345) | 4×3 网格第 1 格 |
| 书架翻页箭头 | (979, 1401) | 底栏右侧 |
| KOReader 顶端菜单 | (536, 60) | v0.6.1 起原生菜单无阅读X入口；引导进入书架改用 `emu_start "shelf"` |

> 截图查看软件常缩放到 808 宽，图上坐标 ×1.327 才是原图坐标。

## 已知坑（写测试脚本前必读）

1. **Trapper Paused 框**：后台任务（书架加载/开书抓章节）未结束时点击，会弹 `Paused / Continue / Abort`，后续点击全被吃掉。对策：用 `emu_wait_mark` 等插件标记 + `emu_settle` 等画面稳定，别用固定 `sleep` 后盲点。
2. **左上角 (60,50) 是 KOReader 主页图标**，不是空白区，点它会退回文件管理器。
3. **WSL 后台进程不跨 `wsl.exe` 调用存活**：所有点击与截图必须在同一个 `run_all.sh` 进程内完成。
4. **每轮启动前清状态**：`rm -f /tmp/xread_autotest_once /root/.config/koreader/history.lua`，否则会打开上次 quickstart 或不再触发 autotest。
5. **启动入口**必须是 `./lib/koreader/koreader.sh /root`，不是 `./bin/koreader`。

## 手动探针（不参与 run_all）

| 脚本 | 验证内容 | 备注 |
|---|---|---|
| `tests/probe_health_ui.sh` | 测试连接回执：成功「地址 + 耗时」，失败「地址 + 耗时 + 原因」 | 提示卡自 v0.6.33 起不自动消失，`XREAD_AUTOTEST_DELAY` 只用于等业务请求返回 |
| `tests/probe_update_ui.sh [confirm|full]` | 检查更新 → 唯一确认框「更新并重启」→ 安装进度 → 自动重启，`_meta.lua` 已换成包内版本 | `full` 需传 `TAP_OK_X/TAP_OK_Y`（确认框按钮坐标） |
| `tests/probe_auto_raw.sh` | 自动检查更新提示（本地 http.server 提供 filelist.json + 0.6.8 包，避开 NAS webdav 抖动） | 通过 `XREAD_UPDATER_URL` 走 raw 通道 |
| `tests/probe_remote_targz.sh [confirm|full]` | 远端 tar.gz 全链路：模拟器降级 0.6.6 → 列远端目录 → 确认框 → 下载/校验/解压 → 自动重启 | `full` 传 `TAP_OK_X=732 TAP_OK_Y=816` |
| `tests/probe_remote_targz_multi.sh` | 同上的多文件替换版本（0.6.6 包体 + 0.6.7 main.lua） | 旧版 updater 无超时，NAS 抖动时可能长时间无响应 |
| `tests/probe_targz_multi_local.sh` | 插件目录内 tar.gz 多文件替换（`changed=2 skipped=108`），不联网 | 需传 `NEW_PKG=<tar.gz 绝对路径>` |

## 归档说明

- 每次 `run_all.sh` 生成 `reports/<时间戳>/`，内含 `SUMMARY.md`（PASS/FAIL 表）、`*.emu.log`（KOReader 原始日志）、`*.case.log`（用例判定日志）、`*.png`（截图）。
- 历史调试脚本保留在 `wsl-setup/`（22 个），**不再维护**；新增/修改用例一律改 `tests/cases/`。
