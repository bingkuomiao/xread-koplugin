# 测试覆盖矩阵

> 用途：改动插件后，先看这张表判断「改了哪块 → 该跑哪几个用例」。
> 全部用例都在 WSL + KOReader SDL 模拟器（1072×1448 / dpi300）内跑，
> 入口 `bash tests/run_all.sh [--quick|--only <id> ...]`。

## 一、按功能域

| 功能域 | 覆盖内容 | 用例 |
|---|---|---|
| 静态质量 | 全部 `.lua` 可被 LuaJIT 解析 | 09_syntax |
| 交付一致性 | zip / 源码 / 部署三方 md5 完全一致 | 10_package_consistency |
| 书架 | 加载、网格、空/异常数据、翻页 | 01_shelf_smoke、25_layout_edge、26_shelf_paging |
| 首页 | 首屏渲染、hero 卡、刷新按钮、简介清洗、长书名排版 | 06_home、22_home_hero_cache、36_hero_title |
| 首页按钮 | 更新/搜索/同步/夜晚/设置 逐个点击 | 15a_home_buttons |
| 首页 ↔ 书架 | 进入书架、返回首页、不叠层 | 20_shelf_back、05_back_to_shelf |
| 开书 / 正文 | 点书进入、正文渲染、翻页 | 02_reading_open、14_full_flow_touch |
| 阅读工具栏 | 呼出、按钮布局、目录图标、返回书架 | 03_toolbar、08_toolbar_catalog_tap、15b_toolbar_buttons |
| 目录 | 打开、跳章、缓存态高亮、翻章后章节名同步 | 04_catalog、22_home_hero_cache（chapter_sync） |
| 更多菜单 | 我的书架/本地书架/首页管理/系统管理/升级管理/关于本机（v0.6.37 起 6 项） | 15c_more_menu |
| 设置面板 | 地址、账号、翻页、缓存章节数单选 | 22_home_hero_cache（settings / cache_none） |
| 阅读统计 | 统计页渲染 | 07_stats |
| 缓存 | 整本预缓存、未设置章节数时的引导、缓存失败常驻卡 | 15b_toolbar_buttons（cache）、22_home_hero_cache |
| 夜晚模式 | 首页全局 / 正文书籍级，两者互不干扰 | 21_night_buttons |
| 消息与弹窗 | 提示卡（不自动消失、按钮/✕ 关闭）、确认框、原生 ConfirmBox | 35_notice_no_auto_dismiss、22（msgbox/msgconfirm）、15c |
| 本地阅读 | 本地书列表、返回 | 15a（local_books / local_back） |
| 热更新 | zip / tar.gz / 本地包 / 列目录取最新 / 留存策略 / 静默检查 / 建目录 | 12、16、18、19、13、31_quiet_update、34_updater_ensure_dir |
| 封面接口 | 编码、鉴权、Referer、401 重登 | 17_cover_api |
| 界面字号 | standard / compact / large 三档布局 | 23_display_size |
| 屏幕旋转 | 横屏 ↔ 竖屏重建 | 24_rotate |
| 搜索加书 | 搜索输入框弹出/关闭 | 27_search_panel |
| 内存档位 | low 档：图层缓存 1 层 + 封面不进全局缓存 | 28_memory_low |
| 关于本机 | 后端版本从「检测中」更新为具体版本号 | 29_about_version |
| 测试连接 | 成功后顶部状态立即变「已连接」 | 30_test_connection_status |
| 触摸全流程 | 阅读X → 书架 → 开书 → 目录 → 跳章 → 返回 | 14_full_flow_touch |

## 二、按改动类型该跑什么

| 改了 | 至少跑 |
|---|---|
| 任意 `.lua` 语法/结构 | 09_syntax、10_package_consistency |
| `ui_scale.lua`、字号/间距常量 | 23_display_size、06_home、25_layout_edge |
| `home_view.lua` | 06_home、36_hero_title、22_home_hero_cache、15a_home_buttons、23 |
| `full_shelf_view.lua` / `shelf_grid.lua` | 01_shelf_smoke、25_layout_edge、26_shelf_paging、20_shelf_back |
| `catalog_view.lua` | 04_catalog、08_toolbar_catalog_tap、22（chapter_sync） |
| `reader_toolbar.lua` | 03_toolbar、15b_toolbar_buttons |
| `main.lua` 开书/跳章/缓存 | 02_reading_open、04_catalog、14_full_flow_touch、22 |
| `memory.lua` / 缓存策略 | 28_memory_low、26_shelf_paging、06_home |
| `updater.lua` / 打包脚本 | 12、16、18、19、13、10 |
| `cover_cache.lua` | 17_cover_api、06_home、22 |
| `showMoreListPanel` / 更多菜单增删条目 | 15c_more_menu、29_about_version（坐标按 `more_row` 日志解析） |
| `feature_quick_actions.lua` 本地书架（列表/封面/删除） | 37_local_shelf |
| `message_box.lua` / `showInfo` / 任何弹窗文案 | 35_notice_no_auto_dismiss、22（msgbox/msgconfirm）、15c_more_menu |

