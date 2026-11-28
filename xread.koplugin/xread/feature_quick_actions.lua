-- xread.koplugin/xread/quick_actions.lua
-- 快捷面板（屏幕中间呼出）里的各个动作：换章、换书、目录、缓存、夜间、排版等。
--
-- 从 main.lua 拆出（Batch 2），方法仍挂在同一个 XRead 类上。
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Device = require("device")
local Screen = require("device").screen
local DeviceListener = require("device/devicelistener")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local MiuiShelf = require("xread.miui.full_shelf_view")
local MiuiHome = require("xread.miui.home_view")
local ReaderToolbar = require("xread.miui.reader_toolbar")
local ReadingStats = require("xread.reading_stats")
local BookExport = require("xread.book_export")
local MessageBox = require("xread.message_box")

local M = {}

function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local BG = env.BG
    local stopBg = env.stopBg
    local pageChapterIndex = env.pageChapterIndex
    local fileSize = env.fileSize
    local disableEndPopup = env.disableEndPopup
    local restoreEndPopup = env.restoreEndPopup
    local hotReload = env.hotReload

    -- ---------- 面板里各快捷动作 ----------
    -- 本机导出的书：正文「下载」会把整本导出成 EPUB，放在「文档目录/xread」。
    -- 这里扫一遍目录，给「本地阅读」面板用（文件名排序按修改时间倒序）。
    function XRead:listExportedBooks()
        local dir
        local ok = pcall(function() dir = BookExport:exportDir() end)
        if not ok or not dir or dir == "" then return "", {} end
        local files = {}
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.dir then
            local ok_dir, iter, dobj = pcall(lfs.dir, dir)
            if ok_dir and iter then
                for name in iter, dobj do
                    if type(name) == "string" and name:lower():match("%.epub$") then
                        local path = dir .. "/" .. name
                        local size, mtime = 0, 0
                        pcall(function()
                            local attr = lfs.attributes(path)
                            if attr then
                                size = tonumber(attr.size) or 0
                                mtime = tonumber(attr.modification) or 0
                            end
                        end)
                        files[#files + 1] = { name = name, path = path, size = size, mtime = mtime }
                    end
                end
            end
        end
        table.sort(files, function(a, b)
            if (a.mtime or 0) ~= (b.mtime or 0) then return (a.mtime or 0) > (b.mtime or 0) end
            return a.name < b.name
        end)
        return dir, files
    end

    -- after_open：阅读器真正显示后调用（用于关掉本地书架）。
    -- 必须在 showReader 之后、用 nextTick 排队，不能在 on_select 里直接关书架：
    -- KOReader 的 showReaderCoroutine 会 forceRePaint 一帧，若那时书架已关，
    -- 画出来的就是下面的首页 —— 用户看到的「先闪一下首页再进正文」。
    function XRead:openLocalBook(path, after_open)
        if not path or path == "" then
            if after_open then after_open() end
            return
        end
        local ReaderUI = require("apps/reader/readerui")
        local tries = 0
        local function doOpen()
            tries = tries + 1
            if self.ui and self.ui.document then
                -- 已经在阅读器里：直接换文档，不用重建 ReaderUI
                if self.ui.document.file == path then
                    local tf = io.open(path, "a")
                    if tf then tf:close() end
                end
                self.ui:switchDocument(path, true)
                if after_open then after_open() end
                return
            end
            if ReaderUI.instance ~= nil and tries < 20 then
                UIManager:scheduleIn(0.15, doOpen)   -- 旧 ReaderUI 还在拆除，等它收完
                return
            end
            if ReaderUI.instance ~= nil and after_open then
                -- 重试耗尽：旧阅读器一直不拆，此时也别把书架永久留在栈里
                UIManager:nextTick(after_open)
            end
            pcall(function() ReaderUI:showReader(path, nil, true) end)
            -- showReaderCoroutine 内部先 forceRePaint、再 nextTick 建阅读器；
            -- 这里排在同批 nextTick 队尾，保证关书架时 reader 已在栈顶。
            if after_open then UIManager:nextTick(after_open) end
        end
        UIManager:nextTick(doOpen)
    end
    -- 本地封面文件：导出目录里和 EPUB 同名的 `<书名>.cover.png`。
    -- 导出/补抓成功后就落一份，删书时跟着 EPUB 一起删。
    local LOCAL_COVER_W, LOCAL_COVER_H = 400, 600
    local function localCoverOf(epub_path)
        local p = tostring(epub_path or ""):gsub("%.epub$", "") .. ".cover.png"
        return lfs.attributes(p, "mode") == "file" and p or nil
    end

    --- 本地 EPUB 对应的「我的书架」条目（按导出文件名反查，名字规则在 BookExport 里）
    function XRead:localShelfBook(name)
        if not name or name == "" then return nil end
        local ok, books = pcall(function() return self.meta_cache:getShelf() end)
        if not ok or type(books) ~= "table" then return nil end
        for _, b in ipairs(books) do
            local stem
            pcall(function() stem = BookExport:baseName(b) end)
            if stem == name then return b end
        end
        return nil
    end

    --- 把「我的书架」那本书的封面存到本地 EPUB 旁边（有缓存直接拷，没有就异步抓一次）。
    -- 存成文件而不是每次都去封面缓存里找：缓存按尺寸命名、还会被清，
    -- 本地书是长期文件，封面得跟着它一起在。
    function XRead:saveLocalCover(book, epub_path, callback)
        local function done(p) if callback then pcall(callback, p) end end
        if not book or not epub_path or epub_path == "" then return done(nil) end
        local existing = localCoverOf(epub_path)
        if existing then return done(existing) end
        local dest = tostring(epub_path):gsub("%.epub$", "") .. ".cover.png"
        local function write(src)
            if not src then return done(nil) end
            local fin = io.open(src, "rb")
            if not fin then return done(nil) end
            local data = fin:read("*a")
            fin:close()
            if not data or #data < 100 then return done(nil) end
            local fout = io.open(dest .. ".tmp", "wb")
            if not fout then return done(nil) end
            fout:write(data)
            fout:close()
            pcall(os.rename, dest .. ".tmp", dest)
            done(localCoverOf(epub_path))
        end
        local cached
        pcall(function() cached = self.cover_cache:anyPathFor(book) end)
        if cached then return write(cached) end
        if type(self._fetchCoverAsync) ~= "function" then return done(nil) end
        local ok = pcall(function()
            self:_fetchCoverAsync(book, LOCAL_COVER_W, LOCAL_COVER_H, write)
        end)
        if not ok then done(nil) end
    end

    -- 「本地阅读」：本机导出的书（正文「下载」导出的 EPUB）用书架同款网格页展示，
    -- 标题就叫「本地阅读」。以前是一个竖排列表弹窗，跟书架风格不统一。
    function XRead:showLocalBooks()
        local _dir, files = self:listExportedBooks()
        if self._local_view then
            pcall(function() UIManager:close(self._local_view) end)
            self._local_view = nil
        end
        if #files == 0 then
            self:showInfo(_("暂无本机导出的书（在正文里按「下载」导出）"), 6)
            return
        end
        local miui_books = {}
        local pending_cover = {}
        for i, f in ipairs(files) do
            local kb = math.max(1, math.floor((tonumber(f.size) or 0) / 1024 + 0.5))
            local title = tostring(f.name):gsub("%.epub$", "")
            local mbook = {
                title = title,
                author = T(_("%1 KB"), tostring(kb)),
                file = f.path,                 -- 有 file 就画「已下载」角标
                bookId = tostring(f.path),
                _xread_local = f.path,
                cover_path = localCoverOf(f.path),
            }
            miui_books[i] = mbook
            -- 没有随书封面：先借「我的书架」同名的封面；连缓存都没有就排队异步抓
            if not mbook.cover_path then
                local shelf_book = self:localShelfBook(title)
                if shelf_book then
                    local cached
                    pcall(function() cached = self.cover_cache:anyPathFor(shelf_book) end)
                    if cached then
                        mbook.cover_path = cached
                    else
                        pending_cover[#pending_cover + 1] = { mbook = mbook, shelf = shelf_book }
                    end
                end
            end
        end
        local view
        -- opening=true：紧接着就要开阅读器，别再整屏重刷一次首页，
        -- 否则关本地书架 → 首页露一帧 → 阅读器才起来，表现为「闪一下首页」。
        local function closeView(opening)
            self._local_view = nil
            if view then pcall(function() UIManager:close(view) end) end
            if not opening then UIManager:setDirty("all", "full") end
        end
        -- 「返回」= 关掉本地阅读页 + 回到我的首页（不是回退到下面的旧画面）
        self._local_back = function()
            closeView()
            self:openHome()
        end
        view = MiuiShelf.show{
            books = miui_books,
            title = _("本地书架"),
            page = 1,
            show_actions = true,
            -- 本地书架只要封面：去掉「已下载 ✓」角标和等比缩放留下的空白行。
            plain_covers = true,
            -- 统计入口已收进首页仪表盘的数据区，本地书架右上角只留「返回」
            left_action_label = "",
            hide_left_action = true,
            on_left_action = nil,
            right_action_label = _("返回"),
            on_right_action = function()
                local back = self._local_back
                if back then back() end
            end,
            on_select = function(mbook)
                local path = mbook and mbook._xread_local
                -- 不再提前关书架：让它在 forceRePaint 那一帧仍盖着首页。
                -- openLocalBook 在 reader 显示后的 nextTick 里回调 closeView。
                if os.getenv("XREAD_AUTOTEST") then
                    print(string.format("[XREAD_AUTOTEST] local_open keep_shelf=%s path=%s",
                        tostring(view and not view._closed), tostring(path)))
                    pcall(function() io.stdout:flush() end)
                end
                self:openLocalBook(path, function()
                    if os.getenv("XREAD_AUTOTEST") then
                        print("[XREAD_AUTOTEST] local_open reader_ready close_shelf=1")
                        pcall(function() io.stdout:flush() end)
                    end
                    closeView(true)
                end)
            end,
            -- 长按删本地文件：本地书架以前没有任何删除入口，
            -- 只能去 KOReader 文件管理器里自己翻目录。
            on_hold = function(mbook)
                self:confirmDeleteLocalBook(mbook and mbook._xread_local)
            end,
            on_back = function()
                local back = self._local_back
                if back then back() end
            end,
            on_close = function() self._local_view = nil end,
        }
        self._local_view = view
        -- 缺封面的后台补：网络段在 fork 里跑完再刷新网格，
        -- 顺带把封面存到 EPUB 旁边，下次离线进来也有图。
        if #pending_cover > 0 then
            UIManager:scheduleIn(0.4, function()
                for _i, item in ipairs(pending_cover) do
                    self:saveLocalCover(item.shelf, item.mbook._xread_local, function(path)
                        if not path then return end
                        item.mbook.cover_path = path
                        local v = self._local_view
                        if v and not v._miu_closed and type(v.updateItems) == "function" then
                            v:updateItems()
                        end
                    end)
                end
            end)
        end
    end

    --- 删除本地导出的 EPUB（连同随附封面），只动本机文件，不动服务器上的书。
    function XRead:confirmDeleteLocalBook(path)
        path = tostring(path or "")
        if path == "" then return end
        MessageBox.confirm{
            text = T(_("删除本机这一份？\n%1\n\n服务器上的书和阅读进度都不受影响。"), path),
            ok_text = _("删除"),
            callback = function(ok)
                if not ok then return end
                -- os.remove 成功返回 true；pcall 只说明「没抛异常」，
                -- 所以要看返回值本身，否则删不掉也会报成功。
                local ok_rm, res = pcall(os.remove, path)
                local removed = ok_rm and res ~= nil and res ~= false
                local cover = localCoverOf(path)
                if cover then pcall(os.remove, cover) end
                if os.getenv("XREAD_AUTOTEST") then
                    print(string.format("[XREAD_AUTOTEST] local_book_deleted path=%s ok=%s",
                        tostring(path), tostring(removed)))
                    pcall(function() io.stdout:flush() end)
                end
                -- 重开列表：删完立刻看到结果，不留一张点不开的空卡片
                self:showLocalBooks()
                if not removed then self:showInfo(_("删除失败")) end
            end,
        }
    end

    function XRead:showReadingStats()
        local ok, view = pcall(function() return ReadingStats:new{} end)
        if not ok then
            logger.warn("xread reading stats failed:", tostring(view))
            self:showInfo(_("阅读记录打开失败"))
            return
        end
        UIManager:show(view)
        UIManager:setDirty("all", "full")
    end
    -- 首页「夜晚」：整屏切换（正文、菜单、弹出页都跟着反色）。
    --
    -- 之前这里广播 SetNightMode(not cur)，cur 用「设置 OR 屏幕」。一旦正文按钮
    -- 让 Screen.night_mode 和 G_reader_settings.night_mode 不一致，DeviceListener
    -- 只按设置值比对，会把「切回日间」当成已经到位而跳过，于是首页按钮连续点
    -- 都没反应。现在直接按屏幕当前视觉状态翻转一次，并在翻转前把设置同步到
    -- 屏幕状态，保证 DeviceListener 的绝对判断和画面始终一致。
    function XRead:_globalNightOn()
        local on = false
        pcall(function() on = (Screen and Screen.night_mode) and true or false end)
        return on
    end
    -- 当前这本书是否处于「视觉夜晚」。没单独设过时跟随全局夜晚，
    -- 一旦正文按钮切换过就按这本书自己的设置走。
    function XRead:_bookNightOn()
        local ui = self.ui
        if not ui then return false end
        local ds = ui.doc_settings
        local v = nil
        if ds then pcall(function() v = ds:readSetting("xread_book_night") end) end
        if type(v) == "boolean" then return v end
        return self:_globalNightOn()
    end
    -- 正文局部夜晚的源色是否需要写成深色：
    -- 全局夜晚靠整屏反色实现。要让正文在反色后仍是用户选的明暗，
    -- 源色必须在「书本地夜晚 ≠ 全局夜晚」时才写成深色。
    function XRead:_bookNightSourceDark()
        return self:_bookNightOn() ~= self:_globalNightOn()
    end

    function XRead:_bookNightCss()
        if not self:_bookNightSourceDark() then return "" end
        return [[
    html, body { background-color: #000000 !important; color: #F2F2F2 !important; }
    body, body * { color: #F2F2F2 !important; border-color: #555555 !important; }
    a, a * { color: #F2F2F2 !important; }
    ]]
    end
    -- 正文局部夜晚：只改文档样式，不动 Screen 反色，所以菜单和弹出页不受影响。
    -- 复用 applyParaIndent 的样式表入口，避免覆盖用户已有的 style tweaks。
    -- 书内「夜晚」只改正文颜色（不整屏反色），而页脚是 ReaderFooter 自己画的
    -- 白色 FrameContainer，于是出现「正文黑、页脚白」这种半截反色。
    -- 这里按「源色」把页脚底色 / 文字色一起翻过来：
    --   书内夜晚 ≠ 全局夜晚 → 页脚写深色（正片是黑底白字）
    --   相等           → 写浅色（正片白底黑字；全局夜晚时由整屏反色负责翻黑）
    function XRead:_applyReaderChromeNight()
        local ui = self.ui
        if not ui then return end
        local footer = ui.view and ui.view.footer
        if not footer then return end
        local dark = self:_bookNightSourceDark()
        local Blitbuffer = require("ffi/blitbuffer")
        pcall(function()
            -- 页脚容器会被 updateFooterContainer 按白底重建，所以先重建再改色
            if footer.updateFooterContainer then footer:updateFooterContainer() end
            if footer.footer_content then
                footer.footer_content.background =
                    dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            end
            if footer.footer_text then
                footer.footer_text.fgcolor =
                    dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            end
            if footer.resetLayout then footer:resetLayout(true) end
            if footer.updateFooterText then footer:updateFooterText(true) end
        end)
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] chrome_night dark=" .. tostring(dark))
        end
    end

    function XRead:_applyBookNightCss()
        local ui = self.ui
        if not (ui and ui.document) then return end
        local dark = self:_bookNightSourceDark()
        pcall(function()
            if ui.document.setBackgroundColor then
                ui.document:setBackgroundColor(dark and "#000000"
                    or (G_reader_settings and G_reader_settings:readSetting("cre_background_color")))
            end
        end)
        pcall(function() self:applyParaIndent() end)
        -- 正文换色后页脚也要跟着换，否则夜里正文黑、页脚一条白
        self:_applyReaderChromeNight()
    end

    function XRead:toggleNightMode()
        local visual = self:_globalNightOn()
        -- 让 DeviceListener 的判断基准与画面一致，避免上面的「点了没反应」。
        pcall(function()
            if G_reader_settings and G_reader_settings:isTrue("night_mode") ~= visual then
                G_reader_settings:saveSetting("night_mode", visual)
            end
        end)
        -- 直接调用一次设备层的翻转，不走 broadcastEvent：
        -- 窗口栈里多个监听者各自翻转会相互抵消。
        pcall(function() DeviceListener:onToggleNightMode() end)
        UIManager:setDirty("all", "full")
        -- 全局反色后，正文局部夜晚的源色要跟着重算一次。
        self:_applyBookNightCss()
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] global_night=" .. tostring(self:_globalNightOn())
                .. " book_night=" .. tostring(self:_bookNightOn()))
        end
    end
    -- 正文菜单/工具栏的「夜晚」：只切当前书籍的明暗，菜单和弹出页保持原样。
    function XRead:toggleBookNightMode()
        local ui = self.ui
        if not (ui and ui.doc_settings) then return end
        local on = not self:_bookNightOn()
        pcall(function()
            ui.doc_settings:saveSetting("xread_book_night", on)
            ui.doc_settings:flush()
        end)
        self:_applyBookNightCss()
        UIManager:setDirty("all", "full")
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] book_night=" .. tostring(on)
                .. " global_night=" .. tostring(self:_globalNightOn()))
        end
    end

    function XRead:changeFontSize(delta)
        local ui = self.ui
        if not ui then return end
        local ok = pcall(function() ui:handleEvent(Event:new("ChangeSize", delta)) end)
        if not ok then pcall(function() ui.font:onChangeSize(delta) end) end
    end
    -- 行距加减（百分比，100 = 原生行距）。走 crengine 的 setInterlineSpacePercent，
    -- 与 KOReader 原生「行距」设置是同一个值，所以两处显示一致。
    -- 不用 Event:new("SetLineSpace") 是因为它会额外弹一个 Notification，
    -- 连点几下 ± 就会弹一串提示盖住正文。
    function XRead:changeLineSpacing(delta)
        local ui = self.ui
        if not (ui and ui.document) then return end
        local cur = 100
        pcall(function()
            local f = ui.font
            cur = tonumber(f and f.configurable and f.configurable.line_spacing) or 100
        end)
        local target = math.max(50, math.min(200, cur + (tonumber(delta) or 0)))
        if target == cur then return end
        pcall(function()
            if ui.font and ui.font.configurable then
                ui.font.configurable.line_spacing = target
            end
            ui.document:setInterlineSpacePercent(target)
            ui:handleEvent(Event:new("UpdatePos"))
        end)
    end

    function XRead:jumpChapter(delta)
        local chapters = SHARED.chapters
        if not chapters then return end
        local target = (SHARED.index or 1) + delta
        if target < 1 or target > #chapters then
            self:showInfo(_("已经到头了"))
            return
        end
        self:jumpToChapter(target)
    end

    function XRead:jumpToChapter(target)
        local book, chapters = SHARED.book, SHARED.chapters
        if not book or not chapters or not chapters[target] then return end
        if SHARED.panel then
            local p = SHARED.panel
            SHARED.panel = nil
            UIManager:close(p)
        end
        self:runQuiet(function()
            self:openAtChapter(book, chapters, target)
        end)
    end

    function XRead:reloadCurrent()
        local ui = self.ui
        if not ui or not ui.document then return end
        local path = ui.document.file
        SHARED.txt_size = fileSize(path)
        UIManager:nextTick(function() hotReload(ui, path) end)
    end

    function XRead:syncProgress()
        local book, index = SHARED.book, SHARED.index
        if not book or not self.client then return end
        local ok = pcall(function()
            self.client:saveBookProgress(book, math.max(0, (index or 1) - 1))
        end)
        if not ok then self:showInfo(_("同步失败")) end
    end
    -- 书源切换：每次点击从当前源的下一个开始，按顺序试 5 个启用小说源；
    -- 搜到精确同名书即换到新书源并重开当前章；没找到则记住游标，下次点击接着找。
    function XRead:switchBookSource()
        local book, chapters, index = SHARED.book, SHARED.chapters, SHARED.index
        if not book or not chapters or not self.client then
            self:showInfo(_("从书架打开书后才能切换书源"))
            return
        end
        local cur_title = chapters[index] and (chapters[index].title or chapters[index].name) or nil
        self:runQuiet(function()
            if not self:ensureLogin() then return end
            local ok, sources = pcall(function() return self.client:getBookSources() end)
            if not ok or type(sources) ~= "table" or #sources == 0 then
                self:showInfo(_("获取书源失败"))
                return
            end
            -- 只取启用的文字书源
            local list = {}
            for _, s in ipairs(sources) do
                if s.enabled and (tonumber(s.bookSourceType) or 0) == 0 and s.bookSourceUrl then
                    list[#list + 1] = s
                end
            end
            if #list == 0 then
                self:showInfo(_("没有可用书源"))
                return
            end
            -- 起点：优先用记忆的游标，否则从当前源的下一个开始
            SHARED.source_cursor = SHARED.source_cursor or {}
            local start_i = tonumber(SHARED.source_cursor[book.bookUrl])
            if not start_i then
                local cur_origin = tostring(book.origin or ""):match("^([^#]+)") or ""
                start_i = 1
                for i, s in ipairs(list) do
                    if tostring(s.bookSourceUrl or "") == cur_origin then start_i = i + 1 break end
                end
                if start_i > #list then start_i = 1 end
            end
            -- 单源短超时，坏源不拖死整个切换（超时随请求传入，不碰全局 http.TIMEOUT）
            local found_book, found_source, tried = nil, nil, 0
            local pos = start_i
            while tried < 5 do
                local s = list[pos]
                pos = pos % #list + 1
                tried = tried + 1
                local candidates = self.client:searchBook(book.name, s.bookSourceUrl, 8)
                for _, cand in ipairs(candidates) do
                    if tostring(cand.name or "") == tostring(book.name) and cand.bookUrl then
                        found_book, found_source = cand, s
                        break
                    end
                end
                if found_book then break end
            end
            if not found_book then
                -- 这 5 个源都没有：记住游标，下次点击接着找
                SHARED.source_cursor[book.bookUrl] = pos
                self:showInfo(T(_("试了 %1 个源没找到本书，再点一次继续找"), tried))
                return
            end
            -- 新源拿目录，优先按当前章标题对位，对不上就按原章序号
            local ok3, new_chapters = pcall(function() return self.client:getChapterList(found_book) end)
            if not ok3 or type(new_chapters) ~= "table" or #new_chapters == 0 then
                SHARED.source_cursor[book.bookUrl] = pos
                self:showInfo(_("新源拿不到目录，再点一次试别的源"))
                return
            end
            local new_index = nil
            if cur_title then
                for i, ch in ipairs(new_chapters) do
                    if tostring(ch.title or ch.name or "") == tostring(cur_title) then new_index = i break end
                end
            end
            if not new_index then new_index = math.min(index, #new_chapters) end
            -- 更新服务器书架里的书源（尽力而为，失败不影响本次阅读）
            pcall(function() self.client:saveBook(found_book) end)
            -- 清旧游标，新书记录下次起点
            SHARED.source_cursor[book.bookUrl] = nil
            SHARED.source_cursor[found_book.bookUrl] = pos
            found_book.durChapterIndex = new_index - 1
            self:openAtChapter(found_book, new_chapters, new_index)
        end)
    end
    -- 翻页 / 换章监听：ReaderUI:handleEvent 会遍历自身数组里的 widget 调 onXxx，
    -- 往数组里注册一个小模块即可收到 PageUpdate / PosUpdate。
    -- 用于「正常翻到下一章后，菜单里的章节名还是旧的」这个问题。
    function XRead:_ensureReaderPageWatcher()
        local ui = self.ui
        if not ui or self._page_watcher_ui == ui then return end
        self._page_watcher_ui = ui
        local ok_w, Widget = pcall(require, "ui/widget/widget")
        if not ok_w then return end
        local owner = self
        local Watcher = Widget:extend{
            onPageUpdate = function() owner:_onReaderPageChanged() end,
            onPosUpdate = function() owner:_onReaderPageChanged() end,
        }
        local watcher = Watcher:new{}
        -- always_active=true：即使当前不在前台也收事件
        pcall(function() ui:registerModule("xreadPageWatcher", watcher, true) end)
    end
    -- 同一帧里可能连发多个 PageUpdate（跨章时还有 PosUpdate），0.3s 防抖合并成一次刷新
    function XRead:_onReaderPageChanged()
        if self._page_chrome_task then
            pcall(function() UIManager:unschedule(self._page_chrome_task) end)
            self._page_chrome_task = nil
        end
        local task
        task = function()
            if self._page_chrome_task ~= task then return end
            self._page_chrome_task = nil
            pcall(function() self:_refreshReaderChromeFromPage() end)
        end
        self._page_chrome_task = task
        UIManager:scheduleIn(0.3, task)
    end
    -- 按当前页码重算「第 N / M 章」和章节名，刷新正文工具栏 + 底栏。
    -- 原来只有 onReaderReady（打开/跳章）时刷一次，正常翻页跨章后一直是旧章节名。
    function XRead:_refreshReaderChromeFromPage()
        local ui = self.ui
        if not (ui and SHARED.book) then return end
        local doc = ui.document
        if not (doc and doc.file and SHARED.txt_path == doc.file) then return end
        local footer = ui.view and ui.view.footer
        local total = type(SHARED.chapters) == "table" and #SHARED.chapters or 0
        local idx = pageChapterIndex(ui, footer and footer.pageno, SHARED.chapters,
            SHARED.doc_first, SHARED.doc_last)
        if idx then SHARED.index = idx end
        if os.getenv("XREAD_AUTOTEST") and idx then
            local first = tonumber(SHARED.doc_first)
            local last = tonumber(SHARED.doc_last)
            if first and last and (idx < first or idx > last) then
                print("[XREAD_AUTOTEST] chapter_index_out_of_range idx=" .. tostring(idx)
                    .. " first=" .. tostring(first) .. " last=" .. tostring(last))
            end
        end
        if os.getenv("XREAD_DIAG") == "1" then
            local toc = ui and ui.toc and ui.toc.toc
            print(string.format("[XREAD_DIAG] refresh pageno=%s toc=%s first=%s last=%s pages=%s idx=%s total=%s",
                tostring(footer and footer.pageno), tostring(toc and #toc), tostring(SHARED.doc_first),
                tostring(SHARED.doc_last), tostring(footer and footer.pages), tostring(idx), tostring(total)))
        end
        local cur = math.max(1, math.min(tonumber(SHARED.index) or 1, math.max(1, total)))
        local ch = (SHARED.chapters and SHARED.chapters[cur]) or {}
        local ch_title = ch.title or ch.name
        if not ch_title or ch_title == "" then
            ch_title = T(_("第 %1 章"), tostring(cur))
        end
        pcall(function()
            ReaderToolbar.refreshHeader({
                title = SHARED.book.name or _("未知书籍"),
                chapter_label = tostring(ch_title),
                location_label = T(_("第 %1 / %2 章"), tostring(cur), tostring(total)),
                progress_label = (total > 0 and tostring(math.floor(cur / total * 100 + 0.5)) or "0") .. "%",
            })
        end)
        if footer and footer.updateFooterText then
            pcall(function() footer:updateFooterText(true) end)
        end
    end
    -- 每次阅读器加载好文档记一个会话起点，退出时结算到阅读记录
    function XRead:onReaderReady()
        local doc = self.ui and self.ui.document
        -- 跳章（switchDocument）会先关旧文档：onCloseDocument 把 SHARED.txt_path 清成 nil，
        -- 新文档就绪时若 SHARED.book 仍在（说明是从阅读X打开的书），必须把 txt_path 指回当前文件。
        -- 否则 onReaderTapZone 的 doc.file == SHARED.txt_path 判定失败，点正文中央呼不出工具栏。
        if doc and doc.file and not SHARED.txt_path and SHARED.book then
            SHARED.txt_path, SHARED.txt_size = doc.file, fileSize(doc.file)
        end
        if doc and doc.file and SHARED.txt_path == doc.file then
            SHARED.read_start = os.time()
            -- 跳章会先关旧文档（onCloseDocument 恢复了结束动作），新文档就绪后必须重新关掉；
            -- 否则读到本批末尾仍会执行 KOReader 原生结束动作，闪回书架/文件管理器。
            disableEndPopup()
        end
        -- 底部状态栏：左对齐章节名 / 右对齐页码，去掉进度条
        self:_applyReaderFooter()
        -- 正文排版的用户偏好（段落缩进 / 字体粗细 / 本书夜晚）在每次文档就绪后重新套一遍：
        -- crengine 换文档会丢掉 setStyleSheet 追加的覆盖规则
        pcall(function() self:_applyBookNightCss() end)
        pcall(function() self:applyFontBold() end)
        -- 后台扫描正文 "== 章节标题 ==" 注入 TOC，章节名随翻页自动更新
        self:_injectTocFromText()
        -- 跳章/换文档（switchDocument）会重建阅读器触摸分区，插件注册的 xread_tap_* 丢失：
        -- 必须在文档就绪后重新注册，否则跳章后点正文中央无法呼出工具栏、回不了书架。
        -- onReaderReady 在文档加载完成后触发，是补注册的正确时机。
        self:setupCenterTap()
        -- 监听翻页：正常读到下一章时同步菜单里的章节名 / 底栏章节名
        self:_ensureReaderPageWatcher()
        -- 换书/切书源/跳章后，工具栏若还开着，标题仍是上一本书的名字（正文已变）。
        -- 用当前 SHARED.book 原地刷新标题/章节名，不必关掉重建。
        if SHARED.book and SHARED.chapters then
            local total = #SHARED.chapters
            local idx = SHARED.index or 1
            local ch = SHARED.chapters[idx] or {}
            local ch_title = ch.title or ch.name
            if not ch_title or ch_title == "" then
                ch_title = T(_("第 %1 章"), tostring(idx))
            end
            pcall(function()
                ReaderToolbar.refreshHeader({
                    title = SHARED.book.name or _("未知书籍"),
                    chapter_label = tostring(ch_title),
                    location_label = T(_("第 %1 / %2 章"), tostring(idx), tostring(total)),
                    progress_label = (total > 0 and tostring(math.floor(idx / total * 100 + 0.5)) or "0") .. "%",
                })
            end)
        end
        -- 目录跳章：目录一直盖在正文上，等新文档就绪才收起来。
        -- 这样「关目录 → switchDocument 关旧文档」的中间空档不会露出底层书架。
        local overlay = self._switch_overlay
        if overlay then
            self._switch_overlay = nil
            pcall(function() UIManager:close(overlay) end)
        end
        -- footer 的 pageno 要等 ReaderView 重新布局后才是新文档的值，
        -- 这里延后一点再按页码校正一次章节名（跳章后立即刷新会拿到旧页码）。
        UIManager:scheduleIn(0.6, function()
            pcall(function() self:_refreshReaderChromeFromPage() end)
        end)
    end
    -- 章内页码：覆盖 KOReader footer 的 page_progress 生成器。
    -- 只对「从阅读X打开的书」生效（doc.file == SHARED.txt_path）：
    -- 显示 当前章内第几页 / 本章总页数（如 3/10）；其他书保留 KOReader 原生行为。
    do
        local ok_rf, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
        if ok_rf and ReaderFooter and type(ReaderFooter.textGeneratorMap) == "table" then
            ReaderFooter.textGeneratorMap.page_progress = function(footer)
                local is_xread = SHARED.txt_path
                    and footer.ui and footer.ui.document
                    and footer.ui.document.file == SHARED.txt_path
                if is_xread then
                    local pageno = footer.pageno or 1
                    local pages = footer.pages or 1
                    local toc = footer.ui.toc and footer.ui.toc.toc
                    if type(toc) == "table" and #toc > 0 then
                        -- 二分查找「最后一个起始页 <= 当前页」的章节。
                        -- 原来是 1..3000 线性扫描并且每次 footer 重绘都跑一遍，
                        -- 3000 章的目录每翻一页要比较约 3000 次。toc 已按 page 升序。
                        local idx = 0
                        local lo, hi = 1, #toc
                        while lo <= hi do
                            local mid = math.floor((lo + hi) / 2)
                            if (tonumber(toc[mid].page) or 0) <= pageno then
                                idx = mid
                                lo = mid + 1
                            else
                                hi = mid - 1
                            end
                        end
                        -- 兜底修正：目录里若混入 page 缺失/乱序条目，二分可能偏一格，
                        -- 在命中点附近做一次小范围修正（代价恒定）。
                        for i = math.max(1, idx - 2), math.min(#toc, idx + 3) do
                            if (tonumber(toc[i].page) or 0) <= pageno then idx = i end
                        end
                        if idx > 0 then
                            local start_page = tonumber(toc[idx].page) or 1
                            local next_start = (toc[idx + 1] and tonumber(toc[idx + 1].page)) or (pages + 1)
                            local total = next_start - start_page
                            if total < 1 then total = 1 end
                            local in_ch = pageno - start_page + 1
                            if in_ch < 1 then in_ch = 1 end
                            if in_ch > total then in_ch = total end
                            return string.format("%d / %d", in_ch, total)
                        end
                    end
                    return string.format("%d / %d", pageno, pages)
                end
                -- 非 xread 书：保持 KOReader 原生行为
                if footer.ui.pagemap and footer.ui.pagemap:wantsPageLabels() then
                    return ("%s / %s"):format(footer.ui.pagemap:getCurrentPageLabel(true),
                        footer.ui.pagemap:getLastPageLabel(true))
                end
                return ("%d / %d"):format(footer.pageno or 1, footer.pages or 1)
            end
            -- 底栏左侧章节名：跳章 / 换文档后 toc 可能还没重建，
            -- getTocTitleByPage 返回空串 → 底栏只剩右边页码（用户反馈的「只有右边没有左边」）。
            -- xread 的书用章节表兜底，保证左边永远有可读的章节名。
            ReaderFooter.textGeneratorMap.book_chapter = function(footer)
                local title
                local ok_t, t = pcall(function()
                    return footer.ui.toc:getTocTitleByPage(footer.pageno)
                end)
                if ok_t then title = t end
                if not title or title == "" then
                    local is_xread = SHARED.txt_path and footer.ui and footer.ui.document
                        and footer.ui.document.file == SHARED.txt_path
                    if is_xread then
                        local idx = pageChapterIndex(footer.ui, footer.pageno, SHARED.chapters,
                            SHARED.doc_first, SHARED.doc_last) or SHARED.index or 1
                        local ch = (SHARED.chapters and SHARED.chapters[idx]) or {}
                        title = ch.title or ch.name or T(_("第 %1 章"), tostring(idx))
                    end
                end
                if not title or title == "" then title = _("正文") end
                local ok_f, fitted = pcall(function()
                    return footer:getFittedText(title, footer.settings.book_chapter_max_width_pct)
                end)
                return ok_f and fitted or title
            end
        end
    end
    -- 底部状态栏改为：左对齐当前章节名 + 右对齐页码（1/11），不再显示进度条
    -- 浅拷贝：footer.settings 是 G_reader_settings 内部表的引用，直接改字段等于改用户全局配置
    local function shallowCopyTable(t)
        local o = {}
        if type(t) == "table" then
            for k, v in pairs(t) do o[k] = v end
        end
        return o
    end
    --- 恢复被本插件改写的 footer 设置（关闭 xread 书时调用）
    -- 因为不再写 G_reader_settings，恢复只是把实例字段换回原表，
    -- 防止同一 ReaderUI 实例复用（reloadDocument 等）时残留定制样式。
    function XRead:_restoreReaderFooter()
        local orig = self._footer_orig_settings
        if not orig then return end
        self._footer_orig_settings = nil
        local footer = self.ui and self.ui.view and self.ui.view.footer
        if not footer then return end
        pcall(function()
            footer.settings = orig
            if footer.set_mode_index then footer:set_mode_index() end
            -- 与 _applyReaderFooter 对称：settings 变了就要重建 mode_list / 重算 has_no_mode，
            -- 否则恢复后 mode_list 仍是 xread 定制态，原生书的底栏显示/切换会错乱
            footer.mode_list = {}
            for i = 0, #footer.mode_index do
                footer.mode_list[footer.mode_index[i]] = i
            end
            if footer.set_has_no_mode then footer:set_has_no_mode() end
            if footer.updateFooterTextGenerator then footer:updateFooterTextGenerator() end
            -- 还原原来的显示模式（xread 里可能被切成 off / page_progress）
            local orig_mode = self._footer_orig_mode
            self._footer_orig_mode = nil
            if footer.applyFooterMode and orig_mode ~= nil then
                footer:applyFooterMode(orig_mode)
            end
            if footer.updateFooterContainer then footer:updateFooterContainer() end
            -- 退出本书时把书内夜晚改过的页脚颜色还原成默认（白底黑字），
            -- 否则同一 ReaderUI 实例的底栏会留着白字，下本书的白色页脚上看不见
            local Blitbuffer = require("ffi/blitbuffer")
            if footer.footer_content then
                footer.footer_content.background = Blitbuffer.COLOR_WHITE
            end
            if footer.footer_text then
                footer.footer_text.fgcolor = Blitbuffer.COLOR_BLACK
            end
            if footer.resetLayout then footer:resetLayout(true) end
            if footer.updateFooterText then footer:updateFooterText(true) end
        end)
    end

    function XRead:_applyReaderFooter()
        local footer = self.ui and self.ui.view and self.ui.view.footer
        if not footer or not footer.settings then
            if os.getenv("XREAD_AUTOTEST") then
                print("[XREAD_AUTOTEST] footer apply: no footer")
            end
            return
        end
        local ok, err = pcall(function()
            -- 备份原始设置（只在第一次进入时），再在副本上改。
            -- 原实现直接把 footer.settings（即 G_reader_settings 里的表）改掉并
            -- saveSetting + flush() 落盘：读一本 xread 的书之后，再打开任何原生
            -- EPUB/TXT，底部栏也被改成「章节名+页码」、时间/电量/百分比全部消失，
            -- 且不会自动恢复（用户原配置已被覆盖）。
            if not self._footer_orig_settings then
                self._footer_orig_settings = shallowCopyTable(footer.settings)
                -- 记下原始显示模式：关掉「页尾页码」时会把 mode 切成 off，
                -- 离开本书时必须还原，否则再打开原生 EPUB 底栏就再也出不来
                self._footer_orig_mode = footer.mode
            end
            local s = shallowCopyTable(footer.settings)
            footer.settings = s
            s.disable_progress_bar = true          -- 去掉进度条
            s.all_at_once = true                   -- 默认只显示一项，必须打开才能同显多项
            -- 关掉默认开启的其它元素，只保留：章节名 + 弹性填充 + 页码
            s.time, s.pages_left, s.percentage = false, false, false
            s.book_time_to_read, s.chapter_time_to_read = false, false
            s.battery = false
            -- 打开需要的三个元素；dynamic_filler 用空格撑满中间，实现左右两端对齐
            s.book_chapter = true
            s.dynamic_filler = true
            s.page_progress = true
            s.book_chapter_max_width_pct = 60      -- 长章节名最多占屏宽 60%，超出省略号截断
            s.order = { "book_chapter", "dynamic_filler", "page_progress" }
            footer:set_mode_index()
            -- set_mode_index 只重建 mode_index（模式名数组），不重建 mode_list（name→index 映射），
            -- 也不重算 has_no_mode、不更新 view.footer_visible。这三样正是决定底栏是否显示的关键，
            -- init() 里是依次做的；这里改 settings 后必须同样补齐，否则底栏「消失」、页码不显示。
            footer.mode_list = {}
            for i = 0, #footer.mode_index do
                footer.mode_list[footer.mode_index[i]] = i
            end
            if footer.set_has_no_mode then footer:set_has_no_mode() end
            footer:updateFooterTextGenerator()
            footer:updateFooterContainer()
            -- 强制把底栏置为可见（切到 page_progress 模式），并触发可见性变化通知，
            -- 让 ReaderView 重新为底栏分配显示空间；
            -- 「正文设置 → 页面管理 → 页尾页码」关掉时改切 off 模式（footer_visible=false，
            -- 正文会把这一行的高度收回去）。
            if self:getSetting("reader_footer", "1") == "0" then
                if footer.mode_list and footer.mode_list.off ~= nil then
                    footer:applyFooterMode(footer.mode_list.off)
                elseif footer.applyFooterMode then
                    footer:applyFooterMode(0)
                end
            elseif footer.applyFooterMode and footer.mode_list.page_progress then
                footer:applyFooterMode(footer.mode_list.page_progress)
            end
            -- updateFooterContainer 重建了 positioner（dimen 为空），必须强制重算布局
            footer:resetLayout(true)
            -- updateFooterText 要等 footer 自己的 onReaderReady 才初始化为真实现，
            -- 延迟调用确保能真正刷新文本
            UIManager:scheduleIn(1, function()
                if footer.updateFooterText then footer:updateFooterText(true) end
            end)
            -- 注意：这里**不再** G_reader_settings:saveSetting("footer", s) + flush()。
            -- 那两行会把定制永久写进用户全局配置，影响之后打开的所有原生书。
        end)
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] footer apply: " .. tostring(ok) .. " " .. tostring(err))
        end
        -- 底栏刚被按白底重建：书内夜晚时要把底色/文字色再翻一次
        self:_applyReaderChromeNight()
    end
    -- 扫描 TXT 正文里的 "== 章节标题 ==" 行，构建 页码->章节 映射并注入 KOReader TOC。
    -- HTML 正文：crengine 从 h2 自动生成原生 TOC，无需注入；纯 TXT 才走扫描注入。
    function XRead:_injectTocFromText()
        local ui = self.ui
        local doc = ui and ui.document
        if not (doc and ui.toc) then return end
        if not (doc.file and SHARED.txt_path == doc.file) then return end
        -- 原生 TOC 已有内容（HTML h2）：直接用，不注入
        local native = ui.toc.toc
        if type(native) == "table" and #native > 0 then
            -- crengine 会把 <title> 标签也生成一条「空标题」TOC 条目（通常在 page=1）。
            -- footer 的 book_chapter 通过 getTocTitleByPage 命中的是「本页第一条」，
            -- 空标题条目会让正文底部左侧章节名显示为空。这里过滤掉空标题条目（page 映射不变）。
            local cleaned = {}
            for _, e in ipairs(native) do
                local t = e and e.title
                if type(t) == "string" and t:gsub("%s", "") ~= "" then
                    cleaned[#cleaned + 1] = e
                end
            end
            if #cleaned > 0 then
                ui.toc.toc = cleaned
                local footer = ui.view and ui.view.footer
                if footer and footer.updateFooterText then footer:updateFooterText(true) end
            end
            if os.getenv("XREAD_AUTOTEST") then
                print("[XREAD_AUTOTEST] toc injected: native " .. tostring(#native)
                    .. " cleaned " .. tostring(#cleaned))
            end
            return
        end
        if os.getenv("XREAD_NO_TOC_SCAN") == "1" then return end
        local pages = 0
        pcall(function() pages = doc:getPageCount() or 0 end)
        if pages < 1 then return end
        local items = {}
        local scan  -- 分批扫描，每帧 25 页，避免卡住翻页交互
        scan = function(from)
            if not (self.ui and self.ui.document == doc) then return end  -- 已换书/退出
            local to = math.min(pages, from + 24)
            for p = from, to do
                local ok, found = pcall(function()
                    local x0 = doc:getPageXPointer(p)
                    if not x0 then return nil end
                    local x1 = doc:getPageXPointer(p + 1)   -- 超界返回 nil 时退化为单点
                    local text
                    if x1 then
                        text = doc:getTextFromXPointers(x0, x1)
                    else
                        text = doc:getTextFromXPointer(x0)
                    end
                    if not text or text == "" then return nil end
                    local list = {}
                    for line in text:gmatch("[^\n]+") do
                        local t = line:match("^==%s*(.-)%s*==$")
                        if t and t ~= "" then list[#list + 1] = t end
                    end
                    return list
                end)
                if ok and type(found) == "table" then
                    for _, t in ipairs(found) do
                        items[#items + 1] = { page = p, title = t }
                    end
                end
            end
            if to < pages then
                UIManager:scheduleIn(0.05, function() scan(to + 1) end)
            elseif #items > 0 then
                pcall(function()
                    ui.toc.toc = items
                    local footer = ui.view and ui.view.footer
                    if footer then footer:updateFooterText(true) end
                    if os.getenv("XREAD_AUTOTEST") then
                        print("[XREAD_AUTOTEST] toc injected: " .. tostring(#items))
                    end
                end)
            end
        end
        UIManager:scheduleIn(1.5, function() scan(1) end)
    end
    -- 退出书籍：清掉“正在阅读”标记，后台缓存下一步就会自己停

    function XRead:onCloseDocument()
        -- 热加载（追加新章节后刷新同一个文件）不算退出书籍
        if SHARED.reloading then return end
        -- 结算本次阅读会话（阅读记录），跳章切换文档时也会走这里，之后由 onReaderReady 重新计时
        if SHARED.read_start and SHARED.book then
            local elapsed = os.time() - SHARED.read_start
            SHARED.read_start = nil
            if elapsed > 0 and elapsed < 12 * 3600 then
                pcall(function() ReadingStats.record(SHARED.book.name, elapsed) end)
            end
        end
        if SHARED.panel then
            local panel = SHARED.panel
            SHARED.panel = nil
            UIManager:close(panel)
        end
        -- 文档路径：优先当前阅读器的 ui.document，其次插件实例快照的 self.document。
        -- self.document 是插件实例创建时传入的快照，reloadDocument 之后它会指向
        -- 已关闭的旧对象；只认它会让下面的清理（open_path / txt_path / 首页时钟）全部失效。
        local doc = self.ui and self.ui.document
        local path = (doc and doc.file) or (self.document and self.document.file)
        -- 恢复被 _applyReaderFooter 改写的底栏定制（只影响本实例，不动全局设置）
        self:_restoreReaderFooter()
        if not path then return end
        if SHARED.open_path == path then
            SHARED.open_path = nil
        end
        if SHARED.ui and SHARED.ui.document and SHARED.ui.document.file == path then
            SHARED.ui = nil
        end
        if SHARED.txt_path == path then
            -- 退出同步：关书时把当前章上传到云端。放在清空 SHARED.index 之前，
            -- 失败静默（后端刚判定不可达时直接跳过，不让关书卡在网络超时上）。
            self:_uploadProgressOnExit()
            SHARED.txt_path = nil
            SHARED.txt_size = nil
            restoreEndPopup()
            if BG.job and BG.job.path == path then stopBg("closed book") end
        end
    end
    -- 读到本批末尾：若磁盘上已经追加了新章节，就热加载让用户接着往下翻
    function XRead:onEndOfBook()
        local doc = self.ui.document
        if not doc or not doc.file then return end
        local path = doc.file
        if SHARED.txt_path ~= path then return end
        -- 读到末尾前再兜一次：任何路径把 end_document_action 恢复成别的值时，
        -- KOReader 会在最后一页执行原生结束动作（打开文件管理器/下一本），
        -- 真机表现就是连续翻页突然闪回书架。
        disableEndPopup()
        local size = fileSize(path)
        logger.dbg("xread EndOfBook", path, "size", tostring(size), "loaded", tostring(SHARED.txt_size))
        if SHARED.txt_size and size > SHARED.txt_size + 512 then
            SHARED.txt_size = size
            UIManager:nextTick(function() hotReload(self.ui, path) end)
            return true
        end
        local job = BG.job
        if job and job.path == path and job.next <= job.last then
            job.want_reload = true
            -- 静默等后续章节：补齐后 auto-reload 会自动接上，不弹提示打断阅读
            logger.info("xread end of book, waiting for next chunks")
            return true
        end
        -- 本批章节已读完（后台也补完了）：同样吞掉事件。
        -- 不能让 KOReader 落回自带的「文档结束」动作（可能配置成打开文件管理器/下一本），
        -- 否则正文里连续点下一页会突然闪回书架。退出请走工具栏「书架 / 首页」。
        -- 但完全静默会让人误以为"翻页失灵/卡死"，所以第一次到底给一次轻提示。
        if self._end_notified_path ~= path then
            self._end_notified_path = path
            UIManager:nextTick(function()
                pcall(function()
                    self:showInfo(_("已到本书最后一章"))
                end)
            end)
        end
        logger.info("xread end of book, no more chunks; swallow end action")
        return true
    end
    -- 返回书架：先退出书籍，回到文件管理器，再把书架弹出来

    function XRead:closeBookToShelf()
        -- 验收标记：仅供 tests/ 判定返回书架链路是否执行（生产环境不输出）
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] close_book_to_shelf done")
        end
        local ui = self.ui
        -- 切换界面的瞬间屏蔽一下触摸，避免这一下的“抬手”被新界面当成点击
        if Device.input and Device.input.inhibitInputUntil then
            Device.input:inhibitInputUntil(0.8)
        end
        UIManager:nextTick(function()
            -- 关书与重建书架必须在同一个 UI tick 内完成。
            -- 之前先盖书架 → 延时 0.15s 关书 → 再延时 0.4s 补书架，
            -- 中间两次 repaint 会把 KOReader 文件管理器露出来（闪现 xread_books）。
            -- onHome 会关书并重新拉起文件管理器；只 close 的话整个 UI 会一起退出。
            if ui and ui.document then
                if ui.onHome then
                    ui:onHome()
                else
                    ui:onClose()
                end
            end
            -- 关书后立刻盖书架：同一 tick 内入窗，
            -- UIManager 下一次 repaint 直接画书架，不再经过文件管理器那一帧
            local fm = SHARED.fm
            if fm and fm.openShelf then
                pcall(function() fm:openShelf() end)
            else
                pcall(function() self:openShelf() end)
            end
        end)
    end
    -- 返回我的首页：与 closeBookToShelf 同思路——先把首页盖到最上层，再关书，
    -- 避免关书露出文件管理器闪现。供正文工具栏顶部「首页」按钮使用。
    function XRead:closeBookToHome()
        if Device.input and Device.input.inhibitInputUntil then
            Device.input:inhibitInputUntil(0.8)
        end
        UIManager:nextTick(function()
            local ui = self.ui
            -- 先把遗留首页收干净。HomeView 内部还留着 live_widget 时，
            -- show 会走「原地更新」并返回那个旧实例；旧实例若在文件管理器下面，
            -- 真机就表现为点首页没反应 / 只闪一下别的页面。
            self:_stopHomeTicker()
            if self._home_view and not self._home_view._miu_closed then
                pcall(function() UIManager:close(self._home_view) end)
            end
            pcall(function() MiuiHome.close() end)
            self._home_view = nil
            SHARED.home_view = nil
            -- 先在 ReaderUI 还盖满屏幕时把新首页建好（此刻入栈但看不见），
            -- 再关书：同一 tick 内只会有一次重绘，直接落在新首页上。
            pcall(function() self:showHome(self._home_shelf_page or 1) end)
            if ui and ui.document then
                if ui.onHome then
                    ui:onHome()
                else
                    ui:onClose()
                end
            end
            -- onHome 会拉起文件管理器并可能把它放到栈顶，盖住刚建好的首页
            local FM = nil
            pcall(function() FM = require("apps/filemanager/filemanager") end)
            if FM and FM.instance and UIManager:isWidgetShown(FM.instance) then
                pcall(function() UIManager:close(FM.instance) end)
            end
            -- 首页若被意外挤下去（仍存活），重新置顶
            local view = self._home_view
            if view and not view._miu_closed and not UIManager:isWidgetShown(view) then
                pcall(function() UIManager:show(view) end)
            end
        end)
    end
end

return M
