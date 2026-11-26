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

local CloseButton = InputContainer:extend{
    width = nil, height = nil, callback = nil,
    glyph = "✕", face_size = nil, glyph_size = nil,
}

function CloseButton:init()
    -- 纯字形按钮：不画圆形底色/边框，只用 ✕ 本身（用户要求去掉圆形背景色）。
    -- width 仍是热区宽度（可比字形宽，用来把按钮顶到弹窗边框）。
    local size = self.glyph_size or Screen:scaleBySize(40)
    local w = self.width or size
    local h = self.height or size
    self.dimen = Geom:new{ w = w, h = h }
    local face = Font:getFace("cfont", self.face_size or Screen:scaleBySize(21))
    local glyph = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        TextWidget:new{
            text = self.glyph, face = face,
            fgcolor = Blitbuffer.COLOR_GRAY_D,
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
    return CloseButton:new{
        width = size, height = size, callback = callback,
        face_size = face_size, glyph_size = size,
    }
end

-- 弹窗内容区有左右 padding，让热区多出一个 padding 并把圆按钮右对齐，
-- 按钮就能贴到弹窗边框内侧而不是缩在内容区里。
function M.closeButtonAtEdge(callback, pad, size, face_size)
    size = size or Screen:scaleBySize(44)
    return CloseButton:new{
        width = size + (pad or 0), height = size, callback = callback,
        face_size = face_size, glyph_size = size,
    }
end

return M
