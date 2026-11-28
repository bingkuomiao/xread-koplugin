-- xread.koplugin/main.lua
-- 流程：书架点书 -> 只抓 1 章 -> 立刻打开阅读器 -> 后台静默缓存后续章节
-- 退出书籍（CloseDocument）时自动中断后台缓存。
-- 数据源：xread-fpk /reader3/*（用 xread/client.lua 封装）
local DataStorage  = require("datastorage")
local LuaSettings  = require("luasettings")
local UIManager    = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog  = require("ui/widget/inputdialog")
local Menu         = require("ui/widget/menu")
local ConfirmBox   = require("ui/widget/confirmbox")
local Trapper      = require("ui/trapper")
local Event        = require("ui/event")
local Device       = require("device")
local Screen       = require("device").screen
local DeviceListener = require("device/devicelistener")
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
local Repaint = require("xread.miui.repaint")
local MiuiUtil = require("xread.miui.util")
local ReaderToolbar = require("xread.miui.reader_toolbar")
local CatalogView = require("xread.catalog_view")
local QuickPanel = require("xread.quick_panel")
local ReadingStats = require("xread.reading_stats")
local UICommon = require("xread.ui_common")
local BookExport = require("xread.book_export")
-- 长任务进度框：单实例、文字原地刷新（替代 Trapper:info 的空框闪屏）
local ProgressToast = require("xread.progress_toast")
-- 统一提示框：白底 + 2px 黑边 + 居中文字，全部提示都走它
local MessageBox = require("xread.message_box")
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
-- 跨实例运行时状态已提取到 xread/shared.lua（单例，两个实例共用同一份）
local SHARED = require("xread.shared")
--- 当前页 -> 当前章节序号（1 基）。
-- TOC 是「每章一个起始页」的升序数组（原生 h2 或正文扫描注入），
-- 用二分找最后一个 page <= pageno 的条目；条目数与章节数对不上时按比例映射。
-- @return number|nil
local function pageChapterIndex(ui, pageno, chapters, doc_first, doc_last)
    local toc = ui and ui.toc and ui.toc.toc
    local has_toc = type(toc) == "table" and #toc > 0
    local total = type(chapters) == "table" and #chapters or 0
    local first = tonumber(doc_first) or 1
    local doc_count = (tonumber(doc_last) or 0) - first + 1
    pageno = tonumber(pageno) or 1
    local toc_idx = 0
    if has_toc then
        local lo, hi = 1, #toc
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if (tonumber(toc[mid].page) or 0) <= pageno then
                toc_idx = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        if toc_idx == 0 then toc_idx = 1 end
    end
    -- 当前文件只拼了「起始章 .. 起始章+N」这一段，TOC 也只覆盖这一段：
    -- 文档内第 idx 章 = 全书第 doc_first + idx - 1 章。
    local idx
    if doc_count > 0 then
        if has_toc and #toc == doc_count then
            idx = first + toc_idx - 1
        else
            -- TOC 条目数和写进文件的章数对不上（换文档瞬间还挂着旧 TOC、
            -- 或原生 TOC 里有标题被过滤）。以前这里按「全书章节数」做比例换算，
            -- 换文档的一瞬间会算出 349 这种完全不存在的章节号，工具栏/底栏
            -- 于是显示成另一章。现在改成按当前页在本文件里的相对位置换算，
            -- 结果一定落在 [first, doc_last] 之内，最多差一两章，不会跳到别处。
            local pages = 1
            pcall(function()
                local footer = ui and ui.view and ui.view.footer
                pages = tonumber(footer and footer.pages) or 1
            end)
            local pos = math.max(0, math.min(1, (pageno - 1) / math.max(1, pages)))
            idx = first + math.floor(pos * doc_count)
        end
    elseif has_toc then
        idx = toc_idx
        -- 没有文档范围信息（非 xread 文档）：条目数与章节数不符时按比例映射
        if total > 0 and #toc ~= total then
            idx = math.max(1, math.min(total, math.floor(idx / #toc * total + .5)))
        end
    else
        return nil
    end
    if total > 0 then idx = math.max(1, math.min(total, idx)) end
    return idx
end
local BG = { job = nil }
-- 简繁转换模式：拼正文（textToHtmlParas / chapterBlock）时按它转字。
-- 放在模块级是因为拼正文的函数是文件内 local，拿不到 self。
-- 模块**懒加载**：zh_convert.lua 有 47KB 字表，只有真的切到「简体/繁体」时才 require，
-- 绝大多数用户全程用不到，不需要在开机时把它读进来占内存。
local ZhConvert

local function zhText(s)
    local mode = SHARED.zh_mode
    if mode == "s" or mode == "t" then
        if not ZhConvert then
            local ok_req, mod = pcall(require, "xread/zh_convert")
            ZhConvert = ok_req and mod or nil
        end
        if ZhConvert then
            local ok, out = pcall(ZhConvert.convert, tostring(s or ""), mode)
            if ok and out then return out end
        end
    end
    return s
end
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
        if line ~= "" then out[#out + 1] = "<p>" .. htmlEscape(zhText(line)) .. "</p>" end
    end
    return table.concat(out, "\n")
end
-- 章节块（HTML）：新章从新页开始，h2 标题加大加粗；不含 head（开书时统一写一次），
-- 也不写 </body>，方便后台缓存追加
local function chapterBlock(title, text)
    return '<h2>' .. htmlEscape(zhText(tostring(title or ""))) .. '</h2>\n'
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
-- 统一提示：所有 InfoMessage 都从这里出，保证样式（白底黑边黑字居中）一致。
--
-- v0.6.33 起不再自动消失：原来按内容长度给 4~8s 的 timeout，长一点的错误原因
-- 常没读完就没了，用户只能反复触发同一个错误去「抢读」。
-- 现在固定「知道了」按钮 + 右上角 ✕ 两个出口，且点卡片外区域不关闭
-- （dismissable=false），必须由用户明确关掉。
-- 第二个参数 timeout 已废弃，仅为兼容历史调用保留，传了也不会自动关闭。
function XRead:showInfo(text, _timeout)
    local txt = tostring(text or "")
    if txt == "" then return end
    -- 每个提示一个序号：自动演验收据此断言「同一张卡没有被自动关掉」
    self._notice_seq = (self._notice_seq or 0) + 1
    local id = self._notice_seq
    if os.getenv("XREAD_AUTOTEST") then
        print("[XREAD_AUTOTEST] notice_shown id=" .. tostring(id) .. " len=" .. tostring(#txt))
    end
    MessageBox.show{
        text = txt,
        dismissable = false,
        buttons = { { text = _("知道了"), bold = true } },
        on_close = function()
            if os.getenv("XREAD_AUTOTEST") then
                print("[XREAD_AUTOTEST] notice_closed id=" .. tostring(id))
            end
        end,
    }
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
--- 后端类问题的统一弹窗：居中等宽卡片，一句话说明现状，
--- 底部「修改」直达地址管理，右边「忽略」继续用缓存；右上角另有 ✕。
function XRead:showBackendIssue(opts)
    opts = opts or {}
    MessageBox.confirm{
        title = opts.title or _("连不上服务器"),
        text = opts.text or "",
        sticky = true,
        ok_text = _("修改"),
        callback = function(ok)
            if ok then self:showServerManage() end
        end,
    }
end
--- 统一的后端不可达提示：说清楚「连的是哪台、为什么」，并给可操作的按钮
function XRead:notifyBackendDown(reason, silent)
    self:markBackendDown(reason)
    local msg = T(_("连不上 %1：%2，点「修改」改地址。"),
        display_address(self:backendAddress()), readable_error(reason))
    logger.warn("xread backend unreachable:", self:backendAddress(), tostring(reason))
    if os.getenv("XREAD_AUTOTEST") then
        print("[XREAD_AUTOTEST] backend_down " .. tostring(reason))
    end
    if not silent then
        self:showBackendIssue{ title = _("无法连接后端"), text = msg }
    end
end
--- 探活期间的等待提示。
-- v0.6.33：不再用系统 Notification 小横幅（一闪而过、字小、还抢不到焦点），
-- 改成同一套居中卡片；探活有结论后由 withBackend 主动收起（成功即进入内容，
-- 失败由失败卡接替），所以它不算「会自己消失的通知」——它是过程态。
function XRead:showConnectingToast(addr)
    self._connecting_box = MessageBox.show{
        text = T(_("正在连接 %1…"), display_address(addr)),
        dismissable = false,
    }
end

--- 收起探活等待卡（探活结束、无论成败都调）
function XRead:_hideConnectingToast()
    local box = self._connecting_box
    self._connecting_box = nil
    if box then pcall(function() box:close() end) end
end
--- 首页秒开后的「软失败」提示：与 notifyBackendDown 的模态卡片同一套样式，
--- 一句话说现状 + 给出路，本次启动只提示一次（手动关闭后才算看完）。
-- 只对「本地有缓存、之前连通过」的首页生效：无缓存时 withBackend 已经弹过模态引导。
function XRead:notifyBackendSoftDownOnce()
    if self._home_soft_down_notified then return end
    -- 不依赖 openHome 是否走过（从书里返回首页走 showHome），直接看本地缓存：
    -- 有缓存 = 之前连通过，这次连不上才提示；无缓存时 withBackend 会弹窗。
    local cached = self.meta_cache:getShelf(nil)
    if not cached or #cached == 0 then return end
    self._home_soft_down_notified = true
    -- 与「移除书籍」确认框同一张居中卡片：一句话说现状 + 给出路，
    -- 点「修改」直达地址管理，点「忽略」或 ✕ 则继续看缓存书架。
    self:showBackendIssue{
        title = _("后端连不上"),
        text = _("当前显示的是缓存书架，仍可正常阅读。"),
    }
    if os.getenv("XREAD_AUTOTEST") then print("[XREAD_AUTOTEST] soft_backend_down") end
end
--- 网络入口统一守卫：先探活，再执行 fn。
-- @param fn     function() 探活通过后在主线程执行
-- @param opts   { force=忽略冷却, timeout=探活秒数, silent=不显示正在连接 }
-- @return boolean 是否已受理（false = 直接失败并已提示）
function XRead:withBackend(fn, opts)
    opts = opts or {}
    local addr = self:backendAddress()
    if addr == "" or addr:match("^%s*$") then
        self:showBackendIssue{
            title = _("还没有设置后端地址"),
            text = _("现在显示的是本地缓存，点「修改」填写 IP 和端口。"),
        }
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
        -- 探活有结论：先收起「正在连接…」过程卡，后续提示（失败卡 / 业务 UI）才不会被它盖住
        self:_hideConnectingToast()
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
            self:showInfo(_("失败：") .. readable_error(err), 6)
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
            self:showInfo(_("失败：") .. msg)
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
    -- 正文简繁转换模式（none / s 转简体 / t 转繁体）：拼正文时按这个模式转字
    SHARED.zh_mode = tostring(self:getSetting("zh_convert", "none") or "none")
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
        elseif flow == "cache_none" then
            -- 缓存章节数全部取消（none）时，点「缓存」应先提示去首页设置
            UIManager:scheduleIn(4, function()
                local old = self:getSetting("cache_depth", "50")
                self:saveSetting("cache_depth", "none")
                self:doCacheBook(SHARED.book)
                autotest_mark("flow=cache_none done")
                UIManager:scheduleIn(10, function()
                    self:saveSetting("cache_depth", tostring(old or "50"))
                end)
            end)
        elseif flow == "download_confirm" then
            -- 本地已导出过同一本书：确认框按钮应为「覆盖」
            UIManager:scheduleIn(4, function()
                local p
                pcall(function() p = BookExport:exportPath(SHARED.book) end)
                if p then
                    pcall(function() util.makePath(p:match("^(.*)/[^/]+$") or ".") end)
                    local f = io.open(p, "w")
                    if f then f:write("x") f:close() end
                end
                autotest_mark("flow=download_confirm path=" .. tostring(p))
                self:downloadBookToDevice(SHARED.book)
            end)
        elseif flow == "chapter_sync" then
            -- 正常翻到最后一页（跨章），菜单/底栏章节名应随之更新
            UIManager:scheduleIn(5, function()
                local footer = self.ui and self.ui.view and self.ui.view.footer
                local pages = tonumber(footer and footer.pages) or 1
                pcall(function() self.ui:handleEvent(Event:new("GotoPage", pages)) end)
                UIManager:scheduleIn(2.5, function()
                    local ch = (SHARED.chapters or {})[SHARED.index or 1] or {}
                    autotest_mark("flow=chapter_sync idx=" .. tostring(SHARED.index)
                        .. " last=" .. tostring(SHARED.doc_last)
                        .. " title=" .. tostring(ch.title))
                end)
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
        elseif flow == "more_update" then
            UIManager:scheduleIn(4, function()
                self:showUpdateManage()
                autotest_mark("flow=more_update done")
            end)
        elseif flow == "more_about" then
            UIManager:scheduleIn(4, function()
                self:showAboutPanel()
                autotest_mark("flow=more_about done")
            end)
        elseif flow == "book_settings" then
            UIManager:scheduleIn(4, function()
                self:showBookSettingsPanel()
                autotest_mark("flow=book_settings done")
            end)
        elseif flow == "boot_manage" then
            UIManager:scheduleIn(4, function()
                self:showBootManage()
                autotest_mark("flow=boot_manage done")
            end)
        elseif flow == "progress" then
            -- 验收：带「取消」的下载进度卡片（只展示几秒，不真的下书）
            UIManager:scheduleIn(4, function()
                ProgressToast.show(T(_("正在下载 %1%（%2/%3）"), "38", "8", "21"),
                    { buttons = true, only_cancel = true })
                autotest_mark("flow=progress done")
            end)
        elseif flow == "update_notice" then
            -- 验收 v0.6.40：自动更新提示卡点「更新」应直接弹升级确认框，
            -- 不再跳「关于本机」。用假 manifest 触发，避免下载真更新包。
            UIManager:scheduleIn(4, function()
                self._update_info = { newer = true, remote_version = "9.9.9",
                    local_version = "0.6.40", via = "remote" }
                self._update_manifest = { version = "9.9.9", notes = "autotest" }
                self._update_notified = nil
                self:notifyUpdateAvailable()
                autotest_mark("flow=update_notice done")
            end)
        elseif flow == "night_seq" then
            -- 验收：正文夜晚 → 首页夜晚连续切换（首页必须每次都能翻转）
            UIManager:scheduleIn(4, function()
                autotest_mark("flow=night_seq book start")
                self:toggleBookNightMode()
                autotest_mark("flow=night_seq book done")
                UIManager:scheduleIn(2, function()
                    self.ui:onHome()
                    UIManager:scheduleIn(2, function()
                        local home_night = nil
                        for idx, entry in ipairs(self:buildHomeActions()) do
                            if tostring(entry.label) == tostring(_("夜晚")) then
                                home_night = entry.callback
                                break
                            end
                        end
                        if home_night then home_night() end
                        autotest_mark("flow=night_seq home1 done")
                        UIManager:scheduleIn(2, function()
                            local home_night2 = nil
                            for idx2, entry in ipairs(self:buildHomeActions()) do
                                if tostring(entry.label) == tostring(_("夜晚")) then
                                    home_night2 = entry.callback
                                    break
                                end
                            end
                            if home_night2 then home_night2() end
                            autotest_mark("flow=night_seq home2 done")
                        end)
                    end)
                end)
            end)
        elseif flow == "book_night" then
            -- 验收：书内夜晚（只改正文颜色）时页脚要跟着变深，不能留一条白
            UIManager:scheduleIn(5, function()
                self:toggleBookNightMode()
                autotest_mark("flow=book_night done")
            end)
        elseif flow == "msgbox" then
            -- 验收：统一提示框样式（白底 + 2px 黑边 + 居中文字）
            UIManager:scheduleIn(4, function()
                self:showBackendIssue{
                    title = _("首页加载失败"),
                    text = _("暂时取不到书架，可以先看本地缓存。"),
                }
                autotest_mark("flow=msgbox done")
            end)
        elseif flow == "msgconfirm" then
            -- 验收：统一确认框（两个按钮、确定加粗）
            UIManager:scheduleIn(4, function()
                MessageBox.confirm{
                    text = _("移除「老子是马超」？\n服务器书架、服务器缓存和本地缓存都会删除。"),
                    ok_text = _("移除"),
                    callback = function() end,
                }
                autotest_mark("flow=msgconfirm done")
            end)
        elseif flow == "local_books" then
            UIManager:scheduleIn(4, function()
                self:showLocalBooks()
                autotest_mark("flow=local_books done")
            end)
        elseif flow == "local_back" then
            -- 验收：本地阅读页点「返回」→ 我的首页（而不是露出下面的旧画面）
            UIManager:scheduleIn(4, function()
                self:showLocalBooks()
            end)
            UIManager:scheduleIn(12, function()
                if self._local_back then self._local_back() end
                autotest_mark("flow=local_back done")
            end)
        elseif flow == "soft_down" then
            -- 验收：有缓存首页 + 后端不可达 → 首页照常渲染，居中卡片提示只发一次。
            -- 只在本次进程里覆盖 backendAddress（不写盘、不污染后续用例），
            -- 指向本机 1 端口必然 TCP 失败。
            UIManager:scheduleIn(4, function()
                self.backendAddress = function() return "http://127.0.0.1:1" end
                self._backend_down = nil
                self._home_soft_down_notified = nil
                self._health_ok = nil
                self:closeBookToHome()
                UIManager:scheduleIn(8, function()
                    -- 再调一次：一次性标记应挡住，日志里 soft_backend_down 只应出现一次
                    self:notifyBackendSoftDownOnce()
                    autotest_mark("flow=soft_down done")
                end)
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
        elseif flow == "diag_chapter" then
            -- 诊断：开书位置 / 目录跳章后的章节号、文档范围、TOC 条目数是否一致
            UIManager:scheduleIn(4, function()
                local function dump(tag)
                    local ui = self.ui
                    local footer = ui and ui.view and ui.view.footer
                    local toc = ui and ui.toc and ui.toc.toc
                    local chapters = SHARED.chapters or {}
                    local cur = tonumber(SHARED.index) or 1
                    local ch = chapters[cur] or {}
                    print(string.format(
                        "[XREAD_DIAG] %s index=%s first=%s last=%s toc=%s page=%s pages=%s total=%s title=%s next=%s",
                        tag, tostring(SHARED.index), tostring(SHARED.doc_first), tostring(SHARED.doc_last),
                        tostring(toc and #toc), tostring(footer and footer.pageno),
                        tostring(footer and footer.pages), tostring(#chapters),
                        tostring(ch.title), tostring((chapters[cur + 1] or {}).title)))
                end
                dump("at_open")
                if os.getenv("XREAD_DIAG") == "1" then
                    local cps = SHARED.chapters or {}
                    for i = 1, math.min(8, #cps) do
                        print("[XREAD_DIAG] head " .. i .. " = " .. tostring(cps[i] and cps[i].title))
                    end
                    for i = math.max(1, #cps - 2), #cps do
                        print("[XREAD_DIAG] tail " .. i .. " = " .. tostring(cps[i] and cps[i].title))
                    end
                    local function dumpEntry(tag, i)
                        local e = cps[i] or {}
                        local parts = {}
                        for k, v in pairs(e) do
                            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                        end
                        table.sort(parts)
                        print("[XREAD_DIAG] entry " .. tag .. " " .. table.concat(parts, " "))
                    end
                    dumpEntry("1", 1)
                    dumpEntry("2", 2)
                    dumpEntry("3", 3)
                    dumpEntry("cur", tonumber(SHARED.index) or 1)
                end
                local nchap = #(SHARED.chapters or {})
                local target = tonumber(os.getenv("XREAD_DIAG_JUMP") or "")
                    or math.min(nchap, (tonumber(SHARED.index) or 1) + 100)
                if nchap > 0 then target = math.max(1, math.min(nchap, target)) end
                local book, chapters = SHARED.book, SHARED.chapters
                if book and chapters then
                    self:openAtChapter(book, chapters, target)
                    UIManager:scheduleIn(8, function()
                        dump("after_jump_" .. tostring(target))
                        autotest_mark("flow=diag_chapter done")
                    end)
                else
                    autotest_mark("flow=diag_chapter done")
                end
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
    -- 「更多 → 首页管理」：开机后按设置自动进入 我的首页 / 我的书架 / 原生界面
    pcall(function() self:applyBootTarget() end)
    -- 冷启动预热：开机空闲时把书架缓存读进内存（只读本地文件，不联网）
    pcall(function() self:warmup() end)
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
            -- Batch 4 诊断：合并器计数与内存档位直接进日志，自动用例和真机
            -- 都能据此确认「去抖/额度」是否真的生效（e-ink 耗时在 WSL 测不出）
            print("[XREAD_AUTOTEST] perf " .. Repaint.stats_line())
            print("[XREAD_AUTOTEST] memory " .. require("xread.miui.memory").describe())
            -- 首页上下文的验收 flow（书架/布局/旋转/搜索），不依赖已开书
            local home_flow = os.getenv("XREAD_AUTOTEST_FLOW")
            if home_flow and home_flow ~= "" then
                self:_runHomeAutotestFlow(home_flow)
            end
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
                    -- 验收用：把 XREAD_AUTOTEST_BOOK 指定的书排到第一格。
                    -- 触点固定是 (110,300)，书架一换顺序就撞上书源挂掉的书，
                    -- 三次重试全耗在「目录超时」上，最后被 240s 上限杀掉（用例假失败）。
                    local want_shelf = os.getenv("XREAD_AUTOTEST_BOOK")
                    local pick_shelf
                    if want_shelf and want_shelf ~= "" then
                        for bi = 1, #books do
                            if books[bi].name and tostring(books[bi].name):find(want_shelf, 1, true) then
                                pick_shelf = bi
                                break
                            end
                        end
                    end
                    -- 指定的书可能已被移出书架（用例会因此撞上书源挂掉的书，
                    -- 三次重试全耗在「目录超时」上，最后被 240s 上限杀掉）。
                    -- 退化策略：取前几本里第一本目录能取到的。
                    if not pick_shelf then
                        for bi = 1, math.min(#books, 4) do
                            local ok_ch, ch = pcall(function() return self.client:getChapterList(books[bi]) end)
                            if ok_ch and type(ch) == "table" and #ch > 0 then
                                pick_shelf = bi
                                break
                            end
                        end
                    end
                    if pick_shelf and pick_shelf ~= 1 then
                        books[1], books[pick_shelf] = books[pick_shelf], books[1]
                    end
                    print("[XREAD_AUTOTEST] shelf_pick first=" .. tostring(books[1].name))
                    self:showBookshelf(1, books)
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
            -- 连接成功：立刻把顶部「已断开」纠正为「已连接」，别等下一轮心跳。
            -- 原来只弹提示，头部要等 60s 一轮的心跳或手动刷新才变，于是出现
            -- 「弹窗说已连接、顶部却显示已断开」的矛盾。
            self._health_ok = true
            self:clearBackendDown()
            if self._home_view and not self._home_view._miu_closed then
                pcall(function() self._home_view:updateHeader{ sync_text = _("已连接") } end)
            end
            -- 成功也给回执：结论 + 地址 + 耗时，能判断是否连错了机器
            self:showInfo(T(_("已连接：%1（%2 ms）"), addr, tostring(ms)), 6)
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
        self:showInfo(T(_("连接失败：%1\n%2"), addr, reason), 8)
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
        -- 最多补 3 本、间隔 2.5s：每次预取都是一个 fork，500MB 设备上
        -- 排 6 本会在进书架那几秒里连续 fork + 并发 HTTP，反而拖慢点书。
        if b ~= target and n < 3 then
            n = n + 1
            if not self.meta_cache:getChapters(b, ttl) then
                self:_bgFetchChapters(b, 1.5 + n * 2.5)
            end
        end
    end
end

-- ---------- 冷启动预热 ----------
-- 开机后 FileManager 首帧画完、用户还在看文件列表的这几秒，先把「必然要用」的
-- 本地数据读进内存，等用户第一次点「我的首页」时不用再解一遍 JSON。
-- 这里**不发任何网络请求**：开机抢网络会让第一次进首页反而更慢，也白耗电。
-- 内存代价只有一份书架副本（几十 KB，MetaCache 里单份持有，不随次数增长）。
function XRead:warmup()
    if self._warmed then return end
    self._warmed = true
    UIManager:scheduleIn(3, function()
        pcall(function() self.meta_cache:warm() end)
    end)
end

-- ---------- 第二步：miuread 首页 → xread/feature_home.lua ----------
require("xread.feature_home").install{
    XRead = XRead,
    SHARED = SHARED,
    BackendProbe = BackendProbe,
}

-- ---------- 书架 ----------

function XRead:prepareCovers(books, first, last, layout, skip_download)
    local UI = require("ui/trapper")
    local cover_paths = {}
    local total = last - first + 1
    local done = 0
    for i = first, last do
        local book = books[i]
        local path = self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)
        local src = self.cover_cache:sourceFor(book)
        if not path and not skip_download and src then
            done = done + 1
            logger.dbg("xread cover fetch", tostring(done), "/", tostring(total))
            local ok, p = pcall(function()
                return self.cover_cache:fetchAndStore(book, src,
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
    if not cc:sourceFor(book) then
        if callback then callback(nil) end
        return
    end
    -- 近期已确认取不到（AVIF / 书源 404）：别再 fork 一个子进程白跑
    if cc:recentlyFailed(book, max_w, max_h) then
        if callback then callback(nil) end
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
        local data, ferr = cc:fetchRaw(book, book.coverUrl)
        if data then
            cc:writeRawFile(book, data, max_w, max_h)
        else
            cc:writeRawError(book, ferr, max_w, max_h)   -- 让主线程知道失败原因
        end
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
        local ok2, p, perr = pcall(function()
            return cc:storeFromRawFile(book, max_w, max_h)
        end)
        if not (ok2 and p) then cc:markFailed(book, max_w, max_h, perr) end
        if callback then callback(ok2 and p or nil) end
    end
    UIManager:scheduleIn(0.1, poll)
end
-- 未缓存封面不阻塞书架：先显示占位，再逐张静默下载并局部刷新。
-- 用 generation 号防止翻页/关闭后旧队列继续刷新界面。
function XRead:_queueMissingCovers(books, first, last, layout, miui_books, view, refresh_fn, on_done)
    local finished = false

    local function finish()
        if finished then return end
        finished = true
        if on_done then pcall(on_done) end
    end
    if os.getenv("XREAD_COVER_ASYNC") == "0" then finish() return end
    local queue = {}
    for i = first, last do
        local book = books[i]
        if book and not self.cover_cache:pathFor(book, layout.cover_w, layout.cover_h)
            and self.cover_cache:sourceFor(book) then
            queue[#queue + 1] = { i = i, book = book }
        end
    end
    if #queue == 0 then finish() return end
    local gen = (self._cover_generation or 0) + 1
    self._cover_generation = gen

    local function nextOne(k)
        if k > #queue then finish() return end
        UIManager:scheduleIn(0.05, function()
            if self._cover_generation ~= gen or view._miu_closed then finish() return end
            -- 后端不可达时整队放弃，别一张一张撞超时（每张都是同步请求，会冻 UI）
            if not self:_backendUsable() then finish() return end
            -- 弹层开着时封面下载让路，别让同步 HTTP 卡住弹层里的点击
            if self:_uiHasOverlay() then
                UIManager:scheduleIn(1.5, function() nextOne(k) end)
                return
            end
            local item = queue[k]
            -- 网络段进子进程，主线程只做解码 + 局部刷新，不再被单张 8s 冻住
            self:_fetchCoverAsync(item.book, layout.cover_w, layout.cover_h, function(p)
                if self._cover_generation ~= gen or view._miu_closed then finish() return end
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
    -- 后台封面补救的节奏（这是全插件最「主动」的一个后台任务，必须收敛）：
    --   · 起始 120s 一轮；本轮一张封面都没补到时指数退避，最长 15 分钟；
    --   · 只有「本地内存里没有书架」或每 10 轮才真去拉一次 getBookshelf
    --     （原来每一轮都拉，5 分钟一次全量书架 + 每 12 轮一次 refresh，
    --      后端和 500MB 设备都吃不消）；
    --   · 封面都齐了、书架也没变化 → 这一轮完全不发请求。
    local ttl_min = tonumber(self:getSetting("cover_retry_ttl", "120")) or 120
    if ttl_min < 60 then ttl_min = 60 end
    local ttl_max = math.max(ttl_min * 4, 900)
    local ttl = ttl_min
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
        -- 弹层开着时整轮让路，1.5s 后重试
        if self:_uiHasOverlay() then
            UIManager:scheduleIn(1.5, round)
            return
        end
        rounds = rounds + 1
        -- 1) 书架元数据：首轮 / 每 10 轮 / 内存里没有时才拉
        local books = self._shelf_books
        local fetched = false
        if rounds == 1 or rounds % 10 == 0 or type(books) ~= "table" or #books == 0 then
            local ok, fresh = pcall(function() books = self.client:getBookshelf() end)
            if ok and type(books) == "table" and #books > 0 then
                fetched = true
                books = BookFilter.filterReadable(books)
                self._shelf_books = books
                pcall(function() self.meta_cache:putShelf(books) end)
            else
                books = self._shelf_books
            end
        end
        if type(books) ~= "table" or #books == 0 then
            UIManager:scheduleIn(ttl, round)
            return
        end
        -- 2) 缺本地封面缓存的书逐张下载（间隔 1s 错峰）
        local layout = GridShelf.computeLayout(#books)
        local queue = {}
        for _, b in ipairs(books) do
            if not self.cover_cache:pathFor(b, layout.cover_w, layout.cover_h)
                and self.cover_cache:sourceFor(b) then
                queue[#queue + 1] = b
            end
        end
        if #queue == 0 then
            -- 都齐了：不再下载，也不每轮拉书架，退避到最长间隔
            if fetched then ttl = ttl_min else ttl = math.min(ttl_max, ttl * 2) end
            UIManager:scheduleIn(ttl, round)
            return
        end

        local function nextOne(k, added)
            if generation ~= self._cover_retry_generation then return end
            if not view or view._miu_closed or view._closed then return end
            if k > #queue then
                if added > 0 then logger.info("xread cover retry: fetched", added) end
                -- 补到过东西：回到最快节奏；一张都没补到（多半是书源挂了）：退避
                if added > 0 then ttl = ttl_min else ttl = math.min(ttl_max, ttl * 2) end
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
    -- 章节规模与「上次读到」合并成一行：原来 source_line 是「阅读X · 共 N 章」，
    -- last_read_text 又是「上次读到第 X 章 · 共 N 章」，「共 N 章」出现两遍。
    -- 现在信息行只有三行（作者/阅读至/章节），一眼看完不重复。
    hero.last_read_text = ""
    -- 简介只来自后端书架数据（书源抓取时带回来的字段），前端不生成内容。
    -- 不同书源/后端版本用的字段名不一样，这里按常见别名依次取；
    -- 有的书写简介、有的书（如家父汉高祖）后端本身就是空串，前端只能显示「暂无简介」。
    local intro_text = ""
    for _, key in ipairs({ "intro", "description", "desc", "summary",
            "bookIntro", "introduction", "brief", "introText" }) do
        local v = tostring(hero_book[key] or "")
        if v ~= "" then
            -- 后端简介常带 HTML 标签与实体；`&;`、`&#8203;`、`&nbsp;` 这类
            -- 如果不清掉，首页会直接显示成一串 "&; &; &;"。
            local clean = MiuiUtil.plain_text(v)
            if clean ~= "" then intro_text = clean break end
        end
    end
    hero.description = intro_text
    -- 参考图的排法：作者、来源各占一行（来源换行，不和作者挤同一行），
    -- 然后是「最新 · 最新章节名」，再是进度，最后是章节规模。
    local author = tostring(hero_book.author or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local origin = tostring(hero_book.originName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- 作者行带前缀「作者 · 」：和下面「最新 · 」「阅读至 」保持同一种写法，
    -- 否则一行光溜溜的人名读者还得自己猜是作者还是书源。
    hero.author_line = author ~= "" and (_("作者 · ") .. author) or ""
    hero.origin_line = origin
    local meta_bits = {}
    if author ~= "" then meta_bits[#meta_bits + 1] = author end
    if origin ~= "" then meta_bits[#meta_bits + 1] = origin end
    hero.meta_line = table.concat(meta_bits, " · ")
    -- 「最新 · 最新章节名」：后端书架接口直接带 latestChapterTitle（如「第453话」），
    -- 不需要为首页再拉一次目录。个别老后端没有这个字段时退回目录缓存的最后一章。
    local latest_title = tostring(hero_book.latestChapterTitle or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if latest_title == "" then
        pcall(function()
            local chapters = self.meta_cache and self.meta_cache:getChapters(hero_book) or nil
            if type(chapters) ~= "table" then return end
            for i = #chapters, 1, -1 do
                local c = chapters[i]
                if type(c) == "table" and c.isVolume ~= true then
                    local t = tostring(c.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if t ~= "" then latest_title = t break end
                end
            end
        end)
    end
    hero.latest_line = latest_title ~= "" and (_("最新 · ") .. latest_title) or ""
    -- 阅读进度行：阅读至 N% · 上次阅读时间（HH:MM 或 M月D日）
    local progress_text = _("阅读至 ") .. tostring(hero.progress or 0) .. "%"
    if read_time > 0 then
        local hour = os.date("%H:%M", read_time)
        local today = os.date("%Y%m%d")
        hero.when_text = os.date("%Y%m%d", read_time) == today
            and _("今天 ") .. hour or os.date("%m月%d日 ", read_time) .. hour
    end
    hero.progress_line = progress_text .. (hero.when_text and (" · " .. hero.when_text) or "")
    -- 章节规模与「上次读到」合并成一行，避免「共 N 章」出现两遍；
    -- 顺序按参考图：先上次读到，再共 N 章。只有真读过才带前半句。
    local chap_bits = {}
    if read_time > 0 then
        chap_bits[#chap_bits + 1] = _("上次读到第 ") .. tostring(dur + 1) .. _(" 章")
    end
    if total > 0 then chap_bits[#chap_bits + 1] = T(_("共 %1 章"), tostring(total)) end
    hero.last_chap_line = table.concat(chap_bits, " · ")
    -- 经典（无仪表盘）布局仍按原来的字段读，保持向后兼容
    hero.source_line = hero.last_chap_line
    hero.last_read_text = ""
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
            -- 长按封面 = 移除书籍；目录页由短按进书后从正文菜单打开
            self:removeBookFlow(mbook._xread_book)
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
        if not cover_path and self.cover_cache:sourceFor(book) then
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

function XRead:showReaderCatalog(page, order)
    -- 跳章切文档期间：目录只是等新文档就绪的遮罩，缓存轮询/翻页回调会重建它。
    -- onCloseDocument 此时把 SHARED.txt_path 清成 nil，下面的守卫会误判成
    -- 「从别处打开的普通文件」，闪一下「请从书架打开书籍」。切换期间静默跳过。
    if self._switch_overlay then return end
    local doc = self.ui.document
    if not doc or not doc.file then return end
    local book, chapters = SHARED.book, SHARED.chapters
    -- 从别处打开的普通文件：退回书架去选书
    if not book or not chapters or SHARED.txt_path ~= doc.file then
        self:showInfo(_("请从书架打开书籍"))
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
        order = order or "asc",
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
        on_order_toggle = function(next_order)
            -- 切顺序时回到第 1 页：倒序就从最后一章开始看
            self:showReaderCatalog(1, next_order)
        end,
        on_page_changed = function(new_page)
            self:showReaderCatalog(new_page, order)
        end,
        cache_fn = function(i) return self:chapterCacheState(book, i) end,
        on_cache_changed = function(p) self:showReaderCatalog(p, order) end,
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
    if os.getenv("XREAD_DIAG") == "1" then
        print(string.format("[XREAD_DIAG] catalog_tap i=%s total=%s title=%s cur=%s",
            tostring(i), tostring(chapters and #chapters),
            tostring(chapters and chapters[i] and chapters[i].title), tostring(SHARED.index)))
    end
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

function XRead:showCatalog(book, chapters, dur_index, page, cover_path, order)
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
        order = order or "asc",
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
        on_order_toggle = function(next_order)
            self:showCatalog(book, chapters, dur_index, 1, cover_path, next_order)
        end,
        on_page_changed = function(new_page)
            self:showCatalog(book, chapters, dur_index, new_page, cover_path, order)
        end,
        cache_fn = function(i) return self:chapterCacheState(book, i) end,
        on_cache_changed = function(p)
            self:showCatalog(book, chapters, dur_index, p, cover_path, order)
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
            -- 进入同步：开书前主动拉一次云端进度，跟随其它设备读到的最新章。
            -- 失败/未开启时保持本地缓存位置，不影响开书。
            if self:syncOnOpenEnabled() then
                local cloud = self:fetchCloudChapterIndex(book)
                if cloud and cloud ~= start then
                    start = cloud
                    book.durChapterIndex = cloud - 1
                    if chapters and start > #chapters then start = #chapters end
                    pcall(function()
                        self.meta_cache:updateShelfProgress(
                            book.bookUrl or book.name, cloud - 1, os.time())
                    end)
                    if os.getenv("XREAD_AUTOTEST") then
                        print("[XREAD_AUTOTEST] sync_open chapter=" .. tostring(cloud))
                    end
                end
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
    if os.getenv("XREAD_DIAG") == "1" then
        print(string.format("[XREAD_DIAG] open_at index=%s total=%s title=%s",
            tostring(index), tostring(chapters and #chapters),
            tostring(chapters and chapters[index] and chapters[index].title)))
    end
    local max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3
    if max_chapters < 1 then max_chapters = 1 end
    local last = math.min(index + max_chapters - 1, #chapters)
    -- 后台本地预加载范围 = 「浏览器缓存预加载章节数」（max_chapters）。
    -- 目录里的缓存高亮也按这个范围变化，与「服务器缓存预加载章节数」解耦：
    -- 服务器缓存只由正文「缓存」按钮按需触发，不再顺带放大本地预加载。
    local bg_last = last
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
    -- doc_last 必须是「真正写进文件的最后一章」：原来填的是计划范围的上界 last，
    -- 中途某章没缓存上时上界比实际大，TOC 条目数就和 doc_count 对不上，
    -- 页码→章节换算会走进比例兜底，显示成完全不相干的章节。
    SHARED.doc_first, SHARED.doc_last = index, math.max(index, contig_end)
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
    if contig_end < bg_last then
        startBg{
            client = self.client,
            cache = self.chapter_cache,
            book = book,
            chapters = chapters,
            path = path,
            start_index = index,
            end_index = contig_end,
            next = contig_end + 1,
            last = bg_last,
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
    -- 行距：crengine 的 setInterlineSpacePercent，100% 就是原生行距。
    -- 原来这里的 ± 没有回调，只有文字「原生」两个字，点了没有任何反应。
    local function currentLineSpacing()
        local v
        pcall(function()
            local f = self.ui and self.ui.font
            v = f and f.configurable and tonumber(f.configurable.line_spacing)
        end)
        return v or 100
    end

    local function spacingLabel()
        local v = currentLineSpacing()
        -- 100% 就是原生行距，但统一显示成百分比，避免出现「原生」这种
        -- 和其它档位不同类的文案（用户反馈菜单里应显示为 100%）。
        return tostring(v) .. "%"
    end
    local battery_label = ""
    pcall(function()
        if Device:hasBattery() then
            local powerd = Device:getPowerDevice()
            local level = powerd and powerd:getCapacity()
            if level then battery_label = tostring(math.max(0, math.min(100, math.floor(level + 0.5)))) .. "%" end
        end
    end)
    -- 昵称跟在「首页」按钮后单独占一格：拼进 home_label 时昵称一长就折行，
    -- 看着像「首页」和昵称挤在一起。第二行标题位显示书名，左下格显示当前章节名。
    local nickname = tostring(self:getSetting("nickname", "") or "")
    if nickname == "" then nickname = tostring(self:getSetting("username", "") or "") end
    if nickname == "" then nickname = _("书友") end
    local health_text = _("已连接")
    if self._health_ok == false then health_text = _("已断开") end
    local opts = {
        header = {
            home_label = _("首页"),
            nickname_label = nickname,
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
                    -- 缓存多少章由「设置 → 缓存管理 → 服务器缓存预加载章节数」决定；
                    -- 用户把 50/100/全部 全部取消（不缓存）时，这里先引导去首页设置。
                    local count = self:cacheDepthCount()
                    if count == nil then
                        MessageBox.show{
                            text = _("请设置服务器预缓存章节数"),
                            sticky = true,
                            dismissable = false,
                            buttons = { { text = _("知道了") } },
                        }
                        return
                    end
                    local text
                    if count == 0 then
                        text = T(_("让服务器缓存「%1」的全部章节？\n缓存后阅读秒开，失败会提示。"), book.name or "")
                    else
                        text = T(_("让服务器缓存「%1」的 %2 章？\n缓存后阅读秒开，失败会提示。"),
                            book.name or "", tostring(count))
                    end
                    MessageBox.confirm{
                        text = text,
                        ok_text = _("开始缓存"),
                        callback = function(ok)
                            if ok then self:doCacheBook(book, count) end
                        end,
                    }
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
                callback = function() self:showBookSettingsPanel() end,
                on_decrease = function() self:changeFontSize(-1); return fontLabel() end,
                on_increase = function() self:changeFontSize(1); return fontLabel() end,
            },
            spacing = {
                label = _("行距"), value = spacingLabel(),
                callback = function() self:showBookSettingsPanel() end,
                on_decrease = function() self:changeLineSpacing(-10); return spacingLabel() end,
                on_increase = function() self:changeLineSpacing(10); return spacingLabel() end,
            },
        },
        device_actions = {
            -- 正文夜晚只管当前这本书：月亮=这本书日间，太阳=这本书夜晚。
            -- 它不切换 Screen 的整屏反色，所以菜单和弹出页保持原样。
            { icon = self:_bookNightOn() and "sun" or "night",
              label = _("夜晚"), callback = function() self:toggleBookNightMode() end },
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
        -- 正文菜单里的夜晚按钮只作用于当前书籍，不影响菜单/弹出页
        on_night = function() self:toggleBookNightMode() end,
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
-- ---------- 面板里各快捷动作 → xread/feature_quick_actions.lua ----------
require("xread.feature_quick_actions").install{
    XRead = XRead,
    SHARED = SHARED,
    BG = BG,
    stopBg = stopBg,
    pageChapterIndex = pageChapterIndex,
    fileSize = fileSize,
    disableEndPopup = disableEndPopup,
    restoreEndPopup = restoreEndPopup,
    hotReload = hotReload,
}

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

    -- 自动验收：打印每行的屏幕中心坐标，用例按「文字 → 坐标」点击。
    -- 原来 15c/29 是硬编码 y（495/596/…/1000），一加菜单项就全部点偏，
    -- 只能靠人去数行数改坐标。这里让面板自己报位置，增删条目不用再动用例。
    function MoreRow:paintTo(bb, x, y)
        if not self._pos_logged and os.getenv("XREAD_AUTOTEST") then
            self._pos_logged = true
            print(string.format("[XREAD_AUTOTEST] more_row text=%s x=%d y=%d w=%d h=%d",
                tostring(self.text or ""),
                math.floor(x + self.width / 2), math.floor(y + self.height / 2),
                self.width, self.height))
        end
        return InputContainer.paintTo(self, bb, x, y)
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
                    -- 这个面板是整屏的（居中卡片 + 压暗遮罩），关掉后必须整屏重绘：
                    -- 否则接手的界面只刷自己那块，底下会留一条旧卡片/底图的残影
                    -- （「系统管理」打开 KOReader 菜单时最明显：底部残留一行提示文字）。
                    UIManager:setDirty("all", "full")
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
    local close_w = UICommon.closeButtonSize()
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
        UICommon.dimBackdrop(bb, x, y, self.dimen.w, self.dimen.h)
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

-- ---------- 设置 / 更多 / 升级 → xread/feature_menus.lua ----------
-- 每个 feature 模块只声明自己真正需要的依赖：通用模块自己 require，
-- main.lua 的私有小工具从这里显式传入（不复制实现，也不依赖全局）。
require("xread.feature_menus").install{
    XRead = XRead,
    SHARED = SHARED,
    PAGE_MODES = PAGE_MODES,
    now_ms = now_ms,
    readable_error = readable_error,
    display_address = display_address,
}

-- ---------- 书内设置 / 排版 / 同步 → xread/feature_book_settings.lua ----------
require("xread.feature_book_settings").install{
    XRead = XRead,
    SHARED = SHARED,
    chapterHtmlHead = chapterHtmlHead,
    chapterBlock = chapterBlock,
    fileSize = fileSize,
    hotReload = hotReload,
}

-- ---------- 移除书籍 / 整本预缓存 / 漫画 → xread/feature_book_cache.lua ----------
require("xread.feature_book_cache").install{
    XRead = XRead,
    SHARED = SHARED,
    BOOK_DIR = BOOK_DIR,
    bookCacheStem = bookCacheStem,
    removeBookCacheFiles = removeBookCacheFiles,
    fileSize = fileSize,
    readable_error = readable_error,
    reapSubProcess = reapSubProcess,
}

return XRead
