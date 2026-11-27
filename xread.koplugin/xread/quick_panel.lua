-- xread.koplugin/xread/quick_panel.lua

-- 轻点屏幕中间呼出的浮动面板（样式参考微信读书 iOS 面板）：

-- 圆角白卡 + 两条滑块（章节进度 / 字号）+ 3×4 图标网格。

local UICommon        = require("xread.ui_common")

local Blitbuffer      = require("ffi/blitbuffer")

local Geom            = require("ui/geometry")

local Font            = require("ui/font")

local Screen          = require("device").screen

local Device          = require("device")

local GestureRange    = require("ui/gesturerange")

local IconWidget      = require("ui/widget/iconwidget")

local TextWidget      = require("ui/widget/textwidget")

local FrameContainer  = require("ui/widget/container/framecontainer")

local CenterContainer = require("ui/widget/container/centercontainer")

local VerticalGroup   = require("ui/widget/verticalgroup")

local HorizontalGroup = require("ui/widget/horizontalgroup")

local HorizontalSpan  = require("ui/widget/horizontalspan")

local VerticalSpan    = require("ui/widget/verticalspan")

local InputContainer  = require("ui/widget/container/inputcontainer")

local UIManager       = require("ui/uimanager")

local _               = require("gettext")

local T               = require("ffi/util").template

local QuickPanel = InputContainer:extend{

    book = nil,

    chapters = nil,

    index = 1,

    cache_hint = "",

    font_size = 22,

    on_catalog = nil,

    on_cache = nil,

    on_stats = nil,

    on_night = nil,

    on_prev_chapter = nil,

    on_next_chapter = nil,

    on_seek_chapter = nil,

    on_reload = nil,

    on_sync = nil,

    on_settings = nil,

    on_shelf = nil,

    on_font = nil,

    on_close = nil,

}

local function scaled(px)

    return math.floor(px * (Screen:scaleBySize(1000) / 1000) + 0.5)

end

local function fillRound(bb, x, y, w, h, color, r)

    if w <= 0 or h <= 0 then return end

    local fn = Blitbuffer.isColor8(color) and bb.paintRoundedRect or bb.paintRoundedRectRGB32

    fn(bb, x, y, w, h, color, r or 0)

end

local function clamp(v, a, b)

    if v < a then return a end

    if v > b then return b end

    return v

end
-- ---------- 可点击的小图标 / 文字 ----------

local TapBox = InputContainer:extend{ widget = nil, width = nil, height = nil, callback = nil }

function TapBox:init()

    self.dimen = Geom:new{ w = self.width, h = self.height }

    self[1] = CenterContainer:new{

        dimen = Geom:new{ w = self.width, h = self.height },

        self.widget,

    }

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end

function TapBox:onTap()

    if self.callback then self.callback() end

    return true

end

local function iconBox(name, size, box_w, box_h, callback)

    local iw = IconWidget:new{ icon = name, width = size, height = size, alpha = true }

    return TapBox:new{

        widget = iw, width = box_w or size, height = box_h or size,

        callback = callback,

    }

end

local function textBox(text, face_size, color, box_w, box_h, callback)

    return TapBox:new{

        widget = TextWidget:new{

            text = text, face = Font:getFace("cfont", face_size), fgcolor = color,

        },

        width = box_w, height = box_h, callback = callback,

    }

end
-- ---------- 轨道滑块（灰色圆角轨道 + 白色圆形滑块） ----------

local SliderTrack = InputContainer:extend{

    width = nil, height = nil, ratio = 0, dark = false, on_seek = nil,

}

function SliderTrack:init()

    self.dimen = Geom:new{ w = self.width, h = self.height }

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end

function SliderTrack:paintTo(bb, x, y)

    self.dimen.x = x

    self.dimen.y = y

    local r = scaled(10)

    local track_h = self.dark and scaled(8) or scaled(6)

    local ty = y + math.floor((self.height - track_h) / 2)

    fillRound(bb, x, ty, self.width, track_h, Blitbuffer.COLOR_GRAY_D, track_h / 2)

    local fill_w = math.floor(self.width * clamp(self.ratio or 0, 0, 1))

    if self.dark and fill_w > 0 then

        fillRound(bb, x, ty, fill_w, track_h, Blitbuffer.COLOR_GRAY_4, track_h / 2)

    end

    local cx = x + math.max(r, math.min(self.width - r, fill_w))

    local cy = y + math.floor((self.height - 2 * r) / 2)

    fillRound(bb, cx - r, cy, 2 * r, 2 * r, Blitbuffer.COLOR_WHITE, r)

    bb:paintBorder(cx - r, cy, 2 * r, 2 * r, 1, Blitbuffer.COLOR_GRAY_6, r)

