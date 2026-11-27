-- xread.koplugin/xread/catalog_view.lua

-- 仿微信读书目录页：左侧书籍信息，右侧章节列表，底部分页。

local Blitbuffer    = require("ffi/blitbuffer")

local Geom          = require("ui/geometry")

local Font          = require("ui/font")

local Screen        = require("device").screen

local Device        = require("device")

local GestureRange  = require("ui/gesturerange")

local UIManager     = require("ui/uimanager")

local ImageWidget   = require("ui/widget/imagewidget")

local TextWidget    = require("ui/widget/textwidget")

-- 补 TextWidget 缺失的静态宽度测量（见 text_metrics.lua）
require("xread.text_metrics")

local TextBoxWidget = require("ui/widget/textboxwidget")

local FrameContainer = require("ui/widget/container/framecontainer")

local CenterContainer = require("ui/widget/container/centercontainer")

local VerticalGroup = require("ui/widget/verticalgroup")

local HorizontalGroup = require("ui/widget/horizontalgroup")

local HorizontalSpan = require("ui/widget/horizontalspan")

local VerticalSpan  = require("ui/widget/verticalspan")

local LineWidget    = require("ui/widget/linewidget")

local Button        = require("ui/widget/button")

local InputContainer = require("ui/widget/container/inputcontainer")

local FocusManager  = require("ui/widget/focusmanager")

local util          = require("util")

local _             = require("gettext")

local T             = require("ffi/util").template
local CatalogView = FocusManager:extend{

    book = nil,

    chapters = nil,

    cover_path = nil,

    page = 1,

    dur_index = nil,

    back_label = nil,

    on_select = nil,

    on_back = nil,

    order = "asc",           -- "asc" 正序 / "desc" 倒序
    on_order_toggle = nil,    -- function(next_order) 点倒序/正序按钮时切顺序

    selected_index = nil,     -- 刚点选、正在跳转的章节（1 基，chapters 真实下标）

    on_page_changed = nil,

    cache_fn = nil,          -- function(chapter_index) → "active" | nil（正在后台缓存）

    on_cache_changed = nil,  -- function(page) 状态变化时重建页面

}

local function scaled(px)

    return math.floor(px * (Screen:scaleBySize(1000) / 1000) + 0.5)

end

