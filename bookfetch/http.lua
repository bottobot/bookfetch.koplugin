-- Copyright (c) 2026 bottobot. MIT licensed.
-- No KOReader UI dependency. All requests are HTTPS and redirects are explicit.
local M = {}
M.USER_AGENT = 'Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
function M.encode(s)
    return (tostring(s or ''):gsub('[^%w%-._~]',function(c) return string.format('%%%02X',c:byte()) end))
end
function M.redact(s, secret)
    s=tostring(s or '')
    if secret and secret~='' then
        for _,key in ipairs({secret,M.encode(secret)}) do
            s=s:gsub(key:gsub('(%W)','%%%1'),'[REDACTED]')
        end
    end
    s=s:gsub('([?&][^=&#%s]+)=([^&#%s]*)',function(k,v)
        local decoded=k:sub(2):gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end):lower()
        if decoded=='key' or decoded=='token' or decoded=='secret' then return k..'=[REDACTED]' end
        return k..'='..v
    end)
    return s
end
function M.url(s)
    if type(s)~='string' or s:find('[%c%s\\]') then return nil,'Invalid URL' end
    local scheme,authority,path=s:match('^(https)://([^/?#]+)(.*)$')
    if not scheme or authority:find('@',1,true) then return nil,'Only HTTPS URLs without user information are allowed' end
    local host,port=authority:match('^([%w%.%-]+):(%d+)$')
    if not host then host=authority; port='443' end
    if not host:match('^[%w][%w%.%-]*$') or host:find('%.%.') or tonumber(port)>65535 or tonumber(port)<1 then
        return nil,'Invalid HTTPS host or port'
    end
    path=path:gsub('#.*$','')
    if path=='' then path='/' elseif path:sub(1,1)=='?' then path='/'..path end
    return {host=host:lower(),port=tonumber(port),authority=authority:lower(),origin='https://'..authority:lower(),path=path}
