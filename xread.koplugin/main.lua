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

-- 不再直接 require("socket.http")：所有请求都经 xread/client 与 xread/http_client，
-- 那里给每个请求单独设超时并保证恢复全局值，绝不在插件里改写 http.TIMEOUT。

local logger       = require("logger")

local _            = require("gettext")

local T            = require("ffi/util").template

local ffiutil      = require("ffi/util")

--- 回收 fork 出的子进程（waitpid），避免僵尸进程残留。
-- ffiutil.runInSubProcess 只负责 fork，回收必须由调用方自己做；
-- 不回收会留下两个真实后果：
--   ① 每做一次「整本缓存 / 整本导出」就留一个 defunct 条目，直到 KOReader 退出；
--   ② 用户点「中止」后子进程仍在后台把整本书跑完（界面说已取消，实际没取消，
--      还在持续发请求、写文件，导出甚至会写出完整 EPUB）。
-- kill_first=true（中止/超时）时先对进程组发 SIGKILL；terminate 之后内核不保证
-- 立刻回收，故最多轮询 2 秒（40 × 50ms），仍未退出再补一刀。
-- ✅ Lua 5.1 通用（ffiutil.sleep 内部是 C.Sleep，不依赖协程）
local function reapSubProcess(pid, kill_first)
    if not pid then return end
    if kill_first then pcall(ffiutil.terminateSubProcess, pid) end
    for _ = 1, 40 do
        if ffiutil.isSubProcessDone(pid) then return end
        ffiutil.sleep(0.05)
    end
    pcall(ffiutil.terminateSubProcess, pid)
    ffiutil.isSubProcessDone(pid)
end

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

local UICommon = require("xread.ui_common")
local BookExport = require("xread.book_export")

