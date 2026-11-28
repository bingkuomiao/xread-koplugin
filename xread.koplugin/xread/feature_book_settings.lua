-- xread.koplugin/xread/book_settings.lua
-- 书内设置：正文排版偏好（缩进 / 粗细 / 简繁）、进度同步（进入 / 退出）、
-- 以及正文里呼出的「设置」面板（页面管理 / 字体管理 / 同步管理）。
--
-- 从 main.lua 拆出（Batch 2），方法仍挂在同一个 XRead 类上。
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Device = require("device")
local Screen = require("device").screen
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local UICommon = require("xread.ui_common")
local MessageBox = require("xread.message_box")

local M = {}

function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local chapterHtmlHead = env.chapterHtmlHead
    local chapterBlock = env.chapterBlock
    local fileSize = env.fileSize
    local hotReload = env.hotReload

    function XRead:paraIndentEnabled()
        return tostring(self:getSetting("para_indent", "1") or "1") ~= "0"
    end
    -- 段落缩进：正文 HTML 头部自带 p{text-indent:2em}，关掉时用用户样式表里的一条
    -- !important 覆盖掉；改完立刻重排当前页，不用重建正文文件。
    function XRead:applyParaIndent()
        local ui = self.ui
        if not (ui and ui.document) then return end
        pcall(function()
            local extra = ""
            if not self:paraIndentEnabled() then
                extra = "p { text-indent: 0 !important; }"
            end
            -- 保留用户原有的样式表与样式微调，只在末尾追加我们的覆盖：
            -- 段落缩进 + 正文局部夜晚深色源色（全局夜晚时由屏幕反色负责）。
            local tweaks = ""
            pcall(function() tweaks = ui.styletweak:getCssText() or "" end)
            local css = ui.typeset and ui.typeset.css
            if not css then css = ui.document.default_css end
            if not css then return end
            ui.document:setStyleSheet(css, tweaks .. extra .. self:_bookNightCss())
            ui:handleEvent(require("ui/event"):new("UpdatePos"))
        end)
    end

    function XRead:fontBoldEnabled()
        return tostring(self:getSetting("font_bold", "0") or "0") == "1"
    end
    -- 字体粗细：0 = 常规(400)，1.5 = 偏粗（没有对应字重时由引擎合成）。
    -- force=true 用于关闭时把字重还原成 0；文档就绪时只在开启状态下覆盖，
    -- 避免把用户在原生菜单里调过的字重改回去。
    function XRead:applyFontBold(force)
        local ui = self.ui
        if not (ui and ui.document) then return end
        local on = self:fontBoldEnabled()
        if not on and not force then return end
        pcall(function()
            if ui.document.setFontBaseWeight then
                ui.document:setFontBaseWeight(on and 1.5 or 0)
            end
            ui:handleEvent(require("ui/event"):new("UpdatePos"))
        end)
    end

    function XRead:zhMode()
        local v = tostring(self:getSetting("zh_convert", "none") or "none")
        if v ~= "s" and v ~= "t" then return "none" end
        return v
    end

    -- ---------- 进度同步：进入同步 / 退出同步 ----------
    -- 进入同步：打开书籍时主动从云端拉一次进度，而不是只用本地缓存的旧书架位置。
    -- 退出同步：关闭书籍时把当前章节上传到云端。
    -- 默认「进入开、退出关」：开书位置跟随云端，关书不额外发请求。
    function XRead:syncOnOpenEnabled()
        return tostring(self:getSetting("sync_on_open", "1") or "1") ~= "0"
    end

    function XRead:syncOnExitEnabled()
        return tostring(self:getSetting("sync_on_exit", "0") or "0") == "1"
    end

    -- 云端进度快照（模块级）：60s 内连续开书只拉一次书架，
    -- 避免每开一本书都在 UI 线程上多等一个网络往返。
    local CLOUD_PROGRESS = { at = 0, map = nil }

    --- 拉一次云端进度，返回这本书的 1 基章节号（拿不到返回 nil）
    -- 只认 bookUrl 相同的那本：书架里同名不同源的书很常见，不能按书名对位。
    function XRead:fetchCloudChapterIndex(book)
        if not (book and book.bookUrl) then return nil end
        local url = tostring(book.bookUrl)
        local now = os.time()
        if not (CLOUD_PROGRESS.map and (now - CLOUD_PROGRESS.at) < 60) then
            local ok, shelf = pcall(function()
                return self.client:getBookshelf(1, { timeout = 4 })
            end)
            if not ok or type(shelf) ~= "table" then return nil end
            local map = {}
            for _i, b in ipairs(shelf) do
                local u = tostring(b.bookUrl or "")
                if u ~= "" then map[u] = tonumber(b.durChapterIndex) end
            end
            CLOUD_PROGRESS.at, CLOUD_PROGRESS.map = now, map
        end
        local idx = CLOUD_PROGRESS.map[url]
        if idx and idx >= 0 then return idx + 1 end
        return nil
    end

    --- 退出同步的实际动作：把当前章推到云端，并同步写进本地书架缓存
    function XRead:_uploadProgressOnExit()
        if not self:syncOnExitEnabled() then return end
        local book, idx = SHARED.book, tonumber(SHARED.index)
        if not (book and idx) then return end
        if not self:_backendUsable() then return end
        local zero = math.max(0, idx - 1)
        local ok = pcall(function() self.client:saveBookProgress(book, zero) end)
        if not ok then return end
        pcall(function()
            self.meta_cache:updateShelfProgress(book.bookUrl or book.name, zero, os.time())
        end)
        if os.getenv("XREAD_AUTOTEST") then
            print("[XREAD_AUTOTEST] sync_exit chapter=" .. tostring(idx))
        end
    end
    -- 简繁切换：切完要把当前正文文件按新模式重拼一遍再热重载，
    -- 否则已经在看的这一章还是旧字形（下一章才会生效）。
    function XRead:applyZhConvert(mode)
        mode = (mode == "s" or mode == "t") and mode or "none"
        self:saveSetting("zh_convert", mode)
        SHARED.zh_mode = mode
        local ui = self.ui
        local book, chapters, index = SHARED.book, SHARED.chapters, SHARED.index
        if not (ui and ui.document and book and chapters and index) then return end
        if SHARED.txt_path ~= ui.document.file then return end   -- 不是从阅读X打开的书
        local ok = pcall(function()
            local max_chapters = tonumber(self:getSetting("max_chapters", "3")) or 3
            local last = math.min(index + max_chapters - 1, #chapters)
            local parts = { chapterHtmlHead(book.name or "") }
            local n = 0
            for i = index, last do
                local text = self.chapter_cache:get(book, i)
                if not text then break end
                local ch = chapters[i]
                parts[#parts + 1] = chapterBlock(ch and ch.title or ("第" .. i .. "章"), text)
                n = n + 1
            end
            if n == 0 then error("no cached text") end
            SHARED.doc_last = index + n - 1
            local f = io.open(SHARED.txt_path, "w")
            if not f then error("open failed") end
            f:write(table.concat(parts))
            f:close()
            SHARED.txt_size = fileSize(SHARED.txt_path)
        end)
        if not ok then
            logger.warn("xread zh convert rewrite failed")
            self:showInfo(_("简繁切换失败，重新打开本章后生效"), 5)
            return
        end
        UIManager:nextTick(function() hotReload(ui, SHARED.txt_path) end)
    end

    -- ---------- 正文里的「设置」：页面管理 / 字体管理 / 同步管理（卡片分组） ----------

    function XRead:showBookSettingsPanel()
        -- 防重叠：已有面板开着先关掉（改任意一项都会重建面板回显）
        if self._book_settings_dialog then
            pcall(function() UIManager:close(self._book_settings_dialog) end)
            self._book_settings_dialog = nil
        end
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
        local dialog  -- forward

        local function refreshDialog()
            if dialog then UIManager:close(dialog) end
            -- 只换波形、不整屏深刷，避免每改一项就全屏黑白闪一次
            UIManager:setDirty("all", "ui")
            self:showBookSettingsPanel()
        end

        local function closePanel()
            if dialog then UIManager:close(dialog) end
            UIManager:setDirty("all", "full")   -- 整屏重绘，防残影
        end
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local W = math.min(sw - Screen:scaleBySize(56), Screen:scaleBySize(880))
        local pad = Screen:scaleBySize(18)
        local inner_w = W - pad * 2
        local hpad = Screen:scaleBySize(16)
        local content_w = inner_w - 2 * hpad
        local row_h = math.max(Screen:scaleBySize(44),
            math.min(Screen:scaleBySize(58), math.floor(sh * 0.05)))
        local face_title = Font:getFace("cfont", 22)
        local face_group = Font:getFace("cfont", 15)
        local face_row = Font:getFace("cfont", 17)
        local face_value = Font:getFace("cfont", 16)
        local face_hint = Font:getFace("smallinfofont", 13)

        -- ---------- 版式零件（与首页「设置」同一套） ----------
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
        local label_w = math.floor(content_w * 0.46)
        local ctl_w = math.max(1, content_w - label_w)
        local ParamRow = InputContainer:extend{
            label = nil, value = nil, height = nil,
            callback = nil, arrow = nil, value_face = nil,
            value_bold = nil, selected = false,
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
                bold = self.value_bold == true,
                max_width = ctl_w,
                fgcolor = self.value_bold and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_6,
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
                value_face = opts.value_face, value_bold = opts.value_bold,
                selected = opts.selected,
            }
        end
        -- 一行「左侧标签 + 右侧自定义控件」（分段按钮等）
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

        local function pickFromList(title, items)
            local entries = {}
            for _i, it in ipairs(items) do
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
        -- 三段选择（简繁这种三态）：与首页缓存深度同款
        local function segmented(options, current, on_pick)
            local gap = Screen:scaleBySize(8)
            local seg_w = math.max(Screen:scaleBySize(48),
                math.floor((ctl_w - gap * (#options - 1)) / #options))
            local seg_h = row_h - Screen:scaleBySize(14)
            local group = HorizontalGroup:new{ align = "center" }
            for _i, opt in ipairs(options) do
                local key = opt.key
                local active = key == current
                group[#group + 1] = Button:new{
                    text = opt.label, text_font_face = "cfont", text_font_size = 15,
                    text_font_bold = active == true,
                    bordersize = active and 3 or 1,
                    radius = 6,
                    width = seg_w, height = seg_h,
                    callback = function()
                        if active then return end
                        on_pick(key)
                    end,
                }
                if _i < #options then
                    group[#group + 1] = HorizontalSpan:new{ width = gap }
                end
            end
            return group
        end

        -- ---------- 页面管理 ----------
        local function toggleRow(label, on, on_tap)
            return row(label, on and _("开") or _("关"), function()
                on_tap()
                refreshDialog()
            end, { value_bold = true })
        end
        local indent_row = toggleRow(_("段落缩进"), self:paraIndentEnabled(), function()
            self:saveSetting("para_indent", self:paraIndentEnabled() and "0" or "1")
            pcall(function() self:applyParaIndent() end)
        end)
        local footer_row = toggleRow(_("页尾页码"), tostring(self:getSetting("reader_footer", "1")) ~= "0", function()
            local on = tostring(self:getSetting("reader_footer", "1")) ~= "0"
            self:saveSetting("reader_footer", on and "0" or "1")
            pcall(function() self:_applyReaderFooter() end)
        end)

        -- ---------- 字体管理 ----------
        local function currentFontFace()
            local v = nil
            pcall(function() v = self.ui and self.ui.font and self.ui.font.font_face end)
            return tostring(v or "")
        end

        local function currentFontSize()
            local v = nil
            pcall(function()
                local f = self.ui and self.ui.font
                v = f and f.configurable and tonumber(f.configurable.font_size)
            end)
            return tostring(v or 22)
        end
        local font_face_row = row(_("字体"),
            currentFontFace() ~= "" and currentFontFace() or _("系统默认"),
            function()
                local items = {}
                local ok_f, faces = pcall(function()
                    -- engineInit 返回 cre 库本体；字体列表是库级函数，必须点号调用
                    local cre = require("document/credocument"):engineInit()
                    return cre and cre.getFontFaces()
                end)
                local cur = currentFontFace()
                if ok_f and type(faces) == "table" then
                    for _i, f in ipairs(faces) do
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
                pickFromList(_("字体"), items)
            end, { arrow = true })
        local font_size_row = row(_("字号"), currentFontSize() .. "px", function()
            local items = {}
            local cur = tonumber(currentFontSize()) or 22
            for _i, s in ipairs({16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38}) do
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
            pickFromList(_("字号"), items)
        end, { arrow = true })
        local bold_row = toggleRow(_("字体加粗"), self:fontBoldEnabled(), function()
            local on = self:fontBoldEnabled()
            self:saveSetting("font_bold", on and "0" or "1")
            pcall(function() self:applyFontBold(true) end)
        end)
        local ZH_OPTIONS = {
            { key = "none", label = _("原文") },
            { key = "s", label = _("简体") },
            { key = "t", label = _("繁体") },
        }
        local zh_row = ctlRow(_("简繁转换"), segmented(ZH_OPTIONS, self:zhMode(), function(key)
            -- 改完立刻重拼当前正文并热重载，这一章马上换字形
            self:applyZhConvert(key)
            refreshDialog()
        end))

        -- ---------- 同步管理：两个开关，可以同时开 ----------
        -- 翻页管理已从这里移出（与首页齿轮「设置 → 翻页管理」重复，同一功能两处入口）。
        -- 标签写全「做什么」，下面不再挂两行解释小字：解释只会把面板撑长。
        local enter_sync_row = toggleRow(_("进入书籍拉取进度"), self:syncOnOpenEnabled(), function()
            self:saveSetting("sync_on_open", self:syncOnOpenEnabled() and "0" or "1")
        end)
        local exit_sync_row = toggleRow(_("退出上传进度"), self:syncOnExitEnabled(), function()
            self:saveSetting("sync_on_exit", self:syncOnExitEnabled() and "0" or "1")
        end)
        local rows = VerticalGroup:new{ align = "left" }
        rows[#rows + 1] = groupTitle(_("页面管理"))
        rows[#rows + 1] = card({ indent_row, footer_row })
        rows[#rows + 1] = groupTitle(_("字体管理"))
        rows[#rows + 1] = card({ font_face_row, font_size_row, bold_row, zh_row })
        rows[#rows + 1] = groupTitle(_("同步管理"))
        rows[#rows + 1] = card({ enter_sync_row, exit_sync_row })
        rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(14) }
        rows[#rows + 1] = TextWidget:new{
            text = _("改动即时生效并自动保存；点空白处或右上角 ✕ 关闭。"),
            face = face_hint, fgcolor = Blitbuffer.COLOR_GRAY_6,
            max_width = inner_w,
        }
        local card_box = VerticalGroup:new{ align = "left" }
        local title_tw = TextWidget:new{
            text = _("正文设置"), face = face_title, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local close_w = UICommon.closeButtonSize()
        local stretch = inner_w - title_tw:getSize().w - close_w
        if stretch < 0 then stretch = 0 end
        card_box[#card_box + 1] = HorizontalGroup:new{ align = "center",
            title_tw, HorizontalSpan:new{ width = stretch },
            UICommon.closeButtonAtEdge(closePanel, pad, close_w) }
        card_box[#card_box + 1] = rows
        -- 内容比屏幕高时套一层滚动容器（小屏/大字号下不至于把首尾行挤出屏幕）
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
            UICommon.dimBackdrop(bb, x, y, self.dimen.w, self.dimen.h)
            self[1]:paintTo(bb, x, y)
        end
        dialog = Overlay:new{}
        self._book_settings_dialog = dialog
        UIManager:show(dialog)
    end
end

return M
