-- xread/updater.lua — 插件在线热更新（manifest2.json + 规范 zip 整包）
--
-- 更新包与后端放在一起：
--   /vol1/@appdata/xread/data/webdav/<用户名>/plugin/
--     manifest2.json                                  # 指向规范 zip 包
--     xread.koplugin_v<版本>_<YYYYMMDD-HHMMSS>.zip    # 完整插件包
--   通过 GET /reader3/getWebdavFile?path=/plugin/<相对路径>&accessToken=<token>
--   下载（接口带鉴权，token 失效自动重登一次）。此模式不依赖后端版本。
--
-- 【raw 模式】设置环境变量 XREAD_UPDATER_URL（或 settings.update_url）指向
--   更新根目录（带尾斜杠）时，直接 GET <root><相对路径>。后端 router.rs 的
--   /assets not_found fallback 到 ASSETS_DIR 时，可把更新包放 assets/plugin/。
--
-- manifest2.json 由 publish_update.py 生成：
-- {
--   "version": "0.5.9",          -- 插件版本（对应 _meta.lua）
--   "build":   "20261124-204241",
--   "notes":   "更新说明文本",
--   "package": "xread.koplugin_v0.5.9_20261124-204241.zip",
--   "package_size": 123456, "package_md5": "hex", "files_count": 110,
--   "files": [ {"path":"main.lua","size":1234,"md5":"hex"}, ... ]
-- }
-- 规范包名：xread.koplugin_v<版本>_<YYYYMMDD-HHMMSS>.zip

local ltn12 = require("ltn12")
local http = require("socket.http")
local json = require("json")          -- KOReader 内置 LuaJSON（null 会解码成 function 哨兵）
local md5lib = require("ffi/MD5")     -- md5.sumFile(filename) -> hex string
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DataStorage = require("datastorage")

local Updater = {}