--- 插件版本：唯一来源是插件根目录的 _meta.lua
-- 原来这里硬编码 "0.6.10"，升级到 0.6.13 后关于页/更新提示仍显示旧版本，
-- 两个版本号迟早会再次对不上，所以直接读 _meta.lua。
local function readPluginVersion()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local root = src:match("^(.*[/\\])") or ""
    local ok, meta = pcall(dofile, root .. "_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0.0.0"
end

local XRead = WidgetContainer:extend{

    name = "xread",

    is_doc_only = false,

    version = readPluginVersion(),

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

--- 本地整本缓存的文件名主干：书名 + bookUrl 指纹
-- 只用书名时，不同书源的**同名书**会共用同一个 .html/.cbz 文件：
-- 后台缓存 A 书会覆盖 B 书的文件，打开时读到的是另一本书的正文。
-- 指纹用 DJB2（与 chapter_cache 一致），保证同名不同源互不干扰。
local function bookCacheStem(book)

    local url = tostring(book.bookUrl or book.origin or "")

    local h = 5381

    for i = 1, #url do

        h = (h * 33 + url:byte(i)) % 4294967296

    end

    return safeFileName(book.name) .. "_" .. string.format("%08x", h)

end

--- 删除某本书在 BOOK_DIR 下的整本缓存文件（.html / .cbz）
-- 删书时原来只清了章节分片和目录缓存，整本缓存的 html/cbz 会一直留在磁盘上。
-- 同时兼容旧命名（只有书名），避免历史文件变成永久孤儿。
local function removeBookCacheFiles(book)

    local prefixes = {

        bookCacheStem(book) .. "_",

        safeFileName(book.name) .. "_",

    }

    local ok, iter, obj = pcall(lfs.dir, BOOK_DIR)

    if not ok then return 0 end

    local targets = {}

    for name in iter, obj do

        if name:match("%.html$") or name:match("%.cbz$") then

            for _, p in ipairs(prefixes) do

                if name:sub(1, #p) == p then

                    targets[#targets + 1] = BOOK_DIR .. "/" .. name

                    break

                end

            end

        end

    end

    for _, f in ipairs(targets) do pcall(os.remove, f) end

    return #targets

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

-- 丢掉已经排队的重绘请求。热加载/换文档会「先关旧文档、再开新文档」，
-- 中间若有重绘，就会把底下的书架/首页画出来（真机表现为正文翻到本批末尾闪一下书架）。
-- 清掉脏区让墨水屏保持上一页，等新文档 show 时自己重绘。
local function drop_pending_repaint()

    pcall(function()

        UIManager._dirty = {}

        UIManager._refresh_func_stack = {}

    end)

end

-- 热加载同一个文件（追加了新章节后用），要避免把它当成“退出书籍”而中断后台缓存
local function hotReload(ui, path)

    if not ui or not ui.document or ui.document.file ~= path then return end

    SHARED.reloading = true

    -- 加载期间屏蔽触摸，避免连点把这一下算到新文档上
    if Device.input and Device.input.inhibitInputUntil then

        Device.input:inhibitInputUntil(1.0)

    end

    local ok, err = pcall(function()

        -- after_close_callback 在旧文档关掉、新文档加载前执行：在这里清重绘
        ui:reloadDocument(function() drop_pending_repaint() end, true)

    end)

    SHARED.reloading = false

    if not ok then

        logger.warn("xread hot reload failed:", tostring(err))

        -- 失败兜底：保证最终能刷回来，不要停在旧画面
        UIManager:scheduleIn(0.2, function()

            if UIManager._exit_code == nil then UIManager:setDirty("all", "full") end

        end)

    end

end
-- ---------- UI 辅助 ----------

-- 统一提示：默认 4s 自动消失；需要用户读的内容（如连接回执、更新完成）可传更长超时
function XRead:showInfo(text, timeout)

    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })

end

-- 后台同步网络任务是否该让路：首页/书架之上盖了弹层（更多/设置/账号等）时，
-- 同步 HTTP 会卡住 UI 线程，导致弹层里的点击要等十几秒才有反应。
-- 判定方式：栈顶可见 widget 不是首页/书架视图本身，就认为有弹层，后台任务改期。
function XRead:_uiHasOverlay()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    if top == self._home_view or top == self._shelf_view then return false end
    return true
end

-- 同步网络后台任务：弹层打开期间改期再跑（每 1.5s 重试，最多等 60s 就放弃）。
-- 这些请求阻塞 UI 线程，若在弹层里触发，点选项会卡到请求结束才响应。
function XRead:_scheduleNetJob(delay, job, max_wait)
    local waited = 0
    local function attempt()
        -- 后端刚被判定不可达：直接放弃这轮后台请求。
        -- 否则首页心跳/封面重试会每 30s 把 UI 冻结一次，用户只会觉得「整机卡死」。
        if not self:_backendUsable() then return end
        if self:_uiHasOverlay() and waited < (max_wait or 60) then
            waited = waited + 1.5
            UIManager:scheduleIn(1.5, attempt)
            return
        end
        job()
    end
    UIManager:scheduleIn(delay or 0, attempt)
end

-- 统一的后台执行入口：一律静默，只有失败才弹一次错误提示。
-- 不弹「加载中/正在…」模态框——弹窗会吞掉用户点击并触发 Trapper 的
-- Paused 确认框；静默模式下任务期间的点击只是排队，任务结束后立即生效。
-- 验收用高精度时间戳（socket 可用时到毫秒，否则退到秒）
local function autotest_now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return string.format("%.3f", socket.gettime())
    end
    return tostring(os.time())
end

-- 毫秒时间戳：测连接耗时、更新进度节流都用它（socket 不可用时退到秒级）
local function now_ms()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return socket.gettime() * 1000
    end
    return os.time() * 1000
end

-- 把底层异常洗成人话：去掉 client.lua:141: 这类源码位置、URL，
-- 常见网络错误映射成中文；其余保留原文并截断
local function readable_error(msg)
    local s = tostring(msg or "")
    s = s:gsub("[%w_%-%./]+%.lua:%d+:%s*", "")
    s = s:gsub("https?://%S+", _("（服务器地址）"))
    s = s:gsub("%s+", " ")
    local low = s:lower()
    if low:find("endpoint is not connected", 1, true)
            or low:find("connection refused", 1, true)
            or low:find("connect failed", 1, true) then
        return _("无法连接服务器（地址或端口不通）")
    elseif low:find("timed out", 1, true) or low:find("timeout", 1, true) then
        return _("连接超时（服务器无响应）")
    elseif low:find("name or service not known", 1, true)
            or low:find("host not found", 1, true) then
        return _("服务器地址无法解析")
    elseif low:find("network is unreachable", 1, true) then
        return _("网络不可达（检查 Wi-Fi）")
    end
    if #s > 90 then s = s:sub(1, 90) .. "…" end
    return s
end

-- ---------- 后端可用性守卫 ----------
-- 背景：地址填错 / 后端没起时，插件里所有 HTTP 都是 UI 线程上的同步调用。
-- 以前点「我的首页 / 我的书架 / 测试连接 / 更新」会整机冻结十几秒到半分钟，
-- 画面停在原处、点击毫无反应，也**不报任何错**——用户只能以为插件坏了。
--
-- 现在：真要发网络请求之前，先用子进程做一次 2.5s 的 TCP 探活（UI 不冻结），
-- 失败立刻弹一条「连不上哪台机器 + 去地址管理改」的提示，并在 25s 内不再重试，
-- 避免用户每点一次都白等一次超时。探活通过后才在主线程发正式请求。

local BackendProbe = require("xread.backend_probe")

-- 后端不可达后的冷却窗口（秒）
local BACKEND_DOWN_COOLDOWN = 25

--- 当前配置的后端地址（空串表示还没填）
function XRead:backendAddress()
    return tostring(self:getSetting("address", "") or "")
end

--- 把 http://1.2.3.4:7777/ 缩成 1.2.3.4:7777，提示里更短更好认
local function display_address(addr)
    local s = tostring(addr or ""):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^%a[%w+.-]*://", ""):gsub("/+$", "")
    return s ~= "" and s or _("未设置")
end

--- 冷却期内返回上次失败原因，否则 nil
function XRead:_backendDownReason()
    local down = self._backend_down
    if type(down) ~= "table" then return nil end
    if os.time() - (tonumber(down.at) or 0) >= BACKEND_DOWN_COOLDOWN then
        self._backend_down = nil
        return nil
    end
    return tostring(down.reason or "")
end

--- 地址改动 / 手动重试后解除冷却
function XRead:clearBackendDown()
    self._backend_down = nil
end

--- 记录一次后端不可达（后台任务用：静默记录，不弹窗）
function XRead:markBackendDown(reason)
    self._backend_down = { at = os.time(), reason = tostring(reason or "") }
end

--- 统一的后端不可达提示：说清楚「连的是哪台、为什么、去哪改」
function XRead:notifyBackendDown(reason, silent)
    self:markBackendDown(reason)
    local msg = T(_("无法连接后端 %1\n原因：%2\n\n请检查「阅读X → 地址管理」里的地址和端口，\n以及后端服务是否已启动。"),
        display_address(self:backendAddress()), readable_error(reason))
    logger.warn("xread backend unreachable:", self:backendAddress(), tostring(reason))
    if os.getenv("XREAD_AUTOTEST") then
        print("[XREAD_AUTOTEST] backend_down " .. tostring(reason))
    end
    if not silent then
        self:showInfo(msg, 10)
    end
end

--- 探活期间的不遮挡提示（toast，可以继续点击，不是模态框）
function XRead:showConnectingToast(addr)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification and Notification.notify then
        pcall(function()
            Notification:notify(T(_("正在连接 %1…"), display_address(addr)))
        end)
    end
end

--- 网络入口统一守卫：先探活，再执行 fn。
-- @param fn     function() 探活通过后在主线程执行
-- @param opts   { force=忽略冷却, timeout=探活秒数, silent=不显示正在连接 }
-- @return boolean 是否已受理（false = 直接失败并已提示）
function XRead:withBackend(fn, opts)
    opts = opts or {}
    local addr = self:backendAddress()
    if addr == "" or addr:match("^%s*$") then
        self:showInfo(_("还没有设置后端地址。\n请在「阅读X → 地址管理」里填写服务器地址和端口。"), 8)
        return false
    end

    local cooling = self:_backendDownReason()
    if cooling and not opts.force then
        -- 冷却期内直接给结论，不再让用户白等一次超时
        self:notifyBackendDown(cooling)
        return false
    end

    if not opts.silent then self:showConnectingToast(addr) end

    BackendProbe.check(addr, opts.timeout, function(ok, reason)
        if not ok then
            self:notifyBackendDown(reason)
            if type(opts.on_fail) == "function" then
                pcall(opts.on_fail, reason)
            end
            return
        end
        self:clearBackendDown()
        local ok_fn, err = pcall(fn)
        if not ok_fn then
            logger.warn("xread guarded task failed:", tostring(err))
            self:showInfo(_("出错：") .. readable_error(err), 6)
            if type(opts.on_fail) == "function" then
                pcall(opts.on_fail, err)
            end
        end
    end)
    return true
end

--- 后台任务用：后端已知不可达就直接跳过（不弹窗、不卡 UI）
function XRead:_backendUsable()
    return self:_backendDownReason() == nil
end

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

            msg = readable_error(msg)

            self:showInfo(_("出错：") .. msg)

        end

    end)

end
-- ---------- 登录 ----------

function XRead:ensureLogin()

    local user = self:getSetting("username", "")

    local pass = self:getSetting("password", "")

    local address = tostring(self:getSetting("address", "") or "")

    -- token 必须属于「当前地址 + 当前账号」。原来只判 token 非空：
    -- 换后端地址后仍带着旧服务器的 token → 全部接口 401 → 插件看起来"书架为空/目录为空"，
    -- 必须改一次设置或重启才恢复。
    local token_valid = self.client.accessToken ~= nil
        and self._token_addr == address
        and self._token_user == tostring(user)

    if token_valid then return true end

    if self.client.accessToken ~= nil then
        -- 归属不符：作废旧 token，走重新登录
        self.client.accessToken = nil
        self.client.secureKey = nil
        self.client.userNS = nil
    end

    if user == "" or pass == "" then

        self:showInfo(_("请先在菜单中填写后端地址与账号密码"))

        return false

    end

    self.client.address = address

    local ok, err = pcall(function() self.client:login(user, pass) end)

    if not ok then

        self:showInfo(_("登录失败：") .. readable_error(err))

        return false

    end

    self._token_addr = address

    self._token_user = tostring(user)

    return true

end

-- 账号管理/设置页保存后统一同步登录态：
-- 用户名、密码或地址变了就清掉旧 token 并用新账号重登，换账号同时清掉旧书架缓存，
-- 否则首页/地址管理/封面下载/更新检查仍会带着上一个账号的 token 和用户名。
-- defer_login=true 时把 login 推迟到下一个事件循环：saveAndClose 里同步登录
-- （最长 12s）会让「点空白关闭设置页」看起来像假死。
function XRead:_syncCredentials(old_username, old_password, old_address, defer_login)

    local username = tostring(self:getSetting("username", "") or "")

    local password = tostring(self:getSetting("password", "") or "")

    local address = tostring(self:getSetting("address", "") or "")

    local changed = username ~= tostring(old_username or "")

        or password ~= tostring(old_password or "")

        or address ~= tostring(old_address or "")

    if not changed then return end

    self.client.address = address

    self.client.username = username

    self.client.password = password

    self.client.accessToken = nil

    self.client.secureKey = nil

    self.client.userNS = nil

    self._token_addr = nil

    self._token_user = nil

    -- 换账号**或换服务器地址**都要清书架缓存：
    -- 只清用户名的情况，改地址后会继续显示上一个服务器的书架。
    if username ~= tostring(old_username or "") or address ~= tostring(old_address or "") then

        pcall(function() self.meta_cache:clearShelf() end)

    end

    local function doLogin()

        local ok, err = pcall(function() self.client:login(username, password) end)

        if not ok then

            self:showInfo(_("账号已保存，但重新登录失败：") .. readable_error(err))

        else

            self._token_addr = address

            self._token_user = username

        end

    end

    if defer_login then

        -- 先让设置页关掉、界面重绘完，再去登录
        UIManager:scheduleIn(0.3, function() pcall(doLogin) end)

    else

        doLogin()

    end

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

    end

end
-- ---------- 插件实例 ----------

function XRead:init()

    self.settings = LuaSettings:open(SETTINGS_FILE)

    util.makePath(BOOK_DIR)

    -- 第三个参数是延迟 client getter：封面鉴权参数在本地书取图时才需要，
    -- 此时 SHARED.client 已由下面的 init 流程创建并登录。
    self.cover_cache = CoverCache:new(BOOK_DIR .. "/covers",

        self:getSetting("address", "http://192.168.31.51:7777"),

        function() return SHARED.client end)

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

        -- 跳章会重建 ReaderUI（插件 init 会再跑一遍）：验收 flow 只允许执行一次，
        -- 否则 catalog_jump 会无限跳章。生产环境没有该环境变量，不受影响。
        if flow and flow ~= "" and os.getenv("XREAD_AUTOTEST_ONCE") == "1" then

            local flow_flag = "/tmp/xread_flow_once"

            if lfs.attributes(flow_flag, "mode") == "file" then

                flow = nil

            else

                local fh = io.open(flow_flag, "w")

                if fh then fh:write("1"); fh:close() end

            end

        end

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

        elseif flow == "home_btn" then

            -- 验收：正文工具栏「首页」按钮（closeBookToHome），而不是原生文件管理器
            UIManager:scheduleIn(16, function()

                self:closeBookToHome()

                autotest_mark("flow=home_btn done")

            end)

        elseif flow == "update_spam" then

            -- 验收：连点「检查更新」不应叠出多个确认框
            UIManager:scheduleIn(4, function()

                self:showAboutPanel()

                UIManager:scheduleIn(3, function()

                    for k = 1, 4 do

                        UIManager:scheduleIn(k * 0.3, function()

                            self:checkForUpdateInteractive()

                        end)

                    end

                    autotest_mark("flow=update_spam done")

                end)

            end)

        elseif flow == "confirm_native" then

            -- 验收：原生 ConfirmBox 在夜间模式下的背景是否不透字（对照用）
            UIManager:scheduleIn(6, function()

                UIManager:show(ConfirmBox:new{ text = "native confirm background test", ok_text = "OK" })

                autotest_mark("flow=confirm_native done")

            end)

        elseif flow == "reload" then

            -- 验收：热加载（追加章节后 reload）期间不得露出书架/首页
            UIManager:scheduleIn(16, function()

                hotReload(self.ui, SHARED.txt_path)

                autotest_mark("flow=reload done")

            end)

        elseif flow == "catalog_jump" then

            -- 验收：目录点章节（目录保持到新文档就绪）
            UIManager:scheduleIn(4, function()

                self:showReaderCatalog()

                UIManager:scheduleIn(2, function()

                    local book, chapters = SHARED.book, SHARED.chapters

                    local idx = math.min((SHARED.index or 1) + 1,
                        chapters and #chapters or 1)

                    if self._catalog_view then

                        self:jumpToChapterFromCatalog(self._catalog_view, book, chapters, idx)

                    end

                    autotest_mark("flow=catalog_jump done")

                end)

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

    -- 验收脚本可延后几秒再自动进入：启动瞬间进入会被 FileManager 的首帧盖住
    local autotest_delay = tonumber(os.getenv("XREAD_AUTOTEST_DELAY") or "0") or 0

    local function autotest_go(fn)

        if autotest_delay > 0 then

            UIManager:scheduleIn(autotest_delay, fn)

        else

            UIManager:nextTick(fn)

        end

    end

    if autotest == "home" then

        autotest_go(function()

            self:openHome()

            print("[XREAD_AUTOTEST] mode=home done")

        end)

    elseif autotest == "update" then

        -- 在线热更新全流程验收：依赖 XREAD_UPDATER_URL 指向测试更新服务
        -- （列目录挑最新 zip -> 下载 -> 解压增量替换 -> 校验本地版本 -> 退出）

        autotest_go(function()

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

                    .. " skipped=" .. tostring(info.skipped)

                    .. " via=" .. tostring(info.via))

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

    elseif autotest == "localupdate" then

        -- 本地包热更新验收：把规范命名的 zip/tar.gz/tgz 放到插件目录内，
        -- checkLocal 自动发现并安装（不联网）

        autotest_go(function()

            self:runQuiet(function()

                local updater = require("xread/updater"):new{ client = self.client }

                local manifest, info = updater:checkLocal()

                if not manifest then

                    print("[XREAD_AUTOTEST] localupdate: no newer local package")

                    UIManager:quit()

                    return

                end

                print("[XREAD_AUTOTEST] localupdate check: local=" .. tostring(info.local_version)

                    .. " remote=" .. tostring(info.remote_version)

                    .. " newer=" .. tostring(info.newer)

                    .. " via=" .. tostring(info.via))

                local ok_apply, changed, skipped = pcall(function()

                    return updater:applyLocalPackage(manifest, function() end)

                end)

                if not ok_apply then

                    print("[XREAD_AUTOTEST] localupdate apply failed: " .. tostring(changed))

                    UIManager:quit()

                    return

                end

                print("[XREAD_AUTOTEST] localupdate applied: changed=" .. tostring(changed)

                    .. " skipped=" .. tostring(skipped)

                    .. " local_version_now=" .. tostring(updater:getLocalVersion()))

                print("[XREAD_AUTOTEST] mode=localupdate done")

                UIManager:quit()

            end)

        end)

    elseif autotest == "updateui" then

        -- UI 链路验收：检查更新 → 唯一确认框（更新并重启）→ 安装进度 → 自动重启
        -- 前置：插件目录内放一个更高版本的本地包；确认框由测试脚本点击

        autotest_go(function()

            print("[XREAD_AUTOTEST] mode=updateui start")

            self:checkForUpdateInteractive()

        end)

    elseif autotest == "healthui" then

        -- UI 验收：测试连接的成功/失败回执长什么样

        autotest_go(function()

            print("[XREAD_AUTOTEST] mode=healthui start")

            self:testConnection()

        end)

    elseif autotest == "shelfback" then

        -- 验收：首页 → 书架 → 点返回，是否真的回到首页（且首页只有一份）
        autotest_go(function()

            self:runQuiet(function()

                if not self:ensureLogin() then return end

                local books = self.client:getBookshelf()

                if not books or #books == 0 then return end

                self:showHome(1)

                UIManager:scheduleIn(3, function()

                    self:openShelf()

                    UIManager:scheduleIn(4, function()

                        local shelf = SHARED.shelf_view

                        print("[XREAD_AUTOTEST] shelfback: shelf_open="

                            .. tostring(shelf ~= nil and not shelf._miu_closed))

                        if shelf then pcall(function() shelf:_back() end) end

                        UIManager:scheduleIn(3, function()

                            local home = self._home_view

                            print("[XREAD_AUTOTEST] shelfback: home_alive="

                                .. tostring(home ~= nil and not home._miu_closed)

                                .. " shelf_closed=" .. tostring(SHARED.shelf_view == nil))

                            print("[XREAD_AUTOTEST] mode=shelfback done")

                        end)

                    end)

                end)

            end)

        end)

    elseif autotest == "opentime" then

        -- 验收：开书耗时（XREAD_AUTOTEST_ENTRY=home|shelf），用于对比两个入口
        autotest_go(function()

            self:runQuiet(function()

                if not self:ensureLogin() then return end

                local books = self.client:getBookshelf()

                if not books or #books == 0 then return end

                books = BookFilter.filterReadable(books)

                local want = os.getenv("XREAD_AUTOTEST_BOOK")

                local pick = books[1]

                for _i, b in ipairs(books) do

                    if want and want ~= "" and tostring(b.name or ""):find(want, 1, true) then

                        pick = b

                        break

                    end

                end

                local entry = os.getenv("XREAD_AUTOTEST_ENTRY") or "shelf"

                if entry == "home" then

                    self:showHome(1)

                else

                    self:showBookshelf(1, books)

                end

                UIManager:scheduleIn(4, function()

                    print("[XREAD_AUTOTEST] opentime: entry=" .. entry

                        .. " book=" .. tostring(pick.name) .. " t0=" .. autotest_now())

                    self:openBook(pick)

                end)

            end)

        end)

    elseif autotest == "shelf" or autotest == "open" then

        autotest_go(function()

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
-- ---------- 主菜单 ----------

-- ---------- 主菜单 ----------
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

                callback = function() self:testConnection() end,

            },

            {

                text = _("关于本机"),

                callback = function() self:showAboutPanel() end,

            },

        },

    }

end

-- 测试连接：成功回报「地址 + 耗时」，失败回报原因（脱敏截断）
-- 菜单和验收脚本共用这一条路径，避免两处逻辑漂移
function XRead:testConnection()

    local addr = display_address(self:backendAddress())
    local t0 = now_ms()

    -- 先做 2.5s 的可达性探测：地址/端口不通时立刻给结论，
    -- 不再让界面卡在同步 health 请求上等到超时。
    self:withBackend(function()

        local ok, res = pcall(function() return self.client:health({ timeout = 3 }) end)

        local ms = math.floor(now_ms() - t0 + 0.5)

        local good = ok and type(res) == "table" and res.isSuccess ~= false

        if good then

            logger.info("xread health ok", ms, "ms")

            -- 成功也给回执：结论 + 地址 + 耗时，能判断是否连错了机器
            self:showInfo(T(_("连接成功\n%1\n耗时 %2 ms"), addr, tostring(ms)), 6)

            if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] health_ok") end

            return

        end

        local reason
        if not ok then
            reason = tostring(res)
        elseif type(res) == "table" then
            reason = tostring(res.errorMsg or "")
        else
            reason = ""
        end
        if reason == "" then reason = _("后端无响应") end

        reason = readable_error(reason)

        logger.warn("xread health failed:", reason)

        -- 端口通了但服务不健康：也进冷却，避免反复等
        self:markBackendDown(reason)

        self:showInfo(T(_("连接失败\n%1\n耗时 %2 ms\n原因：%3"), addr, tostring(ms), reason), 8)

    end, { force = true, timeout = 2.5 })