## 三、自动化测不到的部分（必须真机/人工）

| 项 | 原因 |
|---|---|
| 真实 e-ink 刷新残影 | Xvfb 瞬时重绘，没有残影累积 |
| 实际耗时/帧感 | 模拟器 CPU 比 PW3 快一个数量级 |
| 内存水位 | 宿主机 GB 级；低内存策略靠 `XREAD_MEM_TIER=low` 强制走分支，但真实 OOM 边界测不到 |
| 固件相关（前光、电源、休眠恢复） | 无固件层 |
| `isKindle()` 分支 | 模拟器 `model = Emulator` |
| 前端滑动惯性、长按手感 | 只有 `xdotool` 合成点击 |

## 四、新增用例说明（v0.6.28）

`23`~`28` 是为「覆盖所有基本功能」补的一批，全部不依赖后端可达性：

- **23_display_size**：`UiScale` 是唯一会改全局几何的开关（compact/standard/large 三套 font/icon/spacing 因子）。
  三档各重建一次首页，任何一档溢出/崩溃都会被抓到。
- **24_rotate**：横屏重建 + 竖屏还原。模拟器旋转行为与真机有差异，因此硬断言只要求
  「两次重建都完成」，尺寸记录在日志里供人工核对。
- **25_layout_edge**：直接喂假 books（超长书名、空作者、无封面、进度 0、13 本跨页），
  不碰网络。用于回归「占位封面文字压到进度徽标上」这类布局缺陷。
- **26_shelf_paging**：30 本 = 3 页，逐页前进再后退。这是 Batch 4 封面内存回收
  （旧 widget 树 `free()`）的主验收路径——翻页重建不崩即说明释放没踩到野指针。
- **27_search_panel**：只验 UI 弹出与关闭，不发请求，所以后端挂着也能跑。
- **28_memory_low**：`XREAD_MEM_TIER=low` 强制低内存档位，断言
  `tier=low` + `layers=1` + `cover_cache=false`，同时首页必须能正常打开。
  真机（PW3 512MB）走的就是这条路径，而模拟器本身永远不会自然触发。
- **29_about_version**：回归「关于本机」后端版本。根因是 `showAboutPanel` 用了
  `_scheduleNetJob`（弹层让路 → 面板本身就是弹层 → 请求永久挂起），改为直接
  `scheduleIn`；且未登录时静默补登录再取 `getVersionUpdate`。
- **30_test_connection_status**：回归「测试连接」成功后顶部状态。根因是 `testConnection`
  成功分支只弹提示、不回写 `_health_ok` 与 header，导致顶部要到下一轮 60s 心跳或手动刷新
  才变「已连接」。现在成功即回写。

## 五、与首页/阅读器的 flow 约定

- `XREAD_AUTOTEST=home|shelf|open|update|opentime|shelfback` → 决定启动后自动进哪个界面。
- `XREAD_AUTOTEST_FLOW=<name>`：
  - 已开书（`self.ui.document` 存在）时才跑的：`panel`、`catalog`、`settings`、`stats`、`more*`、
    `cache`、`chapter_sync`、`catalog_jump`、`reload`、`night_seq`、`msgbox` 等；
  - 首页上下文跑的（没有已开文档）：`display_size`、`rotate`、`layout_edge`、`shelf_paging`、
    `search_panel`、`memory_info`，入口 `XRead:_runHomeAutotestFlow()`。
- 所有验收标记形如 `[XREAD_AUTOTEST] flow=<name> ...`，只在这些环境变量存在时打印，生产无副作用。

## 六、v0.6.30 新增用例与 flow

- `32_book_night_footer`：书内夜晚（只改正文色）时页脚必须一起变深。
  断言 `chrome_night dark=true`，flow=`book_night`。
- `33_catalog_jump_range`：目录跳章后章节号必须落在当前文档范围内。
  flow=`diag_chapter`（默认跳到「当前章 + 100」，可用 `XREAD_DIAG_JUMP` 指定），
  断言打出 `after_jump_<n> index=<n>`，且日志中不得出现 `chapter_index_out_of_range`。
