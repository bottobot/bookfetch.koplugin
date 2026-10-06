-- Copyright (c) 2026 bottobot. MIT licensed. Independently implemented adapter.
local Http=require('bookfetch.http')
local Parse=require('bookfetch.parse')
local Jar=require('bookfetch.cookies')
local AA={}
local function simple(value)
    local kind=type(value)
    if kind=='string' or kind=='number' or kind=='boolean' then return value end
    if kind=='table' then
        local out={}
        for k,v in pairs(value) do
            if type(k)=='string' or type(k)=='number' then out[k]=simple(v) end
        end
        return out
    end
end
AA.__index=AA
function AA.new(client,settings,sessions)
    return setmetatable({http=client,settings=settings,sessions=sessions or {}},AA)
end
function AA:jar(base)
    local entries=self.sessions[base]
    if type(entries)~='table' then entries={}; self.sessions[base]=entries end
    return Jar.new(entries)
end
function AA:login(base)
    local key=self.settings.key or ''
    if key=='' then return nil,"Set your Anna's Archive secret key in Book Fetch settings",'terminal' end
    local jar=self:jar(base)
    local res,err,kind=self.http:request(base..'/account/',{method='POST',body='key='..Http.encode(key),
        same_origin=true,cookie_jar=jar,inspect=function(r)
            if Parse.blocked(r.code,r.headers,r.body) then return nil,'Blocked by DDoS-Guard on '..r.host end
            return true
        end})
    if not res then return nil,err,kind end
    if not jar:has_session() then return nil,"Anna's Archive rejected the key on "..Http.url(base).host,'terminal' end
    return true
end
function AA:authenticated(base,path)
    local jar=self:jar(base)
    if not jar:has_session() then
        local ok,err,kind=self:login(base); if not ok then return nil,err,kind end
    end
    local res,err,kind=self.http:request(base..path,{cookie_jar=jar,same_origin=true,inspect=function(r)
        if Parse.blocked(r.code,r.headers,r.body) then return nil,'Blocked by DDoS-Guard on '..r.host end
        return true
    end})
    if res and res.code==200 then return res end
    return nil,err or ('HTTP '..res.code..' on '..res.host),kind
end
local function terminal(message)
    local lower=message:lower():gsub('_',' '):gsub('%-',' ')
    for _,phrase in ipairs({'invalid key','invalid secret','quota exhausted','quota exceeded','no more domains',
        'out of range','not a member','membership required','daily limit','no downloads left','not logged in'}) do
        if lower:find(phrase,1,true) then return true end
    end
    return false
end
function AA:search(query,format,language,page)
    local errors={}
    local path='/search?q='..Http.encode(query)..'&ext='..Http.encode(format)..'&lang='..Http.encode(language)..'&page='..(page or 1)
    for _,base in ipairs(self.settings.mirrors) do
        local res,err=self:authenticated(base,path)
        if res then
            local books=Parse.search(res.body or '')
            for _,book in ipairs(books) do book.mirror=base end
            return {books=books,page=page or 1,mirror=base}
        end
        errors[#errors+1]=err
    end
    return nil,table.concat(errors,'\n')
end
function AA:fast(book,index)
    if not Parse.is_md5(book.md5) then return nil,'Invalid book MD5' end
    local mirrors={}
    for _,base in ipairs(self.settings.mirrors) do
        if base==book.mirror then mirrors[1]=base end
    end
    for _,base in ipairs(self.settings.mirrors) do if base~=mirrors[1] then mirrors[#mirrors+1]=base end end
    local errors={}
    for _,base in ipairs(mirrors) do
        local path='/dyn/api/fast_download.json?md5='..book.md5:lower()..'&key='..Http.encode(self.settings.key)
            ..'&domain_index='..(index or 0)..'&path_index=0'
        local res,err,kind=self:authenticated(base,path)
        if not res and kind=='terminal' then
            return nil,Http.redact('Fast-download API on '..Http.url(base).host..' (domain_index='..(index or 0)..'): '..err,self.settings.key),kind
        end
        if res then
            local ok,data=pcall(require('json').decode,res.body)
            if not ok or type(data)~='table' then err='Invalid fast-download API response on '..res.host
            elseif type(data.error)=='string' and data.error~='' then
                local context='Fast-download API on '..res.host..' (domain_index='..(index or 0)..'): '
                return nil,Http.redact(context..data.error,self.settings.key),terminal(data.error) and 'terminal' or 'api'
            elseif type(data.download_url)=='string' and Http.url(data.download_url) then
                return {url=data.download_url,quota=simple(data.account_fast_download_info)}
            else err='No HTTPS download URL returned by '..res.host end
        end
        errors[#errors+1]=err
    end
    return nil,'domain_index='..(index or 0)..': '..table.concat(errors,'\n'),'api'
end
return AA
