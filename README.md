# xread.koplugin

KOReader 阅读插件：把本地 xread/reader3 后端（飞牛 NAS 上的阅读服务）的书架、阅读、目录、缓存和阅读记录接入 KOReader，并移植了 miuread 的 MIUI 风格书架/首页/阅读工具栏视觉层。

当前版本：**v0.5.9**（110 文件）。热更新仅支持 `manifest2.json` + 规范 zip 整包模式，旧散文件升级兼容代码已移除。

## 目录结构

```
xread.koplugin/       插件本体（直接复制到 KOReader 的 plugins/ 目录即可安装）
  main.lua            入口：菜单、书架、首页、阅读器集成、后台缓存
  _meta.lua           版本号唯一来源
  xread/              数据层 + 视觉层（client / cache / catalog / miui/ 等）
  resources/          图标资源
publish_update.py     生成规范 zip + manifest2.json 并发布到 NAS（tar over ssh）
release.sh            重打包 + 全套模拟器回归 + 生成发布目录
make_test_kit.py      打包分发用测试包
tests/                12 项回归用例（书架/开书/工具栏/目录/首页/记录/更新/包留存/语法/一致性）
wsl-setup/            WSL 模拟器环境脚本与 NAS 端到端验证
KOPlugin热更新发布说明.md
WSL2模拟测试指南.md
HANDOFF.md            项目交接与实现细节
反馈清单-v0.5.9.md    第 13 批用户反馈的修复记录
```

## 安装

1. 把 `xread.koplugin/` 整个目录复制到 KOReader 的 `plugins/` 下。
2. 重启 KOReader，顶部菜单 → 工具 → 阅读X，进入后先到「设置」填写后端地址、账号、密码。
3. 从「我的首页」或「我的书架」选书阅读。

## 本地开发 / 回归测试

环境：WSL Ubuntu + KOReader 模拟器（详见 `WSL2模拟测试指南.md`）。

```bash
# 全量：重打包 zip → 部署 → 跑全部用例 → 生成发布目录
bash release.sh

# 只验证不重打包
bash tests/run_all.sh
bash tests/run_all.sh --quick
bash tests/run_all.sh --only 03_toolbar
```

回归报告（含日志和截图）输出到 `tests/reports/<时间戳>/`。

## 发布热更新

```bash
cp .publish_env.example .publish_env   # 填入真实 NAS 凭据（已在 .gitignore 中，不会提交）
python3 publish_update.py --notes "本次更新说明" --ssh <用户>@<NAS地址> --ssh-port <端口>
python3 publish_update.py --check      # 校验线上清单与 zip 包
```

凭据也可以直接用环境变量 `XREAD_NAS_HOST` / `XREAD_NAS_USER` / `XREAD_NAS_PASS` / `XREAD_NAS_REMOTE_DIR` 提供；环境变量优先于 `.publish_env`。

发布目录只产出两个文件：`manifest2.json` 和 `xread.koplugin_v<版本>_<时间戳>.zip`。上传时会清理服务端旧散文件与过期规范包。

> 注意：每次发布必须先在 `xread.koplugin/_meta.lua` 升版本号，否则插件判定 `newer=false` 不提示更新。
