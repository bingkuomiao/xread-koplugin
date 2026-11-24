-- xread.koplugin/xread/shelf_grid.lua

-- 仿微信读书的紧凑网格书架：4 列封面、细标题栏、白底小字、底部分页。

-- 自包含，不依赖 weread 插件。

local Blitbuffer    = require("ffi/blitbuffer")

local Geom          = require("ui/geometry")

local Font          = require("ui/font")

local Screen        = require("device").screen

local Device        = require("device")

local GestureRange  = require("ui/gesturerange")

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
local GridShelf = FocusManager:extend{

    books = nil,

    title = nil,

    cover_paths = nil,

    cover_loading = nil,

    on_select = nil,

    on_hold = nil,

    on_page_changed = nil,

    page = 1,

}

local function scaled(px)

    return math.floor(px * (Screen:scaleBySize(1000) / 1000) + 0.5)

end

-- 自己按字符宽度折成两行，避免 TextBoxWidget 在固定高度下只显示一行。

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

-- 统一给 main.lua 的封面预取使用，避免两边算出的每页数量不一致。

function GridShelf.computeLayout(num_books)

    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local header_h = scaled(36)

    local pagebar_h = scaled(46)

    local content_h = sh - header_h - pagebar_h - scaled(18)

    local columns = 4

    if num_books and num_books > 0 and num_books < columns then

        columns = num_books

    end

    local rows = 3

    if num_books and num_books > 0 then

        rows = math.max(1, math.min(rows, math.ceil(num_books / columns)))

    end

    local cell_w = math.floor(sw / columns)

    local cell_h = math.floor(content_h / rows)

    local pad = scaled(9)

    local gap = scaled(5)

    local title_h = scaled(34)

    local avail_w = cell_w - 2 * pad - gap

    local avail_h = cell_h - 2 * pad - gap - title_h - scaled(8)

    local cover_h = math.max(1, avail_h)

    local cover_w = math.floor(cover_h * 0.75 + 0.5)

    if cover_w > avail_w then

        cover_w = math.max(1, avail_w)

        cover_h = math.floor(cover_w / 0.75 + 0.5)

    end

    return {

        screen_w = sw, screen_h = sh,

        header_h = header_h, pagebar_h = pagebar_h, content_h = content_h,

        columns = columns, rows = rows,

        cell_w = cell_w, cell_h = cell_h,

        pad = pad, gap = gap, title_h = title_h,

        cover_w = cover_w, cover_h = cover_h,

        page_size = columns * rows,

    }

end
-- 单个封面格子：白底、细边框、两行小字书名。

local CoverCell = InputContainer:extend{

    book = nil,

    layout = nil,

    cover_path = nil,

    cover_loading = false,

    callback = nil,

    hold_callback = nil,

    show_parent = nil,

}

function CoverCell:init()

    local L = self.layout

    local pad = L.pad

    local title_w = L.cell_w - 2 * pad

    local cover_widget

    if self.cover_path then

        local ok, img = pcall(function()

            local w = ImageWidget:new{

                file = self.cover_path,

                width = L.cover_w,

                height = L.cover_h,

            }

            w:getSize()

            return w

        end)

        if ok and img then cover_widget = img end

    end

    if not cover_widget then

        cover_widget = FrameContainer:new{

            bordersize = 1,

            color = Blitbuffer.COLOR_GRAY_D,

            background = Blitbuffer.COLOR_WHITE,

            width = L.cover_w,

            height = L.cover_h,

            CenterContainer:new{

                dimen = Geom:new{ w = L.cover_w, h = L.cover_h },

                TextWidget:new{

                    text = self.cover_loading and _("读取中…") or _("无封面"),

                    face = Font:getFace("cfont", scaled(14)),

                    fgcolor = Blitbuffer.COLOR_GRAY_B,

                    max_width = L.cover_w - scaled(12),

                },

            },

        }

    end

    local title = self.book.name or self.book.title or "?"

    local face = Font:getFace("cfont", scaled(13))

    local title_w = L.cell_w - scaled(8)

    local line1, line2 = wrapTitle(title, face, title_w)

    local line_h = math.floor(face.size * 1.18)

    local function titleLine(text)

        return CenterContainer:new{

            dimen = Geom:new{ w = title_w, h = line_h },

            TextWidget:new{

                text = text,

                face = face,

                padding = 0,

                max_width = title_w,

                fgcolor = Blitbuffer.COLOR_BLACK,

            },

        }

    end

    local title_widget = VerticalGroup:new{

        align = "center",

        titleLine(line1),

        titleLine(line2),

    }

    local inner = VerticalGroup:new{

        align = "center",

        VerticalSpan:new{ width = pad },

        cover_widget,

        VerticalSpan:new{ width = L.gap },

        title_widget,

    }

    self.frame = FrameContainer:new{

        bordersize = 1,

        color = Blitbuffer.COLOR_WHITE,

        background = Blitbuffer.COLOR_WHITE,

        padding = 0,

        margin = 0,

        width = L.cell_w,

        height = L.cell_h,

        show_parent = self.show_parent,

        inner,

    }

    self[1] = CenterContainer:new{

        dimen = Geom:new{ w = L.cell_w, h = L.cell_h },

        self.frame,

    }

    self.dimen = Geom:new{ w = L.cell_w, h = L.cell_h }

    self.ges_events = {

        TapCell = { GestureRange:new{ ges = "tap", range = self.dimen } },

        HoldCell = { GestureRange:new{ ges = "hold", range = self.dimen } },

    }

