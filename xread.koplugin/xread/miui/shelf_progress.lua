-- xread.koplugin/xread/miui/shelf_progress.lua
-- 首页「已读完」徽标判定。
--
-- 说明：本模块原本是从 MiuRead 移植过来的完整进度解析状态机
-- （percent / timestamp / display / parse / fetch / verification_key 等），
-- 但 xread 只用到 is_finished 一个函数，其余全是无人调用的死分支，
-- 已删除以降低维护成本。需要完整进度解析时请另建模块，不要在这里复活。

local M = {}

local function number(value)
    local n = tonumber(value)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end

--- 是否已读完
-- 优先看界面层给的 pending/cloud 标记，其次看进度百分比是否到 100。
function M.is_finished(row)
    if type(row) ~= "table" then return false end
    if row.finished_pending ~= nil then return row.finished_pending == true end
    if row.cloud_finished ~= nil then return row.cloud_finished == true end
    return row.finished == true
        or row.resolved_finished == true
        or (number(row.progress) or 0) >= 100
end

return M
