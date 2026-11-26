-- xread/http_client.lua
-- 统一 HTTP 入口：给每次请求单独指定超时，且**保证**请求结束后恢复全局值。
--
-- 为什么不能靠 request 表里的 timeout 字段，也不能靠 create + settimeout：
--   KOReader 的 common/socket/http.lua:open() 在 create() 之后无条件执行
--   h.try(c:settimeout(_M.TIMEOUT))，传入的 create 里设的超时会被立刻覆盖，
--   request.timeout 更是完全没人读。luasocket 的超时事实上是模块级全局。
--
-- 所以真正可行的做法只有「临时改模块值 + 用 pcall 保证一定恢复」。
-- 相比各处手写 `old = http.TIMEOUT; http.TIMEOUT = t; ...; http.TIMEOUT = old`，
-- 这里多了三件事：
--   1) pcall 包住请求，抛错也恢复（原来一处抛错就把全局永久改坏）；
--   2) 嵌套计数，最外层才恢复，避免 sink 回调里再发请求时把值改回去；
--   3) 统一返回值，调用方不用记 request 的 1, code, headers 结构。
--
-- ✅ Lua 5.1 通用（只用 pcall / 模块表字段）。

local http = require("socket.http")

local HttpClient = {}

-- 默认超时（秒）。历史行为是 12s，保留为默认值。
HttpClient.DEFAULT_TIMEOUT = 12

local depth = 0          -- 当前嵌套层数
local saved_timeout      -- 最外层进入前的原始 TIMEOUT

--- 发起请求。
-- @param req      ltn12/socket.http 的 request 表
-- @param timeout  number，本次请求的超时秒数；nil 表示不改动超时
-- @return ok(boolean), code(number|nil), headers(table|nil), err(string|nil)
--
-- 关键：KOReader 的 socket.http.request 被 socket.protect 包装，**失败时返回
-- nil, errmsg 而不是抛异常**，成功时返回 1, code, headers, status。
-- 所以判断成败要看「第一个返回值是否等于 1」，而不是 pcall 的 ok。
-- 之前只看 pcall 的 ok（失败时 protect 仍正常返回，pcall 恒 true），会把
-- 失败误读成「成功 code=nil」，一路炸到 httpPost 的 `code >= 500` 比较。
function HttpClient.request(req, timeout)
    local t = tonumber(timeout)
    local ok, r1, r2, r3
    if not t or t <= 0 then
        -- 不改超时：仍用 pcall 统一返回值
        ok, r1, r2, r3 = pcall(http.request, req)
    else
        if depth == 0 then saved_timeout = http.TIMEOUT end
        depth = depth + 1
        http.TIMEOUT = t
        ok, r1, r2, r3 = pcall(http.request, req)
        depth = depth - 1
        if depth == 0 then
            http.TIMEOUT = saved_timeout
            saved_timeout = nil
        end
    end
    -- http.request 自身抛异常（极少见，protect 一般已兜住）
    if not ok then return false, nil, nil, tostring(r1) end
    -- 成败判定：protect 成功返回 1, code, headers, status；失败返回 nil, errmsg
    if r1 ~= 1 then
        return false, nil, nil, tostring(r2 or r1)
    end
    return true, tonumber(r2), r3
end

return HttpClient