end
function M.resolve(base,location)
    local parsed,err=M.url(base)
    if not parsed then return nil,err end
    if type(location)~='string' or location=='' then return nil,'Missing redirect location' end
    local target
    if location:sub(1,2)=='//' then target='https:'..location
    elseif location:match('^[%a][%w+.-]*:') then target=location
    elseif location:sub(1,1)=='/' then target=parsed.origin..location
    elseif location:sub(1,1)=='?' then target=parsed.origin..parsed.path:gsub('%?.*$','')..location
    else
        local dir=parsed.path:gsub('%?.*$',''):match('^(.*)/') or ''
        target=parsed.origin..dir..'/'..location
        -- Normalize relative dot segments, preserving query bytes.
        local head,tail=target:match('^(https://[^/]+)(/.*)$')
        local path,query=tail:match('^([^?]*)(.*)$')
        local parts={}
        for part in path:gmatch('[^/]+') do
            if part=='..' then table.remove(parts) elseif part~='.' then parts[#parts+1]=part end
        end
        target=head..'/'..table.concat(parts,'/')..query
    end
    local valid,why=M.url(target)
    if not valid then return nil,why end
    return target
end
function M.matches_host(host, pattern)
    host,pattern=host:lower(),pattern:lower()
    if pattern:find('\0',1,true) then return false end
    if host==pattern then return true end
    local suffix=pattern:match('^%*%.(.+)$')
    return suffix and suffix:find('%.') and host:match('^[^.]+%.(.+)$')==suffix or false
end
local function check_host(cert,host)
    if not cert then return nil,'TLS peer did not provide a certificate' end
    local ext=cert:extensions() or {}
    local san=ext['2.5.29.17']
    local ip_address=host:match('^[%d%.]+$')~=nil
    if san then
        for _,name in ipairs(san.dNSName or {}) do if not ip_address and M.matches_host(host,name) then return true end end
        for _,ip in ipairs(san.iPAddress or {}) do if ip==host then return true end end
        return nil,'TLS certificate hostname mismatch'
    end
    for _,field in ipairs(cert:subject() or {}) do
        if not ip_address and field.oid=='2.5.4.3' and M.matches_host(host,field.value) then return true end
    end
    return nil,'TLS certificate hostname mismatch'
end
M.check_host=check_host
-- LuaSocket's built-in chunked source may receive an entire HTTP chunk at once.
-- Keep reads bounded even if a partner declares a very large transfer chunk.
function M.body_source(sock,headers)
    local transfer=(headers['transfer-encoding'] or ''):lower()
    if transfer~='' and transfer~='identity' and transfer~='chunked' then
        return nil,'Unsupported Transfer-Encoding'
    end
    local length=tonumber(headers['content-length'])
    if headers['content-length'] and (not length or length<0 or length%1~=0) then
        return nil,'Invalid Content-Length'
    end
    local chunked=transfer=='chunked'
    local remaining=chunked and 0 or length
    local ended,pending_error,separator=false,nil,false
    local function line(label)
        local chars={}
        -- Numeric one-byte receives cap allocation even for an unterminated line.
        for i=1,8192 do
            local c,err=sock:receive(1)
            if not c then return nil,err or 'Incomplete '..label end
            if c=='\n' then return table.concat(chars):gsub('\r$','') end
            chars[i]=c
        end
        return nil,label..' too large'
    end
    local function receive(n,closing_allowed)
        local chunk,err,partial=sock:receive(n)
        if chunk then return chunk end
        if partial and #partial>0 then
            if err=='closed' and closing_allowed then ended=true else pending_error=err or 'Incomplete response' end
            return partial
        end
        if err=='closed' and closing_allowed then ended=true; return nil end
        return nil,err or 'Incomplete response'
    end
    return function()
        if pending_error then local err=pending_error; pending_error=nil; ended=true; return nil,err end
        if ended then return nil end
        if chunked then
            if remaining==0 then
                if separator then
                    local crlf,err=sock:receive(2)
                    if crlf~='\r\n' then return nil,err or 'Invalid chunk separator' end
                end
                local header,err=line('Chunk header')
                if not header then return nil,err end
                local size=header:match('^%s*(%x+)%s*;?.*$')
                remaining=tonumber(size,16)
                if not remaining then return nil,'Invalid chunk length' end
                if remaining==0 then
                    local total=0
                    repeat
                        header,err=line('Trailer')
                        if not header then return nil,err end
                        total=total+#header+2
                        if total>65536 then return nil,'Trailers too large' end
                    until header==''
                    ended=true; return nil
                end
                separator=true
            end
        elseif remaining==0 then ended=true; return nil end
        local count=math.min(65536,remaining or 65536)
        local chunk,err=receive(count,not chunked and length==nil)
        if chunk and remaining then remaining=remaining-#chunk end
        return chunk,err
    end
end
local Client={}
Client.__index=Client
function M.new(options)
    options=options or {}
    return setmetatable({cafile=assert(options.cafile,'CA bundle required'),secret=options.secret,
        bad_hosts=options.bad_hosts or {},transport=options.transport,on_host=options.on_host,on_bad=options.on_bad},Client)
end
function Client:bad(host)
    local entry=self.bad_hosts[host]
    if entry and os.time()-(tonumber(entry.at) or 0)<86400 then return entry.reason end
    self.bad_hosts[host]=nil
end
function Client:mark_bad(host,reason)
    self.bad_hosts[host]={at=os.time(),reason=M.redact(reason,self.secret)}
    if self.on_bad then self.on_bad(self.bad_hosts) end
end
function Client:once(url,opts)
    if self.transport then return self.transport(url,opts) end
    local parsed,err=M.url(url)
    if not parsed then return nil,err end
    local socket_http=require('socket.http')
    local https=require('ssl.https')
    local ltn12=require('ltn12')
    -- socketutil's mutations are confined to the worker and restored after every request.
    local has_util,socketutil=pcall(require,'socketutil')
    local old_http,old_https=socket_http.TIMEOUT,https.TIMEOUT
    local old_block,old_total
    if has_util then
        old_block,old_total=socketutil.block_timeout,socketutil.total_timeout
        socketutil:set_timeout(15,-1)
    else socket_http.TIMEOUT,https.TIMEOUT=15,15 end
    local conn, sink_error,connected
    local function perform()
        local factory=https.tcp{verify='peer',cafile=self.cafile,protocol='any',
            options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}}
        conn=socket_http.open(parsed.host,parsed.port,function()
            local c=factory()
            local connect=c.connect
            function c:connect(host,port)
                local called,ok,why=pcall(connect,self,host,port)
                if not called then self.sock:close(); error(ok,0) end
                if not ok then self.sock:close(); return nil,why end
                local verified,problem=check_host(self.sock:getpeercertificate(),host)
                if not verified then self.sock:close(); return nil,problem end
                self.sock:settimeout(60,'b'); self.sock:settimeout(-1,'t')
                return 1
            end
            return c
        end)
        local headers={host=parsed.authority,['user-agent']=M.USER_AGENT,connection='close',
            ['accept-encoding']='identity',accept='*/*'}
        for k,v in pairs(opts.headers or {}) do
            assert(not tostring(k):find('[%c]') and not tostring(v):find('[%c]'),'Invalid HTTP header')
            headers[k:lower()]=v
        end
        if opts.body then
            headers['content-length']=tostring(#opts.body)
            headers['content-type']='application/x-www-form-urlencoded'
        end
        conn:sendrequestline(opts.method or 'GET',parsed.path)
        conn:sendheaders(headers)
        if opts.body then conn:sendbody(headers,ltn12.source.string(opts.body)) end
        local code,status=conn:receivestatusline()
        assert(code,'Invalid HTTP status')
        connected=true
        local response_headers=conn:receiveheaders()
        local interim=0
        while code>=100 and code<200 do
            interim=interim+1; assert(interim<=5,'Too many interim responses')
            code,status=conn:receivestatusline(); response_headers=conn:receiveheaders()
        end
        local response={code=code,headers=response_headers,url=url,host=parsed.host,status=status}
        local sink,problem
        if opts.sink_factory then sink,problem=opts.sink_factory(response) end
        if problem then return nil,problem,'response' end
        -- Redirect/error responses never reach a caller's file sink.
        if not sink then
            local chunks,size={},0
            sink=function(chunk,sinkerr)
                if sinkerr then return nil,sinkerr end
                if chunk then
                    size=size+#chunk
                    if size>(opts.max_body or 4*1024*1024) then return nil,'Response too large' end
                    chunks[#chunks+1]=chunk
                end
                return 1
            end
            response.chunks=chunks
        end
        local checked_sink=function(chunk,err)
            local accepted,issue=sink(chunk,err)
            if not accepted and not err then sink_error=issue or 'Response sink failed' end
            return accepted,issue
        end
        if code~=204 and code~=304 and opts.method~='HEAD' then
            local source,issue=M.body_source(conn.c,response_headers)
            if not source then return nil,issue,'response' end
            conn.try(ltn12.pump.all(source,checked_sink))
        end
        if response.chunks then response.body=table.concat(response.chunks); response.chunks=nil end
        return response
    end
    local ok,res,why,kind=pcall(perform)
    if conn then pcall(conn.close,conn) end
    if has_util then socketutil:set_timeout(old_block,old_total) end
    socket_http.TIMEOUT,https.TIMEOUT=old_http,old_https
    if not ok then
        local problem=type(res)=='table' and res[1] or res
        return nil,M.redact(sink_error or problem,self.secret),sink_error and 'response' or connected and 'body' or 'transport'
    end
    return res,why,kind
end
function Client:request(url,opts)
    opts=opts or {}
    local current=url
    local first,err=M.url(url)
    if not first then return nil,err,'policy' end
    local headers={}; for k,v in pairs(opts.headers or {}) do headers[k]=v end
    local method,body=opts.method,opts.body
    for hop=0,8 do
        local parsed,why=M.url(current)
        if not parsed then return nil,why,'policy' end
        if opts.same_origin and parsed.origin~=first.origin then return nil,'Cross-origin account redirect refused','policy' end
        if opts.origin_policy then
            local allowed,issue=opts.origin_policy(parsed)
            if not allowed then return nil,issue or 'Origin policy refused '..parsed.host,'policy' end
        end
        local bad=self:bad(parsed.host)
        if bad then return nil,'Skipped '..parsed.host..' ('..bad..')','transport' end
        if opts.cookie_jar then headers.cookie=opts.cookie_jar:header(current) end
        if self.on_host then self.on_host(parsed.host) end
        local request_opts={headers=headers,method=method,body=body,sink_factory=opts.sink_factory,max_body=opts.max_body}
        local res,problem,kind=self:once(current,request_opts)
        if not res then
            if kind=='transport' then self:mark_bad(parsed.host,problem) end
            local reason=tostring(problem)
            if reason:find('timeout',1,true) or reason:find('timed out',1,true) then
                reason=reason..', possibly blocked by firewall'
            end
            return nil,M.redact('Request failed on '..parsed.host..' ('..reason..')',self.secret),kind
        end
        if opts.cookie_jar then opts.cookie_jar:update(current,res.headers['set-cookie']) end
        if opts.inspect then
            local accepted,issue=opts.inspect(res)
            if not accepted then return nil,issue,'response' end
        end
        if res.code==301 or res.code==302 or res.code==303 or res.code==307 or res.code==308 then
            if hop==8 then return nil,'Too many redirects on '..parsed.host end
            local target,issue=M.resolve(current,res.headers.location)
            if not target then return nil,issue end
            local next_url=M.url(target)
            if next_url.origin~=parsed.origin then
                for k in pairs(headers) do
                    if k:lower()=='cookie' or k:lower()=='authorization' then headers[k]=nil end
                end
                if body then return nil,'Cross-origin POST redirect refused' end
            end
            if res.code==303 or ((res.code==301 or res.code==302) and method=='POST') then method,body='GET',nil end
            current=target
        else return res end
    end
end
return M
