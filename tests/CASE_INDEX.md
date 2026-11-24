# xread.koplugin 测试用例归档

> 目的：每次大改动后跑同一套用例，结果可比对、截图可回溯。
> 所有脚本在 **WSL Ubuntu** 内运行，路径以本目录（`xread-migration/tests/`）为基准。

## 目录结构

```
tests/
├── CASE_INDEX.md          本文件：用例索引 + 判定规则 + 坐标基准
├── lib/common.sh          公共库：模拟器启停、验收标记等待、断言、截图
├── cases/01..13/*.sh      12 个独立用例（12=规范 zip 更新，13=包留存策略；11 旧散文件用例已移除）
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
| 12_update_zip | 规范 zip 包热更新 | `update` + manifest2.json + zip | `newer=true`、下载 zip 解压后本地版本变为测试版本；解压到 `xread_update/<包名>/`、同名 zip 同级留存 | ~90s |
| 13_package_retention | 更新包留存与清理 | `update` + 预置 4 个历史包 | 新包落 `xread_update/<包名>/`；索引只留 3 条；最旧 p1/p2 的目录与 zip 被清理，p3/p4 保留 | ~90s |

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
| KOReader 顶端菜单 | (536, 60) | 工具标签约 (340, 50)，阅读X约 (133, 133) |

> 截图查看软件常缩放到 808 宽，图上坐标 ×1.327 才是原图坐标。

## 已知坑（写测试脚本前必读）

1. **Trapper Paused 框**：后台任务（书架加载/开书抓章节）未结束时点击，会弹 `Paused / Continue / Abort`，后续点击全被吃掉。对策：用 `emu_wait_mark` 等插件标记 + `emu_settle` 等画面稳定，别用固定 `sleep` 后盲点。
2. **左上角 (60,50) 是 KOReader 主页图标**，不是空白区，点它会退回文件管理器。
3. **WSL 后台进程不跨 `wsl.exe` 调用存活**：所有点击与截图必须在同一个 `run_all.sh` 进程内完成。
4. **每轮启动前清状态**：`rm -f /tmp/xread_autotest_once /root/.config/koreader/history.lua`，否则会打开上次 quickstart 或不再触发 autotest。
5. **启动入口**必须是 `./lib/koreader/koreader.sh /root`，不是 `./bin/koreader`。

## 归档说明

- 每次 `run_all.sh` 生成 `reports/<时间戳>/`，内含 `SUMMARY.md`（PASS/FAIL 表）、`*.emu.log`（KOReader 原始日志）、`*.case.log`（用例判定日志）、`*.png`（截图）。
- 历史调试脚本保留在 `wsl-setup/`（22 个），**不再维护**；新增/修改用例一律改 `tests/cases/`。