end

-- ---------- 主菜单 ----------

function XRead:openShelf()

    -- 书架会盖在首页上面（返回时能瞬间回家）：先停首页心跳，
    -- 否则它每 30s 发一次 health（同步阻塞，最长 3s）会拖慢书架上的点书
    self:_stopHomeTicker()

    -- 缓存优先：本地书架先秒开，网络刷新放到后台，不阻塞界面
    local ttl = tonumber(self:getSetting("shelf_cache_ttl", "300")) or 300

    if os.getenv("XREAD_SHELF_CACHE") == "0" then ttl = 0 end

    local cached = self.meta_cache:getShelf(ttl)

    if cached then

        self:showBookshelf(self._shelf_page or 1, cached)

        -- 节流：缓存仍在 TTL 内时不必每次进书架都打一次全量 getBookshelf。
        -- 反复进出会排队多个同步请求（每个 12s 超时），点书就变慢。
        local last = self._shelf_refresh_at or 0

        if os.time() - last >= 60 then

            self._shelf_refresh_at = os.time()

            self:_refreshShelfInBackground()

        end

        return

    end

    -- 本地没有可用书架缓存：这是唯一必须等网络的路径，
    -- 先探活（2.5s、不冻结 UI），地址不通时直接提示，不再卡到 socket 超时。
    self:withBackend(function()

        self:runQuiet(function()

            if self:ensureLogin() then

                self:showBookshelf()

            else

                -- 书架没打开：把刚停掉的首页心跳放回去，别让首页时钟一直停着
                local home = self._home_view

                if home and not home._miu_closed then self:_startHomeTicker(home) end

            end

        end)

    end)

end

-- 后台静默刷新书架元数据：只写缓存，不重建当前界面（避免点书/翻页时被闪掉）
function XRead:_refreshShelfInBackground()

    -- 错峰：书架刚显示时用户可能马上点书，刷新延后 2s；
    -- 超时由 xread/http_client 统一给（默认 12s），不再动全局 http.TIMEOUT
    self:_scheduleNetJob(2, function()

        if not self.client.accessToken then return end

        -- 已经在开书就别抢网络：开书用的也是同步请求，会互相等
        if self._opening_book or SHARED.open_path then return end

        if self:_uiHasOverlay() then return end

        local ok, books = pcall(function() return self.client:getBookshelf() end)

        if ok and books and #books > 0 then

            self.meta_cache:putShelf(books)

            logger.info("xread shelf refreshed in background")

        end

    end)

end

-- 后台取一本书的章节目录并写缓存（错峰调度用；失败无声，下次再补）。
-- 网络请求放到 fork 子进程里：getChapterList 最长 10s+重试，原来在主线程
-- 同步跑会把「返回首页后点更多/翻页/点书」冻结到请求结束。子进程直接写
-- meta_cache 的磁盘 JSON（父子进程共享文件系统），主线程只需非阻塞轮询回收。
function XRead:_bgFetchChapters(book, delay)

    -- 记下排队时的代次：开书/重建页面会 +1，排队的预取自动作废
    local gen = self._prefetch_generation or 0

    self:_scheduleNetJob(delay, function()

        if (self._prefetch_generation or 0) ~= gen then return end

        if SHARED.open_path or self._opening_book then return end

        if not self.client.accessToken then return end

        -- 弹层正开着（更多/设置/账号等）时再确认一次
        if self:_uiHasOverlay() then return end

        local client, cache = self.client, self.meta_cache
        local b = book

        local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()
            local ok, chapters = pcall(function() return client:getChapterList(b) end)
            if ok and type(chapters) == "table" and #chapters > 0 then
                pcall(function() cache:putChapters(b, chapters) end)
            end
        end, false)

        if not (ok_fork and type(pid) == "number") then
            logger.warn("xread prefetch fork failed:", tostring(pid))
            return
        end

        -- 非阻塞轮询；isSubProcessDone(pid,false) 内部 waitpid(WNOHANG)，
        -- 子进程一退出就顺手回收，不产生僵尸。失败无声，下次再补。
        local function poll()
            if not ffiutil.isSubProcessDone(pid, false) then
                UIManager:scheduleIn(0.3, poll)
                return
            end
            if os.getenv("XREAD_AUTOTEST") then
                print("[XREAD_AUTOTEST] prefetch chapters done")
            end
            logger.info("xread prefetched chapters for", tostring(book.name))
        end
        UIManager:scheduleIn(0.3, poll)

    end)

end

-- 书架/首页显示后预取当前页书籍的章节目录，点书秒开：
-- 最近在读那本立即取；同页其余书籍错峰补（目录缓存过期也刷新）
function XRead:_prefetchRecentChapters(books, visible)

    if os.getenv("XREAD_NO_PREFETCH") == "1" then return end

    -- 新一代预取：上一轮排队中但还没发的请求全部作废（页面已换）
    self._prefetch_generation = (self._prefetch_generation or 0) + 1

    local target

    -- 挑「最近在读」的书预取目录：按最后阅读时间，而不是章节号。
    -- 用章节号会把读到很后面但早已弃掉的书当成优先目标。
    for _, b in ipairs(books) do

        local dur = tonumber(b.durChapterIndex) or 0

        if dur > 0 then

            local bt = tonumber(b.durChapterTime) or 0

            local tt = tonumber(target and target.durChapterTime) or 0

            if not target or bt > tt

                or (bt == tt and dur > (tonumber(target.durChapterIndex) or 0)) then

                target = b

            end

        end

    end

    local ttl = tonumber(self:getSetting("chapter_cache_ttl", "1800")) or 1800

    if target and not self.meta_cache:getChapters(target, ttl) then

        self:_bgFetchChapters(target, 0.5)

    end

    -- 其余可见书籍错峰预取目录（限制数量，避免一次进页面拉太多）
    local n = 0

    for _, b in ipairs(visible or {}) do

        -- 最多补 6 本、间隔 2s：这些请求是同步阻塞的，排太多会和「点书开书」抢线程
        if b ~= target and n < 6 then

            n = n + 1

            if not self.meta_cache:getChapters(b, ttl) then

                self:_bgFetchChapters(b, 1.5 + n * 2)

            end

        end

    end

end

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
function XRead:_refreshHomeIfOpen()

    if self._home_view and not self._home_view._miu_closed then

        self:_stopHomeTicker()

        UIManager:close(self._home_view)

        self._home_view = nil

        pcall(function() self:showHome(self._home_shelf_page or 1) end)

    end

end

