-- 弹出页通用控件：统一关闭按钮样式与位置。
-- 所有自建对话框的右上角 ✕ 都从这里取，避免各页各写一套导致大小/位置不一致。
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Screen = require("device").screen

local M = {}

-- 全部弹窗统一用这一套尺寸：热区 36、字号 17、纯黑。
-- 位置统一为「标题行最右侧」（closeButtonAtEdge），任何面板都不再自己算偏移。
--
-- 字号这里先 scaleBySize 一次：本插件其它面板都走 scaled(x) + getFace 的写法，
-- 两边一致，✕ 的视觉高度才会和弹窗标题齐平（实测两者笔画高都是 37px）。
local CLOSE_SIZE = 36
local CLOSE_FACE = 17

local CloseButton = InputContainer:extend{
    width = nil, height = nil, callback = nil,
    glyph = "✕", face_size = nil, glyph_size = nil,
}

function CloseButton:init()
    -- 纯字形按钮：不画圆形底色/边框，只用 ✕ 本身（用户要求去掉圆形背景色）。
    -- width 仍是热区宽度（可比字形宽，用来把按钮顶到弹窗边框）。
    local size = self.glyph_size or Screen:scaleBySize(CLOSE_SIZE)
    local w = self.width or size
    local h = self.height or size
    self.dimen = Geom:new{ w = w, h = h }
    local face = Font:getFace("cfont", self.face_size or Screen:scaleBySize(CLOSE_FACE))
    local glyph = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        TextWidget:new{
            text = self.glyph, face = face,
            -- 纯黑：夜间模式是整屏反色，这里写黑，屏幕上自动得到白 ✕
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    self[1] = RightContainer:new{
        dimen = Geom:new{ w = w, h = h }, glyph,
    }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function CloseButton:onTap()
    if self.callback then self.callback() end
    return true
end

M.CloseButton = CloseButton

function M.closeButton(callback, size, face_size)
    local sz = size or Screen:scaleBySize(CLOSE_SIZE)
    return CloseButton:new{
        width = sz, height = sz, callback = callback,
        face_size = face_size or Screen:scaleBySize(CLOSE_FACE), glyph_size = sz,
    }
end

-- 统一尺寸（供布局算 span 用，避免各页硬编码 34/44 对不上）
function M.closeButtonSize()
    return Screen:scaleBySize(CLOSE_SIZE)
end

-- 弹窗内容区有左右 padding，让热区多出一个 padding 并把圆按钮右对齐，
-- 按钮就能贴到弹窗边框内侧而不是缩在内容区里。
function M.closeButtonAtEdge(callback, pad, size, face_size)
    size = size or Screen:scaleBySize(CLOSE_SIZE)
    return CloseButton:new{
        width = size + (pad or 0), height = size, callback = callback,
        face_size = face_size or Screen:scaleBySize(CLOSE_FACE), glyph_size = size,
    }
end

-- 弹窗遮罩：只把底下的画面压暗，不再刷一整块不透明灰底。
-- 原来用 bb:paintRect(..., COLOR_GRAY_E)，弹窗前看到的首页/正文被整块盖掉，
-- 用户会觉得「点一下弹窗，背景就没了」。darkenRect 是带 alpha 的混合，
-- 底图仍在，只是变暗，弹窗边框也更清楚。
-- amount 默认 .22（0..1，越大越暗）。
function M.dimBackdrop(bb, x, y, w, h, amount)
    local by = tonumber(amount) or .22
    if by <= 0 then return end
    if type(bb.darkenRect) == "function" then
        local ok = pcall(bb.darkenRect, bb, x, y, w, h, by)
        if ok then return end
    end
    -- 极老的 BlitBuffer 没有 darkenRect：宁可不画遮罩，也不要盖掉背景内容
end

return M
