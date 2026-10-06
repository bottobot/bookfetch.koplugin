-- Copyright (c) 2026 bottobot. MIT licensed.
local Parse=require('bookfetch.parse')
local Http=require('bookfetch.http')
local LG={}
LG.__index=LG
function LG.new(client,settings) return setmetatable({http=client,settings=settings},LG) end
function LG:resolve(book,base)
    if not Parse.is_md5(book.md5) then return nil,'Invalid book MD5' end
    local allowed={}
    for _,mirror in ipairs(self.settings.libgen_mirrors) do allowed[Http.url(mirror).origin]=true end
    if not allowed[base] then return nil,'LibGen mirror is not allowlisted' end
    local res,err=self.http:request(base..'/ads.php?md5='..book.md5:lower(),{
        inspect=function(r)
            if not allowed[Http.url(r.url).origin] then return nil,'LibGen redirect left the mirror allowlist' end
            if Parse.blocked(r.code,r.headers,r.body) then return nil,'Blocked by DDoS-Guard on '..r.host end
            if r.headers.location then
                local next_url=Http.resolve(r.url,r.headers.location)
                if not next_url or not allowed[Http.url(next_url).origin] then return nil,'LibGen redirect left the mirror allowlist' end
            end
            return true
        end})
    if not res then return nil,err end
    if res.code~=200 then return nil,'HTTP '..res.code..' on '..res.host end
    local link,why=Parse.libgen(res.body or '',book.md5)
    if not link then return nil,why..' on '..res.host end
    local target,issue=Http.resolve(res.url,link)
    if not target then return nil,issue end
    if not allowed[Http.url(target).origin] then return nil,'LibGen link is not on an allowlisted mirror' end
    return target
end
return LG
