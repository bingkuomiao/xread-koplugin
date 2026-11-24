-- xread.koplugin/xread/text_metrics.lua
-- 文本宽度测量兼容层。
-- KOReader 的 TextWidget 只有实例方法（getSize/getWidth），没有静态的
-- getTextWidth；而 shelf_grid / catalog_view 的 wrapTitle 需要在不创建控件
-- 的前提下反复测量候选串宽度。这里在缺失时补一个静态方法，
-- 签名与调用方保持一致：TextWidget.getTextWidth(text, face, bold, kerning)
local TextWidget = require("ui/widget/textwidget")
local RenderText = require("ui/rendertext")
local Screen     = require("device").screen

if not TextWidget.getTextWidth then
    function TextWidget.getTextWidth(text, face, bold, kerning)
        if text == nil then return 0 end
        local use_kerning = kerning ~= nil and kerning ~= false and kerning ~= 0
        local ok, size = pcall(function()
            return RenderText:sizeUtf8Text(0, Screen:getWidth(), face, tostring(text),
                use_kerning, bold and true or false)
        end)
        if not ok or not size then
            -- 极端情况下退回按字号粗估（中文按 1 字宽、西文按 0.55 字宽）
            local n_ascii, n_wide = 0, 0
            for _, ch in ipairs(require("util").splitToChars(tostring(text))) do
                if #ch > 1 then n_wide = n_wide + 1 else n_ascii = n_ascii + 1 end
            end
            return math.floor((n_wide + n_ascii * 0.55) * (face and face.size or 14))
        end
        return math.floor(size.x)
    end
end

return TextWidget