local function wrapTitle(text, face, width)

    local chars = util.splitToChars(text or "")

    local lines, cur = {}, ""

    local overflow = false

    for _i, ch in ipairs(chars) do

        local test = cur .. ch

        if cur == "" or TextWidget.getTextWidth(test, face, false, 0) <= width then

            cur = test

        else

            lines[#lines + 1] = cur

            cur = ch

            if #lines == 2 then

                overflow = true

                break

            end

        end

    end

    if #lines < 2 then

        lines[#lines + 1] = cur

    end

    if overflow and lines[2] then

        local second = util.splitToChars(lines[2])

        while #second > 0

            and TextWidget.getTextWidth(table.concat(second) .. "…", face, false, 0) > width do

            table.remove(second)

        end

        lines[2] = table.concat(second) .. "…"

    end

    return lines[1] or "", lines[2] or ""

end
-- 章节行：一列排布，行之间留一条细缝（列表区底色透出来当缝）。
-- 白天的三档状态：
--   · 当前章 / 选中章：黑底白字（当前章加粗）
--   · 已预加载：深灰底(GRAY_6)白字；预加载完成后加粗
--   · 其它：白底黑字
-- 夜间是整屏反色，这里只写白天的源色即可：黑底→白底、深灰底→浅灰底、
-- 白底→黑底，正好得到「白底黑字加粗 / 浅灰底黑字 / 黑底白字」的效果。
local ChapterRow = InputContainer:extend{
    text = nil, width = nil, height = nil, gap = 0,
    is_current = false, is_selected = false, cache_state = nil, callback = nil,
}

function ChapterRow:colors()
    if self.is_current or self.is_selected then
        return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    end
    if self.cache_state == "active" or self.cache_state == "cached" then
        -- 深灰底白字：比普通行重，比当前章轻
        return Blitbuffer.COLOR_GRAY_6, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY_6
    end
    return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_GRAY_D
end

function ChapterRow:init()
    local pad = scaled(12)
    local bg, fg, border = self:colors()
    -- 当前章始终加粗；预加载完成的章节靠加粗和「还在预加载」区分
    local bold = self.is_current or self.cache_state == "cached"
    local box_w = math.max(scaled(20), self.width)
    local box_h = math.max(scaled(20), self.height - self.gap)

    local tw = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", scaled(14)),
        bold = bold,
        fgcolor = fg,
        max_width = math.max(1, box_w - 2 * pad),
    }
    local tw_h = tw:getSize().h

    self.frame = FrameContainer:new{
        bordersize = 1, color = border, radius = scaled(6),
        margin = 0, padding = 0,
        padding_left = pad, padding_right = pad,
        padding_top = math.max(0, math.floor((box_h - tw_h) / 2)),
        padding_bottom = 0,
        background = bg,
        width = box_w, height = box_h,
        tw,
    }
    self[1] = self.frame
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChapterRow:onTap()
    if self.callback then self.callback() end
    return true
end

function ChapterRow:onFocus()
    if not (self.is_current or self.is_selected) then
        self.frame.background = Blitbuffer.COLOR_GRAY_E
        UIManager:setDirty(self, "ui")
    end
    return true
end

function ChapterRow:onUnfocus()
    self.frame.background = (self:colors())
    UIManager:setDirty(self, "ui")
    return true
end

function CatalogView.computeLayout()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local header_h = 0   -- 顶部“目录”标题行已去掉，章节列表占满内容区
    local footer_h = scaled(44)
    local body_h = sh - header_h - footer_h - scaled(12)
    local pad = scaled(8)
    local divider = 1
    local left_w = math.floor(sw * 0.29)
    local right_w = sw - left_w - divider
    local right_header_h = scaled(34)

    -- 单列列表：一屏 14 章（与两列方块版之前的行高一致），行间只留一条细缝。
    local cols = 1
    local rows = 14
    local gap = scaled(5)
    local list_h = body_h - 2 * pad - right_header_h - 1
    local row_h = math.max(scaled(30), math.floor(list_h / rows))
    local cell_w = right_w - 2 * pad

    return {
        screen_w = sw, screen_h = sh,
        header_h = header_h, footer_h = footer_h, body_h = body_h,
        pad = pad, divider = divider,
        left_w = left_w, right_w = right_w,
        right_header_h = right_header_h,
        row_h = row_h, rows = rows, cols = cols, gap = gap, cell_w = cell_w,
        page_size = rows,
    }
end

-- 小黑按钮（白字），用于“去底部”。

local MiniButton = InputContainer:extend{

    text = nil, width = nil, height = nil, callback = nil,

}

function MiniButton:init()

    local tw = TextWidget:new{

        text = self.text,

        face = Font:getFace("cfont", scaled(14)),

        fgcolor = Blitbuffer.COLOR_WHITE,

        max_width = self.width - scaled(12),

    }

    self.frame = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_BLACK,

        width = self.width, height = self.height,

        CenterContainer:new{

            dimen = Geom:new{ w = self.width, h = self.height }, tw,

        },

    }

    self[1] = CenterContainer:new{

        dimen = Geom:new{ w = self.width, h = self.height }, self.frame,

    }

    self.dimen = Geom:new{ w = self.width, h = self.height }

    self.ges_events = {

        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },

    }

end

function MiniButton:onTap()

    if self.callback then self.callback() end

    return true