- `XREAD_DIAG=1` 打开详细诊断：章节表首尾标题、条目原始字段、页码→章节换算过程。
  （只在排查问题时打开，生产无副作用。）
- 15c_more_menu / 29_about_version 的点击坐标按 6 项更多面板更新
  （我的书架 495 / 地址管理 596 / 账号管理 697 / 首页管理 798 / 升级管理 899 / 关于本机 1000）。

## 七、v0.6.33 提示卡改造（不再自动消失）

- 背景：`showInfo` 原来按文案长度给 4/6/8s 的 timeout，长一点的错误原因没读完就没了；
  用户只能反复触发同一个错误去「抢读」。系统 `Notification` 小横幅同样一闪而过、字还小。
- 现状：所有结果类提示统一走 `MessageBox.show{ buttons={{text="知道了"}} , dismissable=false }`，
  出口只有两个——底部「知道了」按钮、右上角 ✕（返回键也保留）。点卡片外区域不再关闭。
- 过程提示仍会自动收起，但它们是「状态」不是「通知」：
  - `showConnectingToast`（正在连接…）→ 已从系统横幅改成同一套居中卡片，
    探活一出结论就由 `_hideConnectingToast()` 收起，失败则由失败卡接替；
  - 进度类（`ProgressToast`、`Trapper:info` 的「正在下载更新包/正在准备目录」）原地刷新，任务结束即收。
- 回归用例 `35_notice_no_auto_dismiss`：flow=`notice_demo` 弹一条提示 →
  静置 12s 断言日志中**没有**同 id 的 `notice_closed`（旧实现最长 8s 就消失）→
  按插件打印的 `box_geom btn1=x,y` 点「知道了」→ 断言同 id 的 `notice_closed` 出现。
  - 按钮坐标由 `message_box.lua` 在 `XREAD_AUTOTEST` 下打印，**不要手写坐标**：
    字号/DPI/文案行数一变就会点偏。
  - 相关日志标记：`notice_shown id=<n>`、`notice_closed id=<n>`、`box_geom ...`。

## 八、v0.6.34 英雄卡与更多面板

- 英雄卡书名不再和右上角刷新图标同行：图标独占第一行，书名下移一行并用满 `text_w`。
  8 字书名（三国之蜀汉我做主）不再折成「…我做」+「主」。
  `36_hero_title`（flow=`hero_title`）把书名换成长标题重排后截图，人工复核折行。
- 更多面板 7 项（新增「系统设置」= 点左上角「阅读X」同一入口）。
  关闭面板时补 `UIManager:setDirty("all","full")` —— 整屏面板关掉后只刷局部会在底部留残影，
  打开 KOReader 菜单时最明显。
- 更多面板在 `XREAD_AUTOTEST` 下打印 `more_row text=<标签> x=<x> y=<y>`：
  15c / 29 改为按标签取坐标，增删菜单项不必再改用例里的硬编码 y。

## 九、v0.6.35 详情去重与更多面板瘦身

- 英雄卡信息区按参考图重排：顶栏一行左边「最近阅读」、右边刷新图标（图标行独占，书名在其下一行）；信息行只有三行——`作者 · 来源` / `阅读至 N% · 时间` / `共 N 章 · 上次读到第 X 章`。
- 去重：`共 N 章` 原来在 `source_line` 和 `last_read_text` 各出现一次；`阅读至 N%` 与卡片底部「阅读进度 N%」+ 进度条也是同一句话。现在 `last_read_text` 置空不再单独成行，底部进度条整块删除，腾出的高度全部给简介（长简介多两行）。
  - 注意 `home_view.lua` 里 `last_line` 不能再兜底成「尚未阅读」，空串就该少一行。
- 更多面板 5 项：去掉「地址管理」「账号管理」（首页齿轮「设置」里各有入口），「系统设置」改名「系统管理」并移到「升级管理」之前。
  - `15c_more_menu` 跟着改成 5 项；`29_about_version` 仍按 `more_row` 日志取「关于本机」坐标。

## 十、v0.6.36 详情五行 + 字号行距 + 进度条回归

- 英雄卡详情五行顺序：作者 / 来源 / 最新 · 最新章节 / 阅读至 N% · 时间 / 上次读到第 X 章 · 共 N 章。
  - 作者与来源拆成两行（`hero.author_line` / `hero.origin_line`）；最新章节取后端 `latestChapterTitle`，缺失时退 `meta_cache:getChapters()` 最后一章。
- 字号 +1 档、行距 `.12` → `.26`；书名用 `height_adjust` 收到实际行数，简介起点改为「详情最后一行 / 封面底部」取更大值，剩余高度全给简介。
- 底部恢复进度条（只画条，没有「阅读进度 N%」文字）。
- 自动验收新增排版日志：`hero_geom ...`、`hero_intro y= h= rows_bottom= cover_bottom=`。调字号/行距后先看这两行，别靠截图猜简介还能放几行。