end

function SliderTrack:setRatio(ratio)

    self.ratio = clamp(ratio or 0, 0, 1)

    -- 只刷滑条自身区域
    UIManager:setDirty(self, "ui")

end

function SliderTrack:onTap(_arg, ges)

    if not self.on_seek or not ges or not ges.pos then return true end

    local x = (ges.pos.x or (self.dimen.x or 0)) - (self.dimen.x or 0)

    self.on_seek(clamp(x / math.max(1, self.width), 0, 1))

    return true

end
-- ---------- 图标网格里的一格 ----------

local GridCell = InputContainer:extend{

    icon = nil, label = nil, hint = nil,

    width = nil, height = nil, callback = nil,

}

function GridCell:init()

    local icon_size = scaled(26)

    local label = TextWidget:new{

        text = self.label or "",

        face = Font:getFace("cfont", scaled(12)),

        fgcolor = Blitbuffer.COLOR_BLACK,

        max_width = self.width - scaled(8),

    }

    local hint = TextWidget:new{

        text = self.hint or "",

        face = Font:getFace("cfont", scaled(9)),

        fgcolor = Blitbuffer.COLOR_GRAY_6,

        max_width = self.width - scaled(8),

    }

    self.hint_widget = hint

    local icon_widget

    if self.icon then

        local ok, w = pcall(function()

            return IconWidget:new{ icon = self.icon, width = icon_size, height = icon_size, alpha = true }

        end)

        if ok then icon_widget = w end

    end

    if not icon_widget then

        icon_widget = TextWidget:new{

            text = "·", face = Font:getFace("cfont", icon_size), fgcolor = Blitbuffer.COLOR_GRAY_6,

        }

    end

    self[1] = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = self.width, height = self.height,

        CenterContainer:new{

            dimen = Geom:new{ w = self.width, h = self.height },

            VerticalGroup:new{

                align = "center",

                icon_widget,

                VerticalSpan:new{ width = scaled(5) },

                label,

                hint,

            },

        },

    }

    self.dimen = Geom:new{ w = self.width, h = self.height }

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end

function GridCell:setHint(text)

    self.hint_widget:setText(text or "")

    -- 只刷这一格：原来整屏 setDirty("all") 会让缓存进度每更新一章就全屏闪一次
    UIManager:setDirty(self, "ui")

end

function GridCell:onTap()

    if self.callback then self.callback() end

    return true

end
-- ---------- 面板布局 ----------

function QuickPanel.computeLayout()

    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local card_w = math.min(sw - 2 * scaled(18), math.floor(sw * 0.88))

    local pad = scaled(20)

    local inner_w = card_w - 2 * pad - 2

    local top_pad = scaled(16)

    local header_h = scaled(34)

    local slider_h = scaled(46)

    local cell_h = scaled(92)

    local gaps = scaled(14) + scaled(10) + scaled(18) + 2 * scaled(4) + scaled(14)

    local card_h = top_pad + header_h + 2 * slider_h + 3 * cell_h + gaps + 2

    local left = math.floor((sw - card_w) / 2)

    -- 稍微偏下，跟参考图的浮动卡片位置接近

    local top = math.floor((sh - card_h) * 0.56)

    return {

        screen_w = sw, screen_h = sh,

        card_w = card_w, card_h = card_h,

        pad = pad, inner_w = inner_w,

        top_pad = top_pad, header_h = header_h, slider_h = slider_h,

        cell_w = math.floor(inner_w / 4), cell_h = cell_h,

        left = left, top = top,

    }

