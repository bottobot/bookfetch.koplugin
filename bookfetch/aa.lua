-- Copyright (c) 2026 bottobot. MIT licensed. Independently implemented adapter.
local Http=require('bookfetch.http')
local Parse=require('bookfetch.parse')
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
function AA:login(base)
    local key=self.settings.key or ''
    if key=='' then return nil,'Set your Anna\'s Archive secret key in Book Fetch settings' end
    local res,err=self.http:request(base..'/account/',{method='POST',body='key='..Http.encode(key),same_origin=true,
        inspect=function(r)
            if Parse.blocked(r.code,r.headers,r.body) then return nil,'Blocked by DDoS-Guard on '..r.host end
            -- A login redirect is success when the response sets the session cookie.
            if r.headers['set-cookie'] then
                local cookies={}
                for name,value in r.headers['set-cookie']:gmatch('(aa_[%w_%-]+)=([^;,\r\n ]+)') do
                    cookies[#cookies+1]=name..'='..value
                end
                if #cookies>0 then self.sessions[base]=table.concat(cookies,'; ') end
            end
            return true
        end})
    if not res then return nil,err end
    if not self.sessions[base] then return nil,'Anna\'s Archive rejected the key on '..Http.url(base).host end
    return true
end
function AA:authenticated(base,path)
    if not self.sessions[base] then
        local ok,err=self:login(base); if not ok then return nil,err end
    end
    for attempt=1,2 do
        local blocked=false
        local res,err=self.http:request(base..path,{headers={cookie=self.sessions[base]},same_origin=true,
            inspect=function(r)
                if Parse.blocked(r.code,r.headers,r.body) then
                    blocked=true; return nil,'Blocked by DDoS-Guard on '..r.host
                end
                if r.code==403 then return nil,'Access denied on '..r.host end
                return true
            end})
        if res and res.code==200 then return res end
        if attempt==1 and (blocked or (err and err:find('Access denied',1,true))) then
            self.sessions[base]=nil
            local ok,why=self:login(base); if not ok then return nil,why end
        else return nil,err or 'HTTP '..res.code..' on '..res.host end
    end
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
        local res,err=self:authenticated(base,path)
        if res then
            local ok,data=pcall(require('json').decode,res.body)
            if not ok or type(data)~='table' then err='Invalid fast-download API response on '..res.host
            elseif type(data.error)=='string' and data.error~='' then return nil,Http.redact(data.error,self.settings.key),'api'
            elseif type(data.download_url)=='string' and Http.url(data.download_url) then
                return {url=data.download_url,quota=simple(data.account_fast_download_info)}
            else err='No HTTPS download URL returned by '..res.host end
        end
        errors[#errors+1]=err
    end
    return nil,table.concat(errors,'\n')
end
return AA
