-- xread.koplugin/xread/book_export.lua
-- 把后端书籍导出为 EPUB，写入 KOReader/Kindle 本地文档目录，供原生书架阅读。
--
-- Kindle 上 KOReader 与原生系统共用 /mnt/us/documents；其它平台用 KOReader
-- 的 home_dir（filemanagerutil.getDefaultDir）兜底到数据目录。后端没有整本下载
-- 接口，只有逐章 getBookContent，因此这里按目录逐章拉取后打包。
--
-- 两个关键设计（v0.6.14 起）：
--   1) **每章一个 XHTML**，而不是把几千章拼成一个 content.html。
--      单文件几 MB 时 crengine 打开极慢，Kindle 原生阅读器甚至会拒绝。
--   2) **失败章节统计**：超出阈值直接中止并报错，绝不把「（本章获取失败）」
--      写进书里再告诉用户"下载完成"——那样用户得到的是一本残书。
--
-- ✅ Lua 5.1 通用。

local DataStorage = require("datastorage")
local util        = require("util")
local lfs         = require("libs/libkoreader-lfs")

local BookExport = {}
BookExport.__index = BookExport

-- 默认容错阈值：失败超过 3 章**且**超过 5% 才中止
local DEFAULT_MAX_FAIL_COUNT = 3
local DEFAULT_MAX_FAIL_RATIO = 0.05

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function xmlEscape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&apos;")
    return s
end

-- 文档目录：Kindle 原生可读 /mnt/us/documents；其余用 KOReader home_dir
function BookExport:docDir()
    local ok_fm, fm = pcall(function() return require("apps/filemanager/filemanagerutil") end)
    local dir
    if ok_fm and fm and fm.getDefaultDir then
        local ok, d = pcall(fm.getDefaultDir)
        if ok and d and d ~= "" then dir = d end
    end
    if not dir or dir == "." then
        local ok_dev, Device = pcall(function() return require("device") end)
        if ok_dev and Device and Device.home_dir and Device.home_dir ~= "" then
            dir = Device.home_dir
        end
    end
    if not dir or dir == "" or dir == "." then
        dir = DataStorage:getDataDir() .. "/documents"
    end
    return dir
end

-- 导出目录：文档目录下的 xread 专属子文件夹。
-- 不把 EPUB 直接撒进文档根目录，避免和用户其它本地书混在一起；
-- 打开 KOReader 文件管理器 -> xread 文件夹，只看到自己下载的书。
function BookExport:exportDir()
    return self:docDir() .. "/xread"
end

local function safeFileName(s)
    s = tostring(s or "book"):gsub("[%/\\:%*%?\"<>|]", "_")
    if #s > 80 then s = s:sub(1, 80) end
    return s
end

