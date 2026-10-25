-- Copyright (c) 2026 bottobot. MIT licensed.
local LuaSettings=require('luasettings')
local DataStorage=require('datastorage')
local lfs=require('libs/libkoreader-lfs')
local Http=require('bookfetch.http')
local M={}
local defaults={key='',mirrors={'https://annas-archive.pk','https://annas-archive.gl','https://annas-archive.gd'},libgen_mirrors={
    'https://libgen.li','https://libgen.gl','https://libgen.la','https://libgen.vg','https://libgen.bz'},
    download_folder='/mnt/onboard/Books',preferred_format='',bad_hosts={}}
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
M.copy=copy
function M.open()
    local path=DataStorage:getSettingsDir()..'/bookfetch.lua'
    local settings=LuaSettings:open(path)
    local self={settings=settings,path=path}
    return setmetatable(self,{__index=M})
end
function M:get(name)
    local value=self.settings:readSetting(name)
    if value==nil then value=defaults[name] end
    return copy(value)
end
function M:set(name,value)
    assert(defaults[name]~=nil,'Unknown Book Fetch setting')
    self.settings:saveSetting(name,copy(value)); self.settings:flush()
end
function M:merge_bad(entries)
    local all=self:get('bad_hosts')
    for host,entry in pairs(entries or {}) do
        if type(entry)=='table' and type(entry.at)=='number' and os.time()-entry.at<86400 then all[host]=entry end
    end
    for host,entry in pairs(all) do if os.time()-(tonumber(entry.at) or 0)>=86400 then all[host]=nil end end
    self:set('bad_hosts',all)
end
function M.mirrors(text)
    local out,seen={},{}
    for line in text:gmatch('[^\r\n]+') do
        line=line:match('^%s*(.-)%s*$'):gsub('/+$','')
        if line~='' then
            local url=Http.url(line)
            if not url or url.path~='/' then return nil,'Mirrors must be HTTPS base URLs, one per line' end
            if not seen[url.origin] then out[#out+1]=url.origin; seen[url.origin]=true end
        end
    end
    if #out==0 then return nil,'Enter at least one HTTPS mirror' end
    return out
end
function M.cafile()
    -- KOReader normally starts with its installation directory as cwd.
    for _,path in ipairs({lfs.currentdir()..'/data/ca-bundle.crt','/mnt/onboard/.adds/koreader/data/ca-bundle.crt'}) do
        if lfs.attributes(path,'mode')=='file' then return path end
    end
    return nil,'KOReader data/ca-bundle.crt was not found'
end
function M:snapshot()
    local out={}
    for name in pairs(defaults) do out[name]=self:get(name) end
    out.cafile=M.cafile()
    return out
end
return M