-- 最近阅读卡片右上角刷新：只更新 hero 一张卡，不重建整页、不打断心跳/封面循环。
-- 与现有「更新」按钮（整页重建）和 30s 心跳（只刷时间/连接）职责分离；
-- 为避免和后台封面重试的 getBookshelf/putShelf 竞态，刷新期间停掉封面循环，结束再恢复。
function XRead:refreshRecentBook()
    if not MiuiHome.is_shown() then return end
    if self._opening_book or SHARED.open_path then return end

    self:runQuiet(function()
        local ok, books = pcall(function() return self.client:getBookshelf(true) end)
        if not ok or type(books) ~= "table" or #books == 0 then
            UIManager:nextTick(function() self:showInfo(_("刷新最近阅读失败，请检查服务端")) end)
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

            self:showInfo(_("同步失败，请检查服务端"))

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

            -- 每推几本让出一次时间片：50 本串行 POST 时界面不会完全冻结
            if n % 5 == 0 and n < n_local then

                pcall(function()
                    Trapper:info(T(_("正在同步 %1/%2"), tostring(n), tostring(n_local)))
                end)

            end

        end

        -- 同步完拉一次最新书架写回缓存，首页进度与后端一致
        local ok_fresh, fresh = pcall(function() return self.client:getBookshelf() end)

        if ok_fresh and type(fresh) == "table" and #fresh > 0 then

            pcall(function() self.meta_cache:putShelf(fresh) end)

        end

        if failed > 0 then

            self:showInfo(T(_("同步失败 %1 本，请检查服务端"), tostring(failed)))

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

                    UIManager:nextTick(function() self:showInfo(_("更新失败，显示本地缓存书架")) end)

                end

            end)

            end)

        end },

        { icon_key = "search", label = _("搜索"), callback = function() self:searchAndAddBook() end },

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

                self:showInfo(_("首页加载失败：没有拿到书架。\n请检查后端地址、账号密码，或稍后重试。"), 8)

            end

        end, { on_fail = function() self._home_loading = false end })

        if not accepted then self._home_loading = false end

        return

    end

    -- 只展示小说与漫画（过滤视频类条目）

    books = BookFilter.filterReadable(books)

    if not books or #books == 0 then

        self:showInfo(_("首页加载失败：书架为空或获取失败"))

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

    -- hero 不在当前书架页时单独备好封面

    if cover_paths[hero_book] == nil then

        pcall(function() self:prepareCovers({ hero_book }, 1, 1, layout, true) end)

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

        on_local_stats = function() self:showReadingStats() end,

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

    -- 自动检查更新：首页起来后错峰查一次，发现新版才提示（失败无声）
    self:quietUpdateCheck(10)

    -- 看书时攒下的「发现新版本」提示，回到首页再补一次
    if self._update_pending_notice then

        self._update_pending_notice = nil

        UIManager:scheduleIn(1.5, function()

            if self._home_view == view then self:notifyUpdateAvailable() end

        end)

    end

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

                end)

            end

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

    if not ok then

        self:showInfo(_("获取书架失败：") .. tostring(books))

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

            logger.dbg("xread cover fetch", tostring(done), "/", tostring(total))

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

-- 封面异步抓取：网络段（最长 8s）放 fork 子进程里跑，写原始字节到临时文件；
-- 主线程只轮询回收 + 本地解码 + 回调，彻底消除封面下载对 UI 线程的阻塞。
-- @param callback function(path|nil) 完成后回调（一定在主线程）
function XRead:_fetchCoverAsync(book, max_w, max_h, callback)
    local cc = self.cover_cache
    if not cc or not book then
        if callback then callback(nil) end
        return
    end
    -- 已有缓存直接命中，不 fork
    local existing = cc:pathFor(book, max_w, max_h)
    if existing then
        if callback then callback(existing) end
        return
    end
    -- 主线程维护的 inflight 去重：封面队列与重试循环可能同时瞄同一张图
    self._cover_inflight = self._cover_inflight or {}
    local key = cc:keyFor(book, max_w, max_h)
    if self._cover_inflight[key] then
        if callback then callback(nil) end
        return
    end
    self._cover_inflight[key] = true

    local raw = cc:rawTempPath(book, max_w, max_h)
    local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()
        local data = cc:fetchRaw(book, book.coverUrl)
        if data then cc:writeRawFile(book, data, max_w, max_h) end
    end, false)

    if not (ok_fork and type(pid) == "number") then
        self._cover_inflight[key] = nil
        if callback then callback(nil) end
        return
    end

    local function poll()
        if not ffiutil.isSubProcessDone(pid, false) then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self._cover_inflight[key] = nil
        local ok2, p = pcall(function()
            return cc:storeFromRawFile(book, max_w, max_h)
        end)
        if callback then callback(ok2 and p or nil) end
    end
    UIManager:scheduleIn(0.1, poll)
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

            -- 后端不可达时整队放弃，别一张一张撞超时（每张都是同步请求，会冻 UI）
            if not self:_backendUsable() then return end

            -- 弹层开着时封面下载让路，别让同步 HTTP 卡住弹层里的点击
            if self:_uiHasOverlay() then
                UIManager:scheduleIn(1.5, function() nextOne(k) end)
                return
            end

            local item = queue[k]

            -- 网络段进子进程，主线程只做解码 + 局部刷新，不再被单张 8s 冻住
            self:_fetchCoverAsync(item.book, layout.cover_w, layout.cover_h, function(p)

                if self._cover_generation ~= gen or view._miu_closed then return end

                if p and miui_books[item.i] then

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

    local rounds = 0

    local function round()

        if generation ~= self._cover_retry_generation then return end

        if not view or view._miu_closed or view._closed then return end

        -- 后端不可达：整轮跳过（这一轮里全是同步请求，会让首页每轮冻结十几秒）
        if not self:_backendUsable() then
            UIManager:scheduleIn(ttl, round)
            return
        end

        -- 弹层开着时整轮让路（含 getBookshelf 同步请求），1.5s 后重试
        if self:_uiHasOverlay() then
            UIManager:scheduleIn(1.5, round)
            return
        end

        -- 1) 静默刷新书架元数据，拿最新封面地址
        -- refresh=true 会让后端重扫书源，是最重的一次调用：只在首轮和每 12 轮
        -- （默认约 1 小时）做一次；原实现每 5 分钟一次，首页常驻时既压后端又阻塞 UI。
        rounds = rounds + 1

        local want_refresh = (rounds == 1) or (rounds % 12 == 0)

        local books = nil

        pcall(function() books = self.client:getBookshelf(want_refresh) end)

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

                if self:_uiHasOverlay() then
                    UIManager:scheduleIn(1.5, function() nextOne(k, added) end)
                    return
                end

                -- 网络段进子进程，主线程只做解码 + 回调
                self:_fetchCoverAsync(b, layout.cover_w, layout.cover_h, function(p)

                    if p and on_cover then pcall(on_cover, b) end

                    nextOne(k + 1, added + ((p ~= nil) and 1 or 0))

                end)

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

    SHARED.shelf_view = view

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