end
function QuickPanel:init()

    local L = QuickPanel.computeLayout()

    self.layout = L

    self.dimen = Geom:new{ x = 0, y = 0, w = L.screen_w, h = L.screen_h }

    if Device:hasKeys() then

        self.key_events.Close = { { Device.input.group.Back } }

    end

    local chapters = self.chapters or {}

    local total = #chapters

    local cur = math.max(1, math.min(self.index or 1, math.max(1, total)))

    self.font_size = self.font_size or 22

    -- 顶部信息条：书名 + N/M + ✕

    local title = TextWidget:new{

        text = (self.book and self.book.name) or _("阅读X"),

        face = Font:getFace("tfont", scaled(16)),

        fgcolor = Blitbuffer.COLOR_BLACK,

        max_width = math.floor(L.inner_w * 0.60),

    }

    local counter = TextWidget:new{

        text = T(_("%1 / %2"), tostring(cur), tostring(total)),

        face = Font:getFace("cfont", scaled(12)),

        fgcolor = Blitbuffer.COLOR_GRAY_6,

    }

    -- 关闭按钮与其它弹出页统一：纯黑 ✕、贴到卡片边框内侧
    local close_w = UICommon.closeButtonSize()

    local close_mark = UICommon.closeButtonAtEdge(

        function() self:close() end, L.pad)

    local header = HorizontalGroup:new{

        title,

        HorizontalSpan:new{ width = math.max(scaled(6),

            L.inner_w - close_w - scaled(10) - title:getSize().w - counter:getSize().w) },

        counter,

        HorizontalSpan:new{ width = scaled(10) },

        close_mark,

    }

    -- 第一条滑块：章节进度

    local chapter_ratio = total > 0 and clamp(cur / total, 0, 1) or 0

    local icon_w = scaled(30)

    local side_gap = scaled(12)

    local track_w = L.inner_w - 2 * icon_w - 2 * side_gap

    local chapter_track = SliderTrack:new{

        width = track_w, height = L.slider_h, ratio = chapter_ratio,

        on_seek = function(ratio)

            if self.on_seek_chapter then self.on_seek_chapter(ratio) end

        end,

    }

    self.chapter_track = chapter_track

    local row_chapter = HorizontalGroup:new{

        align = "center",

        iconBox("chevron.first", scaled(20), icon_w, L.slider_h,

            function() if self.on_prev_chapter then self.on_prev_chapter() end end),

        HorizontalSpan:new{ width = side_gap },

        chapter_track,

        HorizontalSpan:new{ width = side_gap },

        iconBox("chevron.last", scaled(20), icon_w, L.slider_h,

            function() if self.on_next_chapter then self.on_next_chapter() end end),

    }

    -- 第二条滑块：字号（深色轨道）

    local FONT_MIN, FONT_MAX = 12, 48

    local font_ratio = clamp((self.font_size - FONT_MIN) / (FONT_MAX - FONT_MIN), 0, 1)

    local a_badge = FrameContainer:new{

        bordersize = 1, radius = scaled(17),

        color = Blitbuffer.COLOR_GRAY_6,

        background = Blitbuffer.COLOR_WHITE,

        padding = 0, margin = 0,

        width = scaled(34), height = scaled(34),

        CenterContainer:new{

            dimen = Geom:new{ w = scaled(34), h = scaled(34) },

            TextWidget:new{

                text = "A", face = Font:getFace("cfont", scaled(15)),

                fgcolor = Blitbuffer.COLOR_BLACK,

            },

        },

    }

    local font_track = SliderTrack:new{

        width = track_w - scaled(10), height = L.slider_h, ratio = font_ratio, dark = true,

        on_seek = function(ratio)

            local size = math.floor(FONT_MIN + ratio * (FONT_MAX - FONT_MIN) + 0.5)

            self:applyFontDelta(size - self.font_size)

        end,

    }

    self.font_track = font_track

    self.FONT_MIN, self.FONT_MAX = FONT_MIN, FONT_MAX

    local row_font = HorizontalGroup:new{

        align = "center",

        a_badge,

        HorizontalSpan:new{ width = scaled(6) },

        textBox("−", scaled(20), Blitbuffer.COLOR_GRAY_6, scaled(22), L.slider_h,

            function() self:applyFontDelta(-2) end),

        HorizontalSpan:new{ width = scaled(10) },

        font_track,

        textBox("+", scaled(20), Blitbuffer.COLOR_GRAY_6, scaled(22), L.slider_h,

            function() self:applyFontDelta(2) end),

    }

    -- 3×4 图标网格

    local function cell(icon, label, cb, hint)

        return GridCell:new{

            icon = icon, label = label, hint = hint or "",

            width = L.cell_w, height = L.cell_h, callback = cb,

        }

    end

    local cache_cell

    cache_cell = cell("move.down", _("缓存"), function()

        if self.on_cache then self.on_cache() end

    end, self.cache_hint or "")

    self.cache_cell = cache_cell

    local function closeThen(cb)

        return function()

            self:close()

            if cb then cb() end

        end

    end

    local grid_rows = {

        HorizontalGroup:new{

            cell("book.opened", _("目录"), closeThen(self.on_catalog)),

            cache_cell,

            cell("info", _("阅读记录"), closeThen(self.on_stats)),

            cell("appbar.contrast", _("夜晚"), function()

                if self.on_night then self.on_night() end

            end),

        },

        HorizontalGroup:new{

            cell("chevron.left", _("上一章"), function()

                if self.on_prev_chapter then self.on_prev_chapter() end

            end),

            cell("chevron.right", _("下一章"), function()

                if self.on_next_chapter then self.on_next_chapter() end

            end),

            cell("cre.render.reload", _("刷新"), closeThen(self.on_reload)),

            cell("wifi", _("同步进度"), function()

                if self.on_sync then self.on_sync() end

            end),

        },

        HorizontalGroup:new{

            cell("appbar.settings", _("设置"), closeThen(self.on_settings)),

            cell("home", _("书架"), closeThen(self.on_shelf)),

            cell("appbar.textsize", _("缩小"), function() self:applyFontDelta(-2) end),

            cell("plus", _("放大"), function() self:applyFontDelta(2) end),

        },

    }

    local content = VerticalGroup:new{

        align = "left",

        header,

        VerticalSpan:new{ width = scaled(14) },

        row_chapter,

        VerticalSpan:new{ width = scaled(10) },

        row_font,

        VerticalSpan:new{ width = scaled(18) },

        grid_rows[1],

        VerticalSpan:new{ width = scaled(4) },

        grid_rows[2],

        VerticalSpan:new{ width = scaled(4) },

        grid_rows[3],

    }

    local card = FrameContainer:new{

        bordersize = 1,

        radius = scaled(18),

        color = Blitbuffer.COLOR_GRAY_D,

        background = Blitbuffer.COLOR_WHITE,

        padding = 0, margin = 0,

        width = L.card_w, height = L.card_h,

        VerticalGroup:new{

            align = "left",

            VerticalSpan:new{ width = L.top_pad },

            HorizontalGroup:new{

                HorizontalSpan:new{ width = L.pad },

                content,

            },

            VerticalSpan:new{ width = scaled(14) },

        },

    }

    self._card = card

    -- 只保留一个子 widget 用于事件传播；绘制由 paintTo 自己完成

    -- （WidgetContainer:paintTo 只画 self[1]，但 propagateEvent 会遍历全部子项）

    self[1] = card

    self._L = L

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end

