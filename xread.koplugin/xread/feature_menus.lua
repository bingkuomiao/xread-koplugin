-- xread.koplugin/xread/menus.lua
-- 「更多」面板 / 首页管理 / 升级管理 / 关于本机 / 热更新 / 地址与账号管理 / 首页设置。
--
-- 从 main.lua 拆出（Batch 2）。方法仍挂在同一个 XRead 类上：install(env) 只是
-- 把 main.lua 的私有小工具（now_ms / readable_error / display_address / PAGE_MODES）
-- 传进来，不复制实现，也不依赖全局变量。
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local Device = require("device")
local Screen = require("device").screen
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local MiuiHome = require("xread.miui.home_view")
local UICommon = require("xread.ui_common")
local MessageBox = require("xread.message_box")
local BackendProbe = require("xread.backend_probe")

local M = {}

function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local now_ms = env.now_ms
    local readable_error = env.readable_error
    local display_address = env.display_address
    local PAGE_MODES = env.PAGE_MODES

    function XRead:showMorePanel()
        -- 「翻页管理」从这里移除了：它并进首页齿轮「设置」的翻页管理分组。
        -- 同一功能保留两个入口，用户会在两份列表里各点一遍。
        -- 「地址管理」「账号管理」从这里移除了：两者在首页齿轮「设置」里都有入口，
        -- 同一功能两处入口，用户会在两份列表里各点一遍。
        -- 「系统管理」= 点左上角「阅读X」的同一个入口（KOReader 自身菜单），
        -- 给「不想去点标题」的用户留一条明路；位置紧贴升级管理之前（都是「本机维护」类）。
        self:showMoreListPanel(_("更多"), {
            { label = _("我的书架"), callback = function() self:openShelf() end },
            -- 「本地书架」= 首页底部「本地阅读」按钮的同一入口（本机导出的 EPUB）。
            -- 放在「我的书架」后面：两者都是书架，先云端再本地。
            { label = _("本地书架"), callback = function() self:showLocalBooks() end },
            { label = _("加载管理"), callback = function() self:showBootManage() end },
            { label = _("系统管理"), callback = function() self:openReaderMenuFromHome() end },
            -- 「升级管理」已从更多页移除：检查更新统一走「关于本机」，
            -- 自动检查的周期沿用上次设置，不再单独给一个入口。
            { label = _("关于本机"), callback = function() self:showAboutPanel() end },
        }, { hint = _("点击条目进入；点空白处返回。") })
    end

    -- ---------- 首页管理：开机后自动进入哪个界面 ----------
    -- 三选一：我的首页 / 我的书架 / 原生界面（进入 KOReader 文件管理器）
    -- 文案只留「名字 + 一句说明」：右侧说明只在真有补充信息时才写，
    -- 避免出现「默认」「直接进书架网格」这类和左边重复的废话。
    local BOOT_TARGETS = {
        { key = "home",     label = _("我的首页"), desc = nil },
        { key = "shelf",    label = _("我的书架"), desc = nil },
        { key = "koreader", label = _("进入 KOReader"), desc = _("原生界面") },
    }

    function XRead:bootTarget()
        local v = tostring(self:getSetting("boot_target", "home") or "home")
        for _i, t in ipairs(BOOT_TARGETS) do
            if t.key == v then return v end
        end
        return "home"
    end

    function XRead:showBootManage()
        local cur = self:bootTarget()
        local items = {}
        for _i, t in ipairs(BOOT_TARGETS) do
            local key = t.key
            items[#items + 1] = {
                label = (key == cur and "● " or "○ ") .. t.label
                    .. (t.desc and ("　" .. t.desc) or ""),
                callback = function()
                    self:saveSetting("boot_target", key)
                    self:showBootManage()   -- 重建回显当前选择
                end,
            }
        end
        self:showMoreListPanel(_("首页管理"), items, {
            hint = _("开机后自动进入的界面，下次开机生效。"),
        })
    end
    -- 开机时自动进入：等 FileManager 首帧画完再切，避免被它的首帧盖住。
    -- 验收脚本（XREAD_AUTOTEST）自己控制进入方式，这里不抢。
    function XRead:applyBootTarget()
        if os.getenv("XREAD_AUTOTEST") then return end
        if self._boot_applied then return end
        self._boot_applied = true
        local target = self:bootTarget()
        if target == "koreader" then return end

        local function go()
            -- 已经进正文 / 用户已经点开了别的东西：不抢
            if SHARED.open_path or self._opening_book then return end
            if self._home_view or self._shelf_view then return end
            -- 此时栈顶应该是 FileManager 自己（self.ui）；别的 widget 在上面说明
            -- 用户已经打开了菜单/对话框，这次就不自动跳了
            local top = UIManager:getTopmostVisibleWidget()
            if top and top ~= self.ui then return end
            if target == "shelf" then
                self:openShelf()
            else
                self:openHome()
            end
        end
        UIManager:scheduleIn(1.5, go)
    end

    -- ---------- 在线热更新 ----------
    -- 首页第一屏（含封面）画完再弹更新提示。
    -- 原来固定 10s 后直接 showInfo，常和封面队列 / 首页重绘撞在一起，
    -- 提示一闪就被盖掉，看起来像「没提醒」。现在最多等 25s，队列一结束就弹。
    function XRead:_notifyUpdateWhenHomeReady(attempt)
        attempt = tonumber(attempt) or 0
        if SHARED.open_path or self._opening_book or not MiuiHome.is_shown() then
            self._update_pending_notice = true
            return
        end
        if self._home_covers_busy == true and attempt < 25 then
            UIManager:scheduleIn(1, function() self:_notifyUpdateWhenHomeReady(attempt + 1) end)
            return
        end
        UIManager:nextTick(function() self:notifyUpdateAvailable() end)
    end
    -- 自动检查发现新版本时的提示（同一版本只提示一次，由 _update_notified 去重）
    -- 用置顶卡片（不自动消失），避免被首页的下一次刷新盖掉；
    -- 安装入口仍是「更多 → 关于本机 → 检查更新」，这里只做提醒。
    function XRead:notifyUpdateAvailable()
        local info = self._update_info
        if not info or not info.newer then return end
        local via_local = tostring(info.via or "") == "local"
        -- 一句话说清「有新版本 / 在哪」；更新说明不再塞进弹窗（点「去更新」看关于页）
        local text = via_local
            and T(_("插件目录里已备好新版本 %1，更新后自动重启。"),
                tostring(info.remote_version or ""))
            or T(_("发现新版本 %1（当前 %2）。"),
                tostring(info.remote_version or ""), tostring(info.local_version or ""))
        local notice
        notice = MessageBox.show{
            title = _("发现新版本"),
            text = text,
            sticky = true,
            buttons = {
                { text = _("更新"), bold = true,
                  -- 直接进升级确认框，不再绕去「关于本机」让用户找「检查更新」。
                  -- 必须先收掉这张 sticky 卡：否则 MessageBox.show 的 sticky 单实例
                  -- 保护会把紧随其后的确认框整个吞掉。
                  callback = function()
                      if notice then pcall(function() notice:close() end) end
                      if info.newer and self._update_manifest then
                          UIManager:nextTick(function() self:confirmUpdate() end)
                      else
                          self:showAboutPanel()
                      end
                  end },
                { text = _("稍后"), callback = function() end },
            },
        }
    end
    -- ---------- 升级管理：自动检查周期 ----------
    -- 一小时 / 一天 / 一周 / 启动时（默认一天）。周期只管「自动检查」，
    -- 手动「检查更新」不受影响。周期改完立即重排下一次检查。
    local UPDATE_PERIODS = {
        { key = "1h",   label = _("一小时") },
        { key = "1d",   label = _("一天") },
        { key = "1w",   label = _("一周") },
        { key = "boot", label = _("启动时") },
    }
    local UPDATE_PERIOD_SECONDS = { ["1h"] = 3600, ["1d"] = 86400, ["1w"] = 7 * 86400 }

    function XRead:updateCheckPeriod()
        local v = tostring(self:getSetting("update_period", "1d") or "1d")
        for _i, p in ipairs(UPDATE_PERIODS) do
            if p.key == v then return v end
        end
        return "1d"
    end

    function XRead:showUpdateManage()
        local cur = self:updateCheckPeriod()
        local items = {}
        for _i, p in ipairs(UPDATE_PERIODS) do
            local key = p.key
            items[#items + 1] = {
                label = (key == cur and "● " or "○ ") .. p.label,
                callback = function()
                    self:saveSetting("update_period", key)
                    self:_scheduleNextUpdateCheck()
                    self:showUpdateManage()   -- 重建回显当前选择
                end,
            }
        end
        self:showMoreListPanel(_("升级管理"), items, {
            hint = _("自动检查新版本的周期；发现新版才提示。"),
        })
    end
    -- 书架/首页显示后错峰静默检查新版本（失败完全无声，仅首次发现时提示一次）
    function XRead:quietUpdateCheck(delay)
        if os.getenv("XREAD_NO_UPDATER") == "1" then return end
        -- 首页会反复重建，别每次都发一遍列目录请求：整个会话只起一条检查链
        if self._update_check_started then return end
        self._update_check_started = true
        self._update_checked = true
        UIManager:scheduleIn(delay or 10, function() self:_runUpdateCheck() end)
    end

    --- 按「升级管理」里的周期排下一次自动检查（「启动时」= 不重复）
    function XRead:_scheduleNextUpdateCheck()
        if os.getenv("XREAD_NO_UPDATER") == "1" then return end
        if self._update_timer then
            pcall(function() UIManager:unschedule(self._update_timer) end)
            self._update_timer = nil
        end
        local secs = UPDATE_PERIOD_SECONDS[self:updateCheckPeriod()]
        if not secs then return end
        self._update_timer = function()
            self._update_timer = nil
            self:_runUpdateCheck()
        end
        UIManager:scheduleIn(secs, self._update_timer)
    end

    --- 跑一次静默检查；先排下一次，本轮失败也不会把周期链断掉
    function XRead:_runUpdateCheck()
        self:_scheduleNextUpdateCheck()
        Trapper:wrap(function()
                local ok, updater = pcall(function()
                    return require("xread/updater"):new{ client = self.client }
                end)
                if not ok then Trapper:clear() return end
                -- 列目录要有效 token：未登录时后端直接 400 NEED_LOGIN，这一轮就白跑，
                -- 而 _update_checked 已置位 → 整个会话都不再提示更新。
                -- 首页走本地缓存渲染时恰好还没登录，所以这里静默补一次登录（不弹窗）。
                if not self.client.accessToken then
                    local u = tostring(self:getSetting("username", "") or "")
                    local p = tostring(self:getSetting("password", "") or "")
                    local addr = tostring(self:getSetting("address", "") or "")
                    if u ~= "" and p ~= "" then
                        pcall(function()
                            self.client.address = addr
                            self.client:login(u, p)
                            self._token_addr = addr
                            self._token_user = u
                        end)
                    end
                end
                local ok_check, manifest, info = pcall(function() return self:checkUpdateBest(updater) end)
                Trapper:clear()
                if not ok_check or not manifest or not info then
                    -- 静默失败，但留下可查的痕迹（离线/没登录是常态，不打扰用户）
                    logger.warn("xread quiet update check failed:", tostring(ok_check and "no manifest" or manifest))
                    return
                end
                if os.getenv("XREAD_AUTOTEST") then
                    print("[XREAD_AUTOTEST] update_checked newer=" .. tostring(info.newer)
                        .. " local=" .. tostring(info.local_version)
                        .. " remote=" .. tostring(info.remote_version))
                end
                if info.newer and self._update_notified ~= info.remote_version then
                    self._update_notified = info.remote_version
                    self._update_manifest = manifest
                    self._update_info = info
                    self._update_notes = tostring(manifest.notes or "")
                    logger.info("xread update available",
                        tostring(info.local_version), "->", tostring(info.remote_version))
                    -- 正在看书就先攒着，回首页再提示，避免糊在正文上
                    if SHARED.open_path or self._opening_book then
                        self._update_pending_notice = true
                    else
                        self:_notifyUpdateWhenHomeReady()
                    end
                end
            end)
    end
    -- 关于本机：插件版本 / 后端版本 / 固件版本 / 检查更新
    function XRead:showAboutPanel()
        -- 连点「关于本机」会起多个任务，每个任务都建一份同名面板叠在栈里
        if self._about_panel_loading then return end
        self._about_panel_loading = true
        -- 兜底：任务异常时也要把标记放回去，否则「关于本机」以后都点不开
        UIManager:scheduleIn(20, function() self._about_panel_loading = false end)
        local updater = require("xread/updater"):new{ client = self.client }
        local plugin_v = updater:getLocalVersion() or _("未知")
        local fw = nil
        pcall(function()
            local Device = require("device")
            if Device.firmwareRevision then
                local rev = Device:firmwareRevision()
                if rev and rev ~= "" then fw = tostring(rev) end
            end
        end)
        if not fw then
            pcall(function()
                fw = require("version"):getCurrentRevision()
            end)
        end
        -- 面板立即弹出：后端版本先显示「检测中…」，不为一个网络请求把入口卡住。
        -- （以前是先同步取版本再建面板，地址不通时要等 3~12s 才看到界面。）
        self._about_info = { plugin_v = plugin_v, server_v = nil, fw = fw or _("未知") }
        UIManager:nextTick(function()
            self._about_panel_loading = false
            self:_showAboutPanel()
        end)
        -- 后台补后端版本：拿到后就地改那一行文字。
        -- 注意不能走 _scheduleNetJob：它会在「有弹层时让路」，而「关于本机」面板
        -- 本身就是弹层，于是版本请求永远排不上队，界面一直停在「检测中…」。
        -- 这里直接用 scheduleIn，getServerVersion 的 2.5s 超时阻塞可接受（用户在等结果）。
        -- 也不因短暂冷却期就跳过：用户主动点开就是想看版本，给一次强制尝试。
        UIManager:scheduleIn(0.3, function()
            -- getVersionUpdate 需要 accessToken；首页有缓存时 openHome 会直接渲染不登录，
            -- 此时 client 还没有 token。账号密码已配置的话先静默补一次登录，再取版本。
            if self.client.accessToken == nil then
                local user = tostring(self:getSetting("username", "") or "")
                local pass = tostring(self:getSetting("password", "") or "")
                if user ~= "" and pass ~= "" then
                    pcall(function()
                        self.client.address = self:backendAddress()
                        self.client:login(user, pass)
                        self._token_addr = self:backendAddress()
                        self._token_user = user
                    end)
                end
            end
            local v = self.client:getServerVersion()
            if not v then
                -- 拿不到时把「检测中…」就地改成「未知」，别一直挂着让人以为还在转
                self._about_info = self._about_info or {}
                self._about_info.server_v = nil
                local row = self._about_server_row
                if row and row.text_widget and not row._miu_closed then
                    pcall(function()
                        row.text_widget:setText(T(_("后端版本：%1"), _("未知")))
                        if self._more_panel_view then UIManager:setDirty(self._more_panel_view, "ui") end
                    end)
                end
                if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] about_server_version nil") end
                return
            end
            self._about_info = self._about_info or {}
            self._about_info.server_v = v
            local row = self._about_server_row
            if row and row.text_widget and not row._miu_closed then
                pcall(function()
                    row.text_widget:setText(T(_("后端版本：%1"), tostring(v)))
                    if self._more_panel_view then UIManager:setDirty(self._more_panel_view, "ui") end
                end)
            end
            if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] about_server_version " .. tostring(v)) end
        end)
    end

    function XRead:_showAboutPanel()
        local info = self._about_info or {}
        self:showMoreListPanel(_("关于本机"), {
            { label = T(_("插件版本：%1"), tostring(info.plugin_v or "?")) },
            { key = "server_version",
              label = T(_("后端版本：%1"), tostring(info.server_v or _("检测中…"))) },
            { label = T(_("固件版本：%1"), tostring(info.fw or "?")) },
            { label = _("检查更新"), callback = function() self:checkForUpdateInteractive() end },
        }, {
            hint = _("先从服务端检查更新；服务端不可用或无新版时，再安装放在插件目录内的本地更新包（规范命名 zip/tar.gz/tgz）。确认后自动安装并重启 KOReader。"),
            on_rows_built = function(rows_map)
                self._about_server_row = rows_map and rows_map.server_version
            end,
        })
    end
    -- 检查更新：先走服务端列目录；服务端失败或没有更高版本时，
    -- 再找插件目录内的本地更新包（规范命名 zip/tar.gz/tgz）；返回 manifest + info
    function XRead:checkUpdateBest(updater)
        -- 两边都要查。原来远端目录一成功就直接返回（哪怕远端没有更高版本），
        -- 插件目录里已经放好的本地升级包永远轮不到，启动时自然不提示。
        local ok_r, rmanifest, rinfo = pcall(function() return updater:check() end)
        local ok_l, lmanifest, linfo = pcall(function() return updater:checkLocal() end)
        local use_r = ok_r and rmanifest ~= nil and rinfo ~= nil and rinfo.newer == true
        local use_l = ok_l and lmanifest ~= nil and linfo ~= nil and linfo.newer == true
        -- 两边都有新版：装版本更高的那个
        if use_r and use_l then
            if updater.versionNewer(linfo.remote_version, rinfo.remote_version) then
                use_r = false
            else
                use_l = false
            end
        end
        if use_r then return rmanifest, rinfo end
        if use_l then return lmanifest, linfo end
        -- 都没有更高版本：优先返回远端结果（「已是最新」的口径），其次本地
        if ok_r and rmanifest and rinfo then return rmanifest, rinfo end
        if ok_l and lmanifest and linfo then return lmanifest, linfo end
        -- 两者都没有：把远端错误抛出去（本地无包时保持原报错语义）
        if not ok_r then error(rmanifest, 0) end
        return nil
    end
    -- 手动检查更新（关于本机 → 检查更新）
    function XRead:checkForUpdateInteractive()
        -- 单实例：连点「检查更新」会并发出多个 Trapper 任务，每个任务各自弹一次
        -- 确认框；框叠框 + 旧帧没刷掉，看起来就是画面残留甚至卡死。
        if self._update_checking then
            logger.info("xread update check ignored: already running")
            return
        end
        self._update_checking = true
        local done = function() self._update_checking = false end
        -- 兜底：网络异常/协程被中断时也要解锁，否则以后点「检查更新」毫无反应
        UIManager:scheduleIn(30, done)
        self:runQuiet(function()
            local pending_confirm = false
            local ok_task, err_task = pcall(function()
                -- 列 webdav 目录要 token；没登录先登（未填账号会自己提示）
                if not self:ensureLogin() then return end
                local updater = require("xread/updater"):new{ client = self.client }
                local ok, manifest, info = pcall(function() return self:checkUpdateBest(updater) end)
                -- 两边都没拿到包才算失败（失败才弹窗）；原因洗净后给一行
                if not ok or not manifest or not info then
                    local reason = ok and _("服务端与插件目录内都没有可用的更新包")
                        or readable_error(manifest)
                    logger.warn("xread update check failed:", tostring(reason))
                    self:showInfo(T(_("检查更新失败\n原因：%1"), reason), 6)
                    return
                end
                self._update_manifest = manifest
                self._update_info = info
                -- 用户是主动点的「检查更新」，已经看到结果了，不再重复自动提示
                self._update_pending_notice = nil
                if not info.newer then
                    -- 非失败但需要回执：不然点了没反应像卡住
                    self:showInfo(T(_("当前 %1 已是最新版本"), tostring(info.local_version)))
                    return
                end
                self._update_notified = info.remote_version
                pending_confirm = true
            end)
            if pending_confirm and ok_task then
                -- 确认框交给下一个 tick：既避开面板关闭的刷新，也把「检查中」标记
                -- 一直压到框真正弹出来，防止两次点击各弹一个框。
                UIManager:nextTick(function()
                    self:confirmUpdate()
                    done()
                end)
            else
                done()
            end
            if not ok_task then
                logger.warn("xread update check task error:", tostring(err_task))
            end
        end)
    end

    function XRead:confirmUpdate()
        local manifest, info = self._update_manifest, self._update_info
        if not manifest or not info then return end
        if not info.newer then
            return
        end
        -- 已经有一个确认框在屏幕上：绝不再叠第二个
        local existing = self._update_confirm_box
        if existing then
            if UIManager:isWidgetShown(existing) then return end
            self._update_confirm_box = nil
        end
        -- 收掉底层「关于本机」面板：确认框独占一屏，避免两层文字互相透出像残影
        if self._more_panel_view then
            local panel = self._more_panel_view
            self._more_panel_view = nil
            pcall(function() UIManager:close(panel) end)
            if os.getenv("XREAD_AUTOTEST") then
                print("[XREAD_AUTOTEST] confirm_closed_about_panel")
            end
            -- 面板比确认框大：面板关掉后必须整屏重刷，否则它露在框外的边缘会留成残影
            UIManager:setDirty("all", "full")
        end
        -- 唯一确认框：一句话说明，更新 + 重启合并成一次询问
        local body = T(_("新版本 %1 已就绪，更新后自动重启。"), tostring(info.remote_version))
        local owner = self
        local box
        box = MessageBox.confirm{
            text = body,
            ok_text = _("更新并重启"),
            -- 更新前这一步关框后整屏重刷一次，清掉叠层残影
            full_refresh = true,
            callback = function(ok)
                if owner._update_confirm_box == box then owner._update_confirm_box = nil end
                if ok then self:applyUpdateFlow(manifest) end
            end,
        }
        self._update_confirm_box = box
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] update_confirm_shown")
        end
    end
    -- 安装更新：本地包直接解压；远端包下载并替换文件。
    -- 全程只有一次确认（已在确认框里说明会重启），装完自动重启，不再二次询问。
    function XRead:applyUpdateFlow(manifest)
        self:runQuiet(function()
            local updater = require("xread/updater"):new{ client = self.client }
            -- 进度提示：按时间节流（150ms），边写盘边刷屏反而更慢；
            -- 第三参数跳过 Trapper 的「点击已关掉提示」检测，避免每次刷新都让出 0.1s
            local last_t = 0
            local on_progress = function(done, total, path)
                local cnt = tonumber(total) or 0
                local pct = cnt > 0 and math.floor((tonumber(done) or 0) * 100 / cnt) or 0
                local t = now_ms()
                if t - last_t < 150 then return end
                last_t = t
                local name = tostring(path or ""):match("[^/]+$") or tostring(path or "")
                Trapper:info(T(_("正在更新 %1%（%2/%3） %4"),
                    tostring(pct), tostring(done), tostring(cnt), name), true, true)
            end
            Trapper:info(manifest.local_file and _("正在安装本地更新包…") or _("正在下载更新包…"), true, true)
            local changed, skipped
            if manifest.local_file then
                changed, skipped = updater:applyLocalPackage(manifest, on_progress)
            else
                changed, skipped = updater:apply(manifest, on_progress)
            end
            Trapper:clear()
            self._update_manifest = nil
            self._update_info = nil
            logger.info("xread update installed:",
                tostring(changed), "changed,", tostring(skipped), "skipped")
            self:showInfo(T(_("更新完成（变更 %1 个文件，跳过 %2 个未变更）\n正在重启 KOReader…"),
                tostring(changed), tostring(skipped)), 8)
            -- 确认框已包含「会重启」，这里直接重启；真重启不了才提示手动重启
            UIManager:scheduleIn(3, function()
                local ok = pcall(function() UIManager:restartKOReader() end)
                if not ok then
                    self:showInfo(_("自动重启失败，请手动重启 KOReader 使更新生效"))
                end
            end)
        end)
    end

    function XRead:showPageManage()
        -- 4 种翻页分区方案：点条目即选中并生效（阅读中即时重注册分区）
        local cur = self:currentPageMode()
        local items = {}
        for key, mode in pairs(PAGE_MODES) do
            items[#items + 1] = {
                key = key,
                label = mode.label,
                desc = mode.desc,
                selected = key == cur,
            }
        end
        -- 稳定排序：默认方案在前，其余按字母
        table.sort(items, function(a, b)
            if (a.key == "default") ~= (b.key == "default") then return a.key == "default" end
            return a.key < b.key
        end)
        local rows = {}
        for _idx, it in ipairs(items) do
            local prefix = it.selected and _("● ") or _("○ ")
            rows[#rows + 1] = {
                label = prefix .. it.label,
                callback = function()
                    self:saveSetting("page_mode", it.key)
                    pcall(function() self:setupCenterTap() end)   -- 阅读中即时生效
                end,
            }
        end
        self:showMoreListPanel(_("翻页管理"), rows, {
            hint = _("两种翻页分区方案，点条目选择；「管理位置」即呼出阅读工具栏。选中后立即生效。"),
        })
    end
    -- 地址管理：配置服务器地址和端口；点空白/返回键即保存
    function XRead:showServerManage()
        local VerticalGroup = require("ui/widget/verticalgroup")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local TextWidget = require("ui/widget/textwidget")
        local LineWidget = require("ui/widget/linewidget")
        local GestureRange = require("ui/gesturerange")
        local Font = require("ui/font")
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        local draft = self._server_draft
        if not draft then
            -- 与设置页共用同一份地址解析，避免两处规则不一致
            local ip, port = self:serverAddressParts()
            draft = {
                ip = tostring(ip or ""),
                port = tostring(port or ""),
            }
            self._server_draft = draft
        end
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local W = math.min(sw - 80, 700)
        local pad = math.floor(sw * 0.03)
        local inner_w = W - pad * 2
        local face_title = Font:getFace("cfont", 22)
        local face_row = Font:getFace("cfont", 18)
        local face_hint = Font:getFace("smallinfofont", 13)
        local dialog  -- forward

        local function saveDraft()
            -- 真正的写入/探活逻辑在 applyServerAddress（设置页的地址/端口也用它）
            self:applyServerAddress(draft.ip, draft.port)
        end

        local function saveAndClose()
            saveDraft()
            self._server_draft = nil
            if dialog then UIManager:close(dialog) end
            UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        end

        local function refreshDialog()
            if dialog then UIManager:close(dialog) end
            -- 只换波形、不整屏深刷：原来每改一个字段就全屏黑白闪一次
            UIManager:setDirty("all", "ui")
            self:showServerManage()
        end

        local function editField(key, title)
            local d
            d = InputDialog:new{
                title = title,
                input = tostring(draft[key] or ""),
                input_type = "string",
                buttons = {{
                    { text = _("取消"), callback = function() UIManager:close(d) end },
                    {
                        text = _("确定"), is_enter_default = true,
                        callback = function()
                            draft[key] = d:getInputValue()
                            UIManager:close(d)
                            refreshDialog()
                        end,
                    },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end
        local FieldRow = InputContainer:extend{
            label = nil, value = nil, width = nil, height = nil, callback = nil,
        }

        function FieldRow:init()
            local hpad = Screen:scaleBySize(14)
            local lw = Screen:scaleBySize(110)
            local label_w = TextWidget:new{
                text = self.label, face = face_row,
                fgcolor = Blitbuffer.COLOR_GRAY,
                max_width = lw,
            }
            local value_w = TextWidget:new{
                text = self.value, face = face_row,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = self.width - hpad * 2 - lw,
            }
            self.frame = FrameContainer:new{
                bordersize = 1, color = Blitbuffer.COLOR_GRAY_D,
                background = Blitbuffer.COLOR_WHITE,
                padding = 0, margin = 0,
                padding_left = hpad, padding_right = hpad,
                width = self.width, height = self.height,
                LeftContainer:new{
                    dimen = Geom:new{ w = self.width - 2 * hpad, h = self.height },
                    HorizontalGroup:new{
                        align = "center", label_w,
                        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                        value_w,
                    },
                },
            }
            self[1] = self.frame
            self.dimen = Geom:new{ w = self.width, h = self.height }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        end

        function FieldRow:onTap()
            if self.callback then self.callback() end
            return true
        end
        local row_h = Screen:scaleBySize(52)
        local gap = Screen:scaleBySize(12)
        local rows = VerticalGroup:new{ align = "left" }
        rows[#rows + 1] = FieldRow:new{
            label = _("服务端地址"),
            value = draft.ip ~= "" and draft.ip or _("(未设置)"),
            width = inner_w, height = row_h,
            callback = function() editField("ip", _("服务端地址")) end,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = FieldRow:new{
            label = _("服务端端口"),
            value = draft.port ~= "" and draft.port or _("(未设置)"),
            width = inner_w, height = row_h,
            callback = function() editField("port", _("服务端端口")) end,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = TextBoxWidget:new{
            text = T(_("当前地址：%1"), tostring(self:getSetting("address", "") or "")),
            face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = TextBoxWidget:new{
            text = _("点空白处或按返回键关闭并保存。"),
            face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local card = VerticalGroup:new{ align = "left" }
        -- 标题行右侧加「✕」：保证任何情况下都有可见的关闭按钮
        local title_tw = TextWidget:new{
            text = _("地址管理"), face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local close_w = UICommon.closeButtonSize()
        local stretch = inner_w - title_tw:getSize().w - close_w
        if stretch < 0 then stretch = 0 end
        card[#card + 1] = HorizontalGroup:new{ align = "center",
            title_tw, HorizontalSpan:new{ width = stretch },
            UICommon.closeButtonAtEdge(saveAndClose, pad, close_w) }
        card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
        card[#card + 1] = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = 1 },
            background = Blitbuffer.COLOR_GRAY_D,
        }
        card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
        card[#card + 1] = rows
        local frame = FrameContainer:new{
            bordersize = 2, color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE, radius = 8,
            padding = pad, margin = 0,
            card,
        }
        local overlay_dimen = Geom:new{ w = sw, h = sh }
        -- 必须用实例（:new）入窗：直接 show 类不会跑 _init，
        -- _ordered_touch_zones 为 nil，任何手势广播都会 ipairs(nil) 崩溃
        local Overlay = InputContainer:extend{}
        function Overlay:init()
            self.dimen = overlay_dimen
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = overlay_dimen } } }
            if Device:hasKeys() then
                self.key_events = { Close = { { Device.input.group.Back } } }
            end
            self[1] = CenterContainer:new{ dimen = overlay_dimen, frame }
        end

        function Overlay:onTap()
            saveAndClose()
            return true
        end

        function Overlay:onClose()
            saveAndClose()
            return true
        end

        function Overlay:paintTo(bb, x, y)
            UICommon.dimBackdrop(bb, x, y, self.dimen.w, self.dimen.h)
            self[1]:paintTo(bb, x, y)
        end
        dialog = Overlay:new{}
        UIManager:show(dialog)
    end
    -- 账号管理：配置昵称、用户名、密码；点空白/返回键即保存
    function XRead:showAccountManage()
        local VerticalGroup = require("ui/widget/verticalgroup")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local TextWidget = require("ui/widget/textwidget")
        local LineWidget = require("ui/widget/linewidget")
        local GestureRange = require("ui/gesturerange")
        local Font = require("ui/font")
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        local draft = self._account_draft
        if not draft then
            draft = {
                nickname = tostring(self:getSetting("nickname", "") or ""),
                username = tostring(self:getSetting("username", "") or ""),
                password = tostring(self:getSetting("password", "") or ""),
            }
            self._account_draft = draft
        end
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local W = math.min(sw - 80, 700)
        local pad = math.floor(sw * 0.03)
        local inner_w = W - pad * 2
        local face_title = Font:getFace("cfont", 22)
        local face_row = Font:getFace("cfont", 18)
        local face_hint = Font:getFace("smallinfofont", 13)
        local dialog  -- forward

        local function saveDraft()
            local old_username = self:getSetting("username", "")
            local old_password = self:getSetting("password", "")
            local old_address = self:getSetting("address", "")
            self:saveSetting("nickname", draft.nickname)
            self:saveSetting("username", draft.username)
            self:saveSetting("password", draft.password)
            -- 用户名/密码改了：登录态与所有用到用户名的地方一起切过去
            -- 延迟登录：让设置页/账号页先关掉，再在后台走登录（最长 12s，不能卡住关闭动作）
            self:_syncCredentials(old_username, old_password, old_address, true)
        end

        local function saveAndClose()
            saveDraft()
            self._account_draft = nil
            if dialog then UIManager:close(dialog) end
            self:_refreshHomeIfOpen()   -- 昵称改动实时反映到首页
            UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        end

        local function refreshDialog()
            if dialog then UIManager:close(dialog) end
            UIManager:setDirty("all", "ui")
            self:showAccountManage()
        end

        local function editField(key, title, is_password)
            local d
            d = InputDialog:new{
                title = title,
                input = tostring(draft[key] or ""),
                input_type = is_password and "password" or "string",
                text = is_password and _("密码将以明文保存在本地配置文件中") or nil,
                buttons = {{
                    { text = _("取消"), callback = function() UIManager:close(d) end },
                    {
                        text = _("确定"), is_enter_default = true,
                        callback = function()
                            draft[key] = d:getInputValue()
                            UIManager:close(d)
                            refreshDialog()
                        end,
                    },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end
        local FieldRow = InputContainer:extend{
            label = nil, value = nil, width = nil, height = nil, callback = nil,
        }

        function FieldRow:init()
            local hpad = Screen:scaleBySize(14)
            local lw = Screen:scaleBySize(110)
            local label_w = TextWidget:new{
                text = self.label, face = face_row,
                fgcolor = Blitbuffer.COLOR_GRAY,
                max_width = lw,
            }
            local value_w = TextWidget:new{
                text = self.value, face = face_row,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = self.width - hpad * 2 - lw,
            }
            self.frame = FrameContainer:new{
                bordersize = 1, color = Blitbuffer.COLOR_GRAY_D,
                background = Blitbuffer.COLOR_WHITE,
                padding = 0, margin = 0,
                padding_left = hpad, padding_right = hpad,
                width = self.width, height = self.height,
                LeftContainer:new{
                    dimen = Geom:new{ w = self.width - 2 * hpad, h = self.height },
                    HorizontalGroup:new{
                        align = "center", label_w,
                        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                        value_w,
                    },
                },
            }
            self[1] = self.frame
            self.dimen = Geom:new{ w = self.width, h = self.height }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        end

        function FieldRow:onTap()
            if self.callback then self.callback() end
            return true
        end
        local row_h = Screen:scaleBySize(52)
        local gap = Screen:scaleBySize(12)
        local rows = VerticalGroup:new{ align = "left" }

        local function shownValue(key, is_password)
            local v = tostring(draft[key] or "")
            if v == "" then return _("(未设置)") end
            if is_password then return "******" end
            return v
        end
        rows[#rows + 1] = FieldRow:new{
            label = _("昵称"),
            value = shownValue("nickname"),
            width = inner_w, height = row_h,
            callback = function() editField("nickname", _("昵称")) end,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = FieldRow:new{
            label = _("账号"),
            value = shownValue("username"),
            width = inner_w, height = row_h,
            callback = function() editField("username", _("账号")) end,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = FieldRow:new{
            label = _("密码"),
            value = shownValue("password", true),
            width = inner_w, height = row_h,
            callback = function() editField("password", _("密码"), true) end,
        }
        rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        rows[#rows + 1] = TextBoxWidget:new{
            text = _("昵称显示在首页顶部；点空白处或按返回键关闭并保存。"),
            face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local card = VerticalGroup:new{ align = "left" }
        -- 标题行右侧加「✕」：保证任何情况下都有可见的关闭按钮
        local title_tw = TextWidget:new{
            text = _("账号管理"), face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local close_w = UICommon.closeButtonSize()
        local stretch = inner_w - title_tw:getSize().w - close_w
        if stretch < 0 then stretch = 0 end
        card[#card + 1] = HorizontalGroup:new{ align = "center",
            title_tw, HorizontalSpan:new{ width = stretch },
            UICommon.closeButtonAtEdge(saveAndClose, pad, close_w) }
        card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
        card[#card + 1] = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = 1 },
            background = Blitbuffer.COLOR_GRAY_D,
        }
        card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
        card[#card + 1] = rows
        local frame = FrameContainer:new{
            bordersize = 2, color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE, radius = 8,
            padding = pad, margin = 0,
            card,
        }
        local overlay_dimen = Geom:new{ w = sw, h = sh }
        -- 必须用实例（:new）入窗：直接 show 类不会跑 _init，
        -- _ordered_touch_zones 为 nil，任何手势广播都会 ipairs(nil) 崩溃
        local Overlay = InputContainer:extend{}
        function Overlay:init()
            self.dimen = overlay_dimen
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = overlay_dimen } } }
            if Device:hasKeys() then
                self.key_events = { Close = { { Device.input.group.Back } } }
            end
            self[1] = CenterContainer:new{ dimen = overlay_dimen, frame }
        end

        function Overlay:onTap()
            saveAndClose()
            return true
        end

        function Overlay:onClose()
            saveAndClose()
            return true
        end

        function Overlay:paintTo(bb, x, y)
            UICommon.dimBackdrop(bb, x, y, self.dimen.w, self.dimen.h)
            self[1]:paintTo(bb, x, y)
        end
        dialog = Overlay:new{}
        UIManager:show(dialog)
    end
    -- 书架管理：多选书籍 → 批量删除 / 移动分组
    function XRead:showShelfManage()
        self:runQuiet(function()
            if not self:ensureLogin() then return end
            local ok, books = pcall(function() return self.client:getBookshelf() end)
            if not ok or type(books) ~= "table" or #books == 0 then
                self:showInfo(_("书架为空"))
                return
            end
            self:_showShelfManageDialog(books, {}, 1)
        end)
    end

    function XRead:_showShelfManageDialog(books, selected, page)
        local VerticalGroup = require("ui/widget/verticalgroup")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local TextWidget = require("ui/widget/textwidget")
        local LineWidget = require("ui/widget/linewidget")
        local Button = require("ui/widget/button")
        local GestureRange = require("ui/gesturerange")
        local Font = require("ui/font")
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local W = math.min(sw - 80, 760)
        local pad = math.floor(sw * 0.03)
        local inner_w = W - pad * 2
        local face_title = Font:getFace("cfont", 22)
        local face_row = Font:getFace("cfont", 17)
        local face_hint = Font:getFace("smallinfofont", 13)
        local row_h = Screen:scaleBySize(46)
        local btn_h = Screen:scaleBySize(44)
        local rows_per_page = 12
        local page_count = math.max(1, math.ceil(#books / rows_per_page))
        if page < 1 then page = 1 end
        if page > page_count then page = page_count end
        local dialog  -- forward

        local function refresh(new_page)
            if dialog then UIManager:close(dialog) end
            self:_showShelfManageDialog(books, selected, new_page or page)
        end
        local BookRow = InputContainer:extend{
            text = nil, checked = false, width = nil, height = nil, callback = nil,
        }

        function BookRow:init()
            local hpad = Screen:scaleBySize(12)
            local mark_w = Screen:scaleBySize(46)
            local mark = TextWidget:new{
                text = self.checked and _("☑") or _("☐"),
                face = face_row, bold = true,
                fgcolor = self.checked and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
                max_width = mark_w,
            }
            local tw = TextWidget:new{
                text = self.text,
                face = face_row,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = self.width - hpad * 2 - mark_w,
            }
            self.frame = FrameContainer:new{
                bordersize = 0, margin = 0,
                background = self.checked and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE,
                padding = 0,
                padding_left = hpad, padding_right = hpad,
                width = self.width, height = self.height,
                CenterContainer:new{
                    dimen = Geom:new{ w = self.width - 2 * hpad, h = self.height },
                    HorizontalGroup:new{
                        align = "center", mark,
                        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                        tw,
                    },
                },
            }
            self[1] = self.frame
            self.dimen = Geom:new{ w = self.width, h = self.height }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        end

        function BookRow:onTap()
            if self.callback then self.callback() end
            return true
        end
        local first = (page - 1) * rows_per_page + 1
        local last = math.min(#books, first + rows_per_page - 1)
        local rows = VerticalGroup:new{ align = "left" }
        for i = first, last do
            local book = books[i]
            local url = tostring(book.bookUrl or book.name or i)
            rows[#rows + 1] = BookRow:new{
                text = (book.name or "?") .. "　" .. (book.author or ""),
                checked = selected[url] == true,
                width = inner_w, height = row_h,
                callback = function()
                    selected[url] = not selected[url]
                    refresh()
                end,
            }
        end
        local sel_count = 0
        for _ in pairs(selected) do sel_count = sel_count + 1 end

        local function doDelete()
            local urls = {}
            local by_url = {}
            for i, book in ipairs(books) do
                local url = tostring(book.bookUrl or book.name or i)
                by_url[url] = book
                if selected[url] then urls[#urls + 1] = url end
            end
            if #urls == 0 then self:showInfo(_("先勾选要删除的书")); return end
            MessageBox.confirm{
                text = T(_("删除所选 %1 本书？\n服务器上的书、缓存和进度都会移除。"), #urls),
                ok_text = _("删除"),
                callback = function(ok)
                    if not ok then return end
                    Trapper:wrap(function()
                        local ok_n, fail_n = 0, 0
                        for _ui, url in ipairs(urls) do
                            local b = by_url[url]
                            local okd = pcall(function() self.client:deleteBook(b) end)
                            if okd then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
                        end
                        Trapper:clear()
                        if fail_n > 0 then self:showInfo(T(_("删除失败 %1 本"), fail_n)) end
                        -- 重开时重新拉书架
                        self:showShelfManage()
                    end)
                end,
            }
        end

        local function doMoveGroup()
            local targets = {}
            local by_url = {}
            for i, book in ipairs(books) do
                local url = tostring(book.bookUrl or book.name or i)
                by_url[url] = book
                if selected[url] then targets[#targets + 1] = book end
            end
            if #targets == 0 then self:showInfo(_("先勾选要移动的书")); return end
            self:runQuiet(function()
                if not self:ensureLogin() then return end
                local okg, groups = pcall(function() return self.client:getBookGroups() end)
                if not okg or type(groups) ~= "table" then
                    self:showInfo(_("获取分组失败"))
                    return
                end
                local items = {
                    { text = _("未分组"), group_id = "" },
                }
                for _, g in ipairs(groups) do
                    items[#items + 1] = {
                        text = tostring(g.groupName or g.name or g.groupId),
                        group_id = tostring(g.groupId or g.id or ""),
                    }
                end
                for _it, it in ipairs(items) do
                    local gid = it.group_id
                    it.callback = function()
                        Trapper:wrap(function()
                            local ok_n, fail_n = 0, 0
                            for _ti, b in ipairs(targets) do
                                local nb = util.tableDeepCopy(b) or b
                                nb.group = gid
                                local okm = pcall(function() self.client:saveBook(nb) end)
                                if okm then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
                            end
                            Trapper:clear()
                            if fail_n > 0 then self:showInfo(T(_("移动失败 %1 本"), fail_n)) end
                        end)
                    end
                end
                UIManager:show(Menu:new{
                    title = T(_("移动 %1 本到分组"), #targets),
                    item_table = items,
                    width = Screen:getWidth(),
                    height = Screen:getHeight(),
                })
            end)
        end
        -- 底部按钮行
        local del_btn = Button:new{
            text = _("删除所选"), width = (inner_w - Screen:scaleBySize(20)) / 2, height = btn_h,
            text_font_size = 17, bordersize = 1, radius = 6,
            callback = function() doDelete() end,
        }
        local move_btn = Button:new{
            text = _("移动分组"), width = (inner_w - Screen:scaleBySize(20)) / 2, height = btn_h,
            text_font_size = 17, bordersize = 1, radius = 6,
            callback = function() doMoveGroup() end,
        }
        local prev_btn = Button:new{
            text = _("上一页"), width = Screen:scaleBySize(120), height = btn_h,
            text_font_size = 15, bordersize = 1, radius = 6,
            enabled = page > 1,
            callback = function() refresh(page - 1) end,
        }
        local next_btn = Button:new{
            text = _("下一页"), width = Screen:scaleBySize(120), height = btn_h,
            text_font_size = 15, bordersize = 1, radius = 6,
            enabled = page < page_count,
            callback = function() refresh(page + 1) end,
        }
        local page_label = TextWidget:new{
            text = tostring(page) .. " / " .. tostring(page_count),
            face = face_row, fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local back_btn = Button:new{
            text = _("返回"), width = Screen:scaleBySize(100), height = btn_h,
            text_font_size = 15, bordersize = 1, radius = 6,
            callback = function()
                if dialog then UIManager:close(dialog) end
            end,
        }
        local frame = FrameContainer:new{
            bordersize = 2, color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE, radius = 8,
            padding = pad, margin = 0,
            VerticalGroup:new{
                align = "left",
                TextBoxWidget:new{
                    text = _("书架管理"), face = face_title, bold = true,
                    width = inner_w, fgcolor = Blitbuffer.COLOR_BLACK,
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                TextBoxWidget:new{
                    text = T(_("已选 %1 本 · 第 %2 / %3 页"), sel_count, page, page_count)
                        .. _("　点条目勾选/取消"),
                    face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                LineWidget:new{ dimen = Geom:new{ w = inner_w, h = 1 }, background = Blitbuffer.COLOR_GRAY_D },
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                rows,
                HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = btn_h },
                    HorizontalGroup:new{ del_btn, HorizontalSpan:new{ width = Screen:scaleBySize(20) }, move_btn },
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = btn_h },
                    HorizontalGroup:new{
                        back_btn,
                        HorizontalSpan:new{ width = Screen:scaleBySize(24) },
                        prev_btn,
                        HorizontalSpan:new{ width = Screen:scaleBySize(16) },
                        page_label,
                        HorizontalSpan:new{ width = Screen:scaleBySize(16) },
                        next_btn,
                    },
                },
            },
        }
        if Device:hasKeys() then
            -- 必须用实例（:new）入窗：直接 show 类不会跑 _init，手势广播会 ipairs(nil) 崩溃
            local DialogClass = InputContainer:extend{}
            function DialogClass:init()
                self.dimen = Geom:new{ w = sw, h = sh }
                self.key_events = { Close = { { Device.input.group.Back } } }
                self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ w = sw, h = sh } } } }
                self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame }
            end
            function DialogClass:onClose()
                UIManager:close(self)
                UIManager:setDirty("all", "full")
                return true
            end
            -- 子控件（书行/按钮）的 Tap 会先被消费；点卡片外空白冒泡到这里 → 关闭
            function DialogClass:onTap()
                UIManager:close(self)
                UIManager:setDirty("all", "full")
                return true
            end
            dialog = DialogClass:new{}
        else
            dialog = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame }
        end
        UIManager:show(dialog)
        -- 任务统一静默执行（不再有进度框），show 之后整体重绘一次，避免残影
        UIManager:setDirty(dialog, "full")
    end
    -- 地址解析：把 settings 里的 address（http://ip:port）拆成 地址 + 端口。
    -- 设置页和「更多 → 地址管理」共用同一份逻辑，避免两处解析规则不一致。
    function XRead:serverAddressParts()
        local addr = tostring(self:getSetting("address", "") or "")
        local host = addr:gsub("^%w+://", "")
        local ip, port = host:match("^([^:/]+):(%d+)$")
        if not ip then
            ip, port = host:match("^([^:/]+)$")
            if not ip then
                ip, port = host, ""
            end
        end
        return tostring(ip or ""), tostring(port or "")
    end
    -- 写入地址并即时探活：设置页改地址/端口与地址管理页走同一条路
    function XRead:applyServerAddress(ip, port)
        ip = tostring(ip or ""):gsub("%s", "")
        port = tostring(port or ""):gsub("%s", "")
        if ip == "" then return false end
        local addr = "http://" .. ip
        if port ~= "" then addr = addr .. ":" .. port end
        self:saveSetting("address", addr)
        local changed = addr ~= self.client.address
        if changed then
            self.client.address = addr
            self.client.accessToken = nil   -- 换地址后需重登
            if self.cover_cache then self.cover_cache.base_url = addr end
        end
        -- 地址改动后：立刻解除「连不上」冷却，并异步测一次新地址
        -- （以前要等到下一次点开页面才发现地址还是错的，且没有任何回执）
        self:clearBackendDown()
        if changed then
            BackendProbe.check(addr, 2.5, function(ok, reason)
                if ok then
                    self:showInfo(T(_("地址已保存：%1\n连接正常"), display_address(addr)), 4)
                else
                    self:showInfo(T(_("地址已保存：%1\n但连接失败：%2\n\n请核对 IP、端口，以及后端服务是否已启动。"),
                        display_address(addr), readable_error(reason)), 10)
                end
            end)
        end
        return true
    end
    -- 服务器缓存章数：设置里的 50 / 100 / 全部 → 后端 count（0 = 全部章节）。
    -- 「两个选项都不选 / 再点一次取消」保存为 "none"，返回 nil = 不缓存。
    function XRead:cacheDepthCount()
        local v = tostring(self:getSetting("cache_depth", "50") or "50")
        if v == "none" or v == "" then return nil end
        if v == "all" then return 0 end
        local n = tonumber(v)
        if not n or n < 1 then return 50 end
        return n
    end
    -- 本地预加载深度：50 / 100 / 全部（all）；"none" 返回 0 = 不额外预加载
    function XRead:cacheDepthLimit()
        local v = tostring(self:getSetting("cache_depth", "50") or "50")
        if v == "none" or v == "" then return 0 end
        if v == "all" then return math.huge end
        local n = tonumber(v)
        if not n or n < 1 then n = 50 end
        return n
    end

    function XRead:showSettings()
        -- 首页齿轮「设置」：地址管理 / 账号管理 / 翻页管理 / 缓存管理。
        -- 版式用「分组卡片」：每组一个圆角白框、组内行之间一条细线、组与组之间留白。
        -- 原来所有行挤成一竖列，分组标题和下一行贴在一起，看着很挤。
        local VerticalGroup = require("ui/widget/verticalgroup")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local VerticalSpan = require("ui/widget/verticalspan")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local RightContainer = require("ui/widget/container/rightcontainer")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local TextWidget = require("ui/widget/textwidget")
        local Button = require("ui/widget/button")
        local LineWidget = require("ui/widget/linewidget")
        local GestureRange = require("ui/gesturerange")
        local Font = require("ui/font")
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        -- 草稿：账号 / 缓存项跨面板重建保留（点地址、点账号都会重建面板）
        local draft = self._settings_draft
        if not draft then
            local depth = tostring(self:getSetting("cache_depth", "50") or "50")
            -- "none" = 50/100/全部 都不选（不缓存），必须原样保留；
            -- 其它未知值才回落到默认 50。
            if depth ~= "all" and depth ~= "100" and depth ~= "none" then depth = "50" end
            draft = {
                username = tostring(self:getSetting("username", "") or ""),
                password = tostring(self:getSetting("password", "") or ""),
                nickname = tostring(self:getSetting("nickname", "") or ""),
                max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3,
                cache_depth = depth,
            }
            self._settings_draft = draft
        end
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local W = math.min(sw - Screen:scaleBySize(56), Screen:scaleBySize(880))
        local pad = Screen:scaleBySize(18)
        local inner_w = W - pad * 2
        local hpad = Screen:scaleBySize(16)          -- 行内左右留白
        local content_w = inner_w - 2 * hpad
        local row_h = math.max(Screen:scaleBySize(44),
            math.min(Screen:scaleBySize(58), math.floor(sh * 0.05)))
        local face_title = Font:getFace("cfont", 22)
        local face_group = Font:getFace("cfont", 15)
        local face_row = Font:getFace("cfont", 17)
        local face_value = Font:getFace("cfont", 16)
        local face_hint = Font:getFace("smallinfofont", 13)
        local face_desc = Font:getFace("cfont", 13)
        local dialog  -- forward

        local function saveDraft()
            local old_username = self:getSetting("username", "")
            local old_password = self:getSetting("password", "")
            local old_address = self:getSetting("address", "")
            self:saveSetting("nickname", draft.nickname)
            self:saveSetting("username", draft.username)
            self:saveSetting("password", draft.password)
            self:saveSetting("max_chapters", tostring(draft.max_chapters))
            self:saveSetting("cache_depth", tostring(draft.cache_depth))
            -- 账号/密码变更：清旧 token、按新账号重登（延迟到面板关掉之后）
            self:_syncCredentials(old_username, old_password, old_address, true)
        end

        local function closeSelf()
            if dialog then UIManager:close(dialog) end
            UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        end

        local function saveAndClose()
            saveDraft()
            self._settings_draft = nil
            closeSelf()
            self:_refreshHomeIfOpen()   -- 昵称改动实时反映到首页
        end

        local function refreshDialog()
            if dialog then UIManager:close(dialog) end
            -- 只换波形、不整屏深刷：原来每改一个字段就全屏黑白闪一次
            UIManager:setDirty("all", "ui")
            self:showSettings()
        end

        -- ---------- 版式零件 ----------
        local function groupTitle(text)
            return VerticalGroup:new{ align = "left",
                VerticalSpan:new{ width = Screen:scaleBySize(16) },
                TextWidget:new{
                    text = text, face = face_group, bold = true,
                    fgcolor = Blitbuffer.COLOR_GRAY_6,
                    max_width = inner_w,
                },
                VerticalSpan:new{ width = Screen:scaleBySize(7) },
            }
        end

        local function rowLine()
            return HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = hpad },
                LineWidget:new{
                    dimen = Geom:new{ w = content_w, h = 1 },
                    background = Blitbuffer.COLOR_GRAY_D,
                },
                HorizontalSpan:new{ width = hpad },
            }
        end

        local function card(rows)
            local box = VerticalGroup:new{ align = "left" }
            for i = 1, #rows do
                box[#box + 1] = rows[i]
                if i < #rows then box[#box + 1] = rowLine() end
            end
            return FrameContainer:new{
                bordersize = 1, color = Blitbuffer.COLOR_GRAY_B, radius = 8,
                padding = 0, margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                width = inner_w,
                box,
            }
        end
        local label_w = math.floor(content_w * 0.50)
        local ctl_w = math.max(1, content_w - label_w)
        -- 一行「左侧标签 + 右侧取值」：左右各自贴边，取值右对齐
        local ParamRow = InputContainer:extend{
            label = nil, value = nil, height = nil,
            callback = nil, arrow = nil, value_face = nil, selected = false,
        }
        function ParamRow:init()
            local label_tw = TextWidget:new{
                text = tostring(self.label or ""), face = face_row, bold = true,
                max_width = label_w, fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local value_text = tostring(self.value or "")
            if self.arrow then value_text = value_text .. "   ›" end
            local value_tw = TextWidget:new{
                text = value_text, face = self.value_face or face_value,
                max_width = ctl_w, fgcolor = Blitbuffer.COLOR_GRAY_6,
            }
            self[1] = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                background = self.selected and Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_WHITE,
                width = inner_w, height = self.height,
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = hpad },
                    LeftContainer:new{ dimen = Geom:new{ w = label_w, h = self.height }, label_tw },
                    RightContainer:new{ dimen = Geom:new{ w = ctl_w, h = self.height }, value_tw },
                    HorizontalSpan:new{ width = hpad },
                },
            }
            self.dimen = Geom:new{ w = inner_w, h = self.height }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        end
        function ParamRow:onTap()
            if self.callback then self.callback() end
            return true
        end

        local function row(label, value, on_tap, opts)
            opts = opts or {}
            return ParamRow:new{
                label = label, value = value, height = row_h,
                callback = on_tap, arrow = opts.arrow,
                value_face = opts.value_face, selected = opts.selected,
            }
        end

        local function editText(title, initial, is_password, on_ok)
            local d
            d = InputDialog:new{
                title = title,
                input = tostring(initial or ""),
                input_type = is_password and "password" or "string",
                text = is_password and _("密码将以明文保存在本地配置文件中") or nil,
                buttons = {{
                    { text = _("取消"), callback = function() UIManager:close(d) end },
                    {
                        text = _("确定"), is_enter_default = true,
                        callback = function()
                            local value = d:getInputValue()
                            UIManager:close(d)
                            on_ok(value)
                        end,
                    },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end

        -- ---------- 地址管理 ----------
        local ip, port = self:serverAddressParts()
        local address_row = row(_("地址"), ip ~= "" and ip or _("(未设置)"), function()
            editText(_("地址"), ip, false, function(value)
                self:applyServerAddress(value, port)
                refreshDialog()
            end)
        end, { arrow = true })
        local port_row = row(_("端口"), port ~= "" and port or _("(未设置)"), function()
            editText(_("端口"), port, false, function(value)
                self:applyServerAddress(ip, value)
                refreshDialog()
            end)
        end, { arrow = true })

        -- ---------- 账号管理 ----------
        local nickname_row = row(_("昵称"), draft.nickname ~= "" and draft.nickname or _("(未设置)"), function()
            editText(_("昵称"), draft.nickname, false, function(value)
                draft.nickname = tostring(value or "")
                refreshDialog()
            end)
        end, { arrow = true })
        local username_row = row(_("账号"), draft.username ~= "" and draft.username or _("(未设置)"), function()
            editText(_("账号"), draft.username, false, function(value)
                draft.username = tostring(value or "")
                refreshDialog()
            end)
        end, { arrow = true })
        local password_row = row(_("密码"), draft.password ~= "" and "******" or _("(未设置)"), function()
            editText(_("密码"), draft.password, true, function(value)
                draft.password = tostring(value or "")
                refreshDialog()
            end)
        end, { arrow = true })

        -- ---------- 翻页管理 ----------
        -- 只保留两种方案；选中即生效（阅读中会重新注册分区）
        local PAGE_MODE_TEXT = {
            default = { label = _("上下分区"), desc = _("上点上一页 · 下点下一页") },
            left_right = { label = _("左右分区"), desc = _("左点上一页 · 右点下一页") },
        }
        local cur_mode = self:currentPageMode()
        local page_keys = {}
        for key in pairs(PAGE_MODES) do page_keys[#page_keys + 1] = key end
        table.sort(page_keys, function(a, b)
            if (a == "default") ~= (b == "default") then return a == "default" end
            return tostring(a) < tostring(b)
        end)
        local page_rows = {}
        for _i, key in ipairs(page_keys) do
            local info = PAGE_MODE_TEXT[key] or {}
            local chosen = key == cur_mode
            local mode_key = key
            page_rows[#page_rows + 1] = row(
                (chosen and "● " or "○ ") .. tostring(info.label or key),
                tostring(info.desc or ""),
                function()
                    self:saveSetting("page_mode", mode_key)
                    pcall(function() self:setupCenterTap() end)   -- 阅读中即时生效
                    refreshDialog()
                end,
                { value_face = face_desc, selected = chosen })
        end

        -- ---------- 缓存管理 ----------
        local step_btn_w = Screen:scaleBySize(46)
        local step_btn_h = row_h - Screen:scaleBySize(14)
        local value_w = Screen:scaleBySize(62)
        local value_widget
        local function bumpChapters(delta)
            draft.max_chapters = math.max(1, math.min(200, (tonumber(draft.max_chapters) or 3) + delta))
            if value_widget and value_widget.setText then
                pcall(function()
                    value_widget:setText(tostring(draft.max_chapters))
                    value_widget:getSize()
                end)
                UIManager:setDirty(dialog or "all", "ui")
            else
                refreshDialog()
            end
        end
        local function stepButton(text, delta)
            return Button:new{
                text = text, text_font_face = "cfont", text_font_size = 20,
                text_font_bold = true, bordersize = 1, radius = 6,
                width = step_btn_w, height = step_btn_h,
                callback = function() bumpChapters(delta) end,
            }
        end
        value_widget = TextWidget:new{
            text = tostring(draft.max_chapters), face = face_row, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local function ctlRow(label_text, ctl)
            return HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = hpad },
                LeftContainer:new{ dimen = Geom:new{ w = label_w, h = row_h },
                    TextWidget:new{
                        text = label_text, face = face_row, bold = true,
                        max_width = label_w, fgcolor = Blitbuffer.COLOR_BLACK,
                    } },
                RightContainer:new{ dimen = Geom:new{ w = ctl_w, h = row_h }, ctl },
                HorizontalSpan:new{ width = hpad },
            }
        end
        local stepper = HorizontalGroup:new{ align = "center",
            stepButton("－", -1),
            CenterContainer:new{ dimen = Geom:new{ w = value_w, h = row_h }, value_widget },
            stepButton("＋", 1),
        }
        local stepper_row = ctlRow(_("浏览器缓存预加载章节数"), stepper)
        -- 服务器缓存预加载章节数：50 章 / 100 章 / 全部。
        -- 单选：点一次生效（黑底白字），再点一次取消；三个都不选 = 不缓存。
        -- KOReader 的 Button 只支持黑字，画不出黑底白字，这里自绘一个分段按钮。
        local SegButton = InputContainer:extend{
            text = nil, width = nil, height = nil, active = false, callback = nil,
        }
        function SegButton:init()
            local bg = self.active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            local fg = self.active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            local tw = TextWidget:new{
                text = self.text, face = Font:getFace("cfont", 15),
                bold = self.active, fgcolor = fg,
            }
            self[1] = FrameContainer:new{
                bordersize = 1, color = Blitbuffer.COLOR_BLACK, radius = 6,
                background = bg, width = self.width, height = self.height,
                padding = 0, margin = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = math.max(1, self.width - 2),
                        h = math.max(1, self.height - 2) },
                    tw,
                },
            }
            self.dimen = Geom:new{ w = self.width, h = self.height }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        end
        function SegButton:onTap()
            if self.callback then self.callback() end
            return true
        end
        local DEPTH_OPTIONS = {
            { key = "50", label = _("50 章") },
            { key = "100", label = _("100 章") },
            { key = "all", label = _("全部") },
        }
        local seg_gap = Screen:scaleBySize(8)
        local seg_w = math.max(Screen:scaleBySize(56),
            math.floor((ctl_w - seg_gap * (#DEPTH_OPTIONS - 1)) / #DEPTH_OPTIONS))
        local seg_group = HorizontalGroup:new{ align = "center" }
        for _i, opt in ipairs(DEPTH_OPTIONS) do
            local key = opt.key
            local active = draft.cache_depth == key
            seg_group[#seg_group + 1] = SegButton:new{
                text = opt.label,
                width = seg_w, height = step_btn_h,
                active = active,
                callback = function()
                    -- 再点一次同一个 = 取消（不缓存）
                    draft.cache_depth = active and "none" or key
                    refreshDialog()
                end,
            }
            if _i < #DEPTH_OPTIONS then
                seg_group[#seg_group + 1] = HorizontalSpan:new{ width = seg_gap }
            end
        end
        local depth_row = ctlRow(_("服务器缓存预加载章节数"), seg_group)
        local rows = VerticalGroup:new{ align = "left" }
        rows[#rows + 1] = groupTitle(_("地址管理"))
        rows[#rows + 1] = card({ address_row, port_row })
        rows[#rows + 1] = groupTitle(_("账号管理"))
        rows[#rows + 1] = card({ nickname_row, username_row, password_row })
        rows[#rows + 1] = groupTitle(_("翻页管理"))
        rows[#rows + 1] = card(page_rows)
        rows[#rows + 1] = groupTitle(_("缓存管理"))
        rows[#rows + 1] = card({ stepper_row, depth_row })
        rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(14) }
        rows[#rows + 1] = TextWidget:new{
            text = _("点空白处或按返回键关闭并保存；地址/端口立即生效。"),
            face = face_hint, fgcolor = Blitbuffer.COLOR_GRAY_6,
            max_width = inner_w,
        }
        rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        rows[#rows + 1] = TextWidget:new{
            text = _("缓存章节数：点一次生效（黑底白字），再点一次取消；都不选 = 不缓存。"),
            face = face_hint, fgcolor = Blitbuffer.COLOR_GRAY_6,
            max_width = inner_w,
        }
        local card_box = VerticalGroup:new{ align = "left" }
        -- 标题行右侧「✕」：点空白关闭收不到手势时也有可见的关闭入口
        local title_tw = TextWidget:new{
            text = _("设置"), face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local close_w = UICommon.closeButtonSize()
        local stretch = inner_w - title_tw:getSize().w - close_w
        if stretch < 0 then stretch = 0 end
        card_box[#card_box + 1] = HorizontalGroup:new{ align = "center",
            title_tw, HorizontalSpan:new{ width = stretch },
            UICommon.closeButtonAtEdge(saveAndClose, pad, close_w) }
        card_box[#card_box + 1] = rows
        -- 内容比屏幕高时套一层滚动容器（小屏上不至于把首尾行挤出屏幕）
        local body = card_box
        local max_body_h = sh - pad * 2 - Screen:scaleBySize(48)
        local ok_size, card_size = pcall(function() return card_box:getSize() end)
        if ok_size and card_size and tonumber(card_size.h) and card_size.h > max_body_h then
            local ok_scroll, ScrollableContainer = pcall(require, "ui/widget/container/scrollablecontainer")
            if ok_scroll and ScrollableContainer then
                body = ScrollableContainer:new{
                    dimen = Geom:new{ w = inner_w, h = math.max(1, max_body_h) },
                    _show_v_scrollbar = true,
                    card_box,
                }
            end
        end
        local frame = FrameContainer:new{
            -- 边框/圆角与「更多 / 地址管理 / 账号管理」一致：纯黑 2px、圆角 8
            bordersize = 2,
            radius = 8,
            padding = pad,
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_BLACK,
            body,
        }
        -- 全屏浮层：子控件未消费的点击 = 点空白 → 保存并关闭
        local overlay_dimen = Geom:new{ w = sw, h = sh }
        local Overlay = InputContainer:extend{}
        function Overlay:init()
            self.dimen = overlay_dimen
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = overlay_dimen } } }
            if Device:hasKeys() then
                self.key_events = { Close = { { Device.input.group.Back } } }
            end
            self[1] = CenterContainer:new{ dimen = overlay_dimen, frame }
        end

        function Overlay:onTap()
            saveAndClose()
            return true
        end

        function Overlay:onClose()
            saveAndClose()
            return true
        end

        function Overlay:paintTo(bb, x, y)
            -- 半透明压暗：保留弹窗前的首页画面当背景（原来整屏灰底把内容全盖掉）
            UICommon.dimBackdrop(bb, x, y, self.dimen.w, self.dimen.h)
            self[1]:paintTo(bb, x, y)
        end
        dialog = Overlay:new{}
        UIManager:show(dialog)
    end

end

return M
