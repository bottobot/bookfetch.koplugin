-- Copyright (c) 2026 bottobot. MIT licensed.
-- In-memory RFC 6265 subset for HTTPS account requests; entries survive worker IPC.
local Http=require('bookfetch.http')
local Jar={}
Jar.__index=Jar
function Jar.new(entries) return setmetatable({entries=entries or {}},Jar) end
local months={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local function expiry(value)
    local day,month,year,h,m,s=value:match('(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)')
    month=months[month]; year=tonumber(year)
    if not month or not year then return nil end
    -- UTC calendar arithmetic, independent of the reader's timezone.
    if year<1970 then return 0 end
    if year>9999 then return nil end
    local function leap(y) return y%4==0 and (y%100~=0 or y%400==0) end
    local function leap_days(y) return math.floor(y/4)-math.floor(y/100)+math.floor(y/400) end
    local days=(year-1970)*365+leap_days(year-1)-leap_days(1969)
    local lengths={31,28,31,30,31,30,31,31,30,31,30,31}
    for i=1,month-1 do days=days+lengths[i]+(i==2 and leap(year) and 1 or 0) end
    return (days+tonumber(day)-1)*86400+tonumber(h)*3600+tonumber(m)*60+tonumber(s)
end
local function domain_match(host,domain) return host==domain or host:sub(-#domain-1)=='.'..domain end
function Jar:update(url,header)
    if type(header)=='table' then for _,h in ipairs(header) do self:update(url,h) end; return end
    if type(header)~='string' then return end
    local parsed=assert(Http.url(url))
    -- Split coalesced Set-Cookie fields without splitting an Expires date.
    header=header:gsub(',%s*([%w_%-]+)%s*=', '\n%1=')
    for field in header:gmatch('[^\r\n]+') do
        local name,value=field:match('^%s*([%w_%-]+)=([^;]*)')
        if name then
            local path=parsed.path:gsub('%?.*$',''):match('^(.*)/') or ''
            if path=='' then path='/' end
            local cookie={name=name,value=value,domain=parsed.host,host_only=true,path=path}
            local max_age,valid
            valid=true
            for key,v in field:gmatch(';%s*([%w%-]+)%s*=?%s*([^;]*)') do
                key=key:lower()
                if key=='domain' then
                    cookie.domain=v:lower():gsub('^%.',''); cookie.host_only=false
                    valid=domain_match(parsed.host,cookie.domain)
                elseif key=='path' and v:sub(1,1)=='/' then cookie.path=v
                elseif key=='max-age' then max_age=tonumber(v)
                elseif key=='expires' then cookie.expires=expiry(v) end
            end
            if max_age then cookie.expires=os.time()+max_age end
            if valid then
                local id=name..'\t'..cookie.domain..'\t'..cookie.path
                if cookie.expires and cookie.expires<=os.time() then self.entries[id]=nil
                else self.entries[id]=cookie end
            end
        end
    end
end
function Jar:header(url)
    local parsed=assert(Http.url(url))
    local path=parsed.path:gsub('%?.*$','')
    local selected={}
    for id,c in pairs(self.entries) do
        if c.expires and c.expires<=os.time() then self.entries[id]=nil
        elseif (c.host_only and c.domain==parsed.host or not c.host_only and domain_match(parsed.host,c.domain))
            and path:sub(1,#c.path)==c.path
            and (c.path:sub(-1)=='/' or #path==#c.path or path:sub(#c.path+1,#c.path+1)=='/') then
            selected[#selected+1]=c
        end
    end
    table.sort(selected,function(a,b) if #a.path~=#b.path then return #a.path>#b.path end; return a.name<b.name end)
    local out={}; for _,c in ipairs(selected) do out[#out+1]=c.name..'='..c.value end
    if #out>0 then return table.concat(out,'; ') end
end
function Jar:has_session()
    for _,c in pairs(self.entries) do
        if c.name:match('^aa_') and c.value~='' and (not c.expires or c.expires>os.time()) then return true end
    end
    return false
end
return Jar