-- ---------- 面板行为（重建补回：这批方法在迁移拼接时丢失） ----------

-- 全屏浅色遮罩，让正文“淡出”，圆角卡片浮在指定位置
function QuickPanel:paintTo(bb, x, y)

    local L = self._L

    self.dimen.x = x

    self.dimen.y = y

    -- 半透明压暗：保留弹窗前的正文/书架画面当背景（原整屏灰底会盖掉内容）
    UICommon.dimBackdrop(bb, x, y, L.screen_w, L.screen_h)

    if self._card then

        self._card:paintTo(bb, x + L.left, y + L.top)

    end

end

-- 点卡片外面才收起
function QuickPanel:onTap(_arg, ges)

    local card = self._card

    if card and card.dimen and ges and ges.pos and card.dimen:contains(ges.pos) then

        return true

    end

    self:close()

    return true

end

function QuickPanel:close()

    local cb = self.on_close

    UIManager:close(self)

    UIManager:setDirty("all", "full")

    if cb then cb() end

end

function QuickPanel:onClose()

    self:close()

    return true

end

function QuickPanel:applyFontDelta(delta)

    if not delta or delta == 0 then return end

    self.font_size = clamp(self.font_size + delta, self.FONT_MIN or 12, self.FONT_MAX or 48)

    if self.font_track then

        self.font_track:setRatio((self.font_size - (self.FONT_MIN or 12)) /

            ((self.FONT_MAX or 48) - (self.FONT_MIN or 12)))

    end

    if self.on_font then self.on_font(delta) end

end

function QuickPanel:setCacheHint(text)

    if not self.cache_cell then return end

    self.cache_cell:setHint(text or "")

end

return QuickPanel
