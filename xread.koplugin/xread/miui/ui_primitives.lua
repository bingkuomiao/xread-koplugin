-- 共享 widget 原语：可点击容器、偏移容器、圆角封面、定尺白框。
--
-- 这些容器以前在每个视图文件里各写一份，语义还会悄悄漂移：
--   TapBox           home_view / full_shelf_view / reader_toolbar /
--                    quick_panel / reading_stats 共 5 份
--   OffsetContainer  home_view / full_shelf_view / reader_toolbar 共 3 份
--   RoundedImage     home_view / full_shelf_view 共 2 份
--   fixed_frame      home_view / full_shelf_view 共 2 份（reader_skin 那版默认
--                    背景色不同，故意保留，不走这里）
-- 全部收敛到本文件后，改一处即全部生效；各视图只做别名引入，调用点零改动。
--
-- 注意 reader_skin.lua 的 fixed_frame 没有并进来：那版把 background 默认成
-- 白色，而首页/书架这两版默认不填背景（让底层可见），合并会改变像素。
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local U = require("xread.miui.util")

local M = {}

-- ---------- 偏移容器 ----------
-- 把子控件画到 (x + x_off, y + y_off)。首页/书架是「绝对坐标堆叠」的布局，
-- 全靠它把每块内容摆到算好的位置上。
local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end
M.OffsetContainer = OffsetContainer

function M.offset(x_off, y_off, child)
    return OffsetContainer:new{x_off = x_off, y_off = y_off, child}
end

-- ---------- 可点击容器 ----------
-- 两种构造方式都支持（原来分成两派，各自只认一种）：
--   TapBox:new{dimen = Geom:new{w, h}}                  -- 尺寸已知，子控件自己摆
--   TapBox:new{width = w, height = h, widget = child}   -- 子控件居中放进盒子
--
-- 选项：
--   enabled      false 时吞掉点击不触发（原来只有工具栏那版支持）
--   hold_callback 有值才注册长按/长按释放，避免无长按的卡片抢事件
--   debounce     秒；>0 时该容器在窗口期内只认第一次 tap（首页防连点开书）
local TapBox = InputContainer:extend{
    dimen = nil,
    width = nil,
    height = nil,
    widget = nil,
    callback = nil,
    hold_callback = nil,
    enabled = true,
    debounce = 0,
    _hold_handled = false,
}

function TapBox:init()
    local w = tonumber(self.width) or (self.dimen and self.dimen.w) or 1
    local h = tonumber(self.height) or (self.dimen and self.dimen.h) or 1
    self.dimen = Geom:new{w = w, h = h}
    if self.widget then
        self[1] = CenterContainer:new{dimen = Geom:new{w = w, h = h}, self.widget}
        self.widget = nil
    end
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
    if self.hold_callback then
        self.ges_events.HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}}
        self.ges_events.HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}}
    end
end

function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end

function TapBox:paintTo(bb, x, y)
    -- 把实际绘制位置写回 dimen：GestureRange 持有的是这张表的引用，
    -- 这样命中区会自动跟着布局走，不用每处再手动同步一次。
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end

function TapBox:onTapSelect(_, ges)
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    if self.enabled == false then return true end
    -- 用墙上时钟做双击防抖（os.clock 是 CPU 时间，UI 卡住时几乎不走，
    -- 会把之后几十秒的点击全部误判成「防抖期」吞掉）
    local window = tonumber(self.debounce) or 0
    if window > 0 then
        local now = U.now()
        if now < (tonumber(self._tap_block_until) or 0) then return true end
        self._tap_block_until = now + window
    end
    if self.callback then self.callback(self.dimen:copy(), ges) end
    return true
end

function TapBox:onHoldSelect()
    if not self.hold_callback then return false end
    self._hold_handled = true
    self.hold_callback(self.dimen:copy())
    return true
end

function TapBox:onHoldReleaseSelect()
    if not self._hold_handled then return false end
    self._hold_handled = false
    local window = tonumber(self.debounce) or 0
    if window > 0 then self._tap_block_until = U.now() + window end
    return true
end

M.TapBox = TapBox

-- 定尺可点卡片：盒子大小固定，子控件居中。
function M.tappable(width, height, child, callback, hold_callback, opts)
    opts = opts or {}
    local box = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
        debounce = opts.debounce,
        enabled = opts.enabled,
    }
    box[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return box
end

-- ---------- 圆角封面 ----------
-- 在图片本身的外接矩形上只削掉四个角，而不是套一圈带 padding 的圆角框：
-- 封面能和格子完全对齐。ink_boost 用 darkenRect 轻微提对比，让浅色封面
-- 在墨水屏上不至于发灰（深色封面靠 clamp 上限控制，不会糊成黑块）。
local RoundedImage = WidgetContainer:extend{width = 1, height = 1, radius = 0, ink_boost = 0}

function RoundedImage:getSize()
    return Geom:new{w = self.width, h = self.height}
end

function RoundedImage:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
    local boost = math.max(0, math.min(.18, tonumber(self.ink_boost) or 0))
    if boost > 0 and bb and type(bb.darkenRect) == "function" then
        pcall(bb.darkenRect, bb, x, y, self.width, self.height, boost)
    end
    local r = math.max(0, math.min(math.floor(self.radius or 0), math.floor(math.min(self.width, self.height) / 2)))
    if r <= 1 or not bb or type(bb.paintRect) ~= "function" then return end
    for row = 0, r - 1 do
        local dy = r - row
        local inside = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.max(0, math.floor(r - inside + .5))
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

M.RoundedImage = RoundedImage

function M.rounded_image(width, height, radius, ink_boost, child)
    return RoundedImage:new{
        width = width,
        height = height,
        radius = radius,
        ink_boost = ink_boost,
        child,
    }
end

-- ---------- 定尺白框 ----------
-- 尺寸写死的 FrameContainer：宽度不受内容影响，内容居中。
-- options: bordersize / padding / margin / radius / background / color
function M.frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local margin = tonumber(options.margin) or 0
    local inset = border + padding + margin
    return FrameContainer:new{
        bordersize = border,
        radius = options.radius or 0,
        padding = padding,
        margin = margin,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

return M