end

function CoverCell:onTapCell()

    if self.callback then self.callback() end

    return true

end

function CoverCell:onHoldCell()

    if self.hold_callback then

        self.hold_callback()

        return true

    end

    return false

end

function CoverCell:onFocus()

    -- 只描边，不再把整格涂成灰块。

    self.frame.color = Blitbuffer.COLOR_GRAY_6

    return true

end

function CoverCell:onUnfocus()

    self.frame.color = Blitbuffer.COLOR_WHITE

    return true

end

function GridShelf:init()

    local books = self.books or {}

    local L = GridShelf.computeLayout(#books)

    self.layout = L

    self.dimen = Geom:new{ x = 0, y = 0, w = L.screen_w, h = L.screen_h }

    if Device:hasKeys() then

        self.key_events.Close = { { Device.input.group.Back } }

    end

    local page_size = L.page_size

    local page_count = math.max(1, math.ceil(#books / page_size))

    if self.page < 1 then self.page = 1 end

    if self.page > page_count then self.page = page_count end

    self.page_size = page_size

    self.page_count = page_count

    local first = (self.page - 1) * page_size + 1

    local last = math.min(#books, first + page_size - 1)
    -- 细顶栏：小字号 + 数量 + 分隔线，不再是一整行巨型标题。

    local header_text = TextWidget:new{

        text = self.title or _("我的书架"),

        face = Font:getFace("tfont", scaled(14)),

        fgcolor = Blitbuffer.COLOR_BLACK,

        max_width = math.floor(L.screen_w * 0.6),

    }

    local count_text = TextWidget:new{

        text = T(_("共 %1 本 · 长按封面看目录"), tostring(#books)),

        face = Font:getFace("cfont", scaled(11)),

        fgcolor = Blitbuffer.COLOR_GRAY_6,

    }

    local header = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.screen_w, height = L.header_h,

        VerticalGroup:new{

            align = "left",

            CenterContainer:new{

                dimen = Geom:new{ w = L.screen_w, h = L.header_h - 1 },

                HorizontalGroup:new{

                    header_text,

                    HorizontalSpan:new{ width = scaled(12) },

                    count_text,

                },

            },

            LineWidget:new{

                dimen = Geom:new{ w = L.screen_w, h = 1 },

                background = Blitbuffer.COLOR_GRAY_D,

            },

        },

    }

    local content = VerticalGroup:new{ align = "left" }

    local focus_rows = {}

    local idx = 0

    for r = 1, L.rows do

        local visual_row, focus_row = {}, {}

        for c = 1, L.columns do

            local i = first + idx

            if i <= last then

                local cell = CoverCell:new{

                    book = books[i],

                    layout = L,

                    cover_path = self.cover_paths and self.cover_paths[books[i]] or nil,

                    cover_loading = self.cover_loading and self.cover_loading[books[i]] == true,

                    show_parent = self,

                    callback = function()

                        if self.on_select then self.on_select(books[i]) end

                    end,

                    hold_callback = function()

                        if self.on_hold then self.on_hold(books[i]) end

                    end,

                }

                table.insert(visual_row, cell)

                table.insert(focus_row, cell)

            else

                table.insert(visual_row, HorizontalSpan:new{ width = L.cell_w })

            end

            idx = idx + 1

        end

        table.insert(content, HorizontalGroup:new(visual_row))

        table.insert(focus_rows, focus_row)

    end
    -- 底部分页：参考微信读书，只保留两个大按钮。

    local btn_margin = scaled(7)

    local btn_h = scaled(26)

    local half = math.floor(L.screen_w / 2)

    local function newNavButton(text, width, enabled, callback)

        local btn = Button:new{

            text = text,

            width = width,

            height = btn_h,

            enabled = enabled,

            callback = callback,

            text_font_size = scaled(14),

            bordersize = 1,

            radius = 0,

            margin = 0,

            background = Blitbuffer.COLOR_WHITE,

            color = Blitbuffer.COLOR_GRAY_D,

        }

        return btn

    end

    local prev = newNavButton(_("上一页"), half - 2, self.page > 1,

        function() self:onPageChanged(self.page - 1) end)

    local next = newNavButton(_("下一页"), L.screen_w - half - 2, self.page < page_count,

        function() self:onPageChanged(self.page + 1) end)

    local page_bar = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.screen_w, height = L.pagebar_h,

        VerticalGroup:new{

            align = "center",

            VerticalSpan:new{ width = btn_margin },

            HorizontalGroup:new{

                prev, HorizontalSpan:new{ width = 4 }, next,

            },

            VerticalSpan:new{ width = math.max(0, L.pagebar_h - btn_margin - btn_h) },

        },

    }

    self._page_buttons = { prev, next }

    table.insert(focus_rows, self._page_buttons)

    self[1] = FrameContainer:new{

        background = Blitbuffer.COLOR_WHITE,

        bordersize = 0, padding = 0, margin = 0,

        dimen = self.dimen:copy(),

        VerticalGroup:new{

            align = "left",

            header,

            content,

            page_bar,

        },

    }

    self.layout = focus_rows

    self._focus_rows = focus_rows

    -- 触摸为主的设备不预设焦点，避免打开时第一本被灰底高亮。

end

function GridShelf:onPageChanged(new_page)

    if self.on_page_changed then self.on_page_changed(new_page) end

    return true

end

return GridShelf
