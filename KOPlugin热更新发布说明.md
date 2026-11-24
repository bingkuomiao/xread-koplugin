# xread.koplugin 热更新发布说明（v0.5.7 起，仅 manifest2 规范包模式）

> 适用：飞牛 fpk 后端 + KOReader 阅读X插件。最后更新：2026-11-24
> 目标：**每次只产出一个规范命名的 zip 包，放到服务端后，真机在「关于本机 → 检查更新」点击即可热更新**。

---

## 一、服务端目录与文件

NAS（飞牛应用）上的 WebDAV 用户目录：

```
/var/apps/xread/var/data/webdav/bingkuomiao/plugin/
├── manifest2.json                                  ← 指向规范包
├── xread.koplugin_v0.5.9_20261124-204241.zip       ← 规范命名的完整插件包（热更新用）
```

> **服务端只保留当前这一个规范包**：`publish_update.py` 上传后会自动清理更早的 `xread.koplugin_v*.zip`，避免同名同版本多次发布后分不清哪一个在生效（当前包始终是 `manifest2.json` 指向的那个）。设备端的历次包则单独留档，见第四节。

插件通过带鉴权接口下载：

```
GET /reader3/getWebdavFile?path=/plugin/<文件>&accessToken=<token>
```

- token 失效（401/403）自动用配置里的账号密码重登一次；
- 不依赖后端版本，任何 reader3 后端都可用；
- 插件只读 `manifest2.json`，下载规范 zip 整包后按文件级 md5 增量替换；旧散文件升级路径已移除。

## 二、压缩包命名规范

```
xread.koplugin_v<版本号>_<YYYYMMDD-HHMMSS>.zip
例：xread.koplugin_v0.5.9_20261124-204241.zip
```

- 插件名：`xread.koplugin`
- 版本号：与插件 `_meta.lua` 的 `version` 一致
- 时间：打包时刻（24 小时制），保证唯一、可追溯
- zip 内部根就是插件目录内容（`main.lua`、`_meta.lua`、`xread/…`），解压后直接覆盖插件根目录

## 三、每次发新版本怎么做（三步）

### 1. 改代码后升版本号

编辑 `xread.koplugin/_meta.lua`：

```lua
version = "0.5.9",
```

> 版本号必须比线上大，否则插件判定"没有新版本"。

### 2. 生成规范包 + 发布到 NAS

在有 Python3 + ssh 的电脑上（项目根目录 `xread-migration/`）：

```bash
# 一条命令：源码打包 + manifest2.json + 上传 NAS + 线上校验
python3 publish_update.py --notes "本次更新说明" --ssh root@192.168.31.51 --ssh-port 2233
```

如果手里已有规范命名的 zip（例如别人打好的包），直接发布它：

```bash
python3 publish_update.py --zip xread.koplugin_v0.5.9_20261124-204241.zip \
    --ssh root@192.168.31.51 --ssh-port 2233
```

脚本会自动：识别包内版本 → 统一规范命名 → 生成 `manifest2.json`（含包名/大小/md5）→ tar over ssh 上传（fnOS 禁用 scp）→ 清理服务端旧散文件 → 设置属主 `docker-xread`。

### 3. 真机点击更新

KOReader → 顶部菜单「工具 → 阅读X · 更多 → 关于本机 → 检查更新」→ 确认 → 自动下载并应用 → 重启生效。

## 四、插件端热更新流程

```
检查更新
  └─ 读 manifest2.json（无回退路径）
       ├─ 语义版本号比较：远端 > 本地？
       └─ 下载规范 zip（一次请求）
            ├─ 校验 size + md5
            ├─ 用 KOReader 自带 ffi/archiver 解压（不依赖外部 unzip）
            ├─ 落到 <数据目录>/xread_update/<包名>/（与 zip 同名同级）
            ├─ 逐文件 md5 与本地比对：相同跳过，不同写 .xup_tmp 后原子替换
            ├─ 校验包内 _meta.lua 版本与 manifest 一致（防错包）
            └─ 全部成功才落盘本地清单；失败保留已完成文件，下次重试
```

- 增量：虽然下载的是一个整包（当前 v0.5.9 约 186KB），但**只写变化的文件**，不重复写入 100 多个相同文件；
- 安全：路径校验禁 `..` 与隐藏文件；md5 不符不替换；
- 无弹窗静默检查在插件启动时进行，交互入口在「关于本机」。

### 更新包在设备上的落盘位置（v0.5.8 起）

每次更新的压缩包与解压目录都**按包名单独留档**，同级存放，多次更新不会互相覆盖、事后能分辨是哪一版：

```
<KOReader 数据目录>/xread_update/
├── packages.txt                                  ← 已安装包名索引（按时间先后，只留最近 3 条）
├── xread.koplugin_v0.5.9_20261124-204241.zip      ← 下载到的原始压缩包
└── xread.koplugin_v0.5.9_20261124-204241/         ← 与压缩包同名、同级的解压目录（完整 110 文件）
    ├── _meta.lua
    ├── main.lua
    └── xread/…
```