## 十一、v0.6.37 本地书架 + 近期阅读卡片回紧凑

- 「更多」增加「本地书架」，与首页底部「本地阅读」同一入口（同一个 `showLocalBooks`）；页面标题也从「本地阅读」改成「本地书架」，和菜单项一致。
- 本地书共享「我的书架」封面：
  - `BookExport:baseName()` 成了公开的文件名规则（导出路径与反查共用，改名时不会漏）。
  - 打开本地书架时先找随书封面 `<书名>.cover.png`；没有就按名字反查书架条目，用 `CoverCache:anyPathFor()` 扫已有缓存（不挑尺寸、不多发请求）；都没有才异步抓一次并落成随书封面。
  - 导出完成（`_doDownloadBook` 成功分支）也会顺手存一份，离线也有封面。
- 本地书删除：长按卡片 → 确认卡「删除本机这一份？」→ 删 EPUB + 随书封面 → 重开列表。只动本机文件，服务器与阅读进度不受影响。
- 近期阅读卡片：
  - 「最近阅读」改黑色、字号小一号，并按刷新图标那一行高度居中（同行对齐）。
  - 详情行距 `.26` → `.12` 行高、字号 10.6 → 9.8，信息块不再顶到封面下边缘以外；空间不够时先压 `meta_gap`（`hero_intro` 日志里的 `gap=`）。
  - 作者行加前缀「作者 · 」，和「最新 · 」「阅读至 」同一写法。
- 其它文案：正文设置「同步管理」改为「进入书籍拉取进度 / 退出上传进度」，删掉两行解释小字；发现新版本弹窗按钮「去更新」→「更新」。
- 自动验收踩坑：`message_box` 的 `box_geom` 每个按钮打一行，用例取坐标必须 `grep btn1=`，`tail -1` 拿到的是 btn2；另外 stdout 重定向到文件是块缓冲，打印后要 `io.stdout:flush()`，否则用例运行中 grep 不到（进程被杀才落盘）。

## 十二、v0.6.39 Batch 4：刷新合并 / 延迟任务去抖 / 封面缓存预算

- **合并同一交互内的多次标脏**：`xread/miui/repaint.lua` 新增 `paint(key, mode, rect, window)`，
  默认 120ms 窗口内同 key 请求合并，`full` 优先于 `ui`、区域取并集，窗口末统一发一次标脏。
  接入两处已知重复路径：`dialog_transition` 的连续三个 tick（旧框 → 动作后新框 → 并集），
  以及 `message_box` 的「关旧框 / 开新框 / sticky 补全刷」三条同 key 请求。
  没有把 `setDirty` 同步降级成 `ui`——KOReader 同一事件循环本来就会合并；也不需要把
  full 降成 ui 留下残影。
- **scheduleIn 去抖**：`repaint.debounce` 增加取消/执行计数；首页切节的 2.8s「补一次全刷」
  从手写 `scheduleIn` + `unschedule` 迁到 `Repaint.debounce("home.clean.<widget>")`，
  并在两个关闭路径补 `Repaint.cancel`，快速连切页签只保留最后一次全刷。
- **封面解码预算**：`Memory.cover_do_cache()` 不再只按内存档位开关，而是额外给全局
  ImageCache 一个 16 张（约两页）的额度；用完的封面改由 widget 持有，`free()` 时回收。
  `XREAD_MEM_TIER=low` 时额度为 0。注意 `describe()` 用的是非消耗式查询，不能在这里扣额度。
- **真机验证口径**（WSL 测不出 e-ink 黑闪与内存占用，只能看门限）：
  - `38_batch4` 起两遍首页，正常档日志 `memory tier=normal ... cover_cache=true budget=9/7`
    （首页已经用掉 7 张，剩余 9 张，总额度 16），低内存档 `budget=0/16`；两遍都要求无 fatal、截图非空。
  - 真机开 `XREAD_PERF_LOG=1`，连点页签/连开关弹窗后看 `[XRead][Perf]` 行：
    `paint merge key=...` 出现、`paint flush ... merged=N` 的 N>0；
    再核对 `[XREAD_AUTOTEST] perf ... full merged=` 不为 0（自动构建时会打印）。
  - 真机上重点看「连切页签是否还黑闪多次」「长会话后内存是否还在涨」；合并器只改刷新
    次数与缓存额度，不改像素，布局回归仍以 01/03/04/06/07 的截图逐像素比对为准。