-- 递归清洗 LuaJSON 的 function 哨兵（与 client.lua sanitizeJson 一致）
local function sanitizeJson(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        if type(v) == "function" then
            t[k] = nil
        elseif type(v) == "table" then
            sanitizeJson(v)
        end
    end
end

--- 从 _meta.lua 文本解析 version（不走 require，避免模块缓存读到旧值）
local function parseVersionFromFile(text)
    return text and text:match("version%s*=%s*[\"']([^\"']+)[\"']") or nil
end

--- "0.5.0" -> {0,5,0}
local function versionParts(v)
    local parts = {}
    for num in tostring(v or ""):gmatch("%d+") do
        parts[#parts + 1] = tonumber(num) or 0
    end
    return parts
end

--- 语义比较版本号：远端 > 本地 返回 true
function Updater.versionNewer(remote, local_v)
    local a, b = versionParts(remote), versionParts(local_v)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

--- 插件根目录（xread/updater.lua -> 上两级）
function Updater.getPluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local module_dir = source:match("^(.*[/\\])") or ""
    return module_dir:gsub("xread[/\\]$", "")
end

--- 本地插件版本（读 _meta.lua 文件）
function Updater:getLocalVersion(plugin_root)
    plugin_root = plugin_root or (self and self.plugin_root) or Updater.getPluginRoot()
    plugin_root = plugin_root or Updater.getPluginRoot()
    local f = io.open(plugin_root .. "_meta.lua", "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return parseVersionFromFile(text)
end

--- 本地更新清单缓存路径（KOReader 数据目录，不写插件目录避免真机只读问题）
function Updater.getLocalManifestPath()
    return DataStorage:getDataDir() .. "/xread_update_manifest.json"
end

function Updater:new(opts)
    opts = opts or {}
    local o = {}
    o.plugin_root = opts.plugin_root or Updater.getPluginRoot()
    o.client = opts.client                -- xread/client.lua 实例（取 address）
    o.url_root = opts.url_root            -- manifest 所在目录（带尾斜杠）
    setmetatable(o, { __index = Updater })
    return o
end

--- GET 下载到字符串（不抛错，返回 nil, err）
--- 注意 socket.http.request 依次返回 1, 状态码, headers；pcall 失败时第二个值是错误信息
local function httpGetRaw(url)
    local chunks = {}
    local ok, r1, r2 = pcall(http.request, {
        url = url,
        sink = ltn12.sink.table(chunks),
    })
    if not ok then return nil, tostring(r1) end
    if tonumber(r2) ~= 200 then return nil, "HTTP " .. tostring(r2) end
    return table.concat(chunks)
end

--- 更新文件根 URL（raw 模式）：settings.update_url > 环境变量；未设置返回 nil（webdav 模式）
function Updater:getRawUrlRoot()
    if self.url_root then return self.url_root end
    local env_url = os.getenv("XREAD_UPDATER_URL")
    if env_url and env_url ~= "" then
        self.url_root = env_url
        return self.url_root
    end
    return nil
end

--- 构造单个更新文件的下载 URL
--- raw 模式：<root><相对路径>；webdav 模式：getWebdavFile 接口 + accessToken
function Updater:fetchUrl(rel, cache_bust)
    local root = self:getRawUrlRoot()
    if root then
        return root .. rel .. "?v=" .. tostring(cache_bust)
    end
    local base = self.client and self.client.address or "http://127.0.0.1:7777"
    -- 只编码保留字符，保留字母数字与 ._-/ 以外的字符
    local enc = tostring(rel):gsub("[^%w%._%-/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local token = (self.client and self.client.accessToken) or ""
    return base .. "/reader3/getWebdavFile?path=/plugin/" .. enc
        .. "&accessToken=" .. tostring(token)
        .. "&v=" .. tostring(cache_bust)
end

--- 带重登的 GET：webdav 模式下 token 失效（401/403）自动用 client 凭据重登一次
function Updater:httpFetch(rel)
    local body, err = httpGetRaw(self:fetchUrl(rel, os.time()))
    if not body and (err == "HTTP 401" or err == "HTTP 403") and self.client
            and self.client.username then
        local ok = pcall(function()
            self.client:login(self.client.username, self.client.password)
        end)
        if ok then
            return httpGetRaw(self:fetchUrl(rel, os.time()))
        end
    end
    return body, err
end

--- 拉取远端 manifest2.json（失败抛错，规范 zip 包模式）
function Updater:fetchManifest()
    local body, err = self:httpFetch("manifest2.json")
    if not body then
        error("无法获取更新清单：" .. tostring(err), 0)
    end
    local manifest = json.decode(body)
    if type(manifest) ~= "table" or not manifest.version
            or type(manifest.package) ~= "string" then
        error("更新清单格式无效", 0)
    end
    sanitizeJson(manifest)
    return manifest
end

--- 读取本地清单缓存（从未更新过则 nil）
function Updater:loadLocalManifest()
    local f = io.open(Updater.getLocalManifestPath(), "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    local m = json.decode(body)
    if type(m) ~= "table" then return nil end
    sanitizeJson(m)
    return m
end

function Updater:saveLocalManifest(manifest)
    local path = Updater.getLocalManifestPath()
    local f = io.open(path, "w")
    if not f then return false end
    local slim = {
        version = manifest.version,
        build = manifest.build,
        package = manifest.package,
    }
    f:write(json.encode(slim))
    f:close()
    return true
end

--- 安全校验：只允许插件内的相对路径
local function safeRelPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if path:sub(1, 1) == "/" or path:find("\\", 1, true) then return nil end
    if path:find("%.%.") then return nil end     -- 禁 .. 任意段
    if path:sub(1, 1) == "." then return nil end -- 禁隐藏文件
    return path
end

--- 逐级创建目录（path 为绝对路径目录）
local function ensureDir(path)
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        parts[#parts + 1] = seg
    end
    local cur = ""
    for i, seg in ipairs(parts) do
        cur = cur .. "/" .. seg
        if i > 1 and not lfs.attributes(cur, "mode") then
            pcall(lfs.mkdir, cur)
        end
    end
end

--- 本地文件 md5（不存在返回 nil）
local function localMd5(path)
    if not lfs.attributes(path, "mode") then return nil end
    local ok, sum = pcall(md5lib.sumFile, path)
    if ok then return sum end
    return nil
end

--- 更新包落盘目录：<数据目录>/xread_update/
--- 压缩包与「同名解压目录」同级存放，每次更新的包可单独辨认，不再互相覆盖
local UPDATE_PKG_DIRNAME = "xread_update"
local KEEP_PACKAGES = 3          -- 只保留最近 N 次更新的包与解压目录

local function updatePkgRoot()
    return DataStorage:getDataDir() .. "/" .. UPDATE_PKG_DIRNAME
end

--- 从清单里的包名（可能是 URL 或路径）取出安全的文件基名，去掉 .zip
local function packageBaseName(name)
    local p = tostring(name or ""):gsub("\\", "/")
    p = p:match("[^/]+$") or ""
    if p:sub(-4):lower() == ".zip" then p = p:sub(1, -5) end
    p = p:gsub("[^%w%._%-]", "_")          -- 禁路径分隔与特殊字符
    p = p:gsub("^%.+", "")                 -- 禁隐藏名
    if p == "" then return nil end
    return p
end

--- 删除目录（存在才删）；非目录退回单文件删除
local function removeTree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return end
    if mode == "directory" then
        local ok, util = pcall(require, "ffi/util")
        if ok and util and util.purgeDir then
            pcall(util.purgeDir, path)
            return
        end
    end
    pcall(os.remove, path)
end

--- 记录本次已安装的包，并清理超出保留数量的旧包（压缩包 + 同名解压目录）
local function noteAppliedPackage(root, base, keep)
    local names = {}
    local f = io.open(root .. "/packages.txt", "r")
    if f then
        for line in f:lines() do
            local n = line:match("^%s*(.-)%s*$")
            if n ~= "" and n ~= base then names[#names + 1] = n end
        end
        f:close()
    end
    names[#names + 1] = base
    local over = #names - keep
    for i = 1, over do
        removeTree(root .. "/" .. names[i])
        pcall(os.remove, root .. "/" .. names[i] .. ".zip")
    end
    local kept = {}
    for i = math.max(1, over + 1), #names do kept[#kept + 1] = names[i] end
    local w = io.open(root .. "/packages.txt", "w")
    if w then
        w:write(table.concat(kept, "\n") .. "\n")
        w:close()
    end
end

--- zip 包条目路径 → 插件根相对路径（兼容带 xread.koplugin/ 前缀的安装包）
local function packageRelPath(path)
    local p = tostring(path or ""):gsub("\\", "/")
    if p:sub(1, 2) == "./" then p = p:sub(3) end
    local inner = p:match("^xread%.koplugin/(.+)$")
    if inner then p = inner end
    return safeRelPath(p)
end

--- 规范 zip 包更新：下载整包 → md5/size 校验 → 文件级 md5 增量替换
--- on_progress(done, total, rel_path, skipped)
function Updater:applyPackage(manifest, on_progress)
    local zip_name = manifest.package
    if not zip_name or zip_name == "" then error("更新清单缺少包名", 0) end
    local base = packageBaseName(zip_name)
    if not base then error("更新包名不合法：" .. tostring(zip_name), 0) end
    local root = updatePkgRoot()
    ensureDir(root)
    local zip_path = root .. "/" .. base .. ".zip"
    local extract_dir = root .. "/" .. base     -- 与压缩包同名、同级

    local body, err = self:httpFetch(zip_name)
    if not body then error("下载更新包失败：" .. tostring(err), 0) end
    local f = io.open(zip_path, "wb")
    if not f then error("无法写入更新包：" .. zip_path, 0) end
    f:write(body)
    f:close()
    self._last_package_file = zip_path
    self._last_package_dir = extract_dir

    local okall, changed, skipped = pcall(function()
        if manifest.package_size and #body ~= tonumber(manifest.package_size) then
            error("更新包大小不符", 0)
        end
        if manifest.package_md5 and localMd5(zip_path) ~= manifest.package_md5 then
            error("更新包校验不符", 0)
        end
        -- 解压目标：与压缩包同名同级的目录；先清空，避免上次残留混进来
        removeTree(extract_dir)
        ensureDir(extract_dir)
        local okreq, Archiver = pcall(require, "ffi/archiver")
        if not okreq then error("当前固件不支持 zip 解压：" .. tostring(Archiver), 0) end
        local arc = Archiver.Reader:new()
        if not arc:open(zip_path) then error("无法打开更新包", 0) end
        local entries = {}
        for e in arc:iterate() do
            if e.mode == "file" then
                local rel = packageRelPath(e.path)
                if rel then entries[#entries + 1] = { key = e.path, rel = rel } end
            end
        end
        local has_meta = false
        for _, e in ipairs(entries) do
            if e.rel == "_meta.lua" then has_meta = true end
        end
        if not has_meta then error("更新包缺少 _meta.lua", 0) end

        local changed_n, skipped_n, failed = 0, 0, nil
        for i, e in ipairs(entries) do
            if on_progress then pcall(on_progress, i, #entries, e.rel, 0) end
            local content = arc:extractToMemory(e.key)
            if not content then
                failed = failed or {}
                failed[#failed + 1] = e.rel .. "（解压失败）"
            else
                if e.rel == "_meta.lua" then
                    local pv = parseVersionFromFile(content)
                    if pv ~= tostring(manifest.version) then
                        error("更新包内版本不符：" .. tostring(pv), 0)
                    end
                end
                -- 先落盘到同名解压目录留档，再替换插件内文件
                local epath = extract_dir .. "/" .. e.rel
                local edir = epath:match("^(.*)/[^/]+$")
                if edir then ensureDir(edir) end
                local ef = io.open(epath, "wb")
                if ef then
                    ef:write(content)
                    ef:close()
                end
                local target = self.plugin_root .. e.rel
                local dir = target:match("^(.*)/[^/]+$")
                if dir then ensureDir(dir) end
                local tmp = target .. ".xup_tmp"
                local tf = io.open(tmp, "wb")
                if not tf then
                    failed = failed or {}
                    failed[#failed + 1] = e.rel .. "（无法写入）"
                else
                    tf:write(content)
                    tf:close()
                    local new_md5, old_md5 = localMd5(tmp), localMd5(target)
                    if new_md5 and old_md5 and new_md5 == old_md5 then
                        os.remove(tmp)
                        skipped_n = skipped_n + 1
                    else
                        os.remove(target)
                        if os.rename(tmp, target) then
                            changed_n = changed_n + 1
                        else
                            os.remove(tmp)
                            failed = failed or {}
                            failed[#failed + 1] = e.rel .. "（替换失败）"
                        end
                    end
                end
            end
        end
        arc:close()
        if failed and #failed > 0 then
            error("以下文件更新失败：\n" .. table.concat(failed, "\n"), 0)
        end
        return changed_n, skipped_n
    end)
    if not okall then
        -- 失败：压缩包与解压目录都保留，便于事后排查；本地清单不落盘
        error(changed, 0)
    end
    noteAppliedPackage(root, base, KEEP_PACKAGES)
    self:saveLocalManifest(manifest)
    logger.info("xread updater: applied package", tostring(manifest.version),
        "changed", tostring(changed), "skipped", tostring(skipped),
        "package", zip_path, "extract", extract_dir)
    return changed, skipped
end

--- 最近一次更新的包路径与解压目录（UI 提示用，未更新过返回 nil）
function Updater:getLastPackage()
    return self._last_package_file, self._last_package_dir
end

--- 应用更新：下载 zip 整包 → 校验 → 文件级 md5 增量替换
--- on_progress(done, total, path, skipped)
--- 成功返回 changed, skipped；失败抛错（version 不落盘，下次重试）
function Updater:apply(manifest, on_progress)
    if type(manifest.package) ~= "string" or manifest.package == "" then
        error("更新清单缺少包名", 0)
    end
    return self:applyPackage(manifest, on_progress)
end

--- 只检查不下载：返回 nil（异常）/ manifest + { newer, local_version, need_count }
function Updater:check()
    local manifest = self:fetchManifest()
    local local_version = self:getLocalVersion()
    local newer = Updater.versionNewer(manifest.version, local_version)
    local need_count = tonumber(manifest.files_count) or 0
    return manifest, {
        newer = newer,
        local_version = local_version,
        remote_version = manifest.version,
        total = need_count,
        skipped = 0,   -- zip 包模式的文件级差异在下载后判定
    }
end

return Updater