-- 把「最近在读」的书组装成首页 hero 数据。
-- 封面右侧信息按微信读书样式分行：作者·来源 / 阅读进度·上次时间 / 分类·章数 / 简介
-- 供 showHome 与「刷新最近阅读」局部刷新共用，避免两处格式漂移。
function XRead:_makeHeroInfo(hero_book, cover_paths)
    local hero = self:_toMiuiBooks({ hero_book }, cover_paths)[1]
    hero.subtitle = _("继续阅读")

    local total = tonumber(hero_book.totalChapterNum) or 0
    local dur = tonumber(hero_book.durChapterIndex) or 0
    local read_time = tonumber(hero_book.durChapterTime) or 0

    hero.last_read_text = _("上次读到第 ") .. tostring(dur + 1) .. _(" 章 · 共 ")
        .. tostring(total) .. _(" 章")
    hero.description = tostring(hero_book.intro or "")

    -- 附件1格式：作者 · 书源（originName 作为来源/分类展示）
    local author = tostring(hero_book.author or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local origin = tostring(hero_book.originName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local meta_bits = {}
    if author ~= "" then meta_bits[#meta_bits + 1] = author end
    if origin ~= "" then meta_bits[#meta_bits + 1] = origin end
    hero.meta_line = table.concat(meta_bits, " · ")

    -- 阅读进度行：阅读至 N% · 上次阅读时间（HH:MM 或 M月D日）
    local progress_text = _("阅读至 ") .. tostring(hero.progress or 0) .. "%"
    if read_time > 0 then
        local hour = os.date("%H:%M", read_time)
        local today = os.date("%Y%m%d")
        hero.when_text = os.date("%Y%m%d", read_time) == today
            and _("今天 ") .. hour or os.date("%m月%d日 ", read_time) .. hour
    end
    hero.progress_line = progress_text .. (hero.when_text and (" · " .. hero.when_text) or "")

    -- 底部来源/分类行：微信读书风格「来源 · 共 N 章」
    hero.source_line = _("阅读X") .. (total > 0 and (" · " .. T(_("共 %1 章"), tostring(total))) or "")

    hero.on_tap = function() self:openBook(hero_book) end
    -- 右上角改为「刷新最近阅读」按钮
    hero.on_refresh = function() self:refreshRecentBook() end
    return hero
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
            local shelf = self._shelf_view

            self._shelf_view = nil

            SHARED.shelf_view = nil

            local home = self._home_view

            if home and not home._miu_closed then

                -- 首页还在栈里：关书架后直接唤醒它，瞬间回首页。
                -- 不做 setDirty("all","full")：那会把栈底的文件管理器一起
                -- 标脏并触发整屏刷新，真机上就是「闪一下 KOReader 页面」。
                if shelf and not shelf._miu_closed then

                    pcall(function() UIManager:close(shelf) end)

                end

                pcall(function() self:_startHomeTicker(home) end)

                UIManager:setDirty(home, "ui")

                -- 略后再按最新进度重建一次（静默，读者可能已经翻过章）
                UIManager:scheduleIn(1.2, function()

                    if self._opening_book or SHARED.open_path then return end

                    if self._home_view ~= home or home._miu_closed then return end

                    pcall(function() self:_refreshHomeIfOpen() end)

                end)

            else

                -- 首页已不在栈里：先建好新首页（新页压在书架之上），
                -- 再收掉书架；中间不留 repaint 空档。
                local ok, err = pcall(function() self:showHome(self._home_shelf_page or 1) end)

                if not ok then

                    logger.warn("xread back to home failed:", tostring(err))

                    self:showInfo(_("返回首页失败：") .. readable_error(err))

                elseif shelf and not shelf._miu_closed then

                    pcall(function() UIManager:close(shelf) end)

                end

            end

        end,

        on_close = function()

            self._shelf_view = nil

            -- 书架以任何方式关掉（返回键/开书/系统关闭）后，首页心跳要接回来；
            -- 开书中（_opening_book）由 openBook 自己管，别在这里抢
            if self._opening_book or SHARED.open_path then return end

            local home = self._home_view

            if home and not home._miu_closed then self:_startHomeTicker(home) end

        end,

    }

    self._shelf_view = view

    SHARED.shelf_view = view

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

        -- 不在打开目录前同步下载封面：没有本地缓存的书要先卡 8~16s 才出目录。
        -- 先渲染占位块，目录出来后再在空闲时补一张（下次打开就直接命中）。
        if not cover_path and book.coverUrl and book.coverUrl ~= "" then

            UIManager:scheduleIn(1.5, function()

                if self._opening_book or SHARED.open_path then return end

                if self:_uiHasOverlay() then return end

                -- 网络段进子进程，主线程只做解码
                self:_fetchCoverAsync(book, layout.cover_w, layout.cover_h, nil)

            end)

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

            self:jumpToChapterFromCatalog(view, book, chapters, i)

        end,

        on_back = function()

            UIManager:close(view)

            self._catalog_view = nil

            -- 用户没等跳章完成就返回：撤销「等新文档就绪再关目录」的挂起状态
            if self._switch_overlay == view then self._switch_overlay = nil end

            -- close() 会排队一个局部刷新，forceRePaint 只重绘帧缓冲不触发物理全刷，
            -- 残留的是局部刷新外的旧像素（点一下屏幕才消失）：改为显式全量刷新
            UIManager:setDirty("all", "full")

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
-- 从目录点章节：目录先留着盖住底层书架，等新文档真正就绪（onReaderReady）再关。
-- 之前是「关目录 + 立即全刷 + switchDocument」，中间空档会把书架画出来，
-- 真机表现为点章节先闪一下书架再进正文。
function XRead:jumpToChapterFromCatalog(view, book, chapters, i)

    if self._switch_overlay and self._switch_overlay ~= view then

        pcall(function() UIManager:close(self._switch_overlay) end)

    end

    self._switch_overlay = view

    self._catalog_view = nil

    -- 兜底：新文档一直没就绪（网络失败/文件坏）也不能把目录永久留在屏幕上
    UIManager:scheduleIn(15, function()

        if self._switch_overlay == view then

            self._switch_overlay = nil

            pcall(function() UIManager:close(view) end)

            UIManager:setDirty("all", "full")

        end

    end)

    self:runQuiet(function()

        self:openAtChapter(book, chapters, i)

    end)

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

            -- 同阅读器内目录：目录盖到新文档就绪再关，避免中间空档闪出书架/首页
            self:jumpToChapterFromCatalog(view, book, chapters, i)

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

-- 开书没走成（未登录 / 目录为空）时的收尾：解除开书标记，
-- 并把 openBook 开头为「让路」而停掉的首页定时任务放回去，
-- 否则首页时钟与连接状态会一直停在点书那一刻，封面也不再重试。
function XRead:_cancelOpenBook()

    self._opening_book = false

    local home = self._home_view

    if home and not home._miu_closed then

        self:_startHomeTicker(home)

        self:_startCoverRetryLoop(home, function(b)

            pcall(function() home:updateBook(tostring(b.bookUrl)) end)

        end)

    end

end

function XRead:openBook(book)

    -- 开书优先：先把「抢网络/抢 UI 线程」的后台任务全部停掉，再走网络取章节。
    -- 之前从书架点书慢，就是因为书架显示后还有一串目录预取、封面下载和
    -- health 心跳排队（都是同步阻塞请求），和开书互相等。
    self._opening_book = true

    self._prefetch_generation = (self._prefetch_generation or 0) + 1

    self._cover_generation = (self._cover_generation or 0) + 1

    self:_stopHomeTicker()

    self:_stopCoverRetryLoop()

    -- 8s 兜底复位必须带代次：8s 内又点开第二本书时，
    -- 第一本的定时器会把第二本的守卫提前解除，导致后台任务插队抢网络。
    self._open_generation = (self._open_generation or 0) + 1

    local open_gen = self._open_generation

    UIManager:scheduleIn(8, function()

        if self._open_generation ~= open_gen then return end

        self._opening_book = false

    end)

    -- 记住最后一次打开的书：首页「最近阅读」卡片实时指向它（写进设置，重启后仍生效）
    self._last_open_book_url = tostring((book and book.bookUrl) or "")

    self:saveSetting("last_book_url", self._last_open_book_url)

    -- 目录：优先本地缓存。**过期也先用**——点书时为了目录新章节再等后端
    -- 重新抓一遍目录（几秒）是进书慢的主因；目录刷新改由后台静默补。
    local ttl = tonumber(self:getSetting("chapter_cache_ttl", "1800")) or 1800

    local chapters = self.meta_cache:getChapters(book, ttl)

    local using_stale = false

    if not chapters then

        chapters = self.meta_cache:getChapters(book, nil)

        using_stale = chapters ~= nil

    end

    local start = (tonumber(book.durChapterIndex) or 0) + 1

    if start < 1 then start = 1 end

    if chapters and start > #chapters then start = #chapters end

    -- 这一章正文是否已在本地：决定「点了就能开」还是「必须联网取」
    local cached_first = self.chapter_cache:has(book, start)

    local function proceed()

        self:runQuiet(function()

            if not self:ensureLogin() then

                self:_cancelOpenBook()

                return

            end

            local chs = chapters

            if not chs or #chs == 0 then

                chs = self.client:getChapterList(book)

                if chs and #chs > 0 then self.meta_cache:putChapters(book, chs) end

            elseif using_stale then

                -- 用的旧目录：后台补一次新目录，不挡这次开书
                self:_bgFetchChapters(book, 1)

            end

            if not chs or #chs == 0 then

                self:showInfo(_("目录为空"))

                self:_cancelOpenBook()

                return

            end

            local st = start

            if st < 1 then st = 1 end

            if st > #chs then st = #chs end

            if os.getenv("XREAD_AUTOTEST") == "opentime" then

                print("[XREAD_AUTOTEST] opentime: chapters_ready=" .. autotest_now())

            end

            self:openAtChapter(book, chs, st)

        end)

    end

    if cached_first and chapters then

        -- 本地齐活：不探活、不等网络，直接开
        if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] openbook_quick") end

        proceed()

        return
    end

    -- 需要联网：先 2.5s 探活。地址不通时立刻提示，不再让点书毫无反应地卡半分钟。
    self:withBackend(proceed, {

        on_fail = function() self:_cancelOpenBook() end,

    })

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

        -- 正文没拿到：把等着的目录收掉，别让兜底计时器 15s 后再关
        local overlay = self._switch_overlay

        if overlay then

            self._switch_overlay = nil

            pcall(function() UIManager:close(overlay) end)

        end

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

    local path = BOOK_DIR .. "/" .. bookCacheStem(book) .. "_" .. index .. ".html"

    local f = io.open(path, "w")

    if not f then

        self:showInfo(_("无法写入缓存文件"))

        local overlay = self._switch_overlay

        if overlay then

            self._switch_overlay = nil

            pcall(function() UIManager:close(overlay) end)

        end

        return

    end

    local wrote = f:write(table.concat(parts))

    f:close()

    -- 写入失败（磁盘满/只读）时若不检查返回值，会留下 0 字节文件，
    -- 随后"打开"就是一本空书，而且看起来一切正常。
    if not wrote then

        pcall(os.remove, path)

        self:showInfo(_("写入缓存失败（可能磁盘已满）"))

        local overlay2 = self._switch_overlay

        if overlay2 then

            self._switch_overlay = nil

            pcall(function() UIManager:close(overlay2) end)

        end

        return

    end

    SHARED.book, SHARED.chapters, SHARED.index = book, chapters, index

    SHARED.txt_path, SHARED.txt_size = path, fileSize(path)

    if os.getenv("XREAD_AUTOTEST") == "opentime" then

        print("[XREAD_AUTOTEST] opentime: html_written=" .. autotest_now())

    end

    -- 进度上报异步化：不让它阻塞文档打开（失败也不影响阅读）
    UIManager:scheduleIn(0.5, function()

        pcall(function()

            self.client:saveBookProgress(book, index - 1)

            -- 同步写进书架缓存，首页「最近阅读」立即指向本书的最新进度
            -- 同时记下时间戳：首页排序与进度同步都靠它判断"谁更新"

            pcall(function()

                self.meta_cache:updateShelfProgress(book.bookUrl or book.name, index - 1, os.time())

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

    -- 首页/书架保留在窗口栈里当底衬：ReaderUI 是 covers_fullscreen 的，
    -- 盖上去后它们不会被画出来；反过来若在这里先关掉，KOReader 的
    -- 文件管理器会露出一帧（真机表现为点书闪一下 xread_books 目录）。
    -- 返回首页/书架时会直接复用，也不需要重新取书架。
    -- 取消还在排队的封面下载：让开书前的网络/事件循环不被封面任务占着
    self._cover_generation = (self._cover_generation or 0) + 1
    -- 静默打开：传 seamless 避开 KOReader 的「正在打开文件」提示框
    UIManager:nextTick(function()

        local ReaderUI = require("apps/reader/readerui")

        local tries = 0

        local function doOpen()

            tries = tries + 1

            if self.ui and self.ui.document then

                self._opening_book = false

                -- 同一路径重复打开时 KOReader/crengine 可能认为"文件没变"而不真正重载，
                -- 表现就是点同一本书同一章「没反应」。touch 一下 mtime 强制失效。
                if self.ui.document.file == path then

                    local tf = io.open(path, "a")

                    if tf then tf:close() end

                end

                self.ui:switchDocument(path, true)

                if os.getenv("XREAD_AUTOTEST") == "opentime" then

                    print("[XREAD_AUTOTEST] opentime: reader_shown="

                        .. autotest_now())

                end

                return

            end

            -- 刚从阅读返回时旧 ReaderUI 可能还在拆除中，立即 showReader 会静默失败
            -- （表现为返回后点同一本书没反应、过一会儿才行）：等拆完再开，最多等 2s
            if ReaderUI.instance ~= nil and tries < 20 then

                UIManager:scheduleIn(0.1, doOpen)

                return

            end

            self._opening_book = false

            pcall(function() ReaderUI:showReader(path, nil, true) end)

            if os.getenv("XREAD_AUTOTEST") == "opentime" then

                print("[XREAD_AUTOTEST] opentime: reader_shown="

                    .. autotest_now())

            end

        end

        doOpen()

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

    -- 阅读中后台缓存跑完也不能恢复「文档结束」动作：
    -- 否则读到本批末尾（3 章）时 KOReader 会执行原生结束动作，
    -- 真机表现为连续点下一页突然闪回书架/文件管理器。
    -- 只有真正退出书籍（onCloseDocument / closed book）才恢复。

    if not job then return end

    job.stopped = true

    -- 收掉抓取子进程（若还在跑），并真正回收（waitpid）避免僵尸。
    -- 原来只调 terminateSubProcess 而不再 waitpid：SIGKILL 之后内核不会自动
    -- 回收，defunct 条目会一直挂到 KOReader 退出。
    if job.proc_pid then

        pcall(reapSubProcess, job.proc_pid, true)

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

            if job.on_done then pcall(job.on_done, job) end

            stopBg("done")

            -- 后台缓存完成不再弹窗打扰阅读（目录页高亮已足够提示）

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

        if job.on_done then pcall(job.on_done, job) end

        stopBg("done")

        -- 后台缓存完成不再弹窗打扰阅读（目录页高亮已足够提示）

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

    -- 两件事必须分清，否则用户会以为"缓存"= 下载到本机：
    --   ① 本地已预取到设备的章节数（countCachedAhead，只 stat）
    --   ② 点这个按钮做的是「把整本缓存到服务器」（cacheBookSSE）
    if cached >= remain then return _("本地已全部缓存 · 点按同步整本到服务器") end

    return T(_("本地已缓存 %1/%2 章 · 点按同步整本到服务器"), tostring(cached), tostring(remain))

end

-- 面板里点“缓存后续章节”：从当前章往后补 N 章，进度实时回显在面板上
-- 只做存在性检查（has，一次 stat），不读正文（get 会把整章读进内存）。
-- 这个函数每次打开工具栏、每次缓存进度回调都会跑，原来用 get 时
-- 已缓存 200 章 = 读 200 个文件 + 200 次目录 hash，是工具栏"点一下才出来"的主因。
-- 另加扫描上限：整本都已缓存时不必真的数完 3000 章。
local COUNT_CACHED_MAX_SCAN = 500

function XRead:countCachedAhead(book, chapters, index)

    local n = 0

    if not self.chapter_cache then return 0 end

    local last = math.min(#chapters, index + COUNT_CACHED_MAX_SCAN - 1)

    for i = index, last do

        if self.chapter_cache:has(book, i) then n = n + 1 else break end

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

        -- 工具栏左下格显示「当前章节名」（单行截断），章号由中间位置格承担；
        -- 书名改到第二行标题位显示
        local ch = chapters[index]

        local t = ch and (ch.title or ch.name)

        if t and tostring(t) ~= "" then return tostring(t) end

        return T(_("第 %1 章"), tostring(index))

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

    -- 昵称跟在「首页」按钮后面；第二行标题位显示书名；左下格显示当前章节名。
    -- 昵称兜底与首页一致：设置昵称 > 登录账号 > 「书友」。
    local nickname = tostring(self:getSetting("nickname", "") or "")

    if nickname == "" then nickname = tostring(self:getSetting("username", "") or "") end

    if nickname == "" then nickname = _("书友") end

    local health_text = _("已连接")

    if self._health_ok == false then health_text = _("已断开") end

    local opts = {

        header = {

            home_label = _("首页") .. " " .. nickname,

            title = name,

            time_label = os.date("%H:%M"),

            battery_label = battery_label,

            chapter_label = chapterLabel(),

            location_label = T(_("第 %1 / %2 章"), tostring(index), tostring(total)),

            progress_label = tostring(percent) .. "%",

            wifi_callback = nil,

            sync_label = health_text,

            sync_callback = function() self:syncProgress() end,

            home_callback = function() self:closeBookToHome() end,

            more_callback = function() self:showMorePanel() end,

            book_callback = function() self:showBookCatalog(book) end,

            chapter_callback = function() self:showReaderCatalog() end,

            progress_callback = function() self:showReaderCatalog() end,

        },

        actions = {

            { icon = "toc", label = _("目录"), callback = function() self:showReaderCatalog() end },

            -- 「缓存」= 让后端把整本书缓存到服务器（cacheBookSSE, count=0）；
            -- 长按才换书。本地后续章节的预取仍由开书后的后台任务负责。
            { icon = "cache", label = _("缓存"), value = self:cacheHintText(book, chapters, index),

                callback = function()

                    UIManager:show(ConfirmBox:new{

                        text = T(_("让服务器缓存「%1」全部章节？\n缓存后阅读秒开，失败会提示。"),

                            book.name or ""),

                        ok_text = _("开始缓存"),

                        ok_callback = function() self:doCacheBook(book) end,

                    })

                end,

                hold_callback = function() self:chooseBookToCache() end },

            -- 「下载」= 把整本书导出 EPUB 到 Kindle/KOReader 本地文档目录
            { icon = "download", label = _("下载"), callback = function() self:downloadBookToDevice(book) end },

            -- 正文里的「删除」= 删除当前这本书（后端书架 + 本地缓存）
            { icon = "trash", label = _("删除"), callback = function() self:removeBookFlow(book) end },

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

            -- 夜间开关与首页一致：月亮=当前日间（点击进夜间），太阳=当前夜间（点击回日间）
            { icon = (function()

                local ok_n, Scr = pcall(function() return require("device").screen end)

                return (ok_n and Scr and Scr.night_mode) and "sun" or "night"

            end)(), label = _("夜间"), callback = function() self:toggleNightMode() end },

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

    -- 打开后只回显已知连接状态，不在 UI 线程重新探测。
    -- 原来这里每呼出一次工具栏就同步打 2 个请求（各 3s 超时，最坏阻塞 6s），
    -- 表现就是「点正文中央，工具栏好几秒才响应」。状态由首页心跳维护（60s 一次），
    -- 只有从未探测过（nil）时才在后台补一次。
    UIManager:scheduleIn(0.5, function()

        if not panel or panel.closed then return end

        local healthy = self._health_ok

        if healthy == nil then

            local ok_h, res = pcall(function() return self.client:health() end)

            healthy = ok_h and res and res.isSuccess ~= false

            self._health_ok = healthy

        end

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

            -- 节流：缓存进度每完成一章就回调一次，逐章都整块重排 + 区域重绘
            -- 会让工具栏在后台缓存期间反复闪。1s 内只刷一次足够。
            local now = os.time()

            if panel._hint_last_t == now then return end

            panel._hint_last_t = now

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

    -- 后台扫描正文 "== 章节标题 ==" 注入 TOC，章节名随翻页自动更新
    self:_injectTocFromText()

    -- 跳章/换文档（switchDocument）会重建阅读器触摸分区，插件注册的 xread_tap_* 丢失：
    -- 必须在文档就绪后重新注册，否则跳章后点正文中央无法呼出工具栏、回不了书架。
    -- onReaderReady 在文档加载完成后触发，是补注册的正确时机。
    self:setupCenterTap()

    -- 目录跳章：目录一直盖在正文上，等新文档就绪才收起来。
    -- 这样「关目录 → switchDocument 关旧文档」的中间空档不会露出底层书架。
    local overlay = self._switch_overlay

    if overlay then

        self._switch_overlay = nil

        pcall(function() UIManager:close(overlay) end)

    end

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

        if footer.updateFooterContainer then footer:updateFooterContainer() end

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
        -- 让 ReaderView 重新为底栏分配显示空间
        if footer.applyFooterMode and footer.mode_list.page_progress then

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

                self:showInfo(_("已到本书最后。可从工具栏切换章节或返回书架"))

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

    -- 只认领阅读X打开的书（正文文件都在 BOOK_DIR 下）；非 xread 书不拦截
    if not SHARED.book or not doc.file:find(BOOK_DIR, 1, true) then return false end

    -- 自愈：跳章/重开等瞬间 txt_path 可能短暂错位，直接认领并修复，
    -- 绝不把点击泄漏给 KOReader 原生菜单/设置面板（表现为正文里弹出双栏/屏幕方向设置）
    if SHARED.txt_path ~= doc.file then

        SHARED.txt_path, SHARED.txt_size = doc.file, fileSize(doc.file)

    end

    if act == 0 then

        self:showQuickPanel()

        return true

    end

    local pager = self.ui.paging or self.ui.rolling

    if pager and pager.onGotoViewRel then

        pager:onGotoViewRel(act)

    end

    -- 无论翻页是否成功都吞掉事件，防止落回原生 readerconfigmenu/readermenu 分区
    return true

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

    -- 连续点开（更多/搜索结果等）时先关掉上一个，避免弹层叠住“无法取消”
    if self._more_panel_view then

        pcall(function() UIManager:close(self._more_panel_view) end)

        self._more_panel_view = nil

    end

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
        self.text_widget = tw   -- 供异步结果就地改文字（如后端版本）
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
    local rows_map = {}
    for idx, item in ipairs(items) do
        local row = MoreRow:new{
            text = item.label,
            width = inner_w, height = row_h,
            callback = function()
                -- callback 为空的行是纯信息展示（如版本号），点击无动作
                if item.callback then
                    UIManager:close(dialog)
                    if self._more_panel_view == dialog then self._more_panel_view = nil end
                    item.callback()
                end
                return true
            end,
        }
        rows[#rows + 1] = row
        if item.key then rows_map[item.key] = row end
        if idx < #items then
            rows[#rows + 1] = HorizontalSpan:new{ width = gap }
        end
    end

    local card = VerticalGroup:new{ align = "left" }

    -- 标题行右侧统一放「✕」关闭按钮（右上角），与账号/地址/书籍设置面板一致
    local title_tw = TextWidget:new{
        text = title, face = face_title, bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local close_w = Screen:scaleBySize(44)
    local title_stretch = inner_w - title_tw:getSize().w - close_w
    if title_stretch < 0 then title_stretch = 0 end
    card[#card + 1] = HorizontalGroup:new{ align = "center",
        title_tw, HorizontalSpan:new{ width = title_stretch },
        UICommon.closeButtonAtEdge(function()
            if dialog then UIManager:close(dialog) end
            if self._more_panel_view == dialog then self._more_panel_view = nil end
            UIManager:setDirty("all", "full")
        end, pad, close_w) }
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
        if self._owner and self._owner._more_panel_view == dialog then self._owner._more_panel_view = nil end
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        return true
    end

    function Overlay:onClose()
        UIManager:close(dialog)
        if self._owner and self._owner._more_panel_view == dialog then self._owner._more_panel_view = nil end
        UIManager:setDirty("all", "full")
        return true
    end

    function Overlay:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
        self[1]:paintTo(bb, x, y)
    end

    dialog = Overlay:new{}

    dialog._owner = self

    self._more_panel_view = dialog

    UIManager:show(dialog)

    if opts and type(opts.on_rows_built) == "function" then
        pcall(opts.on_rows_built, rows_map)
    end

end

function XRead:showMorePanel()

    self:showMoreListPanel(_("更多"), {
        { label = _("我的书架"), callback = function() self:openShelf() end },
        { label = _("地址管理"), callback = function() self:showServerManage() end },
        { label = _("账号管理"), callback = function() self:showAccountManage() end },
        { label = _("翻页管理"), callback = function() self:showPageManage() end },
        { label = _("关于本机"), callback = function() self:showAboutPanel() end },
    }, { hint = _("点击条目进入；点空白处返回。") })

end

-- ---------- 在线热更新 ----------

-- 自动检查发现新版本时的提示（同一版本只提示一次，由 _update_notified 去重）
-- 只做通知不做确认：安装入口仍是「更多 → 关于本机 → 检查更新」，那里只有一个确认框
function XRead:notifyUpdateAvailable()

    local info = self._update_info

    if not info or not info.newer then return end

    self:showInfo(_("发现可用新版本，请检查更新"), 6)

end

-- 书架/首页显示后错峰静默检查新版本（失败完全无声，仅首次发现时提示一次）
function XRead:quietUpdateCheck(delay)

    if os.getenv("XREAD_NO_UPDATER") == "1" then return end

    -- 一次会话只查一次：首页会反复重建，别每次都发一遍列目录请求
    if self._update_checked then return end

    self._update_checked = true

    UIManager:scheduleIn(delay or 10, function()

        Trapper:wrap(function()

            local ok, updater = pcall(function()
                return require("xread/updater"):new{ client = self.client }
            end)

            if not ok then Trapper:clear() return end

            local ok_check, manifest, info = pcall(function() return self:checkUpdateBest(updater) end)

            Trapper:clear()

            if not ok_check or not manifest or not info then

                -- 静默失败，但留下可查的痕迹（离线/没登录是常态，不打扰用户）
                logger.warn("xread quiet update check failed:", tostring(ok_check and "no manifest" or manifest))

                return

            end

            if info.newer and self._update_notified ~= info.remote_version then

                self._update_notified = info.remote_version

                self._update_manifest = manifest

                self._update_info = info

                logger.info("xread update available",
                    tostring(info.local_version), "->", tostring(info.remote_version))

                -- 正在看书就先攒着，回首页再提示，避免糊在正文上
                if SHARED.open_path or self._opening_book then

                    self._update_pending_notice = true

                else

                    UIManager:nextTick(function() self:notifyUpdateAvailable() end)

                end

            end

        end)

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

    -- 后台补后端版本：拿到后就地改那一行文字
    if not self:_backendUsable() then return end

    self:_scheduleNetJob(0.2, function()

        local v = self.client:getServerVersion()

        if not v then return end

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

    local ok_r, rmanifest, rinfo = pcall(function() return updater:check() end)

    if ok_r and rmanifest then

        return rmanifest, rinfo

    end

    local ok_l, lmanifest, linfo = pcall(function() return updater:checkLocal() end)

    if ok_l and lmanifest then

        return lmanifest, linfo

    end

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

    local notes = manifest.notes or ""

    if #notes > 300 then notes = notes:sub(1, 300) .. "…" end

    if notes ~= "" then notes = "\n\n更新内容：" .. notes end

    -- 本地包直接安装；远端包下载整包后文件级差异在下载后判定
    local src_line = info.via == "local" and "\n（本地更新包，无需联网）" or ""

    -- 唯一确认框：更新 + 重启合并成一次询问，装完不再二次确认
    local body = T(_("新版本 %1 已就绪，请尽快更新%2%3\n\n点「更新并重启」后立即安装，装完自动重启 KOReader 生效。"),
        tostring(info.remote_version), src_line, notes)

    local owner = self

    local box

    box = ConfirmBox:new{

        text = body,

        ok_text = _("更新并重启"),

        cancel_text = _("取消"),

        -- 不再允许点空白随手关掉：那一下只刷半个屏幕，旧框会留在墨水屏上
        dismissable = false,

        ok_callback = function()

            if owner._update_confirm_box == box then owner._update_confirm_box = nil end

            self:applyUpdateFlow(manifest)

        end,

        cancel_callback = function()

            if owner._update_confirm_box == box then owner._update_confirm_box = nil end

        end,

    }

    -- 确认框关掉时强制整屏重刷一次，清掉叠层留下的残影
    local base_on_close = box.onCloseWidget

    box.onCloseWidget = function(w)

        if base_on_close then base_on_close(w) end

        if owner._update_confirm_box == w then owner._update_confirm_box = nil end

        UIManager:setDirty("all", "full")

    end

    self._update_confirm_box = box

    if os.getenv("XREAD_AUTOTEST") then

        print("[XREAD_AUTOTEST] update_confirm_shown")

    end

    UIManager:show(box)

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
        local changed = addr ~= self.client.address
        if changed then
            self.client.address = addr
            self.client.accessToken = nil   -- 换地址后需重登
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
    local close_w = Screen:scaleBySize(44)
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
    local close_w = Screen:scaleBySize(44)
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
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_GRAY_E)
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
                    if fail_n > 0 then self:showInfo(T(_("删除失败 %1 本"), fail_n)) end
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
        local old_username = self:getSetting("username", "")
        local old_password = self:getSetting("password", "")
        local old_address = self:getSetting("address", "")
        self:saveSetting("address", draft.address)
        self:saveSetting("username", draft.username)
        self:saveSetting("password", draft.password)
        self:saveSetting("nickname", draft.nickname)
        self:saveSetting("max_chapters", tostring(draft.max_chapters))
        -- 地址/账号/密码任一变更：清旧 token、按新账号重登、换账号清旧书架缓存
        -- 延迟登录：让设置页/账号页先关掉，再在后台走登录（最长 12s，不能卡住关闭动作）
        self:_syncCredentials(old_username, old_password, old_address, true)
    end

    local function saveAndClose()
        saveDraft()
        self._settings_draft = nil
        if dialog then UIManager:close(dialog) end
        self:_refreshHomeIfOpen()   -- 昵称改动实时反映到首页
        UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
    end

    local function refreshDialog()
        if dialog then UIManager:close(dialog) end
        UIManager:setDirty("all", "ui")
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
        -- 就地更新数值，不重建整个对话框。
        -- 原来每次按 ± 都 close + 整屏深刷 + 重建，e-ink 上按一下闪一下。
        local function bump(delta)
            draft.max_chapters = math.max(1, math.min(200,
                (tonumber(draft.max_chapters) or 3) + delta))
            if value_widget and value_widget.setText then
                pcall(function()
                    value_widget:setText(tostring(draft.max_chapters))
                    value_widget:getSize()          -- free() 后重算尺寸
                    UIManager:setDirty(dialog or "all", "ui")
                end)
            else
                refreshDialog()
            end
        end
        local minus = Button:new{
            text = "－",
            text_font_face = "cfont", text_font_size = 20,
            bordersize = 1, radius = 6,
            width = Screen:scaleBySize(72),
            callback = function() bump(-1) end,
        }
        local plus = Button:new{
            text = "＋",
            text_font_face = "cfont", text_font_size = 20,
            bordersize = 1, radius = 6,
            width = Screen:scaleBySize(72),
            callback = function() bump(1) end,
        }
        value_widget = TextWidget:new{
            text = tostring(draft.max_chapters),
            face = face_row, bold = true,
        }
        local label = TextWidget:new{
            text = _("默认缓存章数"),
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
        fieldRow(_("账号"), "username", false, _("账号"), ""),
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

    -- 防重叠：已有面板开着先关掉（选字体/字号后会重建面板）
    if self._book_settings_dialog then

        pcall(function() UIManager:close(self._book_settings_dialog) end)

        self._book_settings_dialog = nil

    end

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
        UIManager:setDirty("all", "ui")
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

    -- 行1：默认缓存章数（进书时先拼这么多章立即打开）
    local chapter_row = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - 220, h = row_h },
            labelRow(_("默认缓存章数")) },
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

    -- 下拉框按钮：右侧显示当前值 + ▾，点击弹出选择列表
    local function dropdownBtn(shown_text, on_open)
        local btn = InputContainer:extend{}
        function btn:init()
            self.dimen = Geom:new{ w = Screen:scaleBySize(210), h = row_h }
            self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
            self[1] = TextWidget:new{
                text = tostring(shown_text) .. " ▾", face = face_row, bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = Screen:scaleBySize(200),
            }
        end
        function btn:onTap() on_open(); return true end
        return btn:new{}
    end

    local function pickFromList(title, items)
        local entries = {}
        for _, it in ipairs(items) do
            entries[#entries + 1] = {
                label = (it.current and "● " or "○ ") .. tostring(it.label),
                callback = function()
                    it.on_pick()
                    UIManager:setDirty("all", "ui")
                    self:showBookSettingsPanel()   -- 重建面板回显新值
                end,
            }
        end
        self:showMoreListPanel(title, entries, { hint = _("点击选择；点空白处返回。") })
    end

    local function currentFontFace()
        local v = nil
        pcall(function() v = self.ui and self.ui.font and self.ui.font.font_face end)
        return tostring(v or "")
    end

    -- 行2：设置字体（下拉选择正文字体，即选即生效）
    local font_face_row = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - 220, h = row_h },
            labelRow(_("设置字体")) },
        dropdownBtn(currentFontFace() ~= "" and currentFontFace() or _("系统默认"), function()
            local items = {}
            local ok_f, faces = pcall(function()
                -- engineInit 返回 cre 库本体；字体列表是库级函数，必须点号调用
                -- （readerfont.lua 同款用法）；冒号调用传错参数会拿不到列表
                local cre = require("document/credocument"):engineInit()
                return cre and cre.getFontFaces()
            end)
            local cur = currentFontFace()
            if ok_f and type(faces) == "table" then
                for _, f in ipairs(faces) do
                    items[#items + 1] = {
                        label = tostring(f),
                        current = tostring(f) == cur,
                        on_pick = function()
                            pcall(function()
                                local fo = self.ui and self.ui.font
                                if fo then
                                    fo.font_face = tostring(f)
                                    self.ui.document:setFontFace(tostring(f))
                                    local Event = require("ui/event")
                                    self.ui:handleEvent(Event:new("UpdatePos"))
                                end
                            end)
                        end,
                    }
                end
            end
            if #items == 0 then
                items[#items + 1] = { label = _("无法获取字体列表"), on_pick = function() end }
            end
            pickFromList(_("设置字体"), items)
        end),
    }

    -- 行3：提高字体（下拉选择字号，即选即生效）
    local font_size_row = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - 220, h = row_h },
            labelRow(_("提高字体")) },
        dropdownBtn((currentFontSize()) .. "px", function()
            local items = {}
            local cur = tonumber(currentFontSize()) or 22
            for _, s in ipairs({16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38}) do
                items[#items + 1] = {
                    label = tostring(s),
                    current = s == cur,
                    on_pick = function()
                        pcall(function()
                            local fo = self.ui and self.ui.font
                            if fo then
                                fo.configurable.font_size = s
                                self.ui.document:setFontSize(Screen:scaleBySize(s))
                                local Event = require("ui/event")
                                self.ui:handleEvent(Event:new("UpdatePos"))
                            end
                        end)
                    end,
                }
            end
            pickFromList(_("提高字体"), items)
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
    rows[#rows + 1] = font_face_row
    rows[#rows + 1] = HorizontalSpan:new{ width = gap }
    rows[#rows + 1] = font_size_row
    rows[#rows + 1] = HorizontalSpan:new{ width = gap }
    rows[#rows + 1] = TextWidget:new{
        text = _("字体与字号即选即生效；预加载越多开书越快，但占用存储也越多"),
        face = face_hint, width = inner_w, fgcolor = Blitbuffer.COLOR_GRAY,
    }

    local card = VerticalGroup:new{ align = "left" }

    -- 标题行右侧加「✕」：点击分区（上/中/下 1/3）会抢走全屏 tap，
    -- 点空白关闭收不到手势，必须有可见的关闭按钮（与地址/账号管理一致）
    local title_tw = TextWidget:new{
        text = _("书籍设置"), face = face_title, bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local close_w = Screen:scaleBySize(44)
    local stretch = inner_w - title_tw:getSize().w - close_w
    if stretch < 0 then stretch = 0 end
    card[#card + 1] = HorizontalGroup:new{ align = "center",
        title_tw, HorizontalSpan:new{ width = stretch },
        UICommon.closeButtonAtEdge(closePanel, pad, close_w) }
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

    self._book_settings_dialog = dialog

    UIManager:show(dialog)

end

-- ---------- 移除书籍（从后端书架删除） ----------

-- 真正执行删除：后端 deleteBook + 本地章节/目录缓存清理 + 刷新书架缓存
function XRead:_confirmRemoveBook(book)

    UIManager:show(ConfirmBox:new{

        text = T(_("移除「%1」？\n将从服务器书架删除这本书（含服务器缓存与本地章节缓存）。"), book.name or ""),

        ok_text = _("移除"),

        ok_callback = function()

            self:runQuiet(function()

                local del_ok = self.client:deleteBook(book)

                if del_ok then

                    -- 清本地：章节分片目录 + 目录缓存 + 整本缓存文件 + 封面缓存
                    pcall(function()

                        local util = require("util")

                        local dir = self.chapter_cache:dirFor(book)

                        if lfs.attributes(dir, "mode") == "directory" then util.purgeDir(dir) end

                        local meta_path = self.meta_cache:chaptersPath(book)

                        if meta_path and lfs.attributes(meta_path, "mode") == "file" then os.remove(meta_path) end

                        removeBookCacheFiles(book)

                        if self.cover_cache and self.cover_cache.removeBook then
                            self.cover_cache:removeBook(book)
                        end

                    end)

                    -- 刷新书架缓存（移除后重新拉取）
                    pcall(function()

                        local fresh = self.client:getBookshelf()

                        if type(fresh) == "table" then self.meta_cache:putShelf(fresh) end

                    end)

                else

                    self:showInfo(_("移除失败"))

                end

            end)

        end,

    })

end

-- 正文「下载」：把整本书导出为 EPUB 到 Kindle/KOReader 本地文档目录。
-- 后端无整本下载接口，按目录逐章 getBookContent；优先用本地章节缓存， networked 拉取带重试。
function XRead:downloadBookToDevice(book)
    if not book then
        self:showInfo(_("没有可下载的书"))
        return
    end

    local dir
    pcall(function() dir = BookExport:exportDir() end)
    local target = _("本地文档目录") .. "（" .. tostring(dir or "?") .. "）"
    UIManager:show(ConfirmBox:new{
        text = T(_("把「%1」导出为 EPUB 保存到 %2？\n导出后可在 KOReader 文件管理器（xread 文件夹）或 Kindle 书架直接打开，需要逐章拉取，章节较多时请耐心等待。"),
            tostring(book.name or ""), target),
        ok_text = _("下载"),
        cancel_text = _("取消"),
        ok_callback = function() self:_doDownloadBook(book) end,
    })
end

function XRead:_doDownloadBook(book)

    -- 导出的网络 + 打包全部在 fork 出的子进程里做，主进程只轮询进度文件。
    -- 原实现逐章同步请求跑在 UI 线程（每章一个 12s 超时），几千章要跑很久，
    -- 期间界面完全无响应；失败章节还被写成「（本章获取失败）」后仍提示"下载完成"。
    Trapper:wrap(function()

        -- 取目录这一次请求仍在 UI 线程（本地缓存命中时是 0 网络），
        -- 先给个提示，避免用户以为点了没反应
        Trapper:info(_("正在准备目录…"))

        local ok_chapters, chapters = pcall(function()
            local cached = self.meta_cache:getChapters(book)
            if type(cached) == "table" and #cached > 0 then return cached end
            return self.client:getChapterList(book)
        end)
        if not ok_chapters or type(chapters) ~= "table" or #chapters == 0 then
            Trapper:clear()
            self:showInfo(_("下载失败：无法获取目录"))
            return
        end

        local total = #chapters
        local stem = bookCacheStem(book)
        local prog_file = BOOK_DIR .. "/" .. stem .. ".exportprog"
        local res_file = BOOK_DIR .. "/" .. stem .. ".exportres"
        pcall(os.remove, prog_file)
        pcall(os.remove, res_file)

        local client, cache = self.client, self.chapter_cache

        local function writeProg(done, state)
            local f = io.open(prog_file .. ".tmp", "w")
            if not f then return end
            f:write(string.format("done=%d total=%d state=%s", done, total, state))
            f:close()
            pcall(os.rename, prog_file .. ".tmp", prog_file)
        end

        local function writeResult(tag, payload)
            local f = io.open(res_file .. ".tmp", "w")
            if not f then return end
            f:write(tostring(tag) .. "\n" .. tostring(payload or "") .. "\n")
            f:close()
            pcall(os.rename, res_file .. ".tmp", res_file)
        end

        writeProg(0, "run")

        local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()

            local function getContent(i, ch)
                local cached = cache:get(book, i)
                if cached and cached ~= "" then return cached end
                local ok, text = pcall(function() return client:getBookContent(ch, book) end)
                if ok and type(text) == "string" and text ~= "" then
                    pcall(function() cache:put(book, i, text) end)
                    return text
                end
                return nil       -- nil = 该章失败，由 book_export 统计并计入门槛
            end

            -- 多返回值用表接：createEpub -> path, err, stats
            local r = { pcall(BookExport.createEpub, BookExport, book, chapters, getContent,
                function(done) writeProg(done, "run") end) }

            if r[1] and r[2] then
                writeResult("ok", r[2])
            elseif r[1] then
                writeResult("err", r[3])
            else
                writeResult("err", r[2])
            end

            writeProg(total, "end")

        end, false)

        if not (ok_fork and pid) then
            logger.warn("xread export fork failed:", tostring(pid))
            Trapper:clear()
            pcall(os.remove, prog_file)
            self:showInfo(_("下载失败：当前环境不支持后台任务"))
            return
        end

        -- 轮询进度：Trapper:info 每次让出 100ms 让 UI 能刷新/响应；
        -- 按秒节流，避免 e-ink 被高频重绘。
        local deadline = os.time() + math.max(180, total * 30)
        local last_done, last_t = -1, 0
        local user_aborted = false
        while os.time() < deadline do
            local text = ""
            local pf = io.open(prog_file, "r")
            if pf then
                text = pf:read("*a") or ""
                pf:close()
            end
            local state = text:match("state=(%w+)")
            local done = tonumber(text:match("done=(%d+)")) or 0
            if state == "end" then break end
            local now = os.time()
            local go_on
            if done ~= last_done and (now - last_t >= 1 or done >= total) then
                last_done, last_t = done, now
                go_on = Trapper:info(T(_("正在下载 %1%（%2/%3）"),
                    tostring(math.floor(done / total * 100)), tostring(done), tostring(total)))
            else
                go_on = Trapper:info(nil)      -- 保持提示，仅让出一次时间片
            end
            -- 用户点了提示框的「中止」：不再等下去（子进程会自己跑完，不阻塞界面）
            if go_on == false then
                user_aborted = true
                break
            end
        end

        Trapper:clear()

        -- 轮询已结束：回收子进程。中止或超时时先杀掉，否则它会在后台把整本书
        -- 继续写完（界面提示「已取消」但导出文件照样生成）。
        reapSubProcess(pid, user_aborted or os.time() >= deadline)

        if user_aborted then
            -- 用户主动中止：子进程可能还在写，清掉进度文件，不要误报「下载失败」
            pcall(os.remove, prog_file)
            pcall(os.remove, res_file)
            self:showInfo(_("已取消下载"))
            return
        end

        local tag, payload = "err", _("子进程未返回结果")
        local rf = io.open(res_file, "r")
        if rf then
            local all = rf:read("*a") or ""
            rf:close()
            tag = all:match("^(%a+)") or "err"
            payload = all:match("^%a+\n(.-)\n*$") or ""
        end
        pcall(os.remove, prog_file)
        pcall(os.remove, res_file)

        if tag ~= "ok" or payload == "" then
            self:showInfo(_("下载失败：") .. tostring(payload))
            return
        end

        local size = fileSize(payload)
        self:showInfo(T(_("下载完成\n%1\n共 %2 章 · %3\n可在 KOReader 文件管理器打开"),
            tostring(payload), tostring(total), tostring(size) .. " B"), 8)

    end)

end

-- 正文里的「删除」直接删当前书；没有传入书时才列书单供选择
function XRead:removeBookFlow(book)

    if book then

        self:_confirmRemoveBook(book)

        return

    end

    local ok, books = pcall(function() return self.client:getBookshelf() end)

    if not ok or type(books) ~= "table" or #books == 0 then

        self:showInfo(_("书架为空或获取失败"))

        return

    end

    local items = {}

    for _i, b in ipairs(books) do

        items[#items + 1] = {

            text = (b.name or "?") .. "　" .. (b.author or ""),

            callback = function() self:_confirmRemoveBook(b) end,

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

    -- 整本缓存是一条 SSE 长连接，几千章要跑几分钟。原来在 UI 线程同步跑，
    -- 这段时间界面完全无响应、无进度、不可取消，用户只能强杀 KOReader。
    -- 改成：子进程消费 SSE 并写进度文件，主进程轮询显示进度（网络不再占 UI 线程）。
    Trapper:wrap(function()

        local opts = {

            count = tonumber(count) or 0,   -- 0 = 全部章节

            concurrentCount = 8,

            refresh = 0,

        }

        local stem = bookCacheStem(book)

        local prog_file = BOOK_DIR .. "/" .. stem .. ".sseprog"

        local err_file = prog_file .. ".err"

        pcall(os.remove, prog_file)

        pcall(os.remove, err_file)

        local client = self.client

        local function writeProg(info, done)

            local f = io.open(prog_file .. ".tmp", "w")

            if not f then return end

            f:write(string.format("cached=%d ok=%d fail=%d state=%s",

                info.cachedCount or 0, info.successCount or 0, info.failedCount or 0,

                done and "end" or "run"))

            f:close()

            pcall(os.rename, prog_file .. ".tmp", prog_file)

        end

        writeProg({}, false)

        local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()

            local last = {}

            local ok_req, req_err = pcall(function()

                client:cacheBookSSE(book, opts, function(info)

                    last = info

                    if info.isEnd then

                        logger.info("xread cache book done", tostring(info.cachedCount),

                            tostring(info.successCount), tostring(info.failedCount))

                    end

                    writeProg(info, info.isEnd)

                end)

            end)

            if not ok_req then

                local f = io.open(err_file, "w")

                if f then

                    f:write(tostring(req_err))

                    f:close()

                end

            end

            writeProg(last, true)

        end, false)

        if not (ok_fork and pid) then

            Trapper:clear()

            pcall(os.remove, prog_file)

            self:showInfo(_("缓存失败：当前环境不支持后台任务"))

            return

        end

        -- 主进程只轮询进度，不持有任何网络连接
        local deadline = os.time() + 3 * 3600

        local last_cached, last_t = -1, 0

        local user_aborted = false

        while os.time() < deadline do

            local text = ""

            local pf = io.open(prog_file, "r")

            if pf then

                text = pf:read("*a") or ""

                pf:close()

            end

            local state = text:match("state=(%w+)")

            local cached = tonumber(text:match("cached=(%d+)")) or 0

            if state == "end" then break end

            local now = os.time()

            local go_on

            if cached ~= last_cached and now - last_t >= 1 then

                last_cached, last_t = cached, now

                go_on = Trapper:info(T(_("正在缓存到服务器：已处理 %1 章"), tostring(cached)))

            else

                go_on = Trapper:info(nil)

            end

            -- 用户点了「中止」：不再等（子进程自己会结束，不阻塞界面）
            if go_on == false then

                user_aborted = true

                break

            end

        end

        Trapper:clear()

        -- 轮询已结束：回收子进程。中止或超时时先杀掉，否则它还会在后台
        -- 按 SSE 继续把整本缓存完（可达数小时），用户却以为已经取消了。
        reapSubProcess(pid, user_aborted or os.time() >= deadline)

        if user_aborted then

            pcall(os.remove, prog_file)

            pcall(os.remove, err_file)

            self:showInfo(_("已取消缓存"))

            return

        end

        local err_text

        local ef = io.open(err_file, "r")

        if ef then

            err_text = ef:read("*a")

            ef:close()

        end

        pcall(os.remove, prog_file)

        pcall(os.remove, err_file)

        if err_text and err_text ~= "" then

            self:showInfo(_("缓存失败：") .. readable_error(err_text))

        end

    end)

end
-- ---------- 漫画：下载图片 -> 打包 CBZ -> 打开 ----------

function XRead:downloadComicAndOpen(book, chapters, start_index)

    local Archiver = require("ffi/archiver")

    local batch = tonumber(self:getSetting("comic_chapters", "5")) or 5

    if batch < 1 then batch = 1 end

    local last = math.min(start_index + batch - 1, #chapters)

    local path = BOOK_DIR .. "/" .. bookCacheStem(book) .. "_" .. start_index .. ".cbz"

    local arc = Archiver.Writer:new{}

    if not arc:open(path, "zip") then

        self:showInfo(_("无法创建漫画文件"))

        return

    end

    arc:setZipCompression("store")   -- 图片已压缩，无需再 deflate

    local mtime = os.time()

    local total_img, total_ch = 0, 0

    -- 用 pcall 包住整个下载 + 写包过程：任何异常都必须能走到 arc:close()，
    -- 否则 libarchive 句柄泄漏，并留下半个 .cbz（下次会被当成完整缓存直接打开）。
    local ok_loop, loop_err = pcall(function()

        for i = start_index, last do

            local ch = chapters[i]

            if ch then

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

        end

    end)

    pcall(arc.close, arc)

    if not ok_loop then

        pcall(os.remove, path)

        self:showInfo(_("漫画下载失败：") .. readable_error(loop_err))

        return

    end

    if total_img == 0 then

        pcall(os.remove, path)      -- 不留 0 图片的坏 cbz

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
