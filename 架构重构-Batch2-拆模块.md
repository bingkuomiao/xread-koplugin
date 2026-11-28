# Batch 2：main.lua 拆模块（v0.6.31）

## 目标

v0.6.30 时 `main.lua` 有 **7760 行 / 143 个方法**，改一处要在一屏里找半天，
新人（包括未来的我）看代码先要读 7000 行才知道「首页在哪、书内设置在哪」。
本轮把它按职责拆开，**行为零变化**，只搬代码 + 显式化依赖。

## 结果

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `main.lua` | 7760 → **3277** | 类定义、init、菜单、开书、后台缓存、目录、书架、工具栏接线 |
| `xread/feature_menus.lua` | 1764 | 更多面板、首页管理、升级管理、关于本机、热更新、地址/账号/书架管理、首页设置 |
| `xread/feature_quick_actions.lua` | 1018 | 快捷面板里的各动作（换章/换书/目录/缓存/夜间/排版） |
| `xread/feature_home.lua` | 845 | miuread 首页（最近阅读、操作行、分类页签、书架预览） |
| `xread/feature_book_settings.lua` | 568 | 书内设置面板、排版偏好、进度同步 |
| `xread/feature_book_cache.lua` | 485 | 移除书籍、整本预缓存、漫画下载打包 |
| `xread/shared.lua` | 34 | 跨实例运行时状态单例（原 main.lua 里的 `SHARED`） |

## 做法

### 1. SHARED 提成模块

`SHARED` 原本是 main.lua 的模块级 local，但它是「跨插件实例」的进程内状态
（FileManager 一个实例、ReaderUI 另一个实例）。提成 `xread/shared.lua` 后：

- 语义更明确：`require("xread.shared")` 明确表示「这是共享状态，不是配置」；
- 为拆模块铺路：feature 模块也要读写同一份，靠 require 拿到的必然是同一张表。

顺带把 `ZH_MODE`（简繁模式）也收进 `SHARED.zh_mode`：拆模块后 `zhText()` 留在
main.lua、`applyZhConvert()` 去了 book_settings，两者必须看到同一个值，
放在模块级 local 里就会各看各的。

### 2. feature 模块用 `install(env)` 注入，而不是环境表 hack

每个 feature 文件长这样：

```lua
local M = {}
function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local fileSize = env.fileSize      -- main.lua 的私有小工具
    -- 原来的方法定义原样搬进来
end
return M
```

main.lua 在原来的位置换成：

```lua
require("xread.feature.home").install{ XRead = XRead, SHARED = SHARED, BackendProbe = BackendProbe }
```

为什么不用 `setfenv` / 全局表那种「看起来更省事」的办法：

- `setfenv` 会把 7000 行代码的依赖变成隐式的，出错时只报 `attempt to call
  global 'xxx'`，根本不知道是谁没传；
- 显式 `install{...}` 一眼能看出这个模块到底依赖 main 的什么，加依赖必须改调用点，
  漏了在语法检查阶段就能看出来。

方法仍然挂在**同一个 XRead 类**上（`function XRead:foo()` 在 install 里定义，
写的是 `env.XRead` 这张表），所以 `self:showSettings()` 这类跨文件调用完全不用改。

### 3. 依赖边界怎么定的

拆之前先做了一次静态统计：按 `-- ----------` 分区，数每段引用了多少 main.lua 的
顶层局部量。规则是：

- **通用依赖**（`UIManager` / `Screen` / `MessageBox` / `gettext` …）由 feature
  文件自己 `require`，不走 env；
- **main.lua 私有小工具**（`fileSize` / `hotReload` / `pageChapterIndex` /
  `chapterBlock` / `readable_error` / `bookCacheStem` …）通过 env 显式传；
- **段内独占的局部量**（`BOOT_TARGETS` / `UPDATE_PERIODS` / `PAGE_MODE_TEXT` /
  `CLOUD_PROGRESS` / `HOME_REBUILD_MIN_INTERVAL` …）跟着代码一起搬走，
  拆完逐个核对过：这些名字在别的文件里零引用。

## 验证

- `luajit -e "assert(loadfile(...))"` 逐文件语法检查；
- 段内局部量泄漏检查：对每个被搬走的名字统计「出现在几个文件」，全部只在自己文件里
  （`BG` / `stopBg` 例外，它们是 main 注入的，符合预期）；
- 全量自动验收（34 项）：见本轮报告 `tests/reports/`。

## 升级事故与修正（v0.6.32）

v0.6.31 用了 `xread/feature/` 这个**新目录**，结果 0.6.29 设备升级时报：

```
失败：以下文件更新失败：xread/feature/book_cache.lua（无法写入）xread/feature/b...
```

根因在 `updater.lua` 的 `ensureDir`：它把路径当绝对路径处理——`cur` 从 `""` 开始
拼 `"/"`，而且**第一段不创建**。只要 `plugin_root` 是相对路径（KOReader 以相对
路径启动时就是这样），它就会去 `mkdir "/plugins/..."`，父目录不存在必然失败。
表现就是「新增目录里的文件全部无法写入，已有目录里的文件照常更新」。

两处修正：

1. `ensureDir` 改用 KOReader 自带的 `util.makePath`（它自己区分绝对/相对，从最近的
   已存在祖先逐级 mkdir），并返回布尔值；建目录失败与写文件失败分开报错，
   不再一律显示「无法写入」。
2. 5 个 feature 模块改成扁平命名 `xread/feature_*.lua`，**这一版升级不再需要任何新目录**，
   已经卡在 0.6.29/0.6.30 的设备可以直接升上来。

回归用例 `34_updater_ensure_dir`：相对路径与绝对路径都必须真的建出多级目录。
另做了端到端验证：用 git 里的 0.6.29 源码部署→放真实 0.6.32 包→本地升级，
版本变 0.6.32、6 个新模块全部落盘、日志无写入失败。

## 还没做的（Batch 3）

- 合并 5 份 `TapBox`、3 份 `OffsetContainer`；
- 两套 hero 布局、三套封面卡合并成一套参数化实现；
- `main.lua` 里「开书 / 后台静默缓存 / 目录」三块还能再各拆一个模块
  （依赖面较宽，牵连 `BG`、`startBg`、`stopBg` 这套后台任务状态，留到下一轮）。
