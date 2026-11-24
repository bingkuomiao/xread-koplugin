-- xread.koplugin/main.lua

-- 流程：书架点书 -> 只抓 1 章 -> 立刻打开阅读器 -> 后台静默缓存后续章节

-- 退出书籍（CloseDocument）时自动中断后台缓存。
-- 数据源：xread-fpk /reader3/*（用 xread/client.lua 封装）

local DataStorage  = require("datastorage")

local LuaSettings  = require("luasettings")

local UIManager    = require("ui/uimanager")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local InfoMessage  = require("ui/widget/infomessage")

local InputDialog  = require("ui/widget/inputdialog")

local Menu         = require("ui/widget/menu")

local ConfirmBox   = require("ui/widget/confirmbox")

local Trapper      = require("ui/trapper")

local Event        = require("ui/event")

local Device       = require("device")

local Screen       = require("device").screen

local util         = require("util")

local lfs          = require("libs/libkoreader-lfs")

local http         = require("socket.http")

local logger       = require("logger")

local _            = require("gettext")

local T            = require("ffi/util").template

local ffiutil      = require("ffi/util")

local Client = require("xread.client")

local CoverCache = require("xread.cover_cache")

local BookFilter = require("xread.book_filter")

local ChapterCache = require("xread.chapter_cache")

local MetaCache = require("xread.meta_cache")

local GridShelf = require("xread.shelf_grid")

-- miuread 视觉层（第一步：书架 / 第二步：首页 / 第三步：阅读工具栏）；数据层仍走 xread.client
local MiuiShelf = require("xread.miui.full_shelf_view")
local MiuiHome = require("xread.miui.home_view")
local ReaderToolbar = require("xread.miui.reader_toolbar")

local CatalogView = require("xread.catalog_view")

local QuickPanel = require("xread.quick_panel")

local ReadingStats = require("xread.reading_stats")

local XRead = WidgetContainer:extend{

    name = "xread",

    is_doc_only = false,

    version = "0.5.0",

}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/xread.lua"

local BOOK_DIR = DataStorage:getDataDir() .. "/xread_books"

-- 书架在 FileManager 里、阅读器里是另一个插件实例，

-- 后台缓存和“当前正在读哪本书”必须放模块级，两个实例才通得上。
local SHARED = {

    client = nil,       -- 复用同一个 Client，登录 token 不用重复拿

    ui = nil,           -- 当前 ReaderUI

    fm = nil,           -- FileManager 里的插件实例（返回书架时用）

    panel = nil,        -- 屏幕中间呼出的快捷面板

    open_path = nil,    -- 当前真正在阅读器里打开的 TXT 路径（nil = 已退出书籍）

    txt_path = nil,     -- 本次会话写的 TXT

    txt_size = nil,     -- 打开/上次热加载时的文件大小，用于判断磁盘上有没有新章节

    book = nil,

    chapters = nil,

    index = nil,

    cover_paths = nil,  -- 书架这一页已缓存的封面，目录页复用

    prev_end_action = nil,

}

local BG = { job = nil }

-- 前向声明：开书流程先于「后台静默缓存」段使用它
local startBg
-- ---------- 小工具 ----------

local function htmlEscape(s)

    s = tostring(s or "")

    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    return s

end

-- HTML 正文头部：h2 新章强制换页、标题加大加粗；段落两字符缩进、无多余空白
local function chapterHtmlHead(title)

    return '<!DOCTYPE html><html><head><meta charset="utf-8"><title>'

        .. htmlEscape(title)

        .. '</title><style>'
        .. 'body { margin: 0; }'
        .. 'h1 { font-weight: bold; font-size: 1.8em; text-align: center; margin: 0.3em 0 0.8em 0; }'
        .. 'h2 { page-break-before: always; font-weight: bold; font-size: 1.5em; margin-top: 0.2em; margin-bottom: 0.6em; }'
        .. 'p { text-indent: 2em; margin: 0; }'
        .. '</style></head><body>'

end

-- 正文纯文本 -> <p> 段落：折叠所有空白行，杜绝大片空白
local function textToHtmlParas(text)

    local out = {}

    for line in tostring(text or ""):gmatch("[^\n]+") do

        line = line:gsub("^%s+", ""):gsub("%s+$", "")

        if line ~= "" then out[#out + 1] = "<p>" .. htmlEscape(line) .. "</p>" end

    end

    return table.concat(out, "\n")

end

-- 章节块（HTML）：新章从新页开始，h2 标题加大加粗；不含 head（开书时统一写一次），
-- 也不写 </body>，方便后台缓存追加
local function chapterBlock(title, text)

    return '<h2>' .. htmlEscape(tostring(title or "")) .. '</h2>\n'

        .. textToHtmlParas(text) .. '\n'

end

local function safeFileName(name)

    local s = tostring(name or "book"):gsub("[%/\\:%*%?\"<>|]", "_")

    if #s > 80 then s = s:sub(1, 80) end

    return s

end

local function fileSize(path)

    if not path then return 0 end

    local ok, size = pcall(function() return lfs.attributes(path, "size") end)

    if ok and tonumber(size) then return tonumber(size) end

    return 0

end

-- 网络小说读到底不该弹“文档结束”对话框，交给插件自动续章。
-- 改的是 KOReader 全局设置，所以把原值同时记在插件自己的配置里，

-- 万一是进程被杀掉没恢复，下次启动 FileManager 时还能补回来。
local function disableEndPopup()

    if not G_reader_settings then return end

    if SHARED.prev_end_action == nil then

        SHARED.prev_end_action = G_reader_settings:readSetting("end_document_action") or "pop-up"

        if SHARED.prev_end_action ~= "nothing" then

            G_reader_settings:saveSetting("end_document_action", "nothing")

            G_reader_settings:flush()

            if SHARED.settings then

                SHARED.settings:saveSetting("_prev_end_action", SHARED.prev_end_action)

                SHARED.settings:flush()

            end

        end

    end

end
local function restoreEndPopup()

    if G_reader_settings and SHARED.prev_end_action then

        G_reader_settings:saveSetting("end_document_action", SHARED.prev_end_action)

        G_reader_settings:flush()

    end

    SHARED.prev_end_action = nil

    if SHARED.settings then

        SHARED.settings:delSetting("_prev_end_action")

        SHARED.settings:flush()

    end

end

-- 热加载同一个文件（追加了新章节后用），要避免把它当成“退出书籍”而中断后台缓存
local function hotReload(ui, path)

    if not ui or not ui.document or ui.document.file ~= path then return end

    SHARED.reloading = true

    local ok, err = pcall(function() ui:reloadDocument(nil, true) end)

    SHARED.reloading = false

    if not ok then logger.warn("xread hot reload failed:", tostring(err)) end

end
-- ---------- UI 辅助 ----------

function XRead:showInfo(text)

    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })

end

function XRead:runOnline(label, fn)

    local UI = require("ui/trapper")

    Trapper:wrap(function()

        UI:info(label)

        local ok, err = pcall(fn)

        UI:clear()

        if not ok then

            local msg = tostring(err)

            logger.warn("xread runOnline error:", msg)

            -- 脱敏：异常里可能带 URL/token，只保留最后一段可读信息

            if msg:find("后端返回", 1, true) then

                msg = msg:match("(后端返回[^|]+)") or msg

            end

            self:showInfo(_("出错：") .. msg)

        end

    end)

end

-- 静默版 runOnline：不弹"加载中"模态框，出错才提示。
-- 用于书架/首页/开书/目录等浏览类操作——弹窗会吞掉用户点击并触发
-- Trapper 的 Paused 确认框；静默模式下任务期间点击只是排队，
-- 任务结束后立即生效，不再被弹窗挡住。
function XRead:runQuiet(fn)

    Trapper:wrap(function()

        local ok, err = pcall(fn)

        Trapper:clear()   -- 清掉任务中可能弹出的进度框，避免残留遮挡

        if not ok then

            logger.warn("xread quiet task error:", tostring(err))

            local msg = tostring(err)

            if msg:find("后端返回", 1, true) then

                msg = msg:match("(后端返回[^|]+)") or msg

            end

            self:showInfo(_("出错：") .. msg)

        end

    end)

end
-- ---------- 登录 ----------

function XRead:ensureLogin()

    if self.client.accessToken then return true end

    local user = self:getSetting("username", "")

    local pass = self:getSetting("password", "")

    if user == "" or pass == "" then

        self:showInfo(_("请先在菜单中填写后端地址与账号密码"))

        return false

    end

    local ok, err = pcall(function() self.client:login(user, pass) end)

    if not ok then

        self:showInfo(_("登录失败：") .. tostring(err))

        return false

    end

    return true

end
-- ---------- 菜单排序：把“阅读X”挪到微信读书下面 ----------
local function moveItemAfter(tab_item_table, key, after_key)

    if type(tab_item_table) ~= "table" then return false end

    for _i, tab in ipairs(tab_item_table) do

        if type(tab) == "table" then

            local key_pos, after_pos

            for j, item in ipairs(tab) do

                if type(item) == "table" then

                    if item.id == key then key_pos = j end

                    if item.id == after_key then after_pos = j end

                end

            end

            if key_pos then

                if after_pos and key_pos ~= after_pos + 1 then

                    local item = table.remove(tab, key_pos)

                    if key_pos < after_pos then after_pos = after_pos - 1 end

                    table.insert(tab, after_pos + 1, item)

                elseif not after_pos and key_pos ~= 1 then

                    -- 没找到参照项（比如微信读书没装）：放到这一页最前面

                    local item = table.remove(tab, key_pos)

                    table.insert(tab, 1, item)

                end

                return true

            end

        end

    end

    return false

end

function XRead:hookMenuOrder()

    local menu = self.ui and self.ui.menu

    if not menu or menu._xread_order_hooked then return end

    if type(menu.setUpdateItemTable) ~= "function" then return end

    menu._xread_order_hooked = true

    local orig = menu.setUpdateItemTable

    menu.setUpdateItemTable = function(m, ...)

        orig(m, ...)

        pcall(moveItemAfter, m.tab_item_table, "xread", "weread")

        -- 阅读界面里的两个入口提到导航页最上面，省得翻页找

        pcall(moveItemAfter, m.tab_item_table, "xread_reader_catalog", "table_of_contents")

        pcall(moveItemAfter, m.tab_item_table, "xread_reader_shelf", "xread_reader_catalog")

        pcall(moveItemAfter, m.tab_item_table, "xread_reader_stats", "xread_reader_shelf")

    end

end
-- ---------- 插件实例 ----------

function XRead:init()

    self.settings = LuaSettings:open(SETTINGS_FILE)

    util.makePath(BOOK_DIR)

    self.cover_cache = CoverCache:new(BOOK_DIR .. "/covers",

        self:getSetting("address", "http://192.168.31.51:7777"))

    self.chapter_cache = ChapterCache:new(BOOK_DIR .. "/chapters")

    self.meta_cache = MetaCache:new(BOOK_DIR .. "/meta")

    local address = self:getSetting("address", "http://192.168.31.51:7777")

    if not SHARED.client then

        SHARED.client = Client:new(address)

    else

        SHARED.client.address = address

    end

    self.client = SHARED.client

    SHARED.settings = self.settings

    self.ui.menu:registerToMainMenu(self)

    self:hookMenuOrder()

    -- 阅读器实例：登记当前打开的文件，让后台缓存知道“书还开着”

    if self.ui.document then

        SHARED.ui = self.ui

        SHARED.open_path = self.ui.document.file

        if SHARED.txt_path == self.ui.document.file then disableEndPopup() end

        self:setupCenterTap()

        -- 仅验收用：XREAD_AUTOTEST_FLOW=panel|shelf|catalog，进书后自动跑一遍

        local flow = os.getenv("XREAD_AUTOTEST_FLOW")

        -- 验收标记：仅供 tests/ 下的自动测试判定动作是否真的执行完
        local autotest_mark = function(tag)

            print("[XREAD_AUTOTEST] " .. tag)

        end

        if flow == "panel" then

            UIManager:scheduleIn(4, function()

                self:showQuickPanel()

                autotest_mark("flow=panel done")

            end)

        elseif flow == "catalog" then

            UIManager:scheduleIn(4, function()

                self:showReaderCatalog()

                autotest_mark("flow=catalog done")

            end)

        elseif flow == "settings" then

            UIManager:scheduleIn(4, function()

                self:showSettings()

                autotest_mark("flow=settings done")

            end)

        elseif flow == "shelf" then

            UIManager:scheduleIn(6, function()

                self:closeBookToShelf()

                autotest_mark("flow=shelf done")

            end)

        elseif flow == "home" then

            UIManager:scheduleIn(6, function()

                self.ui:onHome()

                autotest_mark("flow=home done")

            end)

        elseif flow == "cache" then

            UIManager:scheduleIn(4, function()

                self:showQuickPanel()

                if SHARED.panel then self:startCacheMore(10) end

                autotest_mark("flow=cache done")

            end)

        elseif flow == "stats" then

            UIManager:scheduleIn(4, function()

                self:showReadingStats()

                autotest_mark("flow=stats done")

            end)

        elseif flow == "more" then

            UIManager:scheduleIn(4, function()

                self:showMorePanel()

                autotest_mark("flow=more done")

            end)

        elseif flow == "more_server" then

            UIManager:scheduleIn(4, function()

                self:showServerManage()

                autotest_mark("flow=more_server done")

            end)

        elseif flow == "more_account" then

            UIManager:scheduleIn(4, function()

                self:showAccountManage()

                autotest_mark("flow=more_account done")

            end)

        elseif flow == "more_shelf" then

            UIManager:scheduleIn(4, function()

                self:showShelfManage()

                autotest_mark("flow=more_shelf done")

            end)

        elseif flow == "more_cache" then

            UIManager:scheduleIn(4, function()

                self:showCacheManage()

                autotest_mark("flow=more_cache done")

            end)

        elseif flow == "more_page" then

            UIManager:scheduleIn(4, function()

                self:showPageManage()

                autotest_mark("flow=more_page done")

            end)

        elseif flow == "more_about" then

            UIManager:scheduleIn(4, function()

                self:showAboutPanel()

                autotest_mark("flow=more_about done")

            end)

        elseif flow == "panel_stats" then

            UIManager:scheduleIn(4, function()

                self:showQuickPanel()

                UIManager:scheduleIn(2, function()

                    if SHARED.panel then

                        UIManager:close(SHARED.panel)

                        SHARED.panel = nil

                        self:showReadingStats()

                    end

                    autotest_mark("flow=panel_stats done")

                end)

            end)

        end

        -- 仅验收用：XREAD_TEST_EXIT=秒数，到点自动退出书籍，验证后台缓存是否中断

        local exit_after = tonumber(os.getenv("XREAD_TEST_EXIT") or "")

        if exit_after and exit_after > 0 then

            UIManager:scheduleIn(exit_after, function()

                if self.ui.document then

                    logger.info("xread test exit book")

                    self.ui:onClose()

                end

            end)

        end

        return

    end

    -- 上次异常退出可能没来得及还原“文档结束”动作，这里补一下

    local leftover = self.settings:readSetting("_prev_end_action")

    if leftover and G_reader_settings then

        SHARED.prev_end_action = leftover

        restoreEndPopup()

    end

    SHARED.fm = self

    -- 仅开发验收用：XREAD_AUTOTEST=shelf|open 自动打开书架/第一本书

    local autotest = os.getenv("XREAD_AUTOTEST")

    if os.getenv("XREAD_AUTOTEST_ONCE") == "1" then

        -- 只跑一次（返回书架会重建 FileManager，避免又自动开书）

        local flag = "/tmp/xread_autotest_once"

        if lfs.attributes(flag, "mode") == "file" then autotest = nil end

        local f = io.open(flag, "w"); if f then f:write("1"); f:close() end

    end

    if autotest == "home" then

        UIManager:nextTick(function()

            self:openHome()

            print("[XREAD_AUTOTEST] mode=home done")

        end)

    elseif autotest == "update" then

        -- 在线热更新全流程验收：依赖 XREAD_UPDATER_URL 指向测试更新服务
        -- （fetch manifest -> diff -> apply -> 校验本地版本 -> 退出）

        UIManager:nextTick(function()

            Trapper:wrap(function()

                local ok, updater = pcall(function()

                    -- webdav 模式需要真实 address + 登录 token；raw 模式（XREAD_UPDATER_URL）不需要
                    local st = LuaSettings:open(SETTINGS_FILE)
                    local addr = tostring(st:readSetting("address") or "http://192.168.31.51:7777")
                    local c = Client:new(addr)
                    pcall(function()
                        c:login(tostring(st:readSetting("username") or ""),
                            tostring(st:readSetting("password") or ""))
                    end)

                    return require("xread/updater"):new{ client = c }

                end)

                if not ok then

                    print("[XREAD_AUTOTEST] update init failed: " .. tostring(updater))

                    UIManager:quit()

                    return

                end

                local ok_check, manifest, info = pcall(function() return updater:check() end)

                if not ok_check then

                    print("[XREAD_AUTOTEST] update check failed: " .. tostring(manifest))

                    UIManager:quit()

                    return

                end

                print("[XREAD_AUTOTEST] update check: local=" .. tostring(info.local_version)

                    .. " remote=" .. tostring(info.remote_version)

                    .. " newer=" .. tostring(info.newer)

                    .. " total=" .. tostring(info.total)

                    .. " skipped=" .. tostring(info.skipped))

                local changed, skipped = 0, info.skipped

                if info.newer then

                    local ok_apply, c, s = pcall(function()

                        return updater:apply(manifest, function(done, total, path)

                            print("[XREAD_AUTOTEST] update file " .. tostring(done)

                                .. "/" .. tostring(total) .. " " .. tostring(path))

                        end)

                    end)

                    if not ok_apply then

                        print("[XREAD_AUTOTEST] update apply failed: " .. tostring(c))

                        UIManager:quit()

                        return

                    end

                    changed, skipped = c, s

                end

                print("[XREAD_AUTOTEST] update applied: changed=" .. tostring(changed)

                    .. " skipped=" .. tostring(skipped)

                    .. " local_version_now=" .. tostring(updater:getLocalVersion()))

                print("[XREAD_AUTOTEST] mode=update done")

                UIManager:quit()

            end)

        end)

    elseif autotest == "shelf" or autotest == "open" then

        UIManager:nextTick(function()

            self:runQuiet(function()

                if not self:ensureLogin() then return end

                local books = self.client:getBookshelf()

                if not books or #books == 0 then return end

                if autotest == "shelf" then

                    self:showBookshelf()

                    print("[XREAD_AUTOTEST] mode=shelf done")

                else

                    -- 可用 XREAD_AUTOTEST_BOOK 指定书名子串，避免测试撞上坏书/漫画
                    local want = os.getenv("XREAD_AUTOTEST_BOOK")

                    local pick = tonumber(os.getenv("XREAD_AUTOTEST_BOOK_IDX") or "0") or 0

                    if want and want ~= "" then

                        for bi = 1, #books do

                            if books[bi].name and tostring(books[bi].name):find(want, 1, true) then

                                pick = bi

                                break

                            end

                        end

                    end

                    local order = {}

                    if pick > 0 then

                        order[1] = pick

                        for bi = 1, math.min(#books, 8) do

                            if bi ~= pick then order[#order + 1] = bi end

                        end

                    else

                        for bi = 1, math.min(#books, 8) do order[bi] = bi end

                    end

                    for _, bi in ipairs(order) do

                        local ok, chapters = pcall(function()

                            return self.client:getChapterList(books[bi])

                        end)

                        if ok and chapters and #chapters > 0 then

                            self:openAtChapter(books[bi], chapters,

                                math.max(1, math.min((tonumber(books[bi].durChapterIndex) or 0) + 1, #chapters)))

                            print("[XREAD_AUTOTEST] mode=open done")

                            return

                        end

                    end

                end

            end)

        end)

    end

end
function XRead:addToMainMenu(menu_items)

    -- 只保留一个「阅读X」入口：点开直接弹功能页（与原「阅读X · 更多」一致），不再单列「更多」
    menu_items.xread = {

        text = _("阅读X"),

        sorting_hint = "tools",

        sub_item_table = {

            {

                text = _("我的首页"),

                callback = function() self:openHome() end,

            },

            {

                text = _("我的书架"),

                callback = function() self:openShelf() end,

            },

            {

                text = _("地址管理"),

                callback = function() self:showServerManage() end,

            },

            {

                text = _("账号管理"),

                callback = function() self:showAccountManage() end,

            },

            {

                text = _("测试连接"),

                callback = function()

                    self:runOnline(_("正在测试连接…"), function()

                        local res = self.client:health()

                        self:showInfo(res and res.isSuccess and _("连接成功") or _("连接失败"))

                    end)

                end,

            },

            {

                text = _("关于本机"),

                callback = function() self:showAboutPanel() end,

            },

        },

    }

    -- 阅读界面里的入口：放在第一页“导航”里，少翻几层

    if self.ui.document then

        menu_items.xread_reader_catalog = {

            text = _("阅读X · 目录 / 跳章"),

            sorting_hint = "navi",

            callback = function() self:showReaderCatalog() end,

        }

        menu_items.xread_reader_shelf = {

            text = _("阅读X · 书架"),

            sorting_hint = "navi",

            callback = function() self:openShelf() end,

        }

    end

end
-- ---------- 主菜单 ----------

function XRead:openShelf()

    -- 缓存优先：本地书架先秒开，网络刷新放到后台，不阻塞界面
    local ttl = tonumber(self:getSetting("shelf_cache_ttl", "300")) or 300

    if os.getenv("XREAD_SHELF_CACHE") == "0" then ttl = 0 end

    local cached = self.meta_cache:getShelf(ttl)

    if cached then

        self:showBookshelf(self._shelf_page or 1, cached)

        self:_refreshShelfInBackground()

        return

    end

    self:runQuiet(function()

        if self:ensureLogin() then self:showBookshelf() end

    end)

end

-- 后台静默刷新书架元数据：只写缓存，不重建当前界面（避免点书/翻页时被闪掉）
function XRead:_refreshShelfInBackground()

    -- 错峰：书架刚显示时用户可能马上点书，刷新延后 2s 且受 http.TIMEOUT 限制
    UIManager:scheduleIn(2, function()

        if not self.client.accessToken then return end

        local ok, books = pcall(function() return self.client:getBookshelf() end)

        if ok and books and #books > 0 then

            self.meta_cache:putShelf(books)

            logger.info("xread shelf refreshed in background")

        end

    end)

end

-- 书架/首页显示后预取「最近在读那本」的章节目录，下次点它可秒开
function XRead:_prefetchRecentChapters(books)

    if os.getenv("XREAD_NO_PREFETCH") == "1" then return end

    local target

    for _, b in ipairs(books) do

        local dur = tonumber(b.durChapterIndex) or 0

        if dur > 0 and (not target or dur > (tonumber(target.durChapterIndex) or 0)) then

            target = b

        end

    end

    if not target or self.meta_cache:getChapters(target) then

        self:quietUpdateCheck(10)

        return

    end

    UIManager:scheduleIn(5, function()

        if not self.client.accessToken then return end

        local ok, chapters = pcall(function() return self.client:getChapterList(target) end)

        if ok and chapters and #chapters > 0 then

            self.meta_cache:putChapters(target, chapters)

            print("[XREAD_AUTOTEST] prefetch chapters done")

            logger.info("xread prefetched chapters for", tostring(target.name))

        end

    end)

end

-- ---------- 第二步：miuread 首页（视觉层，数据来自 xread 书架） ----------

function XRead:openHome()

    self:runQuiet(function()

        if self:ensureLogin() then self:showHome() end

    end)

end

-- 首页点左上角标题：呼出 KOReader 菜单（阅读X 入口所在）；无菜单上下文时退回更多面板
function XRead:openReaderMenuFromHome()

    pcall(function()

        local Event = require("ui/event")

        local ui = (self.ui and self.ui.menu) and self.ui

            or ((SHARED.ui and SHARED.ui.menu) and SHARED.ui)

            or ((SHARED.fm and SHARED.fm.ui and SHARED.fm.ui.menu) and SHARED.fm)

        if ui then

            ui:handleEvent(Event:new("ShowMenu"))

        else

            self:showMorePanel()

        end

    end)

end

-- 手动把当前在读书的进度同步到服务端
function XRead:syncProgressFromHome()

    local b, idx = SHARED.book, SHARED.index

    if not b then

        self:showInfo(_("当前没有正在读的书"))

        return

    end

    self:runQuiet(function()

        local ok = pcall(function() self.client:saveBookProgress(b, (idx or 1) - 1) end)

        pcall(function()

            self.meta_cache:updateShelfProgress(b.bookUrl or b.name, (idx or 1) - 1)

        end)

        UIManager:nextTick(function()

            self:showInfo(ok and _("进度已同步到服务端") or _("同步失败，请检查服务端"))

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

                self:runQuiet(function()

                    if not self:ensureLogin() then return end

                    local found = nil

                    local ok_s, sources = pcall(function() return self.client:getBookSources() end)

                    if ok_s and type(sources) == "table" then

                        -- 单源短超时，坏源不拖死搜索

                        local old_timeout = http.TIMEOUT

                        http.TIMEOUT = 8

                        for _si, s in ipairs(sources) do

                            if s.enabled and s.bookSourceUrl then

                                local ok_r, res = pcall(function()

                                    return self.client:searchBook(kw, s.bookSourceUrl)

                                end)

                                if ok_r and type(res) == "table" and #res > 0 then

                                    found = res

                                    break

                                end

                            end

                        end

                        http.TIMEOUT = old_timeout or 12

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

                                            self:showInfo(ok_save and (_("已加入书架：") .. tostring(r.name))

                                                or _("加入书架失败"))

                                        end)

                                    end)

                                end,

                            }

                        end

                        self:showMoreListPanel(_("搜索结果"), items,

                            { hint = _("点击条目加入书架；点空白处返回。") })

                    end)

                end)

            end },

        }},

    }

    UIManager:show(d)

    pcall(function() d:onShowKeyboard() end)

end

-- 首页中部功能按钮排（参考 miuread：更新/搜索/下载/同步/休眠/设置）
function XRead:buildHomeActions()

    return {

        { icon_key = "refresh", label = _("更新"), callback = function()

            -- 强制拉最新书架并重建首页

            self:_stopHomeTicker()

            if self._home_view and not self._home_view._miu_closed then

                UIManager:close(self._home_view)

            end

            self._home_view = nil

            self:runQuiet(function()

                pcall(function() self.meta_cache:clearShelf() end)

                if self:ensureLogin() then self:showHome(1) end

            end)

        end },

        { icon_key = "search", label = _("搜索"), callback = function() self:searchAndAddBook() end },

        { icon_key = "download", label = _("下载"), callback = function() self:showCacheManage() end },

        { icon_key = "sync", label = _("同步"), callback = function() self:syncProgressFromHome() end },

        {

            -- 夜间模式开关：月亮=当前日间（点击进夜间），太阳=当前夜间（点击回日间）
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

    local ttl = tonumber(self:getSetting("shelf_cache_ttl", "300")) or 300

    local books = self.meta_cache:getShelf(ttl)

    if not books then

        local ok, res = pcall(function() return self.client:getBookshelf() end)

        books = ok and res or nil

        if books and #books > 0 then self.meta_cache:putShelf(books) end

    end

    -- 只展示小说与漫画（过滤视频类条目）

    books = BookFilter.filterReadable(books)

    if not books or #books == 0 then

        self:showInfo(_("首页加载失败：书架为空或获取失败"))

        return

    end

    self._shelf_books = books

    self:_prefetchRecentChapters(books)

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

    local cover_paths = self:prepareCovers(page_books, 1, show_n, layout, true)

    local miui_books = self:_toMiuiBooks(page_books, cover_paths)

    -- hero = 最近读的书：本会话最后打开的书优先（实时），否则 durChapterIndex 最大者

    local hero_book = books[1]

    for _hb, b in ipairs(books) do

        if (tonumber(b.durChapterIndex) or 0) > (tonumber(hero_book.durChapterIndex) or 0) then

            hero_book = b

        end

    end

    if self._last_open_book_url then

        for _hb, b in ipairs(books) do

            if tostring(b.bookUrl or "") == tostring(self._last_open_book_url) then hero_book = b break end

        end

    end

    -- hero 不在当前书架页时单独备好封面

    if cover_paths[hero_book] == nil then

        pcall(function() self:prepareCovers({ hero_book }, 1, 1, layout, true) end)

    end

    local hero = self:_toMiuiBooks({ hero_book }, cover_paths)[1]

    hero.subtitle = _("继续阅读")

    -- 封面右侧：书籍简介 + 上次读到第 X 章 · 共 Y 章
    local hero_total = tonumber(hero_book.totalChapterNum) or 0

    local hero_dur = tonumber(hero_book.durChapterIndex) or 0

    hero.last_read_text = _("上次读到第 ") .. tostring(hero_dur + 1) .. _(" 章 · 共 ")

        .. tostring(hero_total) .. _(" 章")

    hero.description = tostring(hero_book.intro or "")

    hero.on_tap = function() self:openBook(hero_book) end

    -- 右上角「历史 ›」入口：点击进入阅读记录页（默认日统计）

    hero.on_history = function() self:showReadingStats() end

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

        on_local_stats = function() self:showReadingStats() end,

        on_open_book = function(mbook) self:openBook(mbook._xread_book) end,

        on_hold_book = function(mbook) self:showBookCatalog(mbook._xread_book, mbook.cover_path) end,

        on_shelf_page = function(delta)

            -- 向后翻：进「我的书架」页（4 排书那页）
            if (tonumber(delta) or 0) > 0 then

                self:_stopHomeTicker()

                if self._home_view and not self._home_view._miu_closed then

                    UIManager:close(self._home_view)

                end

                self._home_view = nil

                self:showBookshelf(1)

                return

            end

            -- 向前翻：首页内回上一页
            self:_stopHomeTicker()

            if self._home_view and not self._home_view._miu_closed then

                UIManager:close(self._home_view)

            end

            self._home_view = nil

            self:showHome((self._home_shelf_page or 1) + delta)

        end,

        on_quick_panel = function() self:openShelf() end,

        on_menu = function() self:showMorePanel() end,

        -- 点左上角「阅读X」标题呼出 KOReader 菜单（首页/书架/阅读记录…入口所在）

        on_header_title = function() self:openReaderMenuFromHome() end,

    }

    local view = MiuiHome.show(opts)

    self._home_view = view

    self:_queueMissingCovers(page_books, 1, show_n, layout, miui_books, view,

        function(i)

            if miui_books[i] then view:updateBook(miui_books[i].bookId) end

        end)

    -- 首页定时器：时钟每 30s 走字；服务器连接状态每 60s 测一次（异常时明确显示）
    self:_startHomeTicker(view)

    -- 无封面书籍定时静默拉取：后端稍后生成封面后自动补上
    self:_startCoverRetryLoop(view, function(b)

        pcall(function() view:updateBook(tostring(b.bookUrl)) end)

    end)

end

-- 首页顶部「已同步」= 服务器连接状态；首页时钟 + 日期定时刷新
function XRead:_startHomeTicker(view)

    self:_stopHomeTicker()

    if not view then return end

    local week_text = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

    local rounds = 0

    local tick

    tick = function()

        if self._home_view ~= view or SHARED.open_path then

            self._home_timer = nil

            return   -- 首页已关闭 / 已进书，停止
        end

        rounds = rounds + 1

        pcall(function()

            local now_str = os.date("%H:%M")

            view:updateHeader{ time_text = now_str }

            view:updateDashboard{ clock_text = now_str,

                date_text = os.date("%m月%d日 ") .. (week_text[(tonumber(os.date("%w")) or 0) + 1] or "") }

        end)

        if rounds % 2 == 1 then

            -- health 走短超时，避免后端异常时长时间阻塞界面
            local old_timeout = http.TIMEOUT

            http.TIMEOUT = 3

            local ok_h, res = pcall(function() return self.client:health() end)

            http.TIMEOUT = old_timeout or 12

            local healthy = ok_h and res and res.isSuccess ~= false

            self._health_ok = healthy

            pcall(function()

                view:updateHeader{ sync_text = healthy and _("已连接") or _("已断开") }

            end)

        end

        UIManager:scheduleIn(30, tick)

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

    if not ok then self:showInfo(_("获取书架失败：") .. tostring(books)); return end

    books = books or {}

    -- 只展示小说与漫画（过滤视频类条目）

    books = BookFilter.filterReadable(books)

    if #books == 0 then self:showInfo(_("书架中没有小说或漫画")); return end

    if not cached_books then self.meta_cache:putShelf(books) end

    self._shelf_books = books

    -- 显示后预取最近在读的书，下次点开直接命中缓存
    self:_prefetchRecentChapters(books)

    local layout = GridShelf.computeLayout(#books)

    local page_count = math.max(1, math.ceil(#books / layout.page_size))

    if page < 1 then page = 1 end

    if page > page_count then page = page_count end

    self._shelf_page = page

    local first = (page - 1) * layout.page_size + 1

    local last = math.min(#books, first + layout.page_size - 1)

    -- 本函数已在 runOnline 的 Trapper 协程里，不能再套 Trapper:wrap

    local cover_paths = self:prepareCovers(books, first, last, layout, true)

    -- 第一步整搬 miuread 书架视觉层：默认走新视图，XREAD_SHELF_LEGACY=1 回退旧版
    if os.getenv("XREAD_SHELF_LEGACY") == "1" then

        self:showShelfGrid(books, page, cover_paths)

    else

        self:showMiuiShelfGrid(books, page, cover_paths)

    end

end
-- ---------- 书架 ----------

function XRead:prepareCovers(books, first, last, layout, skip_download)

    local UI = require("ui/trapper")

    local cover_paths = {}

    local total = last - first + 1

    local done = 0

    for i = first, last do

        local book = books[i]

        local path = self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)

        if not path and not skip_download and book.coverUrl and book.coverUrl ~= "" then

            done = done + 1

            UI:info(T(_("加载封面 %1/%2…"), tostring(done), tostring(total)))

            local ok, p = pcall(function()

                return self.cover_cache:fetchAndStore(book, book.coverUrl,

                    layout.cover_w, layout.cover_h)

            end)

            if ok and p then path = p end

        end

        if path then cover_paths[book] = path end

    end

    UI:clear()

    return cover_paths

end

-- 未缓存封面不阻塞书架：先显示占位，再逐张静默下载并局部刷新。
-- 用 generation 号防止翻页/关闭后旧队列继续刷新界面。
function XRead:_queueMissingCovers(books, first, last, layout, miui_books, view, refresh_fn)

    if os.getenv("XREAD_COVER_ASYNC") == "0" then return end

    local queue = {}

    for i = first, last do

        local book = books[i]

        if book and not self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)

            and book.coverUrl and book.coverUrl ~= "" then

            queue[#queue + 1] = { i = i, book = book }

        end

    end

    if #queue == 0 then return end

    local gen = (self._cover_generation or 0) + 1

    self._cover_generation = gen

    local function nextOne(k)

        if k > #queue then return end

        UIManager:scheduleIn(0.05, function()

            if self._cover_generation ~= gen or view._miu_closed then return end

            local item = queue[k]

            local ok, p = pcall(function()

                return self.cover_cache:fetchAndStore(item.book, item.book.coverUrl,

                    layout.cover_w, layout.cover_h)

            end)

            if ok and p and miui_books[item.i] then

                miui_books[item.i].cover_path = p

                if SHARED.cover_paths then SHARED.cover_paths[item.book] = p end

                if refresh_fn then
                    refresh_fn(item.i)
                elseif view.updateItems then
                    view:updateItems()
                end

            end

            nextOne(k + 1)

        end)

    end

    nextOne(1)

end

-- 无封面书籍定时静默拉取：书架/首页显示期间，后台每 cover_retry_ttl 秒
-- 刷新一次书架元数据（后端可能稍后才生成封面），把新出现的封面逐张
-- 下载到本地缓存；首页视图下载成功即动态刷新对应卡片。
function XRead:_startCoverRetryLoop(view, on_cover)

    if os.getenv("XREAD_COVER_ASYNC") == "0" then return end

    if not self.client then return end

    self:_stopCoverRetryLoop()

    local ttl = tonumber(self:getSetting("cover_retry_ttl", "300")) or 300

    if ttl < 60 then ttl = 60 end

    local generation = (self._cover_retry_generation or 0) + 1

    self._cover_retry_generation = generation

    local function round()

        if generation ~= self._cover_retry_generation then return end

        if not view or view._miu_closed or view._closed then return end

        -- 1) 静默刷新书架元数据，拿最新封面地址
        local books = nil

        pcall(function() books = self.client:getBookshelf(true) end)

        if type(books) ~= "table" or #books == 0 then

            UIManager:scheduleIn(ttl, round)

            return

        end

        books = BookFilter.filterReadable(books)

        self._shelf_books = books

        pcall(function() self.meta_cache:putShelf(books) end)

        -- 2) 缺本地封面缓存的书逐张下载（间隔 1s 错峰）
        local layout = GridShelf.computeLayout(#books)

        local queue = {}

        for _, b in ipairs(books) do

            if not self.cover_cache:pathFor(b, layout.cover_w, layout.cover_h) then

                queue[#queue + 1] = b

            end

        end

        local function nextOne(k, added)

            if generation ~= self._cover_retry_generation then return end

            if not view or view._miu_closed or view._closed then return end

            if k > #queue then

                if added > 0 then logger.info("xread cover retry: fetched", added) end

                UIManager:scheduleIn(ttl, round)

                return

            end

            local b = queue[k]

            UIManager:scheduleIn(1.0, function()

                if generation ~= self._cover_retry_generation then return end

                local ok, p = pcall(function()

                    return self.cover_cache:fetchAndStore(b, b.coverUrl,

                        layout.cover_w, layout.cover_h)

                end)

                if ok and p and on_cover then pcall(on_cover, b) end

                nextOne(k + 1, added + ((ok and p) and 1 or 0))

            end)

        end

        nextOne(1, 0)

    end

    UIManager:scheduleIn(ttl, round)

end

function XRead:_stopCoverRetryLoop()

    self._cover_retry_generation = (self._cover_retry_generation or 0) + 1

end
function XRead:showShelfGrid(books, page, cover_paths)

    -- 记下来：阅读器里的目录页直接复用书架已缓存的封面

    SHARED.cover_paths = cover_paths

    if self._shelf_view then

        UIManager:close(self._shelf_view)

        self._shelf_view = nil

    end

    local view = GridShelf:new{

        books = books,

        title = _("我的书架"),

        cover_paths = cover_paths,

        page = page,

        -- 点封面 = 直接开书（相当于 XRead-kindle 的“点开即读”）

        on_select = function(book)

            self:openBook(book)

        end,

        -- 长按封面 = 看目录/换章

        on_hold = function(book)

            self:showBookCatalog(book, cover_paths[book])

        end,

        on_page_changed = function(new_page)

            local paths = {}

            local layout = GridShelf.computeLayout(#books)

            local first = (new_page - 1) * layout.page_size + 1

            local last = math.min(#books, first + layout.page_size - 1)

            Trapper:wrap(function()

                paths = self:prepareCovers(books, first, last, layout)

            end)

            self:showShelfGrid(books, new_page, paths)

        end,

    }

    self._shelf_view = view

    UIManager:show(view)

end

-- ---------- 第一步：miuread 书架视觉层（数据仍走 xread.client） ----------

-- 把 xread 书本契约转成 miui FullShelfView.books 契约
function XRead:_toMiuiBooks(books, cover_paths)

    local out = {}

    for i, book in ipairs(books) do

        local total = tonumber(book.totalChapterNum) or 0

        local dur = tonumber(book.durChapterIndex) or 0

        local progress = 0

        if total > 0 and dur > 0 then

            progress = math.floor(dur / total * 100 + .5)

            if progress > 100 then progress = 100 end

        end

        out[i] = {

            title = book.name or _("未命名"),

            author = book.author or "",

            cover_path = cover_paths[book],

            progress = progress,

            bookId = tostring(book.bookUrl or ""),

            _xread_book = book,

        }

    end

    return out

end

function XRead:showMiuiShelfGrid(books, page, cover_paths)

    SHARED.cover_paths = cover_paths

    if self._shelf_view then

        UIManager:close(self._shelf_view)

        self._shelf_view = nil

    end

    local miui_books = self:_toMiuiBooks(books, cover_paths)

    local view

    view = MiuiShelf.show{

        books = miui_books,

        title = _("我的书架 共 ") .. tostring(#books) .. _(" 本"),

        page = page,

        on_select = function(mbook)

            self:openBook(mbook._xread_book)

        end,

        on_hold = function(mbook)

            self:showBookCatalog(mbook._xread_book, SHARED.cover_paths[mbook._xread_book])

        end,

        on_page_changed = function(new_page, first, last, shelf_view)

            -- miui 内部已按新页重建；这里补下新页封面再刷新

            local layout = GridShelf.computeLayout(#books)

            local paths = self:prepareCovers(books, first, last, layout, true)

            for i = first, last do

                if miui_books[i] then

                    miui_books[i].cover_path = paths[books[i]]

                end

            end

            SHARED.cover_paths = paths

            if shelf_view then

                shelf_view:updateItems()

                self:_queueMissingCovers(books, first, last, layout, miui_books, shelf_view)

            end

        end,

        on_back = function()

            -- 书架第一页点返回：回「我的首页」
            if self._shelf_view and not self._shelf_view._miu_closed then

                UIManager:close(self._shelf_view)

            end

            self._shelf_view = nil

            self:showHome(1)

        end,

        on_close = function()

            self._shelf_view = nil

        end,

    }

    self._shelf_view = view

    -- 首屏未缓存的封面走后台补，不阻塞书架显示
    local layout = GridShelf.computeLayout(#books)

    local first = (page - 1) * layout.page_size + 1

    local last = math.min(#books, first + layout.page_size - 1)

    self:_queueMissingCovers(books, first, last, layout, miui_books, view)

    -- 无封面书籍定时静默拉取（书架打开期间；封面写缓存，翻页/下次进书架生效）
    self:_startCoverRetryLoop(view, nil)

end

-- ---------- 书架长按进来的目录页（选中就直接开书） ----------

function XRead:showBookCatalog(book, cover_path, page)

    if not cover_path then

        local layout = GridShelf.computeLayout(1)

        cover_path = self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)

        if not cover_path and book.coverUrl and book.coverUrl ~= "" then

            local ok, p = pcall(function()

                return self.cover_cache:fetchAndStore(book, book.coverUrl,

                    layout.cover_w, layout.cover_h)

            end)

            if ok and p then cover_path = p end

        end

    end

    self:runQuiet(function()

        local ttl = tonumber(self:getSetting("chapter_cache_ttl", "1800")) or 1800

        local chapters = self.meta_cache:getChapters(book, ttl)

        if not chapters then

            chapters = self.client:getChapterList(book)

            if chapters and #chapters > 0 then self.meta_cache:putChapters(book, chapters) end

        end

        if not chapters or #chapters == 0 then self:showInfo(_("目录为空")); return end

        local dur_idx = tonumber(book.durChapterIndex) or 0

        -- 自动跳到当前章节所在目录页，不用从头翻

        local target_page = page

        if not target_page then

            local L = CatalogView.computeLayout()

            target_page = math.max(1, math.ceil((dur_idx + 1) / math.max(1, L.page_size)))

        end

        self:showCatalog(book, chapters, dur_idx, target_page, cover_path)

    end)

end
-- ---------- 阅读器内：目录 / 跳章 ----------

function XRead:showReaderCatalog(page)

    local doc = self.ui.document

    if not doc or not doc.file then return end

    local book, chapters = SHARED.book, SHARED.chapters

    -- 从别处打开的普通文件：退回书架去选书

    if not book or not chapters or SHARED.txt_path ~= doc.file then

        self:showInfo(_("这本书不是从 xread 打开的，请回书架选书"))

        return

    end

    if self._catalog_view then

        UIManager:close(self._catalog_view)

        self._catalog_view = nil

    end

    -- 默认翻到当前章所在的那一页，不用从头翻

    if not page then

        local L = CatalogView.computeLayout()

        local idx = math.max(1, math.min(SHARED.index or 1, #chapters))

        page = math.max(1, math.ceil(idx / math.max(1, L.page_size)))

    end

    local layout = GridShelf.computeLayout(1)

    -- 优先复用书架已经下好的封面（书架缓存按尺寸分 key，这里把可能的书架版式都试一遍）

    local cover_path = SHARED.cover_paths and SHARED.cover_paths[book]

    if not cover_path then

        cover_path = self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)

    end

    if not cover_path then

        for n = 1, 12 do

            local l = GridShelf.computeLayout(n)

            local p = self.cover_cache:pathFor(book, l.cover_w, l.cover_h)

            if p then cover_path = p; break end

        end

    end

    local view

    view = CatalogView:new{

        book = book,

        chapters = chapters,

        cover_path = cover_path,

        dur_index = (SHARED.index or 1) - 1,

        page = page,

        back_label = _("返回"),

        on_select = function(i)

            UIManager:close(view)

            self._catalog_view = nil

            -- 目录页是整屏覆盖层，关闭后强制全刷一次，避免按钮残影留在正文上
            UIManager:forceRePaint()

            self:runQuiet(function()

                self:openAtChapter(book, chapters, i)

            end)

        end,

        on_back = function()

            UIManager:close(view)

            self._catalog_view = nil

            UIManager:forceRePaint()

        end,

        on_toc_first = function()

            self:showReaderCatalog(1)

        end,

        on_page_changed = function(new_page)

            self:showReaderCatalog(new_page)

        end,

        cache_fn = function(i) return self:chapterCacheState(book, i) end,

        on_cache_changed = function(p) self:showReaderCatalog(p) end,

    }

    self._catalog_view = view

    UIManager:show(view)

    UIManager:setDirty(view, "full")

end

-- 目录页预加载高亮：第 i 章正在后台缓存时返回 "active"

function XRead:chapterCacheState(book, i)

    local cv = SHARED.cache_visual

    if cv and cv.book_url == book.bookUrl and i == cv.active then return "active" end

    -- 已预加载（本地有正文分片）的章节统一高亮，供目录页区分
    if self.chapter_cache and self.chapter_cache:has(book, i) then return "cached" end

    return nil

end
function XRead:showCatalog(book, chapters, dur_index, page, cover_path)

    if self._catalog_view then

        UIManager:close(self._catalog_view)

        self._catalog_view = nil

    end

    local view

    view = CatalogView:new{

        book = book,

        chapters = chapters,

        cover_path = cover_path,

        dur_index = dur_index,

        page = page or 1,

        on_select = function(i)

            UIManager:close(view)

            self._catalog_view = nil

            UIManager:forceRePaint()

            self:runQuiet(function()

                self:openAtChapter(book, chapters, i)

            end)

        end,

        on_back = function()

            UIManager:close(view)

            self._catalog_view = nil

            UIManager:forceRePaint()

            self:showBookshelf(self._shelf_page or 1)

        end,

        on_toc_first = function()

            self:showCatalog(book, chapters, dur_index, 1, cover_path)

        end,

        on_page_changed = function(new_page)

            self:showCatalog(book, chapters, dur_index, new_page, cover_path)

        end,

        cache_fn = function(i) return self:chapterCacheState(book, i) end,

        on_cache_changed = function(p)

            self:showCatalog(book, chapters, dur_index, p, cover_path)

        end,

    }

    self._catalog_view = view

    UIManager:show(view)

    UIManager:setDirty(view, "full")
end

-- ---------- 开书：1 章即开 ----------

function XRead:openBook(book)

    -- 记住最后一次打开的书：首页「最近阅读」卡片实时指向它

    self._last_open_book_url = tostring((book and book.bookUrl) or "")

    self:runQuiet(function()

        if not self:ensureLogin() then return end

        -- 目录优先读本地缓存（后台预取/上次打开都写缓存），未命中才走网络
        local ttl = tonumber(self:getSetting("chapter_cache_ttl", "1800")) or 1800

        local chapters = self.meta_cache:getChapters(book, ttl)

        local cache_hit = chapters ~= nil

        if not cache_hit then

            chapters = self.client:getChapterList(book)

            if chapters and #chapters > 0 then self.meta_cache:putChapters(book, chapters) end

        else

            print("[XREAD_AUTOTEST] chapters_cache_hit")

        end

        if not chapters or #chapters == 0 then

            self:showInfo(_("目录为空"))

            return

        end

        local start = (tonumber(book.durChapterIndex) or 0) + 1

        if start < 1 then start = 1 end

        if start > #chapters then start = #chapters end

        self:openAtChapter(book, chapters, start)

    end)

end

-- 抓“当前这一章”（本地分片有就直接用），拼好 TXT 立刻打开；

-- 剩下的章节交给后台静默缓存。
function XRead:openAtChapter(book, chapters, index)

    local max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3

    if max_chapters < 1 then max_chapters = 1 end

    local last = math.min(index + max_chapters - 1, #chapters)

    -- 先取第一章原始 HTML：既能判断漫画，也能复用成正文（不重复请求）

    local raw, raw_ok = nil, false

    local cached_first = self.chapter_cache:get(book, index)

    if not cached_first then

        local ok, html = pcall(function() return self.client:getBookContentRaw(chapters[index], book) end)

        if ok and type(html) == "string" then

            raw, raw_ok = html, true

            local urls = self.client:extractImageUrls(html)

            local text_len = #(html:gsub("<[^>]+>", ""):gsub("%s", ""))

            if #urls >= 2 and text_len < 200 then

                return self:downloadComicAndOpen(book, chapters, index)

            end

        end

    end

    if not cached_first and raw_ok then

        cached_first = self.client:toText(raw)

        if cached_first and cached_first ~= "" then

            self.chapter_cache:put(book, index, cached_first)

        end

    end

    if not cached_first or cached_first == "" then

        self:showInfo(_("没有获取到正文"))

        return

    end

    -- 拼 HTML：把本地已有的后续分片一并带上，第二次打开基本是秒开。
    -- 用 HTML 而不是 TXT：crengine 支持 h2 换页（新章起新页、标题加大加粗）、
    -- 段落缩进与空白行折叠（见 chapterBlock/chapterHtmlHead）；h2 还能自动生成原生 TOC。
    -- 不写独立标题页：第 1 章直接从第 1 页开始。
    local parts = {

        chapterHtmlHead(book.name or ""),

    }

    local contig_end = index - 1

    for i = index, last do

        local text = self.chapter_cache:get(book, i)

        if not text then break end

        parts[#parts + 1] = chapterBlock(

            chapters[i] and chapters[i].title or ("第" .. i .. "章"), text)

        contig_end = i

    end

    local path = BOOK_DIR .. "/" .. safeFileName(book.name) .. "_" .. index .. ".html"

    local f = io.open(path, "w")

    if not f then self:showInfo(_("无法写入缓存文件")); return end

    f:write(table.concat(parts))

    f:close()

    SHARED.book, SHARED.chapters, SHARED.index = book, chapters, index

    SHARED.txt_path, SHARED.txt_size = path, fileSize(path)

    -- 进度上报异步化：不让它阻塞文档打开（失败也不影响阅读）
    UIManager:scheduleIn(0.5, function()

        pcall(function()

            self.client:saveBookProgress(book, index - 1)

            -- 同步写进书架缓存，首页「最近阅读」立即指向本书的最新进度

            pcall(function()

                self.meta_cache:updateShelfProgress(book.bookUrl or book.name, index - 1)

            end)

        end)

    end)

    -- 开书全程静默：不再弹「已就绪 X 章 / 正在打开」提示

    -- 剩余章节后台补，退出书籍即中断

    if contig_end < last then

        startBg{

            client = self.client,

            cache = self.chapter_cache,

            book = book,

            chapters = chapters,

            path = path,

            start_index = index,

            end_index = contig_end,

            next = contig_end + 1,

            last = last,

        }

    end

    -- 静默打开：传 seamless 避开 KOReader 的「正在打开文件」提示框
    UIManager:nextTick(function()

        if self.ui.document then

            self.ui:switchDocument(path, true)

        else

            require("apps/reader/readerui"):showReader(path, nil, true)

        end

    end)
end

-- ---------- 后台静默缓存 ----------

local bgStep
local function scheduleBg(delay)

    UIManager:scheduleIn(delay or 1.2, function() bgStep() end)

end
local function stopBg(reason)

    local job = BG.job

    BG.job = nil

    SHARED.cache_visual = nil

    restoreEndPopup()

    if not job then return end

    job.stopped = true

    -- 收掉抓取子进程（若还在跑），并收割避免僵尸
    if job.proc_pid then

        pcall(function()

            if not ffiutil.isSubProcessDone(job.proc_pid) then

                ffiutil.terminateSubProcess(job.proc_pid)

            end

        end)

    end

    if job.progress_file then pcall(os.remove, job.progress_file) end

    -- 注意：进度只按“用户实际打开的章”保存（openAtChapter 里写过一次），

    -- 这里不能写 end_index，否则只是后台多缓存了几章，进度就会被推到很后面。

    logger.info("xread bg cache stop:", tostring(reason or ""),

        "cached to chapter", tostring(job.end_index))

end
-- 抓取 worker：fork 子进程逐章请求后端并落盘，主进程完全不阻塞（修复缓存期间点击无响应）。
-- 子进程每完成一章，原子重写进度文件（先写 .tmp 再 rename），主进程 bgStep 每 1.2s 读一次。
local function spawnWorker(job)

    local prog_file = job.path .. ".bgprog"

    -- 先写一版基线进度，避免子进程首章完成前主进程读到旧/空文件
    do
        local f = io.open(prog_file .. ".tmp", "w")
        if f then
            f:write(string.format("next=%d ok=%d fail=%d end_index=%d",
                job.next, job.ok or 0, job.failed or 0, job.end_index or 0))
            f:close()
            os.rename(prog_file .. ".tmp", prog_file)
        end
    end

    job.progress_file = prog_file

    local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()

        local n_ok, n_fail, end_i = job.ok or 0, job.failed or 0, job.end_index or 0

        local function writeProg(next_i, done)
            local f = io.open(prog_file .. ".tmp", "w")
            if not f then return end
            f:write(string.format("next=%d ok=%d fail=%d end_index=%d %s",
                next_i, n_ok, n_fail, end_i, done and "DONE" or ""))
            f:close()
            os.rename(prog_file .. ".tmp", prog_file)
        end

        local i = job.next
        while i <= job.last do
            local ch = job.chapters[i]
            local okc, content = pcall(job.client.getBookContent, job.client, ch, job.book)
            if okc and type(content) == "string" and content ~= "" then
                pcall(job.cache.put, job.cache, job.book, i, content)
                local f = io.open(job.path, "a")
                if f then
                    f:write(chapterBlock(ch.title or ("第" .. i .. "章"), content))
                    f:close()
                end
                n_ok = n_ok + 1
                end_i = i
            else
                n_fail = n_fail + 1
                logger.warn("xread bg worker chapter failed:", i, tostring(content))
            end
            i = i + 1
            writeProg(i, i > job.last)
        end

    end, false)

    if ok_fork and pid then
        job.proc_pid = pid
    else
        -- fork 不可用（极端环境）：降级为主进程逐章模式（老行为，会短暂阻塞 UI）
        job.proc_pid = nil
        logger.warn("xread bg worker fork failed:", tostring(pid))
    end

end
bgStep = function()

    local job = BG.job

    if not job then return end

    if job.stopped then BG.job = nil; return end

    -- 书还没真正打开：等一会儿；始终没打开就放弃

    if not SHARED.open_path then

        job.waits = (job.waits or 0) + 1

        if job.waits > 15 then

            stopBg("reader never opened")

        else

            scheduleBg(2)

        end

        return

    end

    -- 用户已经退出这本书 / 换了别的书：立刻中断

    if SHARED.open_path ~= job.path then

        stopBg("left book")

        return

    end

    if job.next > job.last then

        stopBg("done")

        return

    end

    -- fork 失败的降级路径：老逻辑主进程同步抓一章（会短暂阻塞 UI，但功能可用）

    if not job.proc_pid then

        local i = job.next

        local ch = job.chapters[i]

        SHARED.cache_visual = {

            book_url = job.book and job.book.bookUrl,

            active = i,

            last = job.last,

        }

        local ok, content = pcall(function() return job.client:getBookContent(ch, job.book) end)

        if ok and content and content ~= "" then

            job.cache:put(job.book, i, content)

            local f = io.open(job.path, "a")

            if f then

                f:write(chapterBlock(ch.title or ("第" .. i .. "章"), content))

                f:close()

            end

            job.end_index = i

            job.ok = (job.ok or 0) + 1

        else

            job.failed = (job.failed or 0) + 1

            logger.warn("xread bg cache chapter failed:", i, tostring(content))

        end

        job.next = i + 1

        job.progress_done = (job.ok or 0) + (job.failed or 0)

        if job.on_progress then pcall(job.on_progress, job) end

        if job.want_reload then

            job.want_reload = false

            SHARED.txt_size = fileSize(job.path)

            local ui = SHARED.ui

            UIManager:nextTick(function() hotReload(ui, job.path) end)

        end

        if job.next > job.last then

            local same = SHARED.open_path == job.path

            local n = job.ok or 0

            if job.on_done then pcall(job.on_done, job) end

            stopBg("done")

            if same and n > 0 and not job.manual then

                UIManager:show(InfoMessage:new{

                    text = T(_("《%1》后续 %2 章已在后台缓存完成"), job.book.name or "", n),

                    timeout = 3,

                })

            end

            return

        end

        scheduleBg(1.2)

        return

    end

    -- 子进程模式：读进度文件推进状态（UI 线程只做文件读取，毫秒级，不阻塞点击）

    local changed, done = false, false

    if job.progress_file then

        local f = io.open(job.progress_file, "r")

        if f then

            local s = f:read("*a") or ""

            f:close()

            local next_i = tonumber(s:match("next=(%d+)"))

            local ok_n   = tonumber(s:match("ok=(%d+)"))

            local fail_n = tonumber(s:match("fail=(%d+)"))

            local end_i  = tonumber(s:match("end_index=(%d+)"))

            done = s:find("DONE", 1, true) ~= nil

            if ok_n and next_i then

                if ok_n ~= (job.ok or 0) or fail_n ~= (job.failed or 0) or (end_i or 0) ~= (job.end_index or 0) then

                    job.ok, job.failed = ok_n, fail_n

                    if end_i then job.end_index = end_i end

                    changed = true

                end

                if next_i ~= (job.next or 0) then

                    job.next = next_i

                    changed = true

                end

            end

        end

    end

    -- 目录页预加载高亮状态：active = 正在下载的那一章（cache_visual.lua 侧读取）

    SHARED.cache_visual = (job.next <= job.last) and {

        book_url = job.book and job.book.bookUrl,

        active = job.next,

        last = job.last,

    } or nil

    if changed then

        job.progress_done = (job.ok or 0) + (job.failed or 0)

        if job.on_progress then pcall(job.on_progress, job) end

    end

    -- 用户已经读到本批末尾、正在等新章节：补上章后热加载

    if job.want_reload and changed then

        job.want_reload = false

        SHARED.txt_size = fileSize(job.path)

        local ui = SHARED.ui

        UIManager:nextTick(function() hotReload(ui, job.path) end)

    end

    if done or job.next > job.last then

        local same = SHARED.open_path == job.path

        local n = job.ok or 0

        if job.on_done then pcall(job.on_done, job) end

        stopBg("done")

        if same and n > 0 and not job.manual then

            UIManager:show(InfoMessage:new{

                text = T(_("《%1》后续 %2 章已在后台缓存完成"), job.book.name or "", n),

                timeout = 3,

            })

        end

        return

    end

    -- 子进程异常退出且未写 DONE（崩溃/被系统杀）：重启一次继续，最多 2 次

    if ffiutil.isSubProcessDone(job.proc_pid) then

        job.restarts = (job.restarts or 0) + 1

        if job.restarts > 2 then

            stopBg("worker died")

            return

        end

        spawnWorker(job)

    end

    scheduleBg(1.2)

end
function startBg(job)

    stopBg("replaced")

    BG.job = job

    job.ok = job.ok or 0

    job.failed = job.failed or 0

    SHARED.cache_visual = nil

    disableEndPopup()

    spawnWorker(job)

    scheduleBg(2.5)   -- 先让阅读器把书打开、首屏排好版

end
function XRead:startCacheMore(count)

    local book, chapters = SHARED.book, SHARED.chapters

    local path = SHARED.txt_path

    if not book or not chapters or not path then

        return false, _("当前书无法缓存")

    end

    local index = SHARED.index or 1

    local cached = self:countCachedAhead(book, chapters, index)

    local from = index + cached

    if from > #chapters then

        return false, _("剩余章节已全部缓存")

    end

    local last = math.min(from + count - 1, #chapters)

    local total = last - from + 1

    local panel = SHARED.panel

    startBg{

        client = self.client,

        cache = self.chapter_cache,

        book = book,

        chapters = chapters,

        path = path,

        start_index = from,

        end_index = from - 1,

        next = from,

        last = last,

        manual = true,

        on_progress = function(job)

            if panel and SHARED.panel == panel then

                panel:setCacheHint(T(_("缓存中 %1/%2"),

                    tostring(job.progress_done or 0), tostring(total)))

            end

        end,

        on_done = function()

            if panel and SHARED.panel == panel then

                panel:setCacheHint(self:cacheHintText(book, chapters, index))

            end

        end,

    }

    return true

end
function XRead:cacheHintText(book, chapters, index)

    local cached = self:countCachedAhead(book, chapters, index)

    local remain = #chapters - index + 1

    if cached >= remain then return _("全部已缓存") end

    return T(_("已缓存 %1 章"), cached)

end

-- 面板里点“缓存后续章节”：从当前章往后补 N 章，进度实时回显在面板上
function XRead:countCachedAhead(book, chapters, index)

    local n = 0

    for i = index, #chapters do

        if self.chapter_cache:get(book, i) then n = n + 1 else break end

    end

    return n

end
-- ---------- 第三步：miuread 阅读工具栏（视觉层，数据仍走 xread） ----------

-- 用 xread 自有状态构造 miuread reader_toolbar 的 opts；读什么/跳到哪全部走 xread。

function XRead:buildMiuiToolbarOptions(book, chapters, index, font_size)

    local total = #chapters

    local percent = total > 0 and math.floor(index / total * 100 + 0.5) or 0

    local name = book.name or _("未知书籍")

    local function chapterLabel()

        -- 工具栏左下格显示书名（单行截断），章号信息由中间位置格承担

        return name

    end

    local function fontLabel()

        local f = self.ui and self.ui.font

        local v = f and f.configurable and tonumber(f.configurable.font_size)

        return tostring(v or font_size)

    end

    local function spacingLabel()

        return _("原生")

    end

    local battery_label = ""

    pcall(function()

        if Device:hasBattery() then

            local powerd = Device:getPowerDevice()

            local level = powerd and powerd:getCapacity()

            if level then battery_label = tostring(math.max(0, math.min(100, math.floor(level + 0.5)))) .. "%" end

        end

    end)

    -- 状态栏与首页一致：第一行显示昵称，右侧同步位显示连接状态

    local nickname = tostring(self:getSetting("nickname", "") or "")

    if nickname == "" then nickname = tostring(self:getSetting("username", "") or "") end

    if nickname == "" then nickname = name end

    local health_text = _("已连接")

    if self._health_ok == false then health_text = _("已断开") end

    local opts = {

        header = {

            title = nickname,

            time_label = os.date("%H:%M"),

            battery_label = battery_label,

            chapter_label = chapterLabel(),

            location_label = T(_("第 %1 / %2 章"), tostring(index), tostring(total)),

            progress_label = tostring(percent) .. "%",

            wifi_callback = nil,

            sync_label = health_text,

            sync_callback = function() self:syncProgress() end,

            home_callback = function() self:closeBookToShelf() end,

            more_callback = function() self:showMorePanel() end,

            book_callback = function() self:showBookCatalog(book) end,

            chapter_callback = function() self:showReaderCatalog() end,

            progress_callback = function() self:showReaderCatalog() end,

        },

        actions = {

            { icon = "toc", label = _("目录"), callback = function() self:showReaderCatalog() end },

            { icon = "cache", label = _("缓存"), value = self:cacheHintText(book, chapters, index),

                callback = function()

                    local max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3

                    if max_chapters < 1 then max_chapters = 1 end

                    local ok_c, msg_c = self:startCacheMore(max_chapters)

                    if not ok_c then

                        self:showInfo(tostring(msg_c or _("当前书无法缓存")))

                    else

                        -- 工具栏已收起，给个轻提示避免「点了没反应」
                        self:showInfo(T(_("已开始预缓存后续 %1 章"), tostring(max_chapters)))

                    end

                end,

                hold_callback = function() self:chooseBookToCache() end },

            { icon = "trash", label = _("删除"), callback = function() self:removeBookFlow() end },

            { icon = "library", label = _("书架"), callback = function() self:closeBookToShelf() end },

        },

        typeset = {

            font = {

                label = _("字号"), value = fontLabel(),

                callback = function() self:showSettings() end,

                on_decrease = function() self:changeFontSize(-1); return fontLabel() end,

                on_increase = function() self:changeFontSize(1); return fontLabel() end,

            },

            spacing = {

                label = _("行距"), value = spacingLabel(),

                callback = function() self:showSettings() end,

            },

        },

        device_actions = {

            { icon = "night", label = _("夜间"), callback = function() self:toggleNightMode() end },

            { icon = "refresh", label = _("刷新"), callback = function() UIManager:setDirty("all", "full") end },

            { icon = "sync", label = _("切换"), callback = function() self:switchBookSource() end },

            { icon = "settings", label = _("设置"), callback = function() self:showBookSettingsPanel() end },

        },

    }

    return opts

end

function XRead:showMiuiToolbar()

    local book, chapters = SHARED.book, SHARED.chapters

    if not book or not chapters or #chapters == 0 then

        self:showInfo(_("这本书不是从阅读X打开的"))

        return

    end

    -- 面板已关闭（点了按钮/点外部收起）时清掉残留引用，否则会一直挡住重新呼出
    if SHARED.panel then

        if SHARED.panel.closed then SHARED.panel = nil else return end

    end

    local index = math.max(1, math.min(SHARED.index or 1, #chapters))

    local font_size = 22

    pcall(function()

        local f = self.ui and self.ui.font

        if f and f.configurable and f.configurable.font_size then

            font_size = tonumber(f.configurable.font_size) or font_size

        end

    end)

    local opts = self:buildMiuiToolbarOptions(book, chapters, index, font_size)

    local panel, err = ReaderToolbar.show(opts, "xread-" .. tostring(SHARED.open_path or "reader"))

    if not panel then

        logger.warn("xread miui toolbar failed:", tostring(err))

        self:showInfo(_("工具栏打开失败，已改用旧面板"))

        return self:_showLegacyQuickPanel()

    end

    -- 打开后探测一次连接状态，动态刷新顶栏（与首页一致）
    UIManager:scheduleIn(0.5, function()

        if not panel or panel.closed then return end

        local old_timeout = http.TIMEOUT

        http.TIMEOUT = 3

        local ok_h, res = pcall(function() return self.client:health() end)

        http.TIMEOUT = old_timeout or 12

        local healthy = ok_h and res and res.isSuccess ~= false

        self._health_ok = healthy

        local header = panel.opts and panel.opts.header

        if header then

            header.sync_label = healthy and _("已连接") or _("已断开")

            pcall(function()

                if panel.updateFromOptions then panel:updateFromOptions(panel.opts) end

            end)

        end

    end)

    -- 兼容旧缓存回显机制：toolbar 把提示写到“位置”一栏

    panel.setCacheHint = function(_, text)

        local header = panel.opts and panel.opts.header

        if header then

            header.location_label = tostring(text or "")

            -- 关键：面板收起时只更新文本，绝不能调 updateFromOptions——
            -- 它内部会把 self.closed 置回 false，把已收起的工具栏“复活”，
            -- 结果是后台缓存期间面板反复拦截点击（表现为点了没反应）。
            if panel.closed then return end

            pcall(function()

                if panel.updateFromOptions then panel:updateFromOptions(panel.opts) end

            end)

        end

    end

    SHARED.panel = panel

end

function XRead:showQuickPanel()

    local book, chapters = SHARED.book, SHARED.chapters

    if not book or not chapters or #chapters == 0 then

        self:showInfo(_("这本书不是从阅读X打开的"))

        return

    end

    -- 面板已关闭（点了按钮/点外部收起）时清掉残留引用，否则会一直挡住重新呼出
    if SHARED.panel then

        if SHARED.panel.closed then SHARED.panel = nil else return end

    end

    if os.getenv("XREAD_PANEL_LEGACY") ~= "1" then

        return self:showMiuiToolbar()

    end

    return self:_showLegacyQuickPanel()

end

function XRead:_showLegacyQuickPanel()

    local index = math.max(1, math.min(SHARED.index or 1, #chapters))

    local font_size = 22

    pcall(function()

        local f = self.ui and self.ui.font

        if f and f.configurable and f.configurable.font_size then

            font_size = tonumber(f.configurable.font_size) or font_size

        end

    end)

    local panel

    panel = QuickPanel:new{

        book = book,

        chapters = chapters,

        index = index,

        font_size = font_size,

        cache_hint = self:cacheHintText(book, chapters, index),

        on_catalog = function() self:showReaderCatalog() end,

        on_cache = function()

            local max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3

            if max_chapters < 1 then max_chapters = 1 end

            local ok, msg = self:startCacheMore(max_chapters)

            if not ok then panel:setCacheHint(msg) end

        end,

        on_stats = function() self:showReadingStats() end,

        on_night = function() self:toggleNightMode() end,

        on_prev_chapter = function() self:jumpChapter(-1) end,

        on_next_chapter = function() self:jumpChapter(1) end,

        on_seek_chapter = function(ratio)

            local target = math.max(1, math.min(#chapters,

                math.floor(ratio * #chapters + 0.5)))

            if target ~= index then self:jumpToChapter(target) end

        end,

        on_reload = function() self:reloadCurrent() end,

        on_sync = function() self:syncProgress() end,

        on_settings = function() self:showSettings() end,

        on_shelf = function() self:closeBookToShelf() end,

        on_font = function(delta) self:changeFontSize(delta) end,

        on_close = function()

            if SHARED.panel == panel then SHARED.panel = nil end

        end,

    }

    SHARED.panel = panel

    UIManager:show(panel)

end
-- ---------- 面板里各快捷动作 ----------

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

function XRead:toggleNightMode()

    UIManager:broadcastEvent(Event:new("ToggleNightMode"))

    UIManager:setDirty("all", "full")

end

function XRead:changeFontSize(delta)

    local ui = self.ui

    if not ui then return end

    local ok = pcall(function() ui:handleEvent(Event:new("ChangeSize", delta)) end)

    if not ok then pcall(function() ui.font:onChangeSize(delta) end) end

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

    self:showInfo(ok and _("进度已同步") or _("同步失败"))

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

        -- 单源短超时，坏源不拖死整个切换

        local old_timeout = http.TIMEOUT

        http.TIMEOUT = 8

        local found_book, found_source, tried = nil, nil, 0

        local pos = start_i

        while tried < 5 do

            local s = list[pos]

            pos = pos % #list + 1

            tried = tried + 1

            local candidates = self.client:searchBook(book.name, s.bookSourceUrl)

            for _, cand in ipairs(candidates) do

                if tostring(cand.name or "") == tostring(book.name) and cand.bookUrl then

                    found_book, found_source = cand, s

                    break

                end

            end

            if found_book then break end

        end

        http.TIMEOUT = old_timeout or 12

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

        self:showInfo(T(_("已切换书源：%1"), tostring(found_source.bookSourceName or "")))

        self:openAtChapter(found_book, new_chapters, new_index)

    end)

end

-- 每次阅读器加载好文档记一个会话起点，退出时结算到阅读记录
function XRead:onReaderReady()

    local doc = self.ui and self.ui.document

    if doc and doc.file and SHARED.txt_path == doc.file then

        SHARED.read_start = os.time()

    end

    -- 底部状态栏：左对齐章节名 / 右对齐页码，去掉进度条
    self:_applyReaderFooter()

    -- 后台扫描正文 "== 章节标题 ==" 注入 TOC，章节名随翻页自动更新
    self:_injectTocFromText()

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

                    local idx = 0

                    for i = 1, #toc do

                        if (tonumber(toc[i].page) or 0) <= pageno then idx = i else break end

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

    end

end

-- 底部状态栏改为：左对齐当前章节名 + 右对齐页码（1/11），不再显示进度条
function XRead:_applyReaderFooter()

    local footer = self.ui and self.ui.view and self.ui.view.footer

    if not footer or not footer.settings then

        print("[XREAD_AUTOTEST] footer apply: no footer")

        return

    end

    local ok, err = pcall(function()

        local s = footer.settings

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

        footer:updateFooterTextGenerator()

        footer:updateFooterContainer()

        -- updateFooterContainer 重建了 positioner（dimen 为空），必须强制重算布局
        footer:resetLayout(true)

        -- updateFooterText 要等 footer 自己的 onReaderReady 才初始化为真实现，
        -- 延迟调用确保能真正刷新文本
        UIManager:scheduleIn(1, function()

            if footer.updateFooterText then footer:updateFooterText(true) end

        end)

        G_reader_settings:saveSetting("footer", s)

        G_reader_settings:flush()

    end)

    if os.getenv("XREAD_AUTOTEST") then

        print("[XREAD_AUTOTEST] footer apply: " .. tostring(ok) .. " " .. tostring(err))

    end

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

        if os.getenv("XREAD_AUTOTEST") then

            print("[XREAD_AUTOTEST] toc injected: native " .. tostring(#native))

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

    local path = self.document and self.document.file

    if not path then return end

    if SHARED.open_path == path then

        SHARED.open_path = nil

    end

    if SHARED.ui and SHARED.ui.document and SHARED.ui.document.file == path then

        SHARED.ui = nil

    end

    if SHARED.txt_path == path then

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

        self:showInfo(_("正在获取后续章节…"))

        return true

    end

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

        -- 先把 xread 书架盖到最上层，再关书；
        -- 否则关书露出的 KOReader 文件管理器会闪现在书架之前

        local fm = SHARED.fm

        if fm and fm.openShelf then

            pcall(function() fm:openShelf() end)

        end

        UIManager:scheduleIn(0.15, function()

            -- onHome 会关书并重新拉起文件管理器；只 close 的话整个 UI 会一起退出

            if ui and ui.document then

                if ui.onHome then

                    ui:onHome()

                else

                    ui:onClose()

                end

            end

            -- 书架可能在关书过程中被重建，再补一次确保盖在最上层

            UIManager:scheduleIn(0.4, function()

                local fm2 = SHARED.fm

                if fm2 and fm2.ui and not fm2.ui.document then

                    pcall(function() fm2:openShelf() end)

                end

            end)

        end)

    end)

end
-- ---------- 阅读点击分区：上 1/3 上一页、下 1/3 下一页、中间 1/3 调出配置菜单 ----------

-- 翻页分区方案：act -1=上一页 0=呼出工具栏 1=下一页
-- mode key 存设置 page_mode，翻页管理页展示同款描述
local PAGE_MODES = {

    default = { label = _("上下分区 · 点中间呼出工具栏"),
        desc = _("上 1/3 上一页，中 1/3 呼出工具栏，下 1/3 下一页"),
        zones = {
            { x = 0, y = 0, w = 1, h = 1/3, act = -1 },
            { x = 0, y = 1/3, w = 1, h = 1/3, act = 0 },
            { x = 0, y = 2/3, w = 1, h = 1/3, act = 1 },
        } },

    left_right = { label = _("左右分区 · 点中间呼出工具栏"),
        desc = _("左 1/3 上一页，中 1/3 呼出工具栏，右 1/3 下一页"),
        zones = {
            { x = 0, y = 0, w = 1/3, h = 1, act = -1 },
            { x = 1/3, y = 0, w = 1/3, h = 1, act = 0 },
            { x = 2/3, y = 0, w = 1/3, h = 1, act = 1 },
        } },

}

function XRead:currentPageMode()
    local mode = tostring(self:getSetting("page_mode", "default") or "default")
    return PAGE_MODES[mode] and mode or "default"
end

function XRead:setupCenterTap()

    if not Device:isTouchDevice() then return end

    local ui = self.ui

    if not ui or not ui.document or not ui.registerTouchZones then return end

    -- 接管这些默认分区：翻页、顶部菜单、底部配置菜单、状态栏点击（防止切走 footer 模式）
    local overrides = {}

    for _i, id in ipairs({
        "tap_forward", "tap_backward",
        "readermenu_tap", "readermenu_ext_tap",
        "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
        "readerfooter_tap", "xread_center_tap",
    }) do

        if ui:checkRegisterTouchZone(id) then overrides[#overrides + 1] = id end

    end

    -- 按翻页管理选中的方案注册分区（id 不变，重新注册即覆盖旧方案）
    local mode = PAGE_MODES[self:currentPageMode()] or PAGE_MODES.default

    local zone_ids = { "xread_tap_top", "xread_tap_middle", "xread_tap_bottom" }

    for i, z in ipairs(mode.zones) do

        local act = z.act

        ui:registerTouchZones({

            {

                id = zone_ids[i],

                ges = "tap",

                screen_zone = { ratio_x = z.x, ratio_y = z.y, ratio_w = z.w, ratio_h = z.h },

                overrides = overrides,

                handler = function(ges) return self:onReaderTapZone(ges, act) end,

            },

        })

    end

end
-- 只有“从阅读X打开的书”才接管点击分区，普通 TXT/EPUB 不受影响
-- act: -1 上一页 / 0 呼出工具栏 / 1 下一页
function XRead:onReaderTapZone(ges, act)

    local doc = self.ui and self.ui.document

    if not doc or not doc.file then return false end

    if SHARED.txt_path ~= doc.file then return false end

    -- 工具栏面板开着时不抢点击（面板自己处理关闭按钮）

    if act == 0 then

        self:showQuickPanel()

        return true

    end

    local pager = self.ui.paging or self.ui.rolling

    if pager and pager.onGotoViewRel then

        pager:onGotoViewRel(act)

        return true

    end

    return false

end
-- ---------- 设置读写 ----------

function XRead:getSetting(key, default)

    local v = self.settings:readSetting(key)

    if v == nil or v == "" then return default end

    return v

end

function XRead:saveSetting(key, value)

    self.settings:saveSetting(key, value)

    self.settings:flush()

end
-- ---------- 设置界面 ----------

-- ---------- 更多面板（首页 ≡ / 设置入口） ----------

-- 通用：标题 + 一列功能行 + 点空白/返回键关闭的全屏浮层
function XRead:showMoreListPanel(title, items, opts)

    local VerticalGroup = require("ui/widget/verticalgroup")
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

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local W = math.min(sw - 80, 700)
    local pad = math.floor(sw * 0.03)
    local inner_w = W - pad * 2
    local face_title = Font:getFace("cfont", 22)
    local face_row = Font:getFace("cfont", 18)
    local face_hint = Font:getFace("smallinfofont", 13)

    local dialog  -- forward

    local MoreRow = InputContainer:extend{
        text = nil, width = nil, height = nil, callback = nil,
    }

    function MoreRow:init()
        local hpad = Screen:scaleBySize(14)
        local tw = TextWidget:new{
            text = self.text,
            face = face_row,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = self.width - hpad * 2,
        }
        self.frame = FrameContainer:new{
            bordersize = 1, color = Blitbuffer.COLOR_GRAY_D,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0, margin = 0,
            padding_left = hpad, padding_right = hpad,
            width = self.width, height = self.height,
            LeftContainer:new{
                dimen = Geom:new{ w = self.width - 2 * hpad, h = self.height }, tw,
            },
        }
        self[1] = self.frame
        self.dimen = Geom:new{ w = self.width, h = self.height }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end

    function MoreRow:onTap()
        if self.callback then self.callback() end
        return true
    end

    local row_h = Screen:scaleBySize(56)
    local gap = Screen:scaleBySize(12)

    local rows = VerticalGroup:new{ align = "left" }
    for idx, item in ipairs(items) do
        rows[#rows + 1] = MoreRow:new{
            text = item.label,
            width = inner_w, height = row_h,
            callback = function()
                -- callback 为空的行是纯信息展示（如版本号），点击无动作
                if item.callback then
                    UIManager:close(dialog)
                    item.callback()
                end
                return true
            end,
        }
        if idx < #items then
            rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        end
    end

    local card = VerticalGroup:new{ align = "left" }

    card[#card + 1] = TextBoxWidget:new{
        text = title, face = face_title, bold = true,
        width = inner_w, fgcolor = Blitbuffer.COLOR_BLACK,
    }
    card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
    card[#card + 1] = LineWidget:new{
        dimen = Geom:new{ w = inner_w, h = 1 },
        background = Blitbuffer.COLOR_GRAY_D,
    }
    card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
    card[#card + 1] = rows

    if opts and opts.hint then
        card[#card + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
        card[#card + 1] = TextBoxWidget:new{
            text = opts.hint, face = face_hint,
            width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
    end

    local frame = FrameContainer:new{
        bordersize = 2, color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE, radius = 8,
        padding = pad, margin = 0,
        card,
    }

    -- 点空白或按返回键直接关闭（无草稿要保存）
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
        UIManager:close(dialog)
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        return true
    end

    function Overlay:onClose()
        UIManager:close(dialog)
        UIManager:setDirty("all", "full")
        return true
    end

    function Overlay:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
        self[1]:paintTo(bb, x, y)
    end

    dialog = Overlay:new{}

    UIManager:show(dialog)

end

function XRead:showMorePanel()

    self:showMoreListPanel(_("更多"), {
        { label = _("我的首页"), callback = function() self:openHome() end },
        { label = _("我的书架"), callback = function() self:openShelf() end },
        { label = _("地址管理"), callback = function() self:showServerManage() end },
        { label = _("账号管理"), callback = function() self:showAccountManage() end },
        { label = _("书架管理"), callback = function() self:showShelfManage() end },
        { label = _("缓存管理"), callback = function() self:showCacheManage() end },
        { label = _("翻页管理"), callback = function() self:showPageManage() end },
        { label = _("阅读记录"), callback = function() self:showReadingStats() end },
        { label = _("关于本机"), callback = function() self:showAboutPanel() end },
    }, { hint = _("点击条目进入；点空白处返回。") })

end

-- ---------- 在线热更新 ----------

-- 书架/首页显示后错峰静默检查新版本（失败完全无声，仅首次发现时提示一次）
function XRead:quietUpdateCheck(delay)

    if os.getenv("XREAD_NO_UPDATER") == "1" then return end

    UIManager:scheduleIn(delay or 10, function()

        Trapper:wrap(function()

            local ok, updater = pcall(function()
                return require("xread/updater"):new{ client = self.client }
            end)

            if not ok then Trapper:clear() return end

            local ok_check, manifest, info = pcall(function() return updater:check() end)

            Trapper:clear()

            if ok_check and manifest and info and info.newer
                    and self._update_notified ~= info.remote_version then

                self._update_notified = info.remote_version

                self._update_manifest = manifest

                self._update_info = info

                self:showInfo(T(_("发现新版本 %1 → %2\n请到 更多 → 关于本机 → 检查更新 安装"),
                    tostring(info.local_version), tostring(info.remote_version)))

            end

        end)

    end)

end

-- 关于本机：插件版本 / 后端版本 / 固件版本 / 检查更新
function XRead:showAboutPanel()

    self:runQuiet(function()

        local updater = require("xread/updater"):new{ client = self.client }

        local plugin_v = updater:getLocalVersion() or _("未知")

        local server_v = self.client:getServerVersion() or _("未知")

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

        self._about_info = { plugin_v = plugin_v, server_v = server_v, fw = fw or _("未知") }

        UIManager:nextTick(function() self:_showAboutPanel() end)

    end)

end

function XRead:_showAboutPanel()

    local info = self._about_info or {}

    self:showMoreListPanel(_("关于本机"), {

        { label = T(_("插件版本：%1"), tostring(info.plugin_v or "?")) },

        { label = T(_("后端版本：%1"), tostring(info.server_v or "?")) },

        { label = T(_("固件版本：%1"), tostring(info.fw or "?")) },

        { label = _("检查更新"), callback = function() self:checkForUpdateInteractive() end },

    }, { hint = _("检查更新会从服务端下载新版插件并安装，需重启 KOReader 生效。") })

end

-- 手动检查更新（关于本机 → 检查更新）
function XRead:checkForUpdateInteractive()

    self:runQuiet(function()

        local updater = require("xread/updater"):new{ client = self.client }

        local manifest, info = updater:check()

        self._update_manifest = manifest

        self._update_info = info

        self._update_notified = info.newer and info.remote_version or self._update_notified

        UIManager:nextTick(function() self:confirmUpdate() end)

    end)

end

function XRead:confirmUpdate()

    local manifest, info = self._update_manifest, self._update_info

    if not manifest or not info then return end

    if not info.newer then

        self:showInfo(T(_("已是最新版本 %1"), tostring(info.local_version)))

        return

    end

    local notes = manifest.notes or ""

    if notes ~= "" then notes = "\n\n更新内容：" .. notes end

    UIManager:show(ConfirmBox:new{

        text = T(_("发现新版本 %1 → %2\n需要下载 %3 个文件（%4 个可跳过）%5\n\n现在更新吗？\n安装后需重启 KOReader 生效。"),
            tostring(info.local_version), tostring(info.remote_version),
            tostring(info.total - info.skipped), tostring(info.skipped), notes),

        ok_text = _("更新"),

        ok_callback = function() self:applyUpdateFlow(manifest) end,

    })

end

-- 下载并替换文件；完成后提示重启
function XRead:applyUpdateFlow(manifest)

    self:runQuiet(function()

        local updater = require("xread/updater"):new{ client = self.client }

        local changed, skipped = updater:apply(manifest, function(done, total, path)

            Trapper:info(T(_("正在更新 %1/%2：%3"), tostring(done), tostring(total), tostring(path)), true)

        end)

        self._update_manifest = nil

        self._update_info = nil

        -- 更新包与解压目录同名同级留存，提示用户可在哪找到本次安装的包
        local pkg_line = ""
        if updater.getLastPackage then
            local _pkg_file, pkg_dir = updater:getLastPackage()
            if pkg_dir then
                pkg_line = "\n" .. T(_("更新包已留存：xread_update/%1/"),
                    tostring(pkg_dir:match("[^/]+$") or pkg_dir))
            end
        end

        UIManager:nextTick(function()

            UIManager:show(ConfirmBox:new{

                text = T(_("更新完成（变更 %1 个文件，跳过 %2 个未变更）。%3\n需要重启 KOReader 生效，现在重启吗？"),
                    tostring(changed), tostring(skipped), pkg_line),

                ok_text = _("重启"),

                ok_callback = function()

                    UIManager:restartKOReader()

                end,

                cancel_text = _("稍后手动重启"),

            })

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

                self:showInfo(T(_("已选择：%1"), it.desc))

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
        local addr = tostring(self:getSetting("address", "") or "")
        local host = addr:gsub("^%w+://", "")
        local ip, port = host:match("^([^:/]+):(%d+)$")
        if not ip then ip, port = host, "" end
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
        local ip = (draft.ip or ""):gsub("%s", "")
        local port = (draft.port or ""):gsub("%s", "")
        if ip == "" then return end
        local addr = "http://" .. ip
        if port ~= "" then addr = addr .. ":" .. port end
        self:saveSetting("address", addr)
        if addr ~= self.client.address then
            self.client.address = addr
            self.client.accessToken = nil   -- 换地址后需重登
        end
    end

    local function saveAndClose()
        saveDraft()
        self._server_draft = nil
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        self:showInfo(_("服务器设置已保存"))
    end

    local function refreshDialog()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")
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
    local close_w = Screen:scaleBySize(48)
    local CloseBtn = InputContainer:extend{}
    function CloseBtn:init()
        self.dimen = Geom:new{ w = close_w, h = Screen:scaleBySize(36) }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        self[1] = TextWidget:new{
            text = "✕", face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_GRAY_D,
        }
    end
    function CloseBtn:onTap() saveAndClose() return true end
    local stretch = inner_w - title_tw:getSize().w - close_w
    if stretch < 0 then stretch = 0 end
    card[#card + 1] = HorizontalGroup:new{ align = "center",
        title_tw, HorizontalSpan:new{ width = stretch }, CloseBtn:new{} }
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
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
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
        self:saveSetting("nickname", draft.nickname)
        self:saveSetting("username", draft.username)
        self:saveSetting("password", draft.password)
    end

    local function saveAndClose()
        saveDraft()
        self._account_draft = nil
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        self:showInfo(_("账号设置已保存"))
    end

    local function refreshDialog()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")
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
        label = _("用户名"),
        value = shownValue("username"),
        width = inner_w, height = row_h,
        callback = function() editField("username", _("用户名")) end,
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
    local close_w = Screen:scaleBySize(48)
    local CloseBtn = InputContainer:extend{}
    function CloseBtn:init()
        self.dimen = Geom:new{ w = close_w, h = Screen:scaleBySize(36) }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        self[1] = TextWidget:new{
            text = "✕", face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_GRAY_D,
        }
    end
    function CloseBtn:onTap() saveAndClose() return true end
    local stretch = inner_w - title_tw:getSize().w - close_w
    if stretch < 0 then stretch = 0 end
    card[#card + 1] = HorizontalGroup:new{ align = "center",
        title_tw, HorizontalSpan:new{ width = stretch }, CloseBtn:new{} }
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
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
        self[1]:paintTo(bb, x, y)
    end

    dialog = Overlay:new{}

    UIManager:show(dialog)

end

-- 书架管理：多选书籍 → 批量删除 / 移动分组
function XRead:showShelfManage()

    self:runOnline(_("正在加载书架…"), function()

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
        UIManager:show(ConfirmBox:new{
            text = T(_("确定删除所选 %1 本书？\n服务器上的书籍、缓存和进度都会被移除。"), #urls),
            ok_text = _("删除"),
            ok_callback = function()
                Trapper:wrap(function()
                    local ok_n, fail_n = 0, 0
                    for _ui, url in ipairs(urls) do
                        local b = by_url[url]
                        local okd = pcall(function() self.client:deleteBook(b) end)
                        if okd then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
                    end
                    Trapper:clear()
                    self:showInfo(T(_("已删除 %1 本（失败 %2 本）"), ok_n, fail_n))
                    -- 重开时重新拉书架
                    self:showShelfManage()
                end)
            end,
        })
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
        self:runOnline(_("正在获取分组…"), function()
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
                        self:showInfo(T(_("已移动 %1 本（失败 %2 本）"), ok_n, fail_n))
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
            self.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = Geom:new{ w = sw, h = sh } } } }
            self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame }
        end
        function DialogClass:onClose()
            UIManager:close(self)
            return true
        end
        function DialogClass:onTapSelect() return true end
        dialog = DialogClass:new{}
    else
        dialog = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame }
    end

    UIManager:show(dialog)

    -- runOnline 的 UI:clear() 会在弹窗 show 之后重绘进度框区域，
    -- 局部刷新会把弹窗区刷回底层正文（残影）；这里强制全屏刷新兜底
    UIManager:setDirty(dialog, "full")

end

-- 缓存管理：选书 → 选档位（10/50/100/全部）
function XRead:showCacheManage()

    self:runOnline(_("正在加载书架…"), function()

        if not self:ensureLogin() then return end

        local ok, books = pcall(function() return self.client:getBookshelf() end)

        if not ok or type(books) ~= "table" or #books == 0 then

            self:showInfo(_("书架为空"))

            return

        end

        local items = {}

        for _bi, book in ipairs(books) do

            items[#items + 1] = {

                text = (book.name or "?") .. "　" .. (book.author or ""),

                callback = function() self:showCacheLevels(book) end,

            }

        end

        UIManager:show(Menu:new{

            title = _("缓存管理 · 选择书籍"),

            item_table = items,

            width = Screen:getWidth(),

            height = Screen:getHeight(),

        })

    end)

end

function XRead:showCacheLevels(book)

    local levels = {
        { label = _("缓存 10 章"), count = 10 },
        { label = _("缓存 50 章"), count = 50 },
        { label = _("缓存 100 章"), count = 100 },
        { label = _("缓存全部章节"), count = 0 },
    }

    local items = {}

    for _li, lv in ipairs(levels) do

        items[#items + 1] = {

            text = lv.label,

            callback = function() self:doCacheBook(book, lv.count) end,

        }

    end

    UIManager:show(Menu:new{

        title = T(_("缓存管理 · %1"), tostring(book.name or "")),

        item_table = items,

        width = Screen:getWidth(),

        height = Screen:getHeight(),

    })

end

function XRead:showSettings()

    -- miuread 风格设置页：分组标题 + 行式布局 + 步进器 + 取消/保存（参考觅阅设置设计稿）
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local Button = require("ui/widget/button")
    local LineWidget = require("ui/widget/linewidget")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")

    -- 草稿：跨对话框重建保留，保存/取消时清除
    local draft = self._settings_draft
    if not draft then
        draft = {
            address = tostring(self:getSetting("address", "") or ""),
            username = tostring(self:getSetting("username", "") or ""),
            password = tostring(self:getSetting("password", "") or ""),
            nickname = tostring(self:getSetting("nickname", "") or ""),
            max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3,
        }
        self._settings_draft = draft
    end

    local W = math.min(Screen:getWidth() - 80, 860)
    local pad = math.floor(Screen:getWidth() * 0.03)
    local inner_w = W - pad * 2
    local face_title = Font:getFace("cfont", 22)
    local face_group = Font:getFace("smallinfofont", 15)
    local face_row = Font:getFace("cfont", 18)
    local face_hint = Font:getFace("smallinfofont", 13)

    local dialog  -- forward

    -- 统一提交草稿到配置（关闭即保存）
    local function saveDraft()
        self:saveSetting("address", draft.address)
        self:saveSetting("username", draft.username)
        self:saveSetting("password", draft.password)
        self:saveSetting("nickname", draft.nickname)
        self:saveSetting("max_chapters", tostring(draft.max_chapters))
        if draft.address ~= self.client.address then
            self.client.address = draft.address
            self.client.accessToken = nil   -- 换地址后需重登
        end
    end

    local function saveAndClose()
        saveDraft()
        self._settings_draft = nil
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        self:showInfo(_("设置已保存"))
    end

    local function refreshDialog()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")
        self:showSettings()   -- 重建读 self._settings_draft
    end

    local function groupLabel(text)
        return TextBoxWidget:new{
            text = text, face = face_group, bold = true,
            width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
    end

    local function editField(key, title, default, is_password)
        local old_val = draft[key]
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

    local function fieldRow(label, key, is_password, title, default)
        local value = tostring(draft[key] or "")
        local shown = value ~= "" and value or _("(未设置)")
        if is_password and value ~= "" then shown = "******" end
        return Button:new{
            text = label .. "  " .. shown,
            text_font_face = "cfont",
            text_font_size = 18,
            text_font_bold = true,
            bordersize = 0,
            width = inner_w,
            padding = 0,
            align = "left",
            callback = function() editField(key, title, default, is_password) end,
        }
    end

    local value_widget  -- 步进器数值，点 ± 后就地刷新文本
    local function stepperRow()
        local minus = Button:new{
            text = "－",
            text_font_face = "cfont", text_font_size = 20,
            bordersize = 1, radius = 6,
            width = Screen:scaleBySize(72),
            callback = function()
                draft.max_chapters = math.max(1, (tonumber(draft.max_chapters) or 30) - 1)
                refreshDialog()
            end,
        }
        local plus = Button:new{
            text = "＋",
            text_font_face = "cfont", text_font_size = 20,
            bordersize = 1, radius = 6,
            width = Screen:scaleBySize(72),
            callback = function()
                draft.max_chapters = math.min(200, (tonumber(draft.max_chapters) or 30) + 1)
                refreshDialog()
            end,
        }
        value_widget = TextWidget:new{
            text = tostring(draft.max_chapters),
            face = face_row, bold = true,
        }
        local label = TextWidget:new{
            text = _("自动缓存章数"),
            face = face_row, bold = true,
        }
        local row = HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = inner_w * 0.55, h = Screen:scaleBySize(52) }, label },
            minus,
            HorizontalSpan:new{ width = Screen:scaleBySize(14) },
            CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = Screen:scaleBySize(52) }, value_widget },
            HorizontalSpan:new{ width = Screen:scaleBySize(14) },
            plus,
        }
        return row
    end

    local function hintLine(text)
        return TextBoxWidget:new{
            text = text, face = face_hint,
            width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
        }
    end

    local function separator()
        return LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(1) },
        }
    end

    local gap_small = Screen:scaleBySize(10)
    local gap_mid = Screen:scaleBySize(16)

    local content = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = _("设置"), face = face_title, bold = true, width = inner_w },
        HorizontalSpan:new{ width = gap_mid },
        separator(),
        HorizontalSpan:new{ width = gap_mid },
        groupLabel(_("服务器连接")),
        HorizontalSpan:new{ width = gap_small },
        fieldRow(_("后端地址"), "address", false, _("后端地址"), "http://192.168.31.51:7777"),
        HorizontalSpan:new{ width = gap_small },
        fieldRow(_("用户名"), "username", false, _("用户名"), ""),
        HorizontalSpan:new{ width = gap_small },
        fieldRow(_("密码"), "password", true, _("密码"), ""),
        HorizontalSpan:new{ width = gap_mid },
        groupLabel(_("个人设置")),
        HorizontalSpan:new{ width = gap_small },
        fieldRow(_("昵称"), "nickname", false, _("昵称（首页显示）"), ""),
        HorizontalSpan:new{ width = gap_mid },
        groupLabel(_("阅读偏好")),
        HorizontalSpan:new{ width = gap_small },
        stepperRow(),
        HorizontalSpan:new{ width = gap_small },
        hintLine(_("每次自动缓存的章节数，范围 1-200。打开书后会后台静默补满。")),
        HorizontalSpan:new{ width = gap_mid },
        separator(),
        HorizontalSpan:new{ width = gap_small },
        hintLine(_("点空白处或按返回键关闭并保存。")),
    }

    local frame = FrameContainer:new{
        bordersize = 2,
        radius = 10,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
        content,
    }

    -- 全屏浮层：子控件未消费的点击 = 点空白 → 保存并关闭
    local InputOverlay = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")

    local overlay_dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    -- 必须用实例（:new）入窗：直接 show 类不会跑 _init，
    -- _ordered_touch_zones 为 nil，任何手势广播都会 ipairs(nil) 崩溃
    local Overlay = InputOverlay:extend{}
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
        -- 先刷一层浅灰遮罩再画卡片，提示「点空白关闭」
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
        self[1]:paintTo(bb, x, y)
    end

    dialog = Overlay:new{}

    UIManager:show(dialog)

end
-- ---------- 齿轮「设置」：预加载 + 字体（即改即存，无保存按钮） ----------

function XRead:showBookSettingsPanel()

    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local LineWidget = require("ui/widget/linewidget")
    local GestureRange = require("ui/gesturerange")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")

    local dialog  -- forward

    local function refreshDialog()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")
        self:showBookSettingsPanel()
    end

    local function closePanel()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
    end

    local function currentFontSize()
        local v = nil
        pcall(function()
            local f = self.ui and self.ui.font
            v = f and f.configurable and tonumber(f.configurable.font_size)
        end)
        return tostring(v or 22)
    end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local W = math.min(sw - 80, 700)
    local pad = math.floor(sw * 0.03)
    local inner_w = W - pad * 2
    local face_title = Font:getFace("cfont", 22)
    local face_row = Font:getFace("cfont", 18)
    local face_hint = Font:getFace("smallinfofont", 13)

    local row_h = Screen:scaleBySize(52)
    local gap = Screen:scaleBySize(12)

    -- 步进按钮：直接挂 ges_events（与 FieldRow 同机制），点按即生效并重建面板
    local function stepBtn(text, on_step)
        local btn = InputContainer:extend{}
        function btn:init()
            self.dimen = Geom:new{ w = Screen:scaleBySize(64), h = Screen:scaleBySize(44) }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
            self[1] = TextWidget:new{
                text = text, face = face_row, bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        function btn:onTap() on_step(); return true end
        return btn:new{}
    end

    local function valueText(text)
        return CenterContainer:new{
            dimen = Geom:new{ w = Screen:scaleBySize(70), h = row_h },
            TextWidget:new{ text = text, face = face_row, bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK },
        }
    end

    local function labelRow(text)
        return TextWidget:new{
            text = text, face = face_row, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end

    -- 行1：自动缓存章数
    local chapter_row = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - 220, h = row_h },
            labelRow(_("自动缓存章数")) },
        stepBtn("－", function()
            local v = (tonumber(self:getSetting("max_chapters", "3")) or 3) - 1
            if v < 1 then v = 1 end
            self:saveSetting("max_chapters", tostring(v))
            refreshDialog()
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        valueText(tostring(self:getSetting("max_chapters", "3"))),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        stepBtn("＋", function()
            local v = (tonumber(self:getSetting("max_chapters", "3")) or 3) + 1
            if v > 200 then v = 200 end
            self:saveSetting("max_chapters", tostring(v))
            refreshDialog()
        end),
    }

    -- 行2：字号
    local font_row = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - 220, h = row_h },
            labelRow(_("字号")) },
        stepBtn("－", function()
            self:changeFontSize(-1)
            refreshDialog()
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        valueText(currentFontSize()),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        stepBtn("＋", function()
            self:changeFontSize(1)
            refreshDialog()
        end),
    }

    local rows = VerticalGroup:new{ align = "left" }
    rows[#rows + 1] = chapter_row
    rows[#rows + 1] = HorizontalSpan:new{ width = gap }
    rows[#rows + 1] = TextWidget:new{
        text = _("打开书后后台静默预缓存这么多章（1-200）"),
        face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
    }
    rows[#rows + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(20) }
    rows[#rows + 1] = font_row
    rows[#rows + 1] = HorizontalSpan:new{ width = gap }
    rows[#rows + 1] = TextWidget:new{
        text = _("字号立即生效；预加载越多开书越快，但占用存储也越多"),
        face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
    }

    local card = VerticalGroup:new{ align = "left" }

    -- 标题行右侧加「✕」：点击分区（上/中/下 1/3）会抢走全屏 tap，
    -- 点空白关闭收不到手势，必须有可见的关闭按钮（与地址/账号管理一致）
    local title_tw = TextWidget:new{
        text = _("书籍设置"), face = face_title, bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local close_w = Screen:scaleBySize(48)
    local CloseBtn = InputContainer:extend{}
    function CloseBtn:init()
        self.dimen = Geom:new{ w = close_w, h = Screen:scaleBySize(36) }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        self[1] = TextWidget:new{
            text = "✕", face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_GRAY_D,
        }
    end
    function CloseBtn:onTap() closePanel() return true end
    local stretch = inner_w - title_tw:getSize().w - close_w
    if stretch < 0 then stretch = 0 end
    card[#card + 1] = HorizontalGroup:new{ align = "center",
        title_tw, HorizontalSpan:new{ width = stretch }, CloseBtn:new{} }
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
        closePanel()
        return true
    end

    function Overlay:onClose()
        closePanel()
        return true
    end

    function Overlay:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
        self[1]:paintTo(bb, x, y)
    end

    dialog = Overlay:new{}

    UIManager:show(dialog)

end

-- ---------- 移除书籍（从后端书架删除） ----------

function XRead:removeBookFlow()

    local ok, books = pcall(function() return self.client:getBookshelf() end)

    if not ok or type(books) ~= "table" or #books == 0 then

        self:showInfo(_("书架为空或获取失败"))

        return

    end

    local items = {}

    for _i, book in ipairs(books) do

        items[#items + 1] = {

            text = (book.name or "?") .. "　" .. (book.author or ""),

            callback = function()

                UIManager:show(ConfirmBox:new{

                    text = T(_("移除「%1」？\n将从服务器书架删除这本书（含服务器缓存与本地章节缓存）。"), book.name or ""),

                    ok_text = _("移除"),

                    ok_callback = function()

                        self:runQuiet(function()

                            local del_ok = self.client:deleteBook(book)

                            if del_ok then

                                -- 清本地：章节分片目录 + 目录缓存
                                pcall(function()

                                    local util = require("util")

                                    local dir = self.chapter_cache:dirFor(book)

                                    if lfs.attributes(dir, "mode") == "directory" then util.purgeDir(dir) end

                                    local meta_path = self.meta_cache:chaptersPath(book)

                                    if meta_path and lfs.attributes(meta_path, "mode") == "file" then os.remove(meta_path) end

                                end)

                                -- 刷新书架缓存（移除后重新拉取）
                                pcall(function()

                                    local fresh = self.client:getBookshelf()

                                    if type(fresh) == "table" then self.meta_cache:putShelf(fresh) end

                                end)

                                self:showInfo(T(_("已移除「%1」"), book.name or ""))

                            else

                                self:showInfo(_("移除失败"))

                            end

                        end)

                    end,

                })

            end,

        }

    end

    UIManager:show(Menu:new{

        title = _("选择要移除的书"),

        item_table = items,

        width = Screen:getWidth(),

        height = Screen:getHeight(),

    })

end

-- ---------- 整本预缓存（后端） ----------

function XRead:chooseBookToCache()

    local books = self.client:getBookshelf()

    if #books == 0 then self:showInfo(_("书架为空")); return end

    local items = {}

    for _i, book in ipairs(books) do

        items[#items + 1] = {

            text = (book.name or "?") .. "　" .. (book.author or ""),

            callback = function()

                UIManager:show(ConfirmBox:new{

                    text = T(_("整本预缓存「%1」？\n后端会把全部章节下载到服务器磁盘，之后阅读秒开。"), book.name or ""),

                    ok_text = _("开始缓存"),

                    ok_callback = function() self:doCacheBook(book) end,

                })

            end,

        }

    end

    UIManager:show(Menu:new{

        title = _("选择要缓存的书"),

        item_table = items,

        width = Screen:getWidth(),

        height = Screen:getHeight(),

    })

end

function XRead:doCacheBook(book, count)

    local UI = require("ui/trapper")

    Trapper:wrap(function()

        local last_msg = ""

        local ok, err = pcall(function()

            self.client:cacheBookSSE(book, {

                count = tonumber(count) or 0,   -- 0 = 全部章节

                concurrentCount = 8,

                refresh = 0,

            }, function(info)

                local msg = string.format(

                    _("已缓存 %d 章（成功 %d / 失败 %d）"),

                    info.cachedCount or 0, info.successCount or 0, info.failedCount or 0)

                if info.isEnd then msg = _("缓存完成：") .. msg end

                if msg ~= last_msg then UI:info(msg); last_msg = msg end

            end)

        end)

        UI:clear()

        if ok then

            self:showInfo(_("整本缓存完成，可在书架直接阅读"))

        else

            self:showInfo(_("缓存失败：") .. tostring(err))

        end

    end)

end
-- ---------- 漫画：下载图片 -> 打包 CBZ -> 打开 ----------

function XRead:downloadComicAndOpen(book, chapters, start_index)

    local Archiver = require("ffi/archiver")

    local batch = tonumber(self:getSetting("comic_chapters", "5")) or 5

    if batch < 1 then batch = 1 end

    local last = math.min(start_index + batch - 1, #chapters)

    local path = BOOK_DIR .. "/" .. safeFileName(book.name) .. "_" .. start_index .. ".cbz"

    local arc = Archiver.Writer:new{}

    if not arc:open(path, "zip") then

        self:showInfo(_("无法创建漫画文件"))

        return

    end

    arc:setZipCompression("store")   -- 图片已压缩，无需再 deflate

    local mtime = os.time()

    local total_img, total_ch = 0, 0

    for i = start_index, last do

        local ch = chapters[i]

        local ok, html = pcall(function() return self.client:getBookContentRaw(ch, book) end)

        if ok then

            local urls = self.client:extractImageUrls(html)

            local n = 0

            for j, url in ipairs(urls) do

                local data = self.client:downloadImage(url)

                if data then

                    n = n + 1

                    arc:addFileFromMemory(string.format("%04d_%04d.jpg", i, j), data, mtime)

                    total_img = total_img + 1

                end

                -- 静默下载：不再弹进度框，点书后直接等正文打开（避免弹窗挡住操作）

            end

            if n > 0 then total_ch = total_ch + 1 end

        end

    end

    arc:close()

    if total_img == 0 then

        self:showInfo(_("没有下载到任何图片"))

        return

    end

    pcall(function() self.client:saveBookProgress(book, start_index - 1) end)

    SHARED.book, SHARED.chapters, SHARED.index = book, chapters, start_index

    -- 静默打开漫画：不弹提示，直接切文档
    UIManager:nextTick(function()

        if self.ui.document then

            self.ui:switchDocument(path, true)

        else

            require("apps/reader/readerui"):showReader(path, nil, true)

        end

    end)

end

return XRead
