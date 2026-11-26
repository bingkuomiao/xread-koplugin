-- xread/backend_probe.lua
-- 后端可达性快速探测（非阻塞）。
--
-- 为什么需要它：
--   菜单/首页里的网络入口（我的首页、我的书架、测试连接、更新、进书……）
--   都是在 UI 线程上同步发 HTTP 的。地址填错或后端没起时，luasocket 会一直
--   卡到超时（12s×N 次重试），整机 UI 冻结、点击无响应，而且**没有任何提示**，
--   用户只能以为「插件坏了」。
--
-- 做法：fork 子进程做一次 TCP connect（超时 2.5s），结果写到临时文件，
--   主线程每 120ms 轮询文件。探测期间 UI 完全可交互，失败立刻能提示原因。
--   探测只用于「快速失败」：探测通过后业务流程照旧在主线程跑（此时后端已确认
--   可达，通常几百毫秒内返回）。
--
-- 兼容：ffi/util 不可用（极老的裁剪版）时退化为 2s 的同步探测，
--   仍然比原来的 12s×N 短，且一定有结论返回。

local logger = require("logger")
local UIManager = require("ui/uimanager")

local Probe = {}

Probe.DEFAULT_TIMEOUT = 2.5

local seq = 0

local function tmpPath()
    seq = seq + 1
    local dir = os.getenv("TMPDIR")
    if not dir or dir == "" then dir = "/tmp" end
    return string.format("%s/xread_probe_%d_%d.txt", dir, os.time(), seq)
end

--- 从 "http://1.2.3.4:7777" 之类的地址里取 host / port
-- 支持带 scheme、带路径、带尾斜杠、IPv6 方括号写法。
-- @return host(string|nil), port(number)
function Probe.parse(address)
    local addr = tostring(address or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if addr == "" then return nil, 80 end
    local scheme, rest = addr:match("^(%a[%w+.-]*)://(.+)$")
    if not rest then rest = addr end
    rest = rest:gsub("[/?#].*$", "")
    local host, port
    host, port = rest:match("^%[([^%]]+)%]:(%d+)$")
    if not host then host = rest:match("^%[([^%]]+)%]$") end
    if not host then host, port = rest:match("^([^:/]+):(%d+)$") end
    if not host then host = rest:match("^([^:/]+)$") end
    if not host or host == "" then return nil, 80 end
    local default_port = (scheme == "https") and 443 or 80
    return host, tonumber(port) or default_port
end

-- 子进程里执行：只碰 socket / 文件，绝不碰 UI。
local function childProbe(path, host, port, timeout)
    local result = "OK"
    local ok, err = pcall(function()
        local socket = require("socket")
        local tcp = socket.tcp()
        if not tcp then error("无法创建 socket", 0) end
        tcp:settimeout(timeout)
        local okc, cerr = tcp:connect(host, port)
        pcall(function() tcp:close() end)
        if not okc then
            -- 把 luasocket 的英文错误映射成用户看得懂的话；
            -- error(..., 0) 不带「文件:行号」前缀，提示更干净
            local msg = tostring(cerr or "connect failed")
            if msg:find("timeout", 1, true) then msg = "连接超时"
            elseif msg:find("refused", 1, true) then msg = "连接被拒绝"
            elseif msg:find("unreachable", 1, true) then msg = "主机不可达"
            elseif msg:find("name or service", 1, true) or msg:find("host not found", 1, true) then msg = "无法解析主机名"
            end
            error(msg, 0)
        end
    end)
    if not ok then
        result = "ERR " .. tostring(err):gsub("[\r\n]+", " ")
    end
    local f = io.open(path, "w")
    if f then f:write(result); f:close() end
end

--- 非阻塞探测
-- @param address string 后端地址（http://host:port）
-- @param timeout number 探测超时秒数（默认 2.5）
-- @param callback function(ok:boolean, reason:string) 结果回调（一定在主线程）
function Probe.check(address, timeout, callback)
    timeout = tonumber(timeout) or Probe.DEFAULT_TIMEOUT
    local host, port = Probe.parse(address)

    local done = false
    local function finish(ok, reason)
        if done then return end
        done = true
        if callback then
            local ok_cb, err = pcall(callback, ok, tostring(reason or ""))
            if not ok_cb then logger.warn("xread probe callback error:", tostring(err)) end
        end
    end

    if not host or host == "" then
        UIManager:nextTick(function() finish(false, "地址为空") end)
        return
    end

    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not ok_ffi or type(ffiutil) ~= "table" or type(ffiutil.runInSubProcess) ~= "function" then
        -- 退化路径：同步探测（2s 上限），保证有结论
        local ok, err = pcall(function()
            local socket = require("socket")
            local tcp = socket.tcp()
            tcp:settimeout(math.min(timeout, 2))
            local okc, cerr = tcp:connect(host, port)
            pcall(function() tcp:close() end)
            if not okc then error(tostring(cerr or "connect failed")) end
        end)
        finish(ok, ok and "" or tostring(err))
        return
    end

    local path = tmpPath()
    local ok_run, pid = pcall(ffiutil.runInSubProcess, function()
        childProbe(path, host, port, timeout)
    end)
    if not ok_run or type(pid) ~= "number" then
        -- fork 失败：不能退回同步（可能再次冻结），直接给出结论让调用方提示
        logger.warn("xread probe fork failed:", tostring(pid))
        UIManager:nextTick(function() finish(false, "无法启动探测进程") end)
        return
    end

    local ok_socket, socket = pcall(require, "socket")
    local function nowSec()
        if ok_socket and socket and socket.gettime then return socket.gettime() end
        return os.time()
    end
    local t0 = nowSec()
    local deadline = timeout + 1.2

    local function poll()
        if done then return end
        local f = io.open(path, "r")
        if f then
            local text = f:read("*a") or ""
            f:close()
            pcall(os.remove, path)
            -- 结果已拿到，阻塞回收子进程（此刻它已写完文件、即将退出，
            -- waitpid 阻塞时间近乎为 0，避免留下僵尸进程）
            pcall(function() ffiutil.isSubProcessDone(pid, true) end)
            if text:sub(1, 2) == "OK" then
                finish(true, "")
            else
                finish(false, (text:gsub("^ERR%s*", "")))
            end
            return
        end
        -- 子进程已退出但没写结果（崩溃/被杀）：不必等满超时
        local alive = true
        pcall(function() alive = not ffiutil.isSubProcessDone(pid, false) end)
        if not alive then
            pcall(os.remove, path)
            finish(false, "探测进程无响应")
            return
        end
        if nowSec() - t0 > deadline then
            pcall(function() ffiutil.terminateSubProcess(pid) end)
            pcall(function() ffiutil.isSubProcessDone(pid, false) end)
            pcall(os.remove, path)
            finish(false, "连接超时")
            return
        end
        UIManager:scheduleIn(0.12, poll)
    end

    UIManager:scheduleIn(0.1, poll)
end

return Probe
