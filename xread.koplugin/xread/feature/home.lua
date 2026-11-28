-- xread.koplugin/xread/feature/home.lua
-- miuread 首页（视觉层）：最近阅读、操作行、分类页签、我的书架预览、
-- 以及首页自动验收（XREAD_AUTOTEST_FLOW）里的 home_* 流程。
--
-- 从 main.lua 拆出（Batch 2），方法仍挂在同一个 XRead 类上。
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local Trapper = require("ui/trapper")
local Event = require("ui/event")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local BookFilter = require("xread.book_filter")
local GridShelf = require("xread.shelf_grid")
local MiuiShelf = require("xread.miui.full_shelf_view")
local MiuiHome = require("xread.miui.home_view")
local Repaint = require("xread.miui.repaint")
local ReadingStats = require("xread.reading_stats")
local ProgressToast = require("xread.progress_toast")

local M = {}

function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local BackendProbe = env.BackendProbe

    -- ---------- 第二步：miuread 首页（视觉层，数据来自 xread 书架） ----------

    function XRead:openHome()
        -- 本地已有书架缓存：直接渲染，不为了登录态先卡一次网络。
        -- （首页的封面/进度刷新都会在后台补，登录态仅在写操作时才需要）
        local cached = self.meta_cache:getShelf(nil)
        if cached and #cached > 0 then
            self:showHome()
            return
        end
        -- 首次使用、本地没有缓存：唯一必须联网的情况，先做 2.5s 探活
        self:withBackend(function()
            self:runQuiet(function()
                if self:ensureLogin() then self:showHome() end
            end)
        end)
    end
    -- 首页顶栏信息（昵称等）保存后，若首页正开着就立即重建（实时生效）
    -- 首页上下文的验收 flow。
    -- 阅读器里的 flow 走 XRead:init() 里 self.ui.document 那一支；书架/首页/布局
    -- 这几类验收没有已开文档，必须在 XREAD_AUTOTEST=home 之后单独跑。
    function XRead:_runHomeAutotestFlow(flow)
        flow = tostring(flow or "")
        local function mark(tag) print("[XREAD_AUTOTEST] " .. tag) end
        if flow == "display_size" then
            -- 三档界面字号依次重建首页：验证 compact/standard/large 都不溢出、不崩。
            -- 这是 UiScale 唯一会改变全局几何的开关，改动布局常量时必须跑一遍。
            UIManager:scheduleIn(4, function()
                local UiScale = require("xread.miui.ui_scale")
                local modes = { "standard", "compact", "large" }
                local i = 0
                local step
                step = function()
                    i = i + 1
                    if i > #modes then
                        UiScale.setDisplayMode("standard")
                        mark("flow=display_size done")
                        return
                    end
                    local mode = modes[i]
                    UiScale.setDisplayMode(mode)
                    pcall(function()
                        if self._home_view then
                            UIManager:close(self._home_view)
                            self._home_view = nil
                        end
                        self:showHome(1)
                    end)
                    mark("flow=display_size mode=" .. mode
                        .. " sw=" .. tostring(Screen:getWidth())
                        .. " sh=" .. tostring(Screen:getHeight()))
                    UIManager:scheduleIn(4, step)
                end
                step()
            end)
        elseif flow == "rotate" then
            -- 横屏/竖屏各重建一次首页：布局必须按新尺寸重算，封面不能越界。
            UIManager:scheduleIn(6, function()
                local function rebuild()
                    if self._home_view then
                        UIManager:close(self._home_view)
                        self._home_view = nil
                    end
                    pcall(function() self:showHome(1) end)
                end
                pcall(function() Screen:setRotationMode(1) end)
                UIManager:scheduleIn(3, function()
                    rebuild()
                    UIManager:scheduleIn(4, function()
                        mark("flow=rotate landscape=" .. tostring(Screen:getWidth())
                            .. "x" .. tostring(Screen:getHeight()))
                        pcall(function() Screen:setRotationMode(0) end)
                        UIManager:scheduleIn(3, function()
                            rebuild()
                            UIManager:scheduleIn(4, function()
                                mark("flow=rotate done portrait=" .. tostring(Screen:getWidth())
                                    .. "x" .. tostring(Screen:getHeight()))
                            end)
                        end)
                    end)
                end)
            end)
        elseif flow == "layout_edge" then
            -- 边界数据：超长书名 / 空作者 / 无封面 / 进度 0 / 超过一页，
            -- 直接用假 books 开全屏书架，不依赖后端。
            UIManager:scheduleIn(5, function()
                local books = {}
                for i = 1, 13 do
                    books[i] = {
                        bookUrl = "edge://" .. tostring(i),
                        title = (i == 1) and string.rep("超长书名压测", 10) or ("边界书 " .. tostring(i)),
                        author = (i == 2) and "" or ("作者" .. tostring(i)),
                        progress = (i == 3) and 0 or ((i * 7) % 101),
                    }
                end
                local ok, view = pcall(function()
                    return MiuiShelf.show{
                        books = books,
                        title = _("边界测试"),
                        page = 1,
                        show_actions = true,
                        on_back = function(v) pcall(function() UIManager:close(v) end) end,
                    }
                end)
                self._edge_view = ok and view or nil
                mark("flow=layout_edge done ok=" .. tostring(ok) .. " n=" .. tostring(#books))
            end)
        elseif flow == "shelf_paging" then
            -- 全屏书架翻页：每页重建整棵树，验证旧树被释放后不崩、翻页数正确。
            UIManager:scheduleIn(5, function()
                local books = {}
                for i = 1, 30 do
                    books[i] = {
                        bookUrl = "page://" .. tostring(i),
                        title = "翻页测试 " .. tostring(i),
                        author = "作者",
                        progress = i % 100,
                    }
                end
                local ok, view = pcall(function()
                    return MiuiShelf.show{
                        books = books,
                        title = _("翻页测试"),
                        page = 1,
                        show_actions = true,
                        on_back = function(v) pcall(function() UIManager:close(v) end) end,
                    }
                end)
                self._paging_view = ok and view or nil
                mark("flow=shelf_paging open ok=" .. tostring(ok)
                    .. " pages=" .. tostring(ok and view and view.pages or 0))
                if not ok or not view then return end
                UIManager:scheduleIn(3, function()
                    pcall(function() view:_change_page(1) end)
                    UIManager:scheduleIn(3, function()
                        pcall(function() view:_change_page(1) end)
                        UIManager:scheduleIn(3, function()
                            pcall(function() view:_change_page(-1) end)
                            UIManager:scheduleIn(2, function()
                                mark("flow=shelf_paging done page=" .. tostring(view.page)
                                    .. " pages=" .. tostring(view.pages))
                            end)
                        end)
                    end)
                end)
            end)
        elseif flow == "memory_info" then
            -- 内存档位与缓存策略快照（供 XREAD_MEM_TIER=low 的低内存路径验收）
            UIManager:scheduleIn(3, function()
                local Memory = require("xread.miui.memory")
                Memory.reset()
                mark("flow=memory_info " .. Memory.describe())
            end)
        elseif flow == "search_panel" then
            -- 搜索加书入口：只验 UI（输入框 + 取消/搜索按钮），不发请求。
            UIManager:scheduleIn(5, function()
                local ok = pcall(function() self:searchAndAddBook() end)
                mark("flow=search_panel done ok=" .. tostring(ok))
                -- 留足时间让测试先截图再关闭（之前 3s 关掉，截图只剩首页）
                UIManager:scheduleIn(14, function()
                    local top = UIManager:getTopmostVisibleWidget()
                    mark("flow=search_panel top=" .. tostring(top and (top.name or top.id or "widget") or "nil")
                        .. " shown=" .. tostring(top ~= nil))
                    pcall(function() if top then UIManager:close(top) end end)
                end)
            end)
        elseif flow == "test_conn" then
            -- 验收：首页顶部「已断开」时点「测试连接」，成功后顶部应立即变「已连接」，
            -- 而不是等下一轮 60s 心跳或手动刷新（见 testConnection 成功分支的 header 回写）。
            UIManager:scheduleIn(5, function()
                self._health_ok = false
                pcall(function()
                    if self._home_view then self._home_view:updateHeader{ sync_text = _("已断开") } end
                end)
                mark("flow=test_conn disconnected")
                UIManager:scheduleIn(2, function()
                    self:testConnection()
                    UIManager:scheduleIn(6, function()
                        mark("flow=test_conn health_ok=" .. tostring(self._health_ok))
                        mark("flow=test_conn done")
                    end)
                end)
            end)
        else
            mark("flow=unknown name=" .. flow)
        end
    end

    -- 首页整页重建的最小间隔。
    -- 保存设置/切账号/同步进度这几条路径都会调 _refreshHomeIfOpen，用户很快
    -- 连做两步时（改地址→保存，再改昵称→保存）原来会连续重建两次整页：
    -- 每次都要关掉旧首页、重新 prepareCovers、重新排整棵树，PW3 上肉眼可见地
    -- 顿一下并黑闪。间隔内的请求合并成一次延迟重建，用户看到的是「保存后一次刷新」。
    local HOME_REBUILD_MIN_INTERVAL = 0.6

    local function precise_now()
        local ok, socket = pcall(require, "socket")
        if ok and socket and socket.gettime then return socket.gettime() end
        return os.time()
    end

    function XRead:_rebuildHomeNow()
        if not (self._home_view and not self._home_view._miu_closed) then return end
        self._home_rebuild_at = precise_now()
        self:_stopHomeTicker()
        UIManager:close(self._home_view)
        self._home_view = nil
        pcall(function() self:showHome(self._home_shelf_page or 1) end)
    end

    function XRead:_refreshHomeIfOpen()
        if not (self._home_view and not self._home_view._miu_closed) then return end
        local now = precise_now()
        local last = tonumber(self._home_rebuild_at) or 0
        local elapsed = now - last
        if elapsed < HOME_REBUILD_MIN_INTERVAL then
            -- 刚重建过：撤销上一个待执行的合并重建，按最新状态再排一次
            Repaint.debounce("home.rebuild", HOME_REBUILD_MIN_INTERVAL - elapsed, function()
                self:_rebuildHomeNow()
            end)
            return
        end
        Repaint.cancel("home.rebuild")
        self:_rebuildHomeNow()
    end
    -- 最近阅读卡片右上角刷新：只更新 hero 一张卡，不重建整页、不打断心跳/封面循环。
    -- 与现有「更新」按钮（整页重建）和 30s 心跳（只刷时间/连接）职责分离；
    -- 为避免和后台封面重试的 getBookshelf/putShelf 竞态，刷新期间停掉封面循环，结束再恢复。
    function XRead:refreshRecentBook()
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] hero_refresh tapped shown=" .. tostring(MiuiHome.is_shown()))
        end
        if not MiuiHome.is_shown() then return end
        if self._opening_book or SHARED.open_path then return end
        self:runQuiet(function()
            local ok, books = pcall(function() return self.client:getBookshelf(true) end)
            if not ok or type(books) ~= "table" or #books == 0 then
                UIManager:nextTick(function()
                    self:showBackendIssue{
                        title = _("刷新失败"),
                        text = _("最近阅读暂时取不到，先看缓存内容。"),
                    }
                end)
                return
            end
            pcall(function() self.meta_cache:putShelf(books) end)
            -- 选书规则与 showHome 保持一致：按最后阅读时间，时间相同才比章节号
            local hero_book = books[1]
            for _b, b in ipairs(books) do
                local bt = tonumber(b.durChapterTime) or 0
                local ht = tonumber(hero_book.durChapterTime) or 0
                if bt > ht then
                    hero_book = b
                elseif bt == ht
                    and (tonumber(b.durChapterIndex) or 0) > (tonumber(hero_book.durChapterIndex) or 0) then
                    hero_book = b
                end
            end
            local last_url = self._last_open_book_url or self:getSetting("last_book_url", "")
            if last_url ~= "" then
                for _b, b in ipairs(books) do
                    if tostring(b.bookUrl or "") == tostring(last_url) then hero_book = b break end
                end
            end
            local layout = GridShelf.computeLayout(1)
            local cover_paths = self:prepareCovers({ hero_book }, 1, 1, layout, true)
            -- 本地还没缓存封面时，刷新后异步补一张；否则「刷新」只会把空白封面
            -- 再画一遍，看起来像按钮没生效。
            local hero_src = self.cover_cache:sourceFor(hero_book)
            if cover_paths[hero_book] == nil and hero_src then
                self:_fetchCoverAsync(hero_book, layout.cover_w, layout.cover_h, function(p)
                    if not p or not MiuiHome.is_shown() or self._opening_book then return end
                    local hero2 = self:_makeHeroInfo(hero_book, { [hero_book] = p })
                    hero2.cover_path, hero2.home_cover_path = p, p
                    pcall(function() MiuiHome.update_hero(hero2) end)
                end)
            end
            local hero = self:_makeHeroInfo(hero_book, cover_paths)
            local updated = MiuiHome.update_hero(hero)
            if not updated then
                -- 几何变化导致局部刷新失败：退回整页重建兜底
                pcall(function() self:_refreshHomeIfOpen() end)
            end
        end)
    end
    -- 首页点左上角标题：呼出 KOReader 菜单（阅读X 入口所在）；无菜单上下文时退回更多面板
    function XRead:openReaderMenuFromHome()
        -- 直接调菜单对象的 onShowMenu：以前广播 Event("ShowMenu")，
        -- 但 FileManager/ReaderUI 本身都不处理这个事件（只有菜单模块处理），
        -- 事件走空 → 点标题毫无反应。这里按「菜单对象」逐层找，找到就开。
        local candidates = { self.ui, SHARED.ui, SHARED.fm,
            SHARED.fm and SHARED.fm.ui or nil }
        for _i, ui in ipairs(candidates) do
            local menu = type(ui) == "table" and ui.menu or nil
            if menu and type(menu.onShowMenu) == "function" then
                local ok = pcall(function() menu:onShowMenu() end)
                if ok then return end
            end
        end
        -- 兜底：没有可用菜单（例如刚退回、FM 已拆）时直接弹「更多」，别让点击石沉大海
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] header_title fallback more_panel")
        end
        self:showMorePanel()
    end
    -- 首页「同步」：把插件本地记录的书籍进度推到后端。
    -- 本地进度来自 meta_cache 的书架缓存（开书/手动同步时 updateShelfProgress 写入），
    -- 只推本地比后端更新的条目，避免用旧进度覆盖服务器。
    function XRead:syncProgressFromHome()
        -- 先探活：地址不通时立刻提示，不让「同步」看起来像没反应
        self:withBackend(function()
        self:runQuiet(function()
            if not self:ensureLogin() then return end
            local local_books = self.meta_cache:getShelf(nil) or {}
            local ok_remote, remote = pcall(function() return self.client:getBookshelf() end)
            if not ok_remote or type(remote) ~= "table" then
                self:showBackendIssue{
                    title = _("同步失败"),
                    text = _("这次没同步成功，缓存书架仍可阅读。"),
                }
                return
            end
            local remote_index = {}
            for _, b in ipairs(remote) do
                remote_index[tostring(b.bookUrl or "")] = {
                    index = tonumber(b.durChapterIndex) or 0,
                    time = tonumber(b.durChapterTime) or 0,
                }
            end
            local failed, pushed, skipped_old = 0, 0, 0
            local n_local = #local_books
            if n_local > 0 then
                pcall(function() ProgressToast.show(T(_("正在同步 %1/%2"), "0", tostring(n_local))) end)
            end
            for n, b in ipairs(local_books) do
                local key = tostring(b.bookUrl or b.name or "")
                local li = tonumber(b.durChapterIndex)
                local lt = tonumber(b.durChapterTime) or 0
                local r = remote_index[key]
                local ri = r and r.index
                local rt = (r and r.time) or 0
                -- 只推「本地确实更新」的条目：章节更靠后，且本地进度时间不比服务器旧。
                -- 原来只比章节号，会把几周前的旧本地进度推上去，覆盖其它设备的新进度。
                local newer = li ~= nil and (ri == nil or li > ri)
                if newer and lt > 0 and rt > 0 and lt < rt then
                    newer = false
                    skipped_old = skipped_old + 1
                end
                if key ~= "" and newer then
                    local ok = pcall(function()
                        return self.client:saveBookProgress(b, li)
                    end)
                    if ok then
                        pushed = pushed + 1
                    else
                        failed = failed + 1
                    end
                end
                -- 每推几本刷新一次进度（同一个进度框原地改字，不新建 widget）
                if n % 5 == 0 and n < n_local then
                    pcall(function()
                        ProgressToast.update(T(_("正在同步 %1/%2"), tostring(n), tostring(n_local)))
                    end)
                end
            end
            -- 同步完拉一次最新书架写回缓存，首页进度与后端一致
            local ok_fresh, fresh = pcall(function() return self.client:getBookshelf() end)
            if ok_fresh and type(fresh) == "table" and #fresh > 0 then
                pcall(function() self.meta_cache:putShelf(fresh) end)
            end
            pcall(function() ProgressToast.close() end)
            if failed > 0 then
                self:showInfo(T(_("同步失败 %1 本"), tostring(failed)))
            elseif pushed > 0 then
                logger.info("xread synced", pushed, "book progress entries")
            end
            pcall(function() self:_refreshHomeIfOpen() end)
        end)
        end)
    end
    -- 搜书并加入书架：按书名搜启用书源，结果点一下即 saveBook
    function XRead:searchAndAddBook()
        local InputDialog = require("ui/widget/inputdialog")
        local d
        d = InputDialog:new{
            title = _("搜索书籍"),
            input = "",
            input_type = "string",
            buttons = {{
                { text = _("取消"), callback = function() UIManager:close(d) end },
                { text = _("搜索"), is_enter_default = true, callback = function()
                    local kw = d:getInputValue()
                    UIManager:close(d)
                    if not kw or kw == "" then return end
                    self:withBackend(function()
                    self:runQuiet(function()
                        if not self:ensureLogin() then return end
                        local found = nil
                        local ok_s, sources = pcall(function() return self.client:getBookSources() end)
                        if ok_s and type(sources) == "table" then
                            -- 单源短超时，坏源不拖死搜索（超时随请求传入，不碰全局 http.TIMEOUT）
                            for _si, s in ipairs(sources) do
                                if s.enabled and s.bookSourceUrl then
                                    local ok_r, res = pcall(function()
                                        return self.client:searchBook(kw, s.bookSourceUrl, 8)
                                    end)
                                    if ok_r and type(res) == "table" and #res > 0 then
                                        found = res
                                        break
                                    end
                                end
                            end
                        end
                        UIManager:nextTick(function()
                            if not found or #found == 0 then
                                self:showInfo(T(_("没有找到：%1"), tostring(kw)))
                                return
                            end
                            local items = {}
                            for _ri, r in ipairs(found) do
                                items[#items + 1] = {
                                    label = tostring(r.name or "?") .. "　" .. tostring(r.author or ""),
                                    callback = function()
                                        self:runQuiet(function()
                                            local ok_save = pcall(function() self.client:saveBook(r) end)
                                            pcall(function() self.meta_cache:clearShelf() end)
                                            UIManager:nextTick(function()
                                                if not ok_save then self:showInfo(_("加入书架失败")) end
                                            end)
                                        end)
                                    end,
                                }
                            end
                            self:showMoreListPanel(_("搜索结果"), items,
                                { hint = _("点击条目加入书架；点空白处返回。") })
                        end)
                    end)
                    end)
                end },
            }},
        }
        UIManager:show(d)
        pcall(function() d:onShowKeyboard() end)
    end
    -- 首页中部功能按钮排（参考 miuread：更新/搜索/同步/夜晚/设置）
    function XRead:buildHomeActions()
        return {
            { icon_key = "refresh", label = _("更新"), callback = function()
                -- 拉取最新书架，写回缓存后重建整个首页。
                -- 旧首页保持到 showHome 里「数据就绪、马上建新页」时才关，
                -- 否则取书架这段同步请求期间底层文件管理器会闪出来。
                -- 先探活：地址不对时 2.5s 内提示，不把首页冻住十几秒。
                if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] refresh_tap") end
                self:withBackend(function()
                self:runQuiet(function()
                    if not self:ensureLogin() then return end
                    local ok, books = pcall(function() return self.client:getBookshelf(true) end)
                    if ok and type(books) == "table" and #books > 0 then
                        pcall(function() self.meta_cache:putShelf(books) end)
                        self:showHome(self._home_shelf_page or 1)
                    else
                        -- 后端拉取失败时退回原缓存重建首页，不让用户看到空白
                        self:showHome(self._home_shelf_page or 1)
                        UIManager:nextTick(function()
                            self:showBackendIssue{
                                title = _("更新失败"),
                                text = _("书架暂时更新不了，当前显示缓存内容。"),
                            }
                        end)
                    end
                end)
                end)
            end },
            { icon_key = "search", label = _("搜索"), callback = function() self:searchAndAddBook() end },
            { icon_key = "sync", label = _("同步"), callback = function() self:syncProgressFromHome() end },
            {
                -- 首页夜晚：月亮=当前日间（点击进夜晚），太阳=当前夜晚（点击回日间）
                icon_key = (function()
                    local ok, Screen = pcall(function() return require("device").screen end)
                    return (ok and Screen and Screen.night_mode) and "sun" or "night"
                end)(),
                label = _("夜晚"),
                callback = function()
                    -- 立即生效：走 KOReader 官方事件（全局反色+重绘），再重建首页让图标/文案同步切换
                    self:toggleNightMode()
                    self:_stopHomeTicker()
                    if self._home_view and not self._home_view._miu_closed then
                        UIManager:close(self._home_view)
                    end
                    self._home_view = nil
                    self:showHome(self._home_shelf_page or 1)
                end,
            },
            { icon_key = "settings", label = _("设置"), callback = function() self:showSettings() end },
        }
    end

    function XRead:showHome(page)
        -- 注意：单实例收尾放在「数据已经准备好、马上要建新首页」处（见下方 MiuiHome.show 前），
        -- 不能一进函数就关旧首页——否则中途取书架失败会只剩空白/底层视图可看。
        local ttl = tonumber(self:getSetting("shelf_cache_ttl", "300")) or 300
        local books = self.meta_cache:getShelf(ttl)
        if not books then
            -- 缓存过期时先用旧缓存渲染（进度可能略旧），后台再静默刷新；
            -- 避免从书架点返回时卡在同步网络请求上（真机表现为「返回没反应」）
            books = self.meta_cache:getShelf(nil)
            if books then
                -- 去重 + 节流：反复进出首页原来会叠出多个 1s 后的同步 getBookshelf。
                -- 只保留一个待执行的刷新，且 60s 内不重复拉。
                local last = self._home_refresh_at or 0
                if not self._home_refresh_pending and os.time() - last >= 60 then
                    self._home_refresh_pending = true
                    UIManager:scheduleIn(1, function()
                        self._home_refresh_pending = false
                        self._home_refresh_at = os.time()
                        -- 用户可能已经点书或进书架了：别和开书/书架上的点击抢网络
                        if self._opening_book or SHARED.open_path then return end
                        local shelf = SHARED.shelf_view
                        if shelf and not shelf._miu_closed then return end
                        if not self.client.accessToken then return end
                        local ok, fresh = pcall(function() return self.client:getBookshelf() end)
                        if ok and fresh and #fresh > 0 then self.meta_cache:putShelf(fresh) end
                    end)
                end
            end
        end
        if not books then
            -- 本地完全没有书架缓存（首次安装 / 清过缓存）：
            -- 先探活再请求，地址不通时 2.5s 内给出明确提示，而不是卡到 socket 超时。
            if self._home_loading then return end
            self._home_loading = true
            local accepted = self:withBackend(function()
                self._home_loading = false
                local ok, res = pcall(function() return self.client:getBookshelf() end)
                if ok and type(res) == "table" and #res > 0 then
                    self.meta_cache:putShelf(res)
                    self:showHome(page)
                else
                    self:showBackendIssue{
                        title = _("首页加载失败"),
                        text = _("暂时取不到书架，可以先看本地缓存。"),
                    }
                end
            end, { on_fail = function() self._home_loading = false end })
            if not accepted then self._home_loading = false end
            return
        end
        -- 只展示小说与漫画（过滤视频类条目）
        books = BookFilter.filterReadable(books)
        if not books or #books == 0 then
            self:showBackendIssue{
                title = _("首页加载失败"),
                text = _("书架暂时是空的，可能还没同步。"),
            }
            return
        end
        self._shelf_books = books
        -- 首页书架分页：每页 8 本，真正翻页（下一页仍是填满书籍的常规书架网格）
        local per_page = 8
        local total_pages = math.max(1, math.ceil(#books / per_page))
        page = tonumber(page) or self._home_shelf_page or 1
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        self._home_shelf_page = page
        local page_books = {}
        local start_i = (page - 1) * per_page + 1
        for _pi = start_i, math.min(#books, start_i + per_page - 1) do
            page_books[#page_books + 1] = books[_pi]
        end
        local layout = GridShelf.computeLayout(#page_books)
        local show_n = #page_books
        -- 预取本页书籍的章节目录（hero 最近在读优先），点书秒开
        self:_prefetchRecentChapters(books, page_books)
        local cover_paths = self:prepareCovers(page_books, 1, show_n, layout, true)
        local miui_books = self:_toMiuiBooks(page_books, cover_paths)
        -- hero = 最近读的书：按最后阅读时间（durChapterTime）挑，没有时间信息的老数据
        -- 才回退到章节号。用章节号时，上月读到第 500 章的书会一直霸占首页卡片，
        -- 而昨天读到第 3 章的根本不会出现。
        local hero_book = books[1]
        for _hb, b in ipairs(books) do
            local bt = tonumber(b.durChapterTime) or 0
            local ht = tonumber(hero_book.durChapterTime) or 0
            if bt > ht then
                hero_book = b
            elseif bt == ht
                and (tonumber(b.durChapterIndex) or 0) > (tonumber(hero_book.durChapterIndex) or 0) then
                hero_book = b
            end
        end
        -- 本会话最后打开的书优先；重启后回退到设置里持久化的最近打开书
        local last_url = self._last_open_book_url or self:getSetting("last_book_url", "")
        if last_url ~= "" then
            for _hb, b in ipairs(books) do
                if tostring(b.bookUrl or "") == tostring(last_url) then hero_book = b break end
            end
        end
        -- hero 不在当前书架页时单独备好封面。
        -- 注意必须把 prepareCovers 的返回值合并回 cover_paths：原来只 pcall 不接返回值，
        -- 首页左上角那张封面永远是空白的（书架里同一本书却有图）。
        if cover_paths[hero_book] == nil then
            local ok_hero_cover, hero_covers = pcall(function()
                return self:prepareCovers({ hero_book }, 1, 1, layout, true)
            end)
            if ok_hero_cover and type(hero_covers) == "table" then
                for hb, hp in pairs(hero_covers) do cover_paths[hb] = hp end
            end
        end
        local hero = self:_makeHeroInfo(hero_book, cover_paths)
        -- 右侧区域：上面时钟，下面本周阅读记录（每天打卡）
        local week_stats = {}
        pcall(function() week_stats = ReadingStats.getHomeStats() end)
        local username = tostring(self:getSetting("username", "") or "")
        -- 首页显示昵称：设置里的昵称优先，其次登录账号名，最后兜底「书友」
        local nickname = tostring(self:getSetting("nickname", "") or "")
        if nickname == "" then nickname = username end
        if nickname == "" then nickname = _("书友") end
        local empty_stats = { available = false, message = _("本地暂无阅读数据") }
        local opts = {
            title = _("阅读X"),
            account_name = nickname,
            -- 顶部连接状态：先显示「连接中」，0.5s 后第一次 health 检查刷新
            sync_text = _("连接中"),
            hero = hero,
            shelf_books = miui_books,
            shelf_title = _("我的书架"),
            shelf_page = page,
            shelf_pages = total_pages,
            home_actions = self:buildHomeActions(),
            tabs = {},
            shelf_subtabs = {},
            show_weread_stats = false,
            show_local_stats = true,
            local_stats = week_stats,
            show_clock_card = true,
            clock_text = os.date("%H:%M"),
            date_text = os.date("%m月%d日 ") .. ({ "周日", "周一", "周二", "周三", "周四", "周五", "周六" })[(tonumber(os.date("%w")) or 0) + 1],
            -- 「本地阅读」卡片：标题进本地书架，数据区进阅读记录
            on_local_stats = function() self:showLocalBooks() end,
            on_weread_stats = function() self:showReadingStats() end,
            on_open_book = function(mbook) self:openBook(mbook._xread_book) end,
            on_hold_book = function(mbook) self:showBookCatalog(mbook._xread_book, mbook.cover_path) end,
            on_shelf_page = function(delta)
                -- 向后翻：进「我的书架」页（4 排书那页）
                -- 不在取数据前关首页：关掉后底层文件管理器会露出一帧
                if (tonumber(delta) or 0) > 0 then
                    self:showBookshelf(1)
                    return
                end
                -- 向前翻：首页内回上一页；showHome 内部在数据就绪后才换页
                self:showHome((self._home_shelf_page or 1) + delta)
            end,
            on_quick_panel = function() self:openShelf() end,
            on_menu = function() self:showMorePanel() end,
            -- 点左上角「阅读X」标题呼出 KOReader 菜单（首页/书架/阅读记录…入口所在）
            on_header_title = function() self:openReaderMenuFromHome() end,
            -- 点昵称区域 → 账号管理；点 Wi-Fi 后的连接状态区域 → 地址管理
            on_account = function() self:showAccountManage() end,
            on_sync = function() self:showServerManage() end,
        }
        -- 单实例：数据已就绪，建新首页前先收掉旧首页。
        -- 反复「首页 → 书架 → 返回」会把旧首页留在窗口栈里叠出多份，
        -- 多份首页各自带时钟/连接检测/封面重试，越用越卡，且返回时会看到旧帧。
        if self._home_view and not self._home_view._miu_closed then
            self:_stopHomeTicker()
            pcall(function() UIManager:close(self._home_view) end)
        end
        -- 只关 _home_view 不够：HomeView 内部 live_widget 可能指向另一个仍在栈里的
        -- 首页实例，show 会原地更新它并返回；若它被文件管理器盖住，首页就永远出不来。
        pcall(function() MiuiHome.close() end)
        self._home_view = nil
        local view = MiuiHome.show(opts)
        self._home_view = view
        SHARED.home_view = view
        -- 首屏封面队列是否还在跑：更新提示要等它结束再弹（见 _notifyUpdateWhenHomeReady）
        self._home_covers_busy = true
        self:_queueMissingCovers(page_books, 1, show_n, layout, miui_books, view,
            function(i)
                if miui_books[i] then view:updateBook(miui_books[i].bookId) end
            end,
            function() self._home_covers_busy = false end)
        -- hero 封面异步补救：不在当前书架页 / 首次打开时缓存还没好，
        -- 单独拉一张并在完成后只刷新「最近阅读」这一张卡（不动整页）。
        if hero and hero_book and not hero.cover_path
            and self.cover_cache:sourceFor(hero_book) then
            self:_fetchCoverAsync(hero_book, layout.cover_w, layout.cover_h, function(p)
                if not p or view._miu_closed or self._home_view ~= view then return end
                hero.cover_path, hero.home_cover_path = p, p
                pcall(function() MiuiHome.update_hero(hero) end)
            end)
        end
        -- 首页定时器：时钟每 30s 走字；服务器连接状态每 60s 测一次（异常时明确显示）
        self:_startHomeTicker(view)
        -- 无封面书籍定时静默拉取：后端稍后生成封面后自动补上
        self:_startCoverRetryLoop(view, function(b)
            pcall(function() view:updateBook(tostring(b.bookUrl)) end)
        end)
        -- 自动检查更新：首页起来后错峰查一次，发现新版才提示（失败无声）
        self:quietUpdateCheck(10)
        -- 看书时攒下的「发现新版本」提示，回到首页再补一次
        if self._update_pending_notice then
            self._update_pending_notice = nil
            UIManager:scheduleIn(1.0, function()
                if self._home_view == view then self:_notifyUpdateWhenHomeReady() end
            end)
        end
    end
    -- 首页顶部「已同步」= 服务器连接状态；首页时钟 + 日期定时刷新
    function XRead:_startHomeTicker(view)
        self:_stopHomeTicker()
        if not view then return end
        local week_text = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }
        local rounds = 0
        local last_minute, last_date
        local tick
        tick = function()
            if self._home_view ~= view or SHARED.open_path then
                self._home_timer = nil
                return   -- 首页已关闭 / 已进书，停止
            end
            rounds = rounds + 1
            -- 只在「分钟真的变了」时重绘：e-ink 上每一帧都是可见的闪动 + 耗电，
            -- 原来的 30s 一拍即使时间没变也会刷一次首页头部。
            pcall(function()
                local now_str = os.date("%H:%M")
                local date_str = os.date("%m月%d日 ") .. (week_text[(tonumber(os.date("%w")) or 0) + 1] or "")
                if now_str ~= last_minute then
                    last_minute = now_str
                    view:updateHeader{ time_text = now_str }
                end
                if date_str ~= last_date then
                    last_date = date_str
                    view:updateDashboard{ clock_text = now_str, date_text = date_str }
                end
            end)
            -- 后端探活每 4 轮（约 4 分钟）一次：首页只是显示「已连接/已断开」，
            -- 没必要每分钟都开一次 TCP 连接。
            if rounds % 4 == 1 then
                if not self:_backendUsable() then
                    -- 已知连不上：不再发请求，直接按「已断开」显示，等冷却窗口过去再自动重试。
                    self._health_ok = false
                    pcall(function() view:updateHeader{ sync_text = _("已断开") } end)
                elseif not self:_uiHasOverlay() then
                    -- 非阻塞 TCP 探活：原来 client:health 是同步 HTTP（2.5s），
                    -- 后端一慢就把首页冻住、还误判「已断开」并污染冷却状态。
                    -- 这里只改头部「已连接/已断开」的语义 = 网络可达，探活结果异步回调。
                        BackendProbe.check(self:backendAddress(), 2.5, function(ok)
                            self._health_ok = ok
                            pcall(function()
                                view:updateHeader{ sync_text = ok and _("已连接") or _("已断开") }
                            end)
                            -- 之前连通过、这次却连不上：给一次不遮挡的软提示。
                            -- 首页本身已经渲染完，用户仍可点书、翻页、去地址管理。
                            if not ok then self:notifyBackendSoftDownOnce() end
                        end)
                end
            end
            UIManager:scheduleIn(60, tick)
        end
        self._home_timer = tick
        -- 先立刻测一次连接
        UIManager:scheduleIn(0.5, tick)
    end

    function XRead:_stopHomeTicker()
        if self._home_timer then
            pcall(function() UIManager:unschedule(self._home_timer) end)
            self._home_timer = nil
        end
    end

    function XRead:showBookshelf(page, cached_books)
        page = page or 1
        local ok, books
        if cached_books then
            ok, books = true, cached_books
        else
            ok, books = pcall(function() return self.client:getBookshelf() end)
        end
        if not ok then
            self:showBackendIssue{
                title = _("获取书架失败"),
                text = tostring(books),
            }
            -- 书架没开起来：恢复首页心跳（openShelf 开头为让路停掉了它）
            local home = self._home_view
            if home and not home._miu_closed then self:_startHomeTicker(home) end
            return
        end
        books = books or {}
        -- 只展示小说与漫画（过滤视频类条目）
        books = BookFilter.filterReadable(books)
        if #books == 0 then self:showInfo(_("书架中没有小说或漫画")); return end
        if not cached_books then self.meta_cache:putShelf(books) end
        self._shelf_books = books
        local layout = GridShelf.computeLayout(#books)
        local page_count = math.max(1, math.ceil(#books / layout.page_size))
        if page < 1 then page = 1 end
        if page > page_count then page = page_count end
        self._shelf_page = page
        local first = (page - 1) * layout.page_size + 1
        local last = math.min(#books, first + layout.page_size - 1)
        -- 显示后预取本页书籍的章节目录（最近在读优先），下次点开直接命中缓存
        local visible = {}
        for _vi = first, last do visible[#visible + 1] = books[_vi] end
        self:_prefetchRecentChapters(books, visible)
        -- 本函数已在 runQuiet 的 Trapper 协程里，不能再套 Trapper:wrap
        local cover_paths = self:prepareCovers(books, first, last, layout, true)
        -- 第一步整搬 miuread 书架视觉层：默认走新视图，XREAD_SHELF_LEGACY=1 回退旧版
        if os.getenv("XREAD_SHELF_LEGACY") == "1" then
            self:showShelfGrid(books, page, cover_paths)
        else
            self:showMiuiShelfGrid(books, page, cover_paths)
        end
    end
end

return M
