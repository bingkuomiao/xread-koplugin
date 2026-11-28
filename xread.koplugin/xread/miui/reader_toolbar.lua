local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local TransientGuard = require("xread.miui.transient_guard")
local DialogTransition = require("xread.miui.dialog_transition")
local Skin = require("xread.miui.reader_skin")
local Prims = require("xread.miui.ui_primitives")
local Ui = require("xread.miui.ui_components")
local UiScale = require("xread.miui.ui_scale")
local U = require("xread.miui.util")

local Screen = Device.screen
local live_toolbar

local OffsetContainer = Prims.OffsetContainer
local TapBox = Prims.TapBox

local function centered_text(text, width, height, face, options)
    options = options or {}
    return Ui.textbox(tostring(text or ""), width, height, face, {
        bold = options.bold == true,
        alignment = "center",
        halign = "center",
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    })
end

local function icon_box(icon, width, height, enabled, size)
    return Ui.icon(tostring(icon or ""), width, height, math.min(width, height, size or Skin.dp(22, 19, 30)), {
        icon_key = tostring(icon or ""),
        face = Skin.face("cfont", 17.2, 23.2, 14.4),
        fgcolor = enabled ~= false and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local function circle_icon_button(icon, width, height, enabled)
    local circle = math.min(Skin.dp(36, 31, 46), math.floor(height * .78), math.floor(width * .78))
    local frame = Skin.frame(circle, circle, {
        bordersize = Skin.line("thin"), padding = 0, radius = math.floor(circle / 2),
        background = Blitbuffer.COLOR_WHITE,
        color = enabled ~= false and Blitbuffer.COLOR_GRAY or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY),
    }, icon_box(icon, circle, circle, enabled, math.floor(circle * .60)))
    return CenterContainer:new{dimen = Geom:new{w = width, h = height}, frame}
end

local function dynamic_value(text, width, height, face, bold)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = bold == true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return widget, CenterContainer:new{dimen = Geom:new{w = width, h = height}, widget}
end

local SliderBar = InputContainer:extend{
    dimen = nil,
    min = 0,
    max = 100,
    value = 0,
    track_w = 1,
    owner = nil,
    on_change = nil,
    value_widget = nil,
    value_suffix = "",
    last_refresh = 0,
}
function SliderBar:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.min = tonumber(self.min) or 0
    self.max = tonumber(self.max) or 100
    if self.max <= self.min then self.max = self.min + 1 end
    self.value = math.max(self.min, math.min(self.max, tonumber(self.value) or self.min))
    self.slide_dimen = Geom:new{x = 0, y = 0, w = math.max(1, self.track_w), h = self.dimen.h}
    self.ges_events = {
        TapSlide = {GestureRange:new{ges = "tap", range = self.slide_dimen}},
        PanSlide = {GestureRange:new{ges = "pan", range = self.slide_dimen}},
    }
end
function SliderBar:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function SliderBar:_ratio()
    return math.max(0, math.min(1, (self.value - self.min) / math.max(1, self.max - self.min)))
end
function SliderBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.slide_dimen.x, self.slide_dimen.y = x, y
    local track_h = math.max(1, Skin.line("medium"))
    local marker = Skin.dp(9, 8, 12)
    local bar_y = y + math.floor((self.dimen.h - track_h) / 2)
    local ratio = self:_ratio()
    local fill_w = math.floor(self.track_w * ratio)
    local marker_x = x + math.floor((self.track_w - marker) * ratio)
    bb:paintRect(x, bar_y, self.track_w, track_h, Blitbuffer.COLOR_GRAY)
    if fill_w > 0 then bb:paintRect(x, bar_y, math.min(self.track_w, fill_w), track_h, Blitbuffer.COLOR_BLACK) end
    bb:paintRect(marker_x, y + math.floor((self.dimen.h - marker) / 2), marker, marker, Blitbuffer.COLOR_BLACK)
end
function SliderBar:_refresh(force)
    if not self.owner or self.owner.closed then return end
    local interval = Screen.low_pan_rate and .10 or .04
    -- 墙面时钟而不是 os.clock：后者是 CPU 时间，UI 卡住时不增长，
    -- 会把拖动刷新的节流窗口拖成几十秒（滑条看上去不跟手）
    local now = U.now()
    if not force and now - (tonumber(self.last_refresh) or 0) < interval then return end
    self.last_refresh = now
    local region=self.refresh_dimen or self.owner.panel_dimen
    UIManager:setDirty(self.owner, function() return "ui", Skin.expand_region(region, Skin.dp(2, 2, 3)) end)
end
function SliderBar:setValue(value, force)
    self.value = math.max(self.min, math.min(self.max, tonumber(value) or self.value))
    if self.value_widget and type(self.value_widget.setText) == "function" then
        self.value_widget:setText(tostring(math.floor(self.value + .5)) .. tostring(self.value_suffix or ""))
    end
    self:_refresh(force ~= false)
end
function SliderBar:_set_from_position(ges, force)
    if not (self.owner and self.owner._controls_ready==true) then return true end
    local pos = ges and ges.pos
    if not pos then return false end
    local ratio = math.max(0, math.min(1, (pos.x - self.dimen.x) / math.max(1, self.track_w)))
    local target = math.floor(self.min + ratio * (self.max - self.min) + .5)
    local actual = target
    if self.on_change then
        local ok, result = pcall(self.on_change, target, force and "commit" or "drag")
        if not ok then
            logger.warn("[MiuRead][ReaderToolbar] slider action failed", tostring(result))
            return true
        end
        if result == false then return true end
        if tonumber(result) then actual = tonumber(result) end
    end
    self:setValue(actual, force)
    return true
end
function SliderBar:onTapSlide(_, ges) return self:_set_from_position(ges, true) end
function SliderBar:onPanSlide(_, ges)
    if not (self.owner and self.owner._controls_ready==true) then return true end
    local direction=tostring(ges and ges.direction or "")
    local horizontal=direction=="east" or direction=="west"
    local relative=ges and ges.relative
    if not horizontal and relative then
        local dx=math.abs(tonumber(relative.x) or 0)
        local dy=math.abs(tonumber(relative.y) or 0)
        horizontal=dx>=Skin.dp(8,6,12) and dx>dy*1.25
    end
    if not horizontal then return true end
    return self:_set_from_position(ges, false)
end
function SliderBar:handleEvent(event) return InputContainer.handleEvent(self, event) end

local function text_pixel_width(text, face, bold)
    local widget = TextWidget:new{
        text = tostring(text or ""), face = face, bold = bold == true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local size = widget:getSize()
    return tonumber(size and size.w) or 0
end

local function fit_line(text, width, face, bold, ellipsis)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    if text_pixel_width(text, face, bold) <= width then return text end
    local suffix = ellipsis == false and "" or "…"
    local length = U.utf8_len(text)
    local low, high, best = 0, length, 0
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = U.utf8_sub(text, 1, middle) .. suffix
        if text_pixel_width(candidate, face, bold) <= width then
            best = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return U.utf8_sub(text, 1, best) .. suffix
end

local function fit_two_lines(text, width, face, bold)
    text = tostring(text or ""):gsub("[\r\n]+", " ")
    if text_pixel_width(text, face, bold) <= width then return text end
    local length = U.utf8_len(text)
    local low, high, best = 1, length, 1
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = U.utf8_sub(text, 1, middle)
        if text_pixel_width(candidate, face, bold) <= width then
            best = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    local first = U.utf8_sub(text, 1, best)
    local rest = U.utf8_sub(text, best + 1)
    if rest == "" then return first end
    return first .. "\n" .. fit_line(rest, width, face, bold, true)
end

-- 状态行每个格子的自然宽度：图标 + 图标/文字间距 + 文字 + 左右内边距。
-- 用它替代「按 weight 平分」，让相邻格子之间的空白完全一致。
local function status_intrinsic_width(entry, height)
    entry = type(entry) == "table" and entry or {}
    if entry.icon_only == true and entry.icon then
        return Skin.dp(24, 21, 32)
    end
    local icon_w = entry.icon and Skin.dp(29, 25, 38) or 0
    local gap = entry.icon and Skin.dp(4, 3, 6) or 0
    local face = entry.multiline
        and Skin.face("cfont", 9.8, 12.8, 8.4)
        or Skin.face("cfont", 10.5, 13.8, 8.9)
    local label = tostring(entry.label or ""):gsub("[\r\n]+", " ")
    local tw = text_pixel_width(label, face, entry.bold ~= false or entry.alert == true)
    if entry.multiline then tw = math.ceil(tw * 0.62) end
    return icon_w + gap + tw + Skin.dp(6, 5, 9) * 2
end

local function status_item(entry, width, height, callback, hold_callback, owner, ref_key)
    entry = type(entry) == "table" and entry or {}
    local enabled = entry.enabled ~= false
    -- icon_only：只画图标、不占文字位（「更多」用它 —— 首页 header 就只有一个 ⋯，
    -- 以前这里图标 + 文字「更多」一起画，看起来像有两个「更多」）
    local icon_only = entry.icon_only == true and entry.icon ~= nil
    local icon_w = entry.icon and Skin.dp(29, 25, 38) or 0
    local gap = entry.icon and Skin.dp(4, 3, 6) or 0
    local text_w = math.max(1, width - icon_w - gap)
    local text_align = entry.text_align or (entry.icon and "left" or "center")
    local bold = entry.bold ~= false or entry.alert == true
    local label_face = entry.multiline
        and Skin.face("cfont", 9.8, 12.8, 8.4)
        or Skin.face("cfont", 10.5, 13.8, 8.9)
    -- 一律单行：原来用 TextBoxWidget 自动折行，昵称一长就折成「首页 昵 / 称」，
    -- 看着像「首页」和昵称挤在一起。这里先按可用宽度截断，再补省略号。
    local function format_label(value)
        local raw = tostring(value or ""):gsub("[\r\n]+", " ")
        if entry.multiline then return fit_two_lines(raw, text_w, label_face, bold) end
        return fit_line(raw, text_w, label_face, bold, true)
    end
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = callback,
        hold_callback = hold_callback,
    }
    if icon_only then
        tap[1] = CenterContainer:new{
            dimen = Geom:new{w = width, h = height},
            icon_box(entry.icon, width, height, enabled, Skin.dp(21, 18, 28)),
        }
        return tap
    end
    -- multiline（Wi-Fi 这种要折成两行的）仍用 TextBoxWidget；其余一律 TextWidget
    -- 单行显示：TextBoxWidget 会自己折行，昵称稍长就变成「首页 昵 / 称」。
    local label_widget
    if entry.multiline then
        label_widget = TextBoxWidget:new{
            text = format_label(entry.label or ""),
            face = label_face,
            bold = bold,
            width = text_w,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = text_align,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }
    else
        label_widget = TextWidget:new{
            text = format_label(entry.label or ""),
            face = label_face,
            bold = bold,
            max_width = text_w,
            truncate_with_ellipsis = true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }
    end
    local label_box = Ui.align(label_widget, text_w, height, text_align, "center")
    if owner and ref_key then
        owner._text_refs[ref_key] = label_widget
        owner._text_formatters[ref_key] = format_label
    end
    local content = HorizontalGroup:new{
        align = "center",
        entry.icon and icon_box(entry.icon, icon_w, height, enabled, Skin.dp(20, 17, 26)) or HorizontalSpan:new{width = 0},
        entry.icon and HorizontalSpan:new{width = gap} or HorizontalSpan:new{width = 0},
        label_box,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, content}
    return tap
end

local function plain_action_item(entry, width, height, activate, hold_activate)
    entry = type(entry) == "table" and entry or {}
    local enabled = entry.enabled ~= false
    -- The first reader action row mixes several SVG silhouettes. Give every
    -- icon the same canvas, then compensate only for each glyph's intrinsic
    -- whitespace so their visible strokes share one baseline and visual size.
    local icon_h = math.floor(height * .60)
    local label_h = math.max(1, height - icon_h)
    local base_icon_size = math.min(Skin.dp(31, 27, 40), math.floor(icon_h * .80))
    local icon_scale = math.max(.75, math.min(1.35, tonumber(entry.icon_scale) or 1))
    local icon_size = math.min(math.floor(icon_h * .94), math.floor(base_icon_size * icon_scale + .5))
    local icon_widget = icon_box(entry.icon or entry.icon_key, width, icon_h, enabled, icon_size)
    local nudge = tonumber(entry.icon_nudge_y) or 0
    if nudge ~= 0 then
        icon_widget = OffsetContainer:new{x_off = 0, y_off = math.floor(nudge), icon_widget}
    end
    local content = VerticalGroup:new{
        align = "center",
        icon_widget,
        centered_text(entry.label or "", width, label_h,
            Skin.face("cfont", 10.4, 13.8, 8.8), {
                bold = entry.active == true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() activate(entry.callback, entry.label or "功能") end,
        hold_callback = entry.hold_callback and function() hold_activate(entry.hold_callback, entry.label or "功能") end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, content}
    return tap
end

local function compact_action_item(entry, width, height, activate, hold_activate)
    entry = type(entry) == "table" and entry or {}
    local enabled = entry.enabled ~= false
    -- 与上一行图标（plain_action_item）同轴：图标上、文字下，整格居中
    local icon_h = math.floor(height * .58)
    local label_h = math.max(1, height - icon_h)
    local icon_size = math.min(math.floor(icon_h * .82), Skin.dp(23, 20, 30))
    local content = VerticalGroup:new{
        align = "center",
        icon_box(entry.icon or entry.icon_key, width, icon_h, enabled, icon_size),
        Ui.textbox(tostring(entry.label or ""), width, label_h,
            Skin.face("cfont", 10.1, 13.4, 8.6), {
                alignment = "center", halign = "center", bold = entry.active == true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() activate(entry.callback, entry.label or "功能") end,
        hold_callback = entry.hold_callback and function()
            hold_activate(entry.hold_callback, entry.label or "功能")
        end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, content}
    return tap
end

local Toolbar = InputContainer:extend{
    name = "miuread_reader_toolbar",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    -- Full-screen gesture capture, partial opaque ink frame.
    covers_fullscreen = false,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    action_locked = false,
}

function Toolbar:handleEvent(event) return InputContainer.handleEvent(self, event) end

function Toolbar:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Toolbar:_activate(action, label)
    if self.closed or self.action_locked or self._controls_ready~=true then return true end
    self.action_locked = true
    logger.info("[MiuRead][ReaderToolbar] tapped", tostring(label or "unknown"))
    return self:_close(action)
end

function Toolbar:_activate_hold(action, label)
    if self.closed or self.action_locked or self._controls_ready~=true then return true end
    self.action_locked = true
    logger.info("[MiuRead][ReaderToolbar] held", tostring(label or "unknown"))
    return self:_close(action)
end

function Toolbar:_inline(action, label, value_widget, suffix)
    if self.closed or self._controls_ready~=true or type(action) ~= "function" then return true end
    local ok, result = pcall(action)
    if not ok then
        logger.warn("[MiuRead][ReaderToolbar] inline action failed", tostring(label or "unknown"), tostring(result))
        return true
    end
    if result ~= false and value_widget and type(value_widget.setText) == "function" and result ~= nil then
        value_widget:setText(tostring(result) .. tostring(suffix or ""))
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen, Skin.dp(2, 2, 3)) end)
    return true
end

function Toolbar:_divider(root, x, y, width, thickness)
    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        Skin.divider(width, (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY), thickness),
    }
end

function Toolbar:_top_status_row(root, header, x, y, width, height)
    header = type(header) == "table" and header or {}
    local has_bluetooth = header.bluetooth_visible == true
    local entries, callbacks, holds, ref_keys
    -- 昵称单独占一格（跟在「首页」后面那一格），不再拼进 home_label：
    -- 拼在一起时只要昵称稍长就会折行成「首页 昵 / 称」，看着像挤在一起。
    -- 「更多」只画 ⋯ 图标（icon_only），与首页 header 一致。
    if has_bluetooth then
        entries = {
            {icon = "home", label = header.home_label or "首页", enabled = type(header.home_callback) == "function", bold = true, weight = 1.0},
            {label = header.nickname_label or "", enabled = true, text_align = "center", bold = true, weight = 1.2},
            {icon = "wifi", label = header.wifi_label or "Wi-Fi", enabled = type(header.wifi_callback) == "function", alert = header.wifi_alert == true, bold = true, multiline = true, weight = 1.1},
            {icon = "bluetooth", label = header.bluetooth_label or "蓝牙", enabled = type(header.bluetooth_callback) == "function", bold = true, weight = 1.0},
            {icon = "sync", label = header.sync_label or "同步", enabled = type(header.sync_callback) == "function", alert = header.sync_alert == true, bold = true, weight = 1.15},
            {label = header.time_label or "", enabled = true, text_align = "center", bold = true, weight = 0.9},
            {icon = "battery", label = header.battery_label or "", enabled = true, bold = true, weight = 1.05},
            {icon = "menu", icon_only = true, enabled = type(header.more_callback) == "function", weight = 0.62},
        }
        callbacks = {
            function() self:_activate(header.home_callback, "首页") end,
            nil,
            function() self:_activate(header.wifi_callback, "Wi-Fi") end,
            function() self:_activate(header.bluetooth_callback, "蓝牙") end,
            function() self:_activate(header.sync_callback, "同步") end,
            nil,nil,
            function() self:_activate(header.more_callback, "更多") end,
        }
        holds = {
            type(header.home_hold_callback) == "function" and function() self:_activate_hold(header.home_hold_callback, "首页 设置") end or nil,
            nil,
            type(header.wifi_hold_callback) == "function" and function() self:_activate_hold(header.wifi_hold_callback, "Wi-Fi 设置") end or nil,
            type(header.bluetooth_hold_callback) == "function" and function() self:_activate_hold(header.bluetooth_hold_callback, "蓝牙设备") end or nil,
            nil,nil,nil,nil,
        }
        ref_keys = {"home","nickname","wifi","bluetooth","sync","time","battery","more"}
    else
        entries = {
            {icon = "home", label = header.home_label or "首页", enabled = type(header.home_callback) == "function", bold = true, weight = 1.0},
            {label = header.nickname_label or "", enabled = true, text_align = "center", bold = true, weight = 1.2},
            {icon = "wifi", label = header.wifi_label or "Wi-Fi", enabled = type(header.wifi_callback) == "function", alert = header.wifi_alert == true, bold = true, multiline = true, weight = 1.1},
            {icon = "sync", label = header.sync_label or "同步", enabled = type(header.sync_callback) == "function", alert = header.sync_alert == true, bold = true, weight = 1.15},
            {label = header.time_label or "", enabled = true, text_align = "center", bold = true, weight = 0.9},
            {icon = "battery", label = header.battery_label or "", enabled = true, bold = true, weight = 1.05},
            {icon = "menu", icon_only = true, enabled = type(header.more_callback) == "function", weight = 0.62},
        }
        callbacks = {
            function() self:_activate(header.home_callback, "首页") end,
            nil,
            function() self:_activate(header.wifi_callback, "Wi-Fi") end,
            function() self:_activate(header.sync_callback, "同步") end,
            nil,nil,
            function() self:_activate(header.more_callback, "更多") end,
        }
        holds = {
            type(header.home_hold_callback) == "function" and function() self:_activate_hold(header.home_hold_callback, "首页 设置") end or nil,
            nil,
            type(header.wifi_hold_callback) == "function" and function() self:_activate_hold(header.wifi_hold_callback, "Wi-Fi 设置") end or nil,
            nil,nil,nil,nil,
        }
        ref_keys = {"home","nickname","wifi","sync","time","battery","more"}
    end
    -- 统一间距布局：每格按自己的自然宽度占位，剩余的空白平均分配到相邻格子之间。
    -- 原来按 weight 分格，昵称格比「首页/Wi-Fi」宽，图标之间的空白就忽大忽小；
    -- 现在「首页」「昵称」「Wi-Fi」「同步」「时间」「电量」「⋯」两两间距一致。
    local count = #entries
    local min_gap = Skin.dp(6, 5, 9)
    local widths, content_total = {}, 0
    for i, entry in ipairs(entries) do
        widths[i] = status_intrinsic_width(entry, height)
        content_total = content_total + widths[i]
    end
    local gap = count > 1 and math.floor((width - content_total) / (count - 1)) or 0
    if gap < min_gap then
        -- 窄屏放不下：先压到最小间距，再按比例缩窄每格（status_item 内部会截断文字）
        gap = min_gap
        local need = content_total + gap * (count - 1)
        if need > width then
            local scale = width / math.max(1, need)
            content_total = 0
            for i = 1, count do
                widths[i] = math.max(Skin.dp(22, 20, 28), math.floor(widths[i] * scale))
                content_total = content_total + widths[i]
            end
            gap = count > 1 and math.max(0, math.floor((width - content_total) / (count - 1))) or 0
        end
    end
    local used = 0
    for index, entry in ipairs(entries) do
        local w = widths[index]
        if index == count then w = math.max(1, width - used) end
        root[#root + 1] = OffsetContainer:new{
            x_off = x + used, y_off = y,
            status_item(entry, w, height, callbacks[index], holds[index], self, ref_keys[index]),
        }
        used = used + w + gap
    end
end

function Toolbar:_title_row(root, header, x, y, width, height)
    header = type(header) == "table" and header or {}
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = type(header.book_callback) == "function",
        callback = function() self:_activate(header.book_callback, "当前书籍") end,
    }
    local title_box=centered_text(header.title or "正在阅读", width, height,
        Skin.face("cfont", 13.7, 18.0, 11.3), {bold = true})
    if title_box and title_box[1] then self._text_refs.title=title_box[1] end
    tap[1] = title_box
    root[#root + 1] = OffsetContainer:new{x_off = x, y_off = y, tap}
end

function Toolbar:_chapter_row(root, header, x, y, width, height)
    header = type(header) == "table" and header or {}
    -- 左格放章节名，要能放下「第002章 拜师徐庶」这种 8-10 字标题；
    -- 原来只给 20%，标题一长就折成两行（截图里「第002章 拜师徐 / 庶」）。
    -- 中格章号固定「第 N / M 章」，右格百分比贴右，三段左右贴齐内容区。
    local left_w = math.floor(width * .34)
    local middle_w = math.floor(width * .36)
    local right_w = width - left_w - middle_w

    local chapter = TapBox:new{
        dimen = Geom:new{w = left_w, h = height},
        enabled = type(header.chapter_callback) == "function",
        callback = function() self:_activate(header.chapter_callback, "目录") end,
    }
    -- 章节名严格单行：先按可用宽度截断再交给 TextWidget（不会自动折行）
    local chapter_text = fit_line(tostring(header.chapter_label or "☰ 目录"), left_w,
        Skin.face("cfont", 10.5, 13.8, 8.9), true)
    local chapter_box=Ui.text(chapter_text, left_w, height,
        Skin.face("cfont", 10.5, 13.8, 8.9), {alignment = "center", halign = "center", bold = true})
    if chapter_box and chapter_box[1] then self._text_refs.chapter=chapter_box[1] end
    chapter[1] = chapter_box

    local location_face = Skin.face("cfont", 10.1, 13.3, 8.6)
    local location_text = fit_line(tostring(header.location_label or "当前阅读位置"), middle_w,
        location_face, false)
    local location_box=Ui.text(location_text, middle_w, height,
        location_face, {alignment = "center", halign = "center", bold = false})
    if location_box and location_box[1] then self._text_refs.location=location_box[1] end
    local location = TapBox:new{dimen = Geom:new{w = middle_w, h = height}, enabled = false}
    location[1] = location_box

    local progress = TapBox:new{
        dimen = Geom:new{w = right_w, h = height},
        enabled = false,
    }
    -- 进度百分比只作展示，后面的「›」入口按钮去掉（不需要从这里进入阅读记录）
    local progress_text=tostring(header.progress_label or "")
    local progress_box=Ui.text(progress_text, right_w, height,
        Skin.face("cfont", 10.3, 13.6, 8.7), {alignment = "right", halign = "right", bold = true})
    if progress_box and progress_box[1] then self._text_refs.progress=progress_box[1] end
    progress[1] = progress_box
    root[#root + 1] = OffsetContainer:new{x_off = x, y_off = y, HorizontalGroup:new{align = "center", chapter, location, progress}}
end

function Toolbar:_content_row(root, entries, x, y, width, height)
    entries = type(entries) == "table" and entries or {}
    local count = math.max(1, #entries)
    local cell_w = math.floor(width / count)
    for index, entry in ipairs(entries) do
        local cell_x = x + (index - 1) * cell_w
        local actual_w = index == count and (x + width - cell_x) or cell_w
        root[#root + 1] = OffsetContainer:new{
            x_off = cell_x, y_off = y,
            plain_action_item(entry, actual_w, height,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end),
        }
    end
end

function Toolbar:_stepper(root, setting, x, y, width, height, ref_key)
    setting = type(setting) == "table" and setting or {}
    local label_w = math.floor(width * .29)
    local button_w = math.max(Skin.dp(42, 36, 54), math.floor(width * .17))
    local value_w = math.max(1, width - label_w - button_w * 2)
    local face = Skin.face("cfont", 10.8, 14.2, 9.1)
    local value_widget, value_container = dynamic_value(setting.value or "", value_w, height, face, true)
    if ref_key then self._text_refs[ref_key]=value_widget end

    local label_tap = TapBox:new{
        dimen = Geom:new{w = label_w, h = height},
        enabled = type(setting.callback) == "function",
        callback = function() self:_activate(setting.callback, setting.label or "设置") end,
    }
    label_tap[1] = Ui.textbox(tostring(setting.label or ""), label_w, height, face, {alignment = "center", halign = "center", bold = true})

    local minus = TapBox:new{
        dimen = Geom:new{w = button_w, h = height},
        enabled = type(setting.on_decrease) == "function",
        callback = function() self:_inline(setting.on_decrease, tostring(setting.label or "") .. "-", value_widget) end,
    }
    minus[1] = circle_icon_button("minus", button_w, height, true)

    local plus = TapBox:new{
        dimen = Geom:new{w = button_w, h = height},
        enabled = type(setting.on_increase) == "function",
        callback = function() self:_inline(setting.on_increase, tostring(setting.label or "") .. "+", value_widget) end,
    }
    plus[1] = circle_icon_button("plus", button_w, height, true)

    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        HorizontalGroup:new{align = "center", label_tap, minus, value_container, plus},
    }
end

function Toolbar:_typeset_row(root, typeset, x, y, width, height)
    typeset = type(typeset) == "table" and typeset or {}
    -- 字号/行距两组步进器对称平分整行，左右结构一致保证上下行对齐
    local half = math.floor(width / 2)
    self:_stepper(root, typeset.font or {}, x, y, half, height, "font_value")
    self:_stepper(root, typeset.spacing or {}, x + half, y, width - half, height, "spacing_value")
end

function Toolbar:_light_row(root, setting, x, y, width, height)
    if type(setting) ~= "table" then return end
    local enabled = setting.enabled ~= false
    local label_w = math.max(Skin.dp(132, 112, 170), math.floor(width * .25))
    local button_w = Skin.dp(50, 43, 64)
    local gap = Skin.dp(9, 7, 12)
    local slider_w = math.max(1, width - label_w - button_w * 2 - gap * 2)
    local icon_w = Skin.dp(36, 31, 46)
    local value_text_w = Skin.dp(46, 39, 58)
    local label_text_w = math.max(1, label_w - icon_w - value_text_w)
    local value_widget = TextWidget:new{
        text = tostring(math.floor((tonumber(setting.value) or 0) + .5)),
        face = Skin.face("cfont", 11.2, 14.8, 9.5),
        bold = true,
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }
    local label_content = HorizontalGroup:new{
        align = "center",
        icon_box(setting.icon or "frontlight", icon_w, height, enabled, Skin.dp(24, 20, 31)),
        Ui.textbox(tostring(setting.label or ""), label_text_w, height,
            Skin.face("cfont", 10.7, 14.1, 9.0), {alignment = "left", halign = "left", bold = true}),
        CenterContainer:new{dimen = Geom:new{w = value_text_w, h = height}, value_widget},
    }
    local label = TapBox:new{dimen = Geom:new{w = label_w, h = height}, enabled = false}
    label[1] = label_content

    local slider = SliderBar:new{
        dimen = Geom:new{w = slider_w, h = height},
        track_w = slider_w,
        min = tonumber(setting.min) or 0,
        max = tonumber(setting.max) or 100,
        value = tonumber(setting.value) or 0,
        owner = self,
        value_widget = value_widget,
        on_change = function(target, interaction)
            if type(setting.on_set) ~= "function" then return target end
            local result = setting.on_set(target, interaction)
            if result == false then return false end
            return tonumber(result) or target
        end,
    }
    slider.refresh_dimen=Geom:new{x=x,y=y,w=width,h=height}
    local slider_key=tostring(setting.icon or "frontlight")
    self._sliders[slider_key]=slider

    local function adjust(callback, direction)
        if type(callback) ~= "function" then return end
        local ok, result = pcall(callback)
        if not ok then
            logger.warn("[MiuRead][ReaderToolbar] light step failed", tostring(direction), tostring(result))
            return
        end
        if result ~= false then slider:setValue(tonumber(result) or slider.value, true) end
    end

    local minus = TapBox:new{
        dimen = Geom:new{w = button_w, h = height}, enabled = enabled and type(setting.on_decrease) == "function",
        callback = function() adjust(setting.on_decrease, "-") end,
    }
    minus[1] = circle_icon_button("minus", button_w, height, enabled)
    local plus = TapBox:new{
        dimen = Geom:new{w = button_w, h = height}, enabled = enabled and type(setting.on_increase) == "function",
        callback = function() adjust(setting.on_increase, "+") end,
    }
    plus[1] = circle_icon_button("plus", button_w, height, enabled)

    root[#root + 1] = OffsetContainer:new{
        x_off = x, y_off = y,
        HorizontalGroup:new{
            align = "center",
            label,
            minus,
            HorizontalSpan:new{width = gap},
            slider,
            HorizontalSpan:new{width = gap},
            plus,
        },
    }
end

function Toolbar:_device_row(root, entries, x, y, width, height)
    entries = type(entries) == "table" and entries or {}
    local count = math.max(1, #entries)
    -- 与上一行「目录/缓存/下载/删除/书架」（5 格）共用同一套格宽：
    -- 首项和末项的图标中心因此上下对齐，中间几项均匀铺开。
    -- 原来这一行按 4 等分，第一项比上一行的第一项更靠里，看着整排都错位。
    local item_w = math.floor(width / 5)
    if count >= 5 then item_w = math.floor(width / count) end
    local gap = 0
    if count > 1 then
        gap = math.floor((width - item_w * count) / (count - 1))
    end
    for index, entry in ipairs(entries) do
        local cell_x = x + (index - 1) * (item_w + gap)
        local actual_w = index == count and math.max(1, x + width - cell_x) or item_w
        root[#root + 1] = OffsetContainer:new{
            x_off = cell_x, y_off = y,
            compact_action_item(entry, actual_w, height,
                function(action, label) self:_activate(action, label) end,
                function(action, label) self:_activate_hold(action, label) end),
        }
    end
end

function Toolbar:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local side_pad = math.max(Skin.dp(16, 13, 25), math.floor(sw * .025))
    local top_pad = Skin.dp(5, 4, 8)
    local bottom_pad = Skin.dp(6, 5, 9)
    local content_w = math.max(1, sw - side_pad * 2)
    local divider_h = math.max(1, Skin.line("thin"))

    local status_h = math.max(Skin.dp(54, 47, 69), math.floor(sh * (portrait and .047 or .068)))
    local title_h = math.max(Skin.dp(54, 46, 69), math.floor(sh * (portrait and .046 or .072)))
    local chapter_h = math.max(Skin.dp(44, 38, 57), math.floor(sh * (portrait and .038 or .058)))
    local content_h = math.max(Skin.dp(76, 65, 97), math.floor(sh * (portrait and .064 or .094)))
    local typeset_h = math.max(Skin.dp(54, 46, 69), math.floor(sh * (portrait and .046 or .069)))
    local light_h = math.max(Skin.dp(54, 46, 69), math.floor(sh * (portrait and .046 or .069)))
    local device_h = math.max(Skin.dp(58, 50, 74), math.floor(sh * (portrait and .050 or .075)))

    local header = type(self.opts.header) == "table" and self.opts.header or {}
    local actions = type(self.opts.actions) == "table" and self.opts.actions or {}
    local typeset = type(self.opts.typeset) == "table" and self.opts.typeset or {}
    local frontlight = type(self.opts.frontlight) == "table" and self.opts.frontlight or nil
    local warmth = type(self.opts.warmth) == "table" and self.opts.warmth or nil
    local devices = type(self.opts.device_actions) == "table" and self.opts.device_actions or {}

    local row_count = 5 + (frontlight and 1 or 0) + (warmth and 1 or 0) + (#devices > 0 and 1 or 0)
    local panel_h = top_pad + status_h + title_h + chapter_h + content_h + typeset_h
        + (frontlight and light_h or 0) + (warmth and light_h or 0) + (#devices > 0 and device_h or 0)
        + divider_h * math.max(0, row_count - 1) + bottom_pad
    panel_h = math.min(sh - Skin.dp(18, 15, 28), panel_h)

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_h = panel_h
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = 0, y_off = 0,
        Skin.frame(sw, panel_h, {
            bordersize = 0, padding = 0, radius = 0,
            background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_WHITE,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_pad
    self:_top_status_row(root, header, side_pad, y, content_w, status_h)
    y = y + status_h
    self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h

    self:_title_row(root, header, side_pad, y, content_w, title_h)
    y = y + title_h
    self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h

    self:_chapter_row(root, header, side_pad, y, content_w, chapter_h)
    y = y + chapter_h
    self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h

    self:_content_row(root, actions, side_pad, y, content_w, content_h)
    y = y + content_h
    self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h

    self:_typeset_row(root, typeset, side_pad, y, content_w, typeset_h)
    y = y + typeset_h

    if frontlight then
        self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h
        self:_light_row(root, frontlight, side_pad, y, content_w, light_h)
        y = y + light_h
    end
    if warmth then
        self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h
        self:_light_row(root, warmth, side_pad, y, content_w, light_h)
        y = y + light_h
    end
    if #devices > 0 then
        self:_divider(root, side_pad, y, content_w, divider_h); y = y + divider_h
        self:_device_row(root, devices, side_pad, y, content_w, device_h)
        y = y + device_h
    end

    root[#root + 1] = OffsetContainer:new{
        x_off = 0, y_off = panel_h - math.max(1, Skin.line("thin")),
        LineWidget:new{background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{w = sw, h = math.max(1, Skin.line("thin"))}},
    }

    self[1] = root
end

function Toolbar:_signature(opts)
    opts=type(opts)=="table" and opts or {}
    return table.concat({
        opts.frontlight and "f1" or "f0",
        opts.warmth and "w1" or "w0",
        (type(opts.header)=="table" and opts.header.bluetooth_visible==true) and "bt1" or "bt0",
        tostring(#(type(opts.actions)=="table" and opts.actions or {})),
        tostring(#(type(opts.device_actions)=="table" and opts.device_actions or {})),
        tostring(Screen:getWidth()),tostring(Screen:getHeight()),
        tostring(UiScale.getDisplayMode and UiScale.getDisplayMode() or "standard"),
        tostring(UiScale.getFontName and UiScale.getFontName() or ""),
    },"|")
end

local function set_ref(ref,value,formatter)
    if not (ref and type(ref.setText)=="function") then return end
    local text=type(formatter)=="function" and formatter(value) or tostring(value or "")
    ref:setText(text)
end

function Toolbar:refreshFrontlightState()
    local changed=false
    for _,key in ipairs({"frontlight","warmth"}) do
        local setting=type(self.opts[key])=="table" and self.opts[key] or nil
        local slider=self._sliders and self._sliders[key] or nil
        if setting and slider and type(setting.get_value)=="function" then
            local ok,value=pcall(setting.get_value)
            if ok and tonumber(value) then
                slider:setValue(tonumber(value),false)
                changed=true
            end
        end
    end
    if changed and self.panel_dimen then
        UIManager:setDirty(self,function() return "ui",Skin.expand_region(self.panel_dimen,Skin.dp(2,2,3)) end)
    end
    return changed
end

function Toolbar:updateFromOptions(opts)
    opts=type(opts)=="table" and opts or {}
    if self:_signature(opts)~=self._layout_signature then return false end
    self.opts=opts
    self.closed=false
    self.action_locked=false
    self._controls_ready=false
    UIManager:nextTick(function() if not self.closed and live_toolbar==self then self._controls_ready=true end end)
    self.pending_action=nil
    local header=type(opts.header)=="table" and opts.header or {}
    set_ref(self._text_refs.wifi,header.wifi_label or "Wi-Fi",self._text_formatters.wifi)
    set_ref(self._text_refs.bluetooth,header.bluetooth_label or "蓝牙",self._text_formatters.bluetooth)
    set_ref(self._text_refs.sync,header.sync_label or "同步",self._text_formatters.sync)
    set_ref(self._text_refs.time,header.time_label or "")
    set_ref(self._text_refs.battery,header.battery_label or "")
    set_ref(self._text_refs.home,header.home_label or "首页")
    set_ref(self._text_refs.nickname,header.nickname_label or "",self._text_formatters.nickname)
    set_ref(self._text_refs.more,header.more_label or "更多")
    set_ref(self._text_refs.title,header.title or "正在阅读")
    set_ref(self._text_refs.chapter,header.chapter_label or "☰ 目录")
    set_ref(self._text_refs.location,header.location_label or "当前阅读位置")
    local progress=tostring(header.progress_label or "")
    set_ref(self._text_refs.progress,progress)
    local typeset=type(opts.typeset)=="table" and opts.typeset or {}
    set_ref(self._text_refs.font_value,typeset.font and typeset.font.value or "")
    set_ref(self._text_refs.spacing_value,typeset.spacing and typeset.spacing.value or "")
    if self._sliders.frontlight and opts.frontlight then
        self._sliders.frontlight.value=tonumber(opts.frontlight.value) or self._sliders.frontlight.value
        if self._sliders.frontlight.value_widget then
            self._sliders.frontlight.value_widget:setText(tostring(math.floor(self._sliders.frontlight.value+.5)))
        end
    end
    if self._sliders.warmth and opts.warmth then
        self._sliders.warmth.value=tonumber(opts.warmth.value) or self._sliders.warmth.value
        if self._sliders.warmth.value_widget then
            self._sliders.warmth.value_widget:setText(tostring(math.floor(self._sliders.warmth.value+.5)))
        end
    end
    return true
end

function Toolbar:init()
    self.opts = self.opts or {}
    self.action_locked = false
    self._controls_ready=false
    self._text_refs={}
    self._text_formatters={}
    self._sliders={}
    self._layout_signature=self:_signature(self.opts)
    self:_build_content()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function Toolbar:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < 0 or pos.y > self.panel_h or pos.x < 0 or pos.x > self.panel_dimen.w) then
        return self:_close()
    end
    return false
end
function Toolbar:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close() end
    return false
end
function Toolbar:onClose() return self:_close() end
function Toolbar:onShow()
    self._controls_ready=false
    UIManager:nextTick(function()
        if not self.closed and live_toolbar==self then self._controls_ready=true end
    end)
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen, Skin.dp(2, 2, 3)) end)
end
function Toolbar:onCloseWidget()
    local region = self.panel_dimen and Skin.expand_region(self.panel_dimen, Skin.dp(2, 2, 3)) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_toolbar == self then live_toolbar = nil end
    DialogTransition.after_close(region, action, "ReaderToolbar")
end

local M = {}
function M.close()
    if live_toolbar and not live_toolbar.closed then live_toolbar:_close(nil, true) end
    live_toolbar = nil
end
function M.refreshFrontlight()
    if live_toolbar and not live_toolbar.closed and type(live_toolbar.refreshFrontlightState)=="function" then
        return live_toolbar:refreshFrontlightState()
    end
    return false
end
-- 换书/切书源后同步标题：面板还开着时，用最新的 header 原地刷新文本，
-- 不必关掉再重建（重建会让用户觉得工具栏闪了一下）。签名不变时只更新文字。
function M.refreshHeader(header)
    if not (live_toolbar and not live_toolbar.closed and type(live_toolbar.updateFromOptions)=="function") then
        return false
    end
    local opts = live_toolbar.opts or {}
    local merged = {}
    for k, v in pairs(opts) do merged[k] = v end
    local h = {}
    for k, v in pairs(type(opts.header) == "table" and opts.header or {}) do h[k] = v end
    for k, v in pairs(type(header) == "table" and header or {}) do h[k] = v end
    merged.header = h
    local ok = pcall(live_toolbar.updateFromOptions, live_toolbar, merged)
    return ok and true or false
end
function M.invalidate()
    M.close()
    return true
end
function M.prepare(opts,key)
    -- Keep prewarm side-effect free: validate data only, never retain a Widget.
    opts=opts or {}
    key=tostring(key or "reader")
    return true,nil
end
function M.show(opts,key)
    TransientGuard.close_all()
    local started=os.clock()
    M.close()
    key=tostring(key or "reader")
    local ok,toolbar=pcall(Toolbar.new,Toolbar,{opts=opts or {}})
    if not ok or not toolbar then return nil,tostring(toolbar) end
    local built=os.clock()
    toolbar.cache_key=key
    toolbar.closed=false
    live_toolbar=toolbar
    local shown,show_err=pcall(UIManager.show,UIManager,toolbar,"ui",toolbar.panel_dimen)
    if not shown then
        live_toolbar=nil
        return nil,tostring(show_err or "show failed")
    end
    logger.info("[MiuRead][ReaderToolbar] build timing",
        "reused=", "false",
        "build_ms=",tostring(math.floor((built-started)*1000+.5)),
        "submit_ms=",tostring(math.floor((os.clock()-built)*1000+.5)))
    return toolbar
end
return M