-- 正文转 HTML 段落：沿用客户端已清洗的纯文本，按换行分段并转义
local function textToHtml(text)
    local out = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local t = trim(line)
        if t ~= "" then out[#out + 1] = "<p>" .. xmlEscape(t) .. "</p>" end
    end
    if #out == 0 then out[1] = "<p></p>" end
    return table.concat(out, "\n")
end

-- 单章 XHTML
local function chapterXhtml(title, content)
    return table.concat({
        '<?xml version="1.0" encoding="utf-8"?>',
        '<!DOCTYPE html>',
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>',
        xmlEscape(title),
        '</title><link rel="stylesheet" type="text/css" href="../stylesheet.css"/></head><body>',
        '<h1>', xmlEscape(title), '</h1>',
        textToHtml(content),
        '</body></html>',
    }, "\n")
end

--- 生成 EPUB。
-- @param book      table 书籍（name/author/bookUrl/origin）
-- @param chapters  table 目录数组，每项含 url/chapterUrl/title
-- @param getContent function(index, chapter) -> 正文字符串；返回 nil/"" 视为该章失败
-- @param onProgress function(done, total) 可选进度回调
-- @param opts      table 可选 { max_fail_count=3, max_fail_ratio=0.05 }
-- @return path | nil, err, stats
--         stats = { total=, written=, failed= }
function BookExport:createEpub(book, chapters, getContent, onProgress, opts)
    opts = opts or {}
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, _("目录为空，无法导出")
    end

    local ok_arch, Archiver = pcall(function() return require("ffi/archiver") end)
    if not ok_arch then return nil, _("当前固件不支持 EPUB 打包") end

    local dir = self:exportDir()
    local ok_mk = pcall(util.makePath, dir)
    if not ok_mk then return nil, _("文档目录不可写：") .. tostring(dir) end

    local name = safeFileName(book.name or "book")
    local path = dir .. "/" .. name .. ".epub"
    local tmp = path .. ".tmp"
    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return nil, _("无法创建 EPUB 文件")
    end

    local mtime = os.time()
    local total = #chapters
    local max_fail_count = tonumber(opts.max_fail_count) or DEFAULT_MAX_FAIL_COUNT
    local max_fail_ratio = tonumber(opts.max_fail_ratio) or DEFAULT_MAX_FAIL_RATIO

    local written, failed = 0, 0
    local manifest, spine, ncx_points = {}, {}, {}
    local fail_err

    local ok, err = pcall(function()
        epub:setZipCompression("store")
        epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
        epub:setZipCompression("deflate")
        epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)
        epub:addFileFromMemory("OEBPS/stylesheet.css",
            "body{line-height:1.6;} h1{font-size:1.4em;}", mtime)

        for i, ch in ipairs(chapters) do
            local title = trim(ch.title or ch.chapterTitle)
            if title == "" then title = T(_("第 %1 章"), tostring(i)) end
            local content = getContent(i, ch)
            if type(content) == "string" and content ~= "" then
                local file = string.format("text/chap_%04d.xhtml", i)
                epub:addFileFromMemory("OEBPS/" .. file, chapterXhtml(title, content), mtime)
                written = written + 1
                manifest[#manifest + 1] = string.format(
                    '<item id="ch%d" href="%s" media-type="application/xhtml+xml"/>', i, file)
                spine[#spine + 1] = string.format('<itemref idref="ch%d"/>', i)
                ncx_points[#ncx_points + 1] = string.format(
                    '<navPoint id="nav%d" playOrder="%d"><navLabel><text>%s</text></navLabel>'
                        .. '<content src="%s"/></navPoint>', i, #spine, xmlEscape(title), file)
            else
                failed = failed + 1
                fail_err = fail_err or tostring(content)
            end
            if onProgress then pcall(onProgress, i, total) end

            -- 边打边判：失败比例已经超标就没必要再耗下去
            if failed > max_fail_count and failed / i > max_fail_ratio then
                error(T(_("有 %1 章获取失败（已处理 %2/%3 章），已中止导出，避免得到残缺的书"),
                    tostring(failed), tostring(i), tostring(total)), 0)
            end
        end

        if written == 0 then
            error(_("所有章节都获取失败，未生成文件"), 0)
        end

        local ncx = {
            '<?xml version="1.0" encoding="utf-8"?>',
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head>',
            '<meta name="dtb:uid" content="xread-' .. tostring(mtime) .. '"/>',
            '<meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/>',
            '<meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>'
                .. xmlEscape(book.name or "book") .. '</text></docTitle><navMap>',
            table.concat(ncx_points, "\n"),
            '</navMap></ncx>',
        }

        local opf = {
            '<?xml version="1.0" encoding="utf-8"?>',
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">',
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
            '<dc:title>' .. xmlEscape(book.name or "book") .. '</dc:title>',
            '<dc:creator>' .. xmlEscape(book.author or "") .. '</dc:creator>',
            '<dc:language>zh-CN</dc:language>',
            '<dc:identifier id="bookid">xread-' .. tostring(mtime) .. '</dc:identifier>',
            '</metadata><manifest>',
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="css" href="stylesheet.css" media-type="text/css"/>',
            table.concat(manifest, "\n"),
            '</manifest><spine toc="ncx">',
            table.concat(spine, "\n"),
            '</spine></package>',
        }

        epub:addFileFromMemory("OEBPS/content.opf", table.concat(opf, "\n"), mtime)
        epub:addFileFromMemory("OEBPS/toc.ncx", table.concat(ncx, "\n"), mtime)
    end)

    -- 无论成败都要关句柄（原来只在成功路径 close，异常时句柄泄漏 + 留下 .tmp）
    local ok_close = pcall(function() epub:close() end)
    if not ok or not ok_close then
        pcall(os.remove, tmp)
        return nil, _("EPUB 打包失败：") .. tostring(err or ""),
            { total = total, written = written, failed = failed }
    end

    -- 原子落盘：rename 失败必须回报失败，不能假装成功返回一个不存在的路径
    if not os.rename(tmp, path) then
        pcall(os.remove, tmp)
        return nil, _("无法写入目标文件：") .. tostring(path),
            { total = total, written = written, failed = failed }
    end

    return path, nil, { total = total, written = written, failed = failed }
end

return BookExport