- 目录名 = 压缩包名去掉 `.zip`，两者**同级**；想确认某次更新装了什么，直接进对应目录看即可；
- 只为最近 **3 次**更新留档（含压缩包与解压目录），更早的自动清理，避免占满设备存储；
- 更新失败时**压缩包与解压目录都保留**（不写本地清单，下次重试），便于排查；
- 更新完成的提示框会显示本次包名目录，例如「更新包已留存：xread_update/xread.koplugin_v0.5.9_.../」。

> 老版本插件（≤v0.5.7）会把包下载成 `xread_update_<版本>.zip` 并在应用后删除，升级到 v0.5.8 后即按新规则留档。

## 五、版本变更记录

### v0.5.9（2026-11-24）
- **后台缓存移入子进程**：逐章抓取用 `ffi/util.runInSubProcess` fork 执行，进度经原子 rename 的进度文件回传，主进程每 1.2s 只读文件——缓存期间（哪怕 200 章）翻页、呼工具栏全程即时响应；fork 不可用自动降级旧同步路径。
- **修复手动缓存"复活"已收起工具栏**：缓存进度回写位置提示时不再重建面板（此前每 1.2s 把 closed 置回 false 拦截点击，表现为"点了没反应"）。
- **目录页预加载高亮**：已缓存章浅灰底（夜间模式自适应 GRAY_3+白字，反色后浅底黑字）、正在缓存章黑底白字加粗、当前章反白加粗标注"上次读到"。
- **菜单合并**：「阅读X」直接弹出原「更多」页；删「阅读X · 更多」；进度百分比后的阅读记录按钮移除。
- **正文工具栏**：更多=我的首页弹层；齿轮=书籍设置面板（自动缓存章数 ± 1-200、字号 ± ，即改即存）；百分比去箭头。
- **弹窗可关**：服务器/账号/书籍设置面板标题行统一加 ✕（点击分区会抢全屏 tap，必须保留可见关闭按钮）。
- **导航**：首页 › 进书架页、书架第一页返回回首页、书架内翻页；首页夜晚按钮=切夜间模式（月/日图标互换）；开书/跳章/目录全静默。
- 默认自动缓存章数 30 → 3（已有用户设置不受影响）。

### v0.5.8（2026-11-24）
- 热更新改规范 zip 包模式：manifest2.json 指向整包，插件下载后 ffi/archiver 解压 + 文件级 md5 增量替换。

## 六、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 检查更新提示"已是最新" | ① 版本号没升；② 服务端 `manifest2.json` 未更新；③ 本地 `xread_update_manifest.json` 缓存了旧清单——删掉重试 |
| 提示无法获取更新清单 | 没上传 manifest；或账号密码变了导致 401（插件会自动重登一次） |
| 老插件（v0.5.7 前）更新失败 | 老版本升级兼容代码已移除，需手动安装新版插件；新版本起统一走 manifest2 规范包 |
| 提示固件不支持 zip 解压 | 需要 KOReader 内置 `ffi/archiver`（ArchiveViewer 插件依赖，正常固件都有） |
| 上传失败 | fnOS 禁 scp；脚本用 tar over ssh。确认 SSH 端口（本机 2233）与 root 权限 |

## 七、相关文件

| 文件 | 作用 |
|---|---|
| `xread.koplugin/xread/updater.lua` | 插件端：manifest2 zip 下载/校验/解压/文件级 md5 增量替换 |
| `publish_update.py` | 发布端：规范命名、生成 manifest、打包、上传、线上 md5 校验 |
| `_meta.lua` | 版本号唯一事实来源 |
| `tests/cases/12_update_zip.sh` | 规范 zip 包更新回归用例（本地 http.server 模拟，不依赖 NAS），并校验同名解压目录 |
| `tests/cases/13_package_retention.sh` | 包留存策略用例：预置 4 个历史包，验证只保留最近 3 次 |
| `wsl-setup/webdav_e2e.sh` | 真实 NAS 端到端：本地降级 → 走 webdav 更新 → 校验版本/文件/落盘结构 |
| `release.sh` | 重打包 + 全套回归 + 生成发布目录 |

## 八、验证命令

```bash
# 只校验线上清单与全部文件 md5（不下载源码）
python3 publish_update.py --check

# 本地模拟 zip 热更新全流程（WSL Ubuntu）
bash tests/run_all.sh --only 12_update_zip 13_package_retention

# 真实 NAS 端到端（需先 python3 publish_update.py --ssh ... 上传）
bash wsl-setup/webdav_e2e.sh 0.5.7     # 参数=把本地降级到的版本

# 查看线上 manifest2
# 浏览器/接口：GET /reader3/getWebdavFile?path=/plugin/manifest2.json&accessToken=<登录token>
```