end
function CatalogView:init()

    local chapters = self.chapters or {}

    local L = CatalogView.computeLayout()

    self.layout = L

    self.dimen = Geom:new{ x = 0, y = 0, w = L.screen_w, h = L.screen_h }

    if Device:hasKeys() then

        self.key_events.Close = { { Device.input.group.Back } }

    end

    local page_size = L.page_size

    local page_count = math.max(1, math.ceil(#chapters / page_size))

    if self.page < 1 then self.page = 1 end

    if self.page > page_count then self.page = page_count end

    self.page_count = page_count

    local first = (self.page - 1) * page_size + 1

    local last = math.min(#chapters, first + page_size - 1)
    -- 左栏：封面 + 书名 + 作者 + 进度 + 书架按钮

    local inner_left_w = L.left_w - 2 * L.pad

    local cover_w = inner_left_w - scaled(12)

    local cover_h = math.floor(cover_w / 0.75 + 0.5)

    local max_cover_h = L.body_h - 2 * L.pad - scaled(250)

    if cover_h > max_cover_h then

        cover_h = math.max(1, max_cover_h)

        cover_w = math.floor(cover_h * 0.75 + 0.5)

    end

    local cover_widget

    if self.cover_path then

        local ok, img = pcall(function()

            local w = ImageWidget:new{

                file = self.cover_path, width = cover_w, height = cover_h,

            }

            w:getSize()

            return w

        end)

        if ok and img then cover_widget = img end

    end

    if not cover_widget then

        cover_widget = FrameContainer:new{

            bordersize = 1, color = Blitbuffer.COLOR_GRAY_D,

            background = Blitbuffer.COLOR_WHITE,

            width = cover_w, height = cover_h,

            CenterContainer:new{

                dimen = Geom:new{ w = cover_w, h = cover_h },

                TextWidget:new{

                    text = _("无封面"),

                    face = Font:getFace("cfont", scaled(16)),

                    fgcolor = Blitbuffer.COLOR_GRAY_B,

                },

            },

        }

    end

    local title_w = inner_left_w - scaled(4)

    local title_face = Font:getFace("tfont", scaled(15))

    local title_line1, title_line2 = wrapTitle(self.book.name or "?", title_face, title_w)

    local title_line_h = math.floor(title_face.size * 1.22)

    local function titleLine(text)

        return CenterContainer:new{

            dimen = Geom:new{ w = title_w, h = title_line_h },

            TextWidget:new{

                text = text, face = title_face, padding = 0,

                max_width = title_w, fgcolor = Blitbuffer.COLOR_BLACK,

            },

        }

    end

    local title_h = title_line_h * 2

    local title_widget = VerticalGroup:new{

        align = "center",

        titleLine(title_line1),

        titleLine(title_line2),

    }

    local author_widget = TextWidget:new{

        text = _("作者：") .. (self.book.author or "—"),

        face = Font:getFace("cfont", scaled(13)),

        fgcolor = Blitbuffer.COLOR_GRAY_6,

        max_width = inner_left_w,

    }

    local total = tonumber(self.book.totalChapterNum) or #chapters

    local dur = tonumber(self.dur_index) or 0

    local progress_widget = TextWidget:new{

        text = T(_("已读 %1 / %2 章"), tostring(dur), tostring(total)),

        face = Font:getFace("cfont", scaled(13)),

        fgcolor = Blitbuffer.COLOR_GRAY_6,

        max_width = inner_left_w,

    }

    local btn_w = inner_left_w

    local btn_h = scaled(36)

    -- 从书架进来时是“书架/目录”，从阅读器里呼出时是“返回/目录”

    local back_label = self.back_label or _("书架")

    -- 返回按钮旁边放「目录」按钮（跳目录第一页），两个按钮平分宽度

    local half_btn_w = math.max(scaled(40), math.floor((btn_w - scaled(10)) / 2))

    local back_btn = Button:new{

        text = back_label, width = half_btn_w, height = btn_h,

        text_font_size = scaled(15), bordersize = 1, radius = scaled(6),

        background = Blitbuffer.COLOR_GRAY_E, color = Blitbuffer.COLOR_GRAY_7,

        callback = function() if self.on_back then self.on_back() end end,

    }

    -- 「倒序 / 正序」：按钮上写的是「点一下会切到的方向」，
    -- 正序时显示「倒序」，倒序时显示「正序」，点了列表立刻翻过来。
    local order_btn = Button:new{

        text = (self.order == "desc") and _("正序") or _("倒序"),

        width = btn_w - half_btn_w - scaled(10), height = btn_h,

        text_font_size = scaled(15), bordersize = 1, radius = scaled(6),

        background = Blitbuffer.COLOR_GRAY_E, color = Blitbuffer.COLOR_GRAY_7,

        callback = function()
            if self.on_order_toggle then
                self.on_order_toggle(self.order == "desc" and "asc" or "desc")
            end
        end,

    }

    local shelf_btn = back_btn

    local left_buttons = HorizontalGroup:new{

        back_btn,

        HorizontalSpan:new{ width = scaled(10) },

        order_btn,

    }

    -- 封面顶部留出一点空隙（下移），并计入占用高度

    local cover_top_gap = scaled(10)

    local used = cover_top_gap + cover_h + scaled(12) + title_h + scaled(8)

        + author_widget:getSize().h + scaled(4) + progress_widget:getSize().h

        + scaled(14) + btn_h

    local filler = math.max(scaled(4), L.body_h - 2 * L.pad - used - scaled(18))

    local left_frame = FrameContainer:new{

        bordersize = 0, padding = L.pad, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.left_w, height = L.body_h,

        VerticalGroup:new{

            align = "center",

            VerticalSpan:new{ width = cover_top_gap },

            cover_widget,

            VerticalSpan:new{ width = scaled(12) },

            title_widget,

            VerticalSpan:new{ width = scaled(8) },

            author_widget,

            VerticalSpan:new{ width = scaled(4) },

            progress_widget,

            VerticalSpan:new{ width = filler },

            left_buttons,

        },

    }

    -- 固定左栏占位，避免内容略高把整个底栏顶出屏幕。

    local left = CenterContainer:new{

        dimen = Geom:new{ w = L.left_w, h = L.body_h },

        left_frame,

    }

    -- 中缝

    local divider_widget = LineWidget:new{

        dimen = Geom:new{ w = 1, h = L.body_h },

        background = Blitbuffer.COLOR_BLACK,

    }

    -- 右栏：书名 + 跳末页 + 章节列表

    local name_widget = TextWidget:new{

        text = _("目录"),

        face = Font:getFace("tfont", scaled(16)),

        max_width = L.right_w - scaled(120),

    }

    local header_fill = math.max(scaled(8),

        L.right_w - name_widget:getSize().w - scaled(20))

    local right_header = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.right_w, height = L.right_header_h,

        HorizontalGroup:new{

            name_widget,

            HorizontalSpan:new{ width = header_fill },

        },

    }

    local chapter_rows = {}
    local chapter_count = #chapters
    local order = (self.order == "desc") and "desc" or "asc"

    -- 倒序时列表从最后一章往前排。pos 是「当前排序下的第几章」，
    -- 换算回 chapters 的真实下标后再取标题 / 缓存状态 / 跳转目标。
    local function bookIndex(pos)
        if order == "desc" then return chapter_count - pos + 1 end
        return pos
    end

    local grid = VerticalGroup:new{ align = "left" }
    local selected = self.selected_index
    local pos = first
    while pos <= last do
        local bi = bookIndex(pos)
        local ch = chapters[bi] or {}
        local label = ch.title or (_("第") .. bi .. _("章"))
        local cache_state = self.cache_fn and self.cache_fn(bi) or nil
        if cache_state == "active" then
            label = label .. " · " .. _("缓存中")
        end
        local row = ChapterRow:new{
            text = label,
            width = L.cell_w,
            height = L.row_h,
            gap = L.gap,
            is_current = (bi - 1 == dur),
            is_selected = (selected ~= nil and bi == selected),
            cache_state = cache_state,
            callback = function() if self.on_select then self.on_select(bi) end end,
        }
        grid[#grid + 1] = row
        chapter_rows[#chapter_rows + 1] = row
        pos = pos + 1
    end

    -- 章节区底色比格子深一档：格子之间露出来的那条就是缝。
    local right = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_GRAY_E,
        width = L.right_w, height = L.body_h,
        VerticalGroup:new{
            align = "left",
            right_header,
            LineWidget:new{
                dimen = Geom:new{ w = L.right_w, h = 1 },
                background = Blitbuffer.COLOR_BLACK,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = L.right_w, h = math.max(1, L.body_h - L.right_header_h - 1) },
                grid,
            },
        },
    }

    -- 底部分页

    local btn_margin = scaled(7)

    local nav_h = scaled(28)

    local half = math.floor(L.screen_w / 2)

    local function newNavButton(text, width, enabled, callback)

        return Button:new{

            text = text, width = width, height = nav_h,

            enabled = enabled, callback = callback,

            text_font_size = scaled(14), bordersize = 1, radius = 0, margin = 0,

            background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_GRAY_D,

        }

    end

    local info_w = scaled(96)

    -- 留出左右边距，别让「上一页」的边框贴到屏幕边被裁掉
    local nav_w = math.max(scaled(60), half - info_w / 2 - scaled(14))

    local prev = newNavButton(_("上一页"), nav_w, self.page > 1,

        function() self:onPageChanged(self.page - 1) end)

    local next = newNavButton(_("下一页"), nav_w, self.page < page_count,

        function() self:onPageChanged(self.page + 1) end)

    local page_info = CenterContainer:new{

        dimen = Geom:new{ w = info_w, h = nav_h },

        TextWidget:new{

            text = T(_("%1 / %2"), tostring(self.page), tostring(page_count)),

            face = Font:getFace("cfont", scaled(14)),

            bold = true,

            fgcolor = Blitbuffer.COLOR_BLACK,

        },

    }

    local footer = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.screen_w, height = L.footer_h,

        VerticalGroup:new{

            align = "center",

            VerticalSpan:new{ width = btn_margin },

            HorizontalGroup:new{ prev, HorizontalSpan:new{ width = scaled(4) }, page_info,
                HorizontalSpan:new{ width = scaled(4) }, next },

            VerticalSpan:new{ width = math.max(0, L.footer_h - btn_margin - nav_h) },

        },

    }

    self[1] = FrameContainer:new{

        background = Blitbuffer.COLOR_WHITE,

        bordersize = 0, padding = 0, margin = 0,

        dimen = self.dimen:copy(),

        VerticalGroup:new{

            align = "left",

            HorizontalGroup:new{ left, divider_widget, right },

            footer,

        },

    }

    self._page_buttons = { prev, next }

    local focus_rows = { { back_btn, order_btn }, chapter_rows, { prev, next } }

    self.layout = focus_rows

    self._focus_rows = focus_rows

    -- 预加载高亮：每秒检查后台缓存状态，变化时重建目录页

    if self.cache_fn and self.on_cache_changed then

        self._cache_sig = self:_cacheSignature()

        self:_scheduleCacheTick()

    end

end

function CatalogView:_cacheSignature()

    local chapters = self.chapters or {}

    local page_size = self.layout.page_size or 14

    local first = (self.page - 1) * page_size + 1

    local last = math.min(#chapters, first + page_size - 1)

    local sig = {}

    for i = first, last do

        sig[#sig + 1] = tostring(self.cache_fn and self.cache_fn(i) or "")

    end

    return table.concat(sig, ",")

end

function CatalogView:_scheduleCacheTick()

    UIManager:scheduleIn(1.0, function()

        if self._closed then return end

        local sig = self:_cacheSignature()

        if sig ~= self._cache_sig then

            self._cache_sig = sig

            local cb = self.on_cache_changed

            if cb then pcall(cb, self.page) end

            return

        end

        self:_scheduleCacheTick()

    end)

end

-- 关闭/被覆盖时停掉预加载高亮的轮询

function CatalogView:onCloseWidget()

    self._closed = true

end

function CatalogView:onClose()

    self._closed = true

end

function CatalogView:onPageChanged(new_page)

    if self.on_page_changed then self.on_page_changed(new_page) end

    return true

end

-- 目录页是整屏覆盖层，显式刷白，避免 e-ink 局部刷新留下文件管理器残影。

function CatalogView:paintTo(bb, x, y)

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    FocusManager.paintTo(self, bb, x, y)

end

return CatalogView
