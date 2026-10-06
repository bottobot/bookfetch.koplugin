return function(T)
    local H=require('bookfetch.http')
    T.test('URL encoding',function() T.eq(H.encode('a b&é/?='),'a%20b%26%C3%A9%2F%3F%3D'); T.eq(H.encode('-._~'),'-._~') end)
    T.test('redact keys in URLs including encoded names',function()
        T.eq(H.redact('https://a.org/?key=abc&x=1&KEY=def'),'https://a.org/?key=[REDACTED]&x=1&KEY=[REDACTED]')
        T.eq(H.redact('?%6bey=abc'),'?%6bey=[REDACTED]')
    end)
    T.test('redact literal and encoded secrets anywhere',function()
        T.eq(H.redact('oops a+b and a%2Bb','a+b'),'oops [REDACTED] and [REDACTED]')
    end)
    T.test('reject HTTP credentials and URL injection',function()
        for _,s in ipairs({'http://a.org/?key=abc','https://user:pw@a.org/','https://a.org/\r\nx','https://a.org:99999/'}) do T.eq(H.url(s),nil) end
    end)
    T.test('HTTPS URL decomposition',function() local u=H.url('https://A.org:8443/file?q=1#x'); T.eq(u.host,'a.org'); T.eq(u.port,8443); T.eq(u.path,'/file?q=1') end)
    T.test('relative redirect resolution',function()
        T.eq(H.resolve('https://a.org/books/get.php?q=x','../file.pdf'),'https://a.org/file.pdf')
        T.eq(H.resolve('https://a.org/file','//b.org/a'),'https://b.org/a')
        T.eq(H.resolve('https://a.org/file','http://b.org/a'),nil)
    end)
    T.test('TLS hostname wildcards are single-label',function()
        T.truth(H.matches_host('dl.example.org','*.example.org')); T.eq(H.matches_host('a.b.example.org','*.example.org'),false)
        T.eq(H.matches_host('evil.org','*.org'),false); T.eq(H.matches_host('example.org','example.org\0evil'),false)
    end)
    T.test('certificate SAN takes precedence over CN',function()
        local cert={extensions=function() return {['2.5.29.17']={dNSName={'other.org'}}} end,
            subject=function() return {{oid='2.5.4.3',value='example.org'}} end}
        T.eq(H.check_host(cert,'example.org'),nil)
    end)
    T.test('redirect strips cookies across origins',function()
        local calls=0
        local c=H.new{cafile='test',transport=function(url,opts)
            calls=calls+1
            if calls==1 then T.eq(opts.headers.cookie,'aa_secret=x'); return {code=302,headers={location='https://b.org/file'},host='a.org',url=url} end
            T.eq(opts.headers.cookie,nil); return {code=200,headers={},host='b.org',url=url,body='done'}
        end}
        T.eq(c:request('https://a.org/',{headers={cookie='aa_secret=x'}}).body,'done'); T.eq(calls,2)
    end)
    T.test('account cross-origin redirect refused before contact',function()
        local calls=0
        local c=H.new{cafile='test',transport=function(url)
            calls=calls+1; return {code=302,headers={location='https://b.org/'},host='a.org',url=url}
        end}
        T.eq(c:request('https://a.org/?key=secret',{same_origin=true}),nil); T.eq(calls,1)
    end)
    T.test('redirect cap',function()
        local calls=0; local c=H.new{cafile='test',transport=function(url)
            calls=calls+1; return {code=302,headers={location='/loop'},host='a.org',url=url}
        end}
        T.eq(c:request('https://a.org/'),nil); T.eq(calls,9)
    end)
    T.test('bad host skip and expiry',function()
        local calls=0; local c=H.new{cafile='test',bad_hosts={['a.org']={at=os.time(),reason='timed out'}},transport=function()
            calls=calls+1; return nil,'refused','transport' end}
        T.eq(c:request('https://a.org/'),nil); T.eq(calls,0)
        c.bad_hosts['a.org'].at=os.time()-86401
        T.eq(c:request('https://a.org/'),nil); T.eq(calls,1); T.truth(c.bad_hosts['a.org'])
    end)
    T.test('transport error never exposes secret',function()
        local c=H.new{cafile='test',secret='abc',transport=function() return nil,'failed ?key=abc','transport' end}
        local _,err=c:request('https://a.org/')
        T.eq(err:find('abc',1,true),nil); T.eq(c.bad_hosts['a.org'].reason:find('abc',1,true),nil)
    end)
    local function drain(source)
        local out={}
        while true do
            local chunk,err=source()
            if not chunk then return table.concat(out),err end
            out[#out+1]=chunk
        end
    end
    T.test('chunked source reads at most 64 KiB',function()
        local left=200000
        local max_read=0
        local stage=0
        local sock={receive=function(_,n)
            if n=='*l' then
                stage=stage+1
                if stage==1 then return string.format('%x',left) elseif stage==2 then return '0' else return '' end
            end
            if left==0 then T.eq(n,2); return '\r\n' end
            max_read=math.max(max_read,n); T.truth(n<=65536)
            left=left-n; return string.rep('x',n)
        end}
        local result,err=drain(assert(H.body_source(sock,{['transfer-encoding']='chunked'})))
        T.eq(#result,200000); T.eq(err,nil); T.eq(max_read,65536)
    end)
    T.test('truncated fixed-length source reports error after partial bytes',function()
        local calls=0
        local sock={receive=function() calls=calls+1; return nil,'closed','abc' end}
        local result,err=drain(assert(H.body_source(sock,{['content-length']='10'})))
        T.eq(result,'abc'); T.eq(err,'closed'); T.eq(calls,1)
    end)
    T.test('close-delimited source retains last partial bytes',function()
        local sock={receive=function() return nil,'closed','abc' end}
        local result,err=drain(assert(H.body_source(sock,{})))
        T.eq(result,'abc'); T.eq(err,nil)
    end)

    T.test('raw transport enforces peer CA hostname and timeouts',function()
        local saved={}
        for _,name in ipairs({'socket.http','ssl.https','socketutil'}) do saved[name]=package.loaded[name] end
        local seen={}
        local low={TIMEOUT=60}
        local tls={TIMEOUT=60,tcp=function(params)
            T.eq(params.verify,'peer'); T.eq(params.cafile,'/test/ca-bundle.crt')
            return function()
                local sock={settimeout=function(_,timeout,mode) seen[mode or 'initial']=timeout; return 1 end,
                    close=function() end,getpeercertificate=function()
                        return {extensions=function() return {['2.5.29.17']={dNSName={'a.org'}}} end}
                    end}
                return {sock=sock,settimeout=function() return 1 end,connect=function() return 1 end,
                    receive=function(_,n) T.eq(n,3); return 'abc' end}
            end
        end}
        low.open=function(host,port,create)
            T.eq(host,'a.org'); T.eq(port,443); T.eq(low.TIMEOUT,15)
            local c=create(); T.truth(c:connect(host,port))
            return {c=c,sendrequestline=function(_,method,path) T.eq(method,'GET'); T.eq(path,'/file') end,
                sendheaders=function(_,headers) T.eq(headers['accept-encoding'],'identity') end,
                receivestatusline=function() return 200,'HTTP/1.1 200 OK' end,
                receiveheaders=function() return {['content-length']='3'} end,
                try=function(value,err) assert(value,err); return value end,
                close=function() seen.closed=true end}
        end
        local util={block_timeout=60,total_timeout=-1,set_timeout=function(self,block,total)
            self.block_timeout,self.total_timeout=block,total; low.TIMEOUT,tls.TIMEOUT=block,block
        end}
        package.loaded['socket.http']=low; package.loaded['ssl.https']=tls; package.loaded.socketutil=util
        local ok,err=pcall(function()
            local res=assert(H.new{cafile='/test/ca-bundle.crt'}:request('https://a.org/file'))
            T.eq(res.body,'abc'); T.eq(seen.b,60); T.eq(seen.t,-1); T.truth(seen.closed)
            T.eq(low.TIMEOUT,60); T.eq(tls.TIMEOUT,60); T.eq(util.block_timeout,60)
        end)
        for _,name in ipairs({'socket.http','ssl.https','socketutil'}) do package.loaded[name]=saved[name] end
        assert(ok,err)
    end)

end
