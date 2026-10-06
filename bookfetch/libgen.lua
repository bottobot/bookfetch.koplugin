-- Copyright (c) 2026 bottobot. MIT licensed.
local Parse=require('bookfetch.parse')
local Http=require('bookfetch.http')
local LG={}
LG.__index=LG
function LG.new(client,settings) return setmetatable({http=client,settings=settings},LG) end
function LG:policy()
    local hosts={}
    for _,mirror in ipairs(self.settings.libgen_mirrors) do
        local parsed=Http.url(mirror)
        if parsed then hosts[#hosts+1]=parsed.host end
    end
    return function(parsed)
        for _,host in ipairs(hosts) do
            if parsed.host==host or parsed.host:sub(-#host-1)=='.'..host then return true end
        end
        return nil,'LibGen host is not allowlisted: '..parsed.host
    end
end
function LG:resolve(book,base)
    if not Parse.is_md5(book.md5) then return nil,'Invalid book MD5' end
    local policy=self:policy()
    local parsed,why=Http.url(base)
    if not parsed then return nil,why end
    local allowed,issue=policy(parsed)
    if not allowed then return nil,issue end
    local res,err=self.http:request(base..'/ads.php?md5='..book.md5:lower(),{
        origin_policy=policy,inspect=function(r)
            if Parse.blocked(r.code,r.headers,r.body) then return nil,'Blocked by DDoS-Guard on '..r.host end
            return true
        end})
    if not res then return nil,err end
    if res.code~=200 then return nil,'HTTP '..res.code..' on '..res.host end
    local link,problem=Parse.libgen(res.body or '',book.md5)
    if not link then return nil,problem..' on '..res.host end
    local target,error_message=Http.resolve(res.url,link)
    if not target then return nil,error_message end
    local accepted,reason=policy(Http.url(target))
    if not accepted then return nil,reason end
    return target
end
return LG
