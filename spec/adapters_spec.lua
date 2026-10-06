return function(T)
    local AA=require('bookfetch.aa')
    local LG=require('bookfetch.libgen')
    local H=require('bookfetch.http')
    local hash='0123456789abcdef0123456789abcdef'
    local settings={key='test-secret',mirrors={'https://aa.example.org','https://backup.example.org'},
        libgen_mirrors={'https://lg.example.org'}}
    T.test('AA login cookie then encoded paginated search',function()
        local calls=0
        local c=H.new{cafile='test',transport=function(url,opts)
            calls=calls+1
            if calls==1 then
                T.eq(url,'https://aa.example.org/account/'); T.eq(opts.method,'POST'); T.eq(opts.body,'key=test-secret')
                return {code=200,host='aa.example.org',url=url,headers={['set-cookie']='aa_account=x; Path=/; HttpOnly, aa_other=y; Path=/'},body='ok'}
            end
            T.truth(url:find('q=A%26B',1,true)); T.truth(url:find('page=2',1,true)); T.eq(opts.headers.cookie,'aa_account=x; aa_other=y')
            return {code=200,host='aa.example.org',url=url,headers={},body=T.fixture('search.html')}
        end}
        local aa=AA.new(c,settings)
        T.eq(#assert(aa:search('A&B','epub','en',2)).books,3); T.eq(calls,2)
    end)
    T.test('AA blocked search skips relogin and tries the next mirror',function()
        local login,search=0,0
        local logins={}
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then
                login=login+1; logins[#logins+1]=H.url(url).host
                return {code=200,headers={['set-cookie']='aa_session=x; Path=/'},body='',host='aa.example.org',url=url}
            end
            search=search+1
            return {code=search==1 and 403 or 200,headers={},body='',host='aa.example.org',url=url}
        end}
        T.truth(AA.new(c,settings):search('book','','',1)); T.eq(login,2); T.eq(search,2); T.truth(logins[1]~=logins[2])
    end)
    T.test('blocked mirror falls through without solving challenge',function()
        local seen={}
        local c=H.new{cafile='test',transport=function(url)
            seen[#seen+1]=url
            if url:find('aa.example.org',1,true) then
                return {code=302,headers={location='/?check=1'},body='',host='aa.example.org',url=url}
            elseif url:find('/account/',1,true) then
                return {code=200,headers={['set-cookie']='aa_session=x; Path=/'},body='',host='backup.example.org',url=url}
            end
            return {code=200,headers={},body='',host='backup.example.org',url=url}
        end}
        local result=assert(AA.new(c,settings):search('book','','',1))
        T.eq(result.mirror,'https://backup.example.org'); T.eq(#seen,3)
        for _,url in ipairs(seen) do T.eq(url:find('check=1',1,true),nil) end
    end)
    T.test('fast API alternate domain and quota',function()
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x; Path=/'},body='',host='aa.example.org',url=url} end
            T.truth(url:find('domain_index=3',1,true)); T.truth(url:find('path_index=0',1,true))
            return {code=200,headers={},host='aa.example.org',url=url,
                body='{"download_url":"https://partner.example.org/book","account_fast_download_info":{"downloads_left":7}}'}
        end}
        local result=assert(AA.new(c,settings):fast({md5=hash},3)); T.eq(result.quota.downloads_left,7)
    end)
    T.test('unconfigured book mirror never receives key',function()
        local c=H.new{cafile='test',transport=function(url)
            T.eq(url:find('evil.example.org',1,true),nil)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x; Path=/'},body='',host='aa.example.org',url=url} end
            return {code=200,headers={},host='aa.example.org',url=url,body='{"download_url":"https://partner.example.org/book"}'}
        end}
        T.truth(AA.new(c,settings):fast({md5=hash,mirror='https://evil.example.org'},0))
    end)
    T.test('API errors stop alternates and redact secrets',function()
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x; Path=/'},body='',host='aa.example.org',url=url} end
            return {code=200,headers={},host='aa.example.org',url=url,body='{"error":"No more domains test-secret"}'}
        end}
        local result,err,kind=AA.new(c,settings):fast({md5=hash},6)
        T.eq(result,nil); T.eq(kind,'terminal'); T.truth(err:find('domain_index=6',1,true)); T.truth(err:find('aa.example.org',1,true)); T.eq(err:find('test-secret',1,true),nil)
    end)
    T.test('LibGen resolves decoded allowlisted get.php',function()
        local c=H.new{cafile='test',transport=function(url)
            T.truth(url:find('/ads.php?md5='..hash,1,true))
            return {code=200,headers={},body=T.fixture('libgen.html'),url=url,host='lg.example.org'}
        end}
        T.eq(LG.new(c,settings):resolve({md5=hash},'https://lg.example.org'),
            'https://lg.example.org/get.php?md5='..hash..'&key=PARTNERKEY')
    end)
    T.test('LibGen denies off-allowlist redirect before request',function()
        local calls=0
        local c=H.new{cafile='test',transport=function(url)
            calls=calls+1; return {code=302,headers={location='https://evil.example.org/get.php'},body='',url=url,host='lg.example.org'}
        end}
        T.eq(LG.new(c,settings):resolve({md5=hash},'https://lg.example.org'),nil); T.eq(calls,1)
    end)
    T.test('retryable API error retains index and host context',function()
        local aa=AA.new({},settings)
        aa.authenticated=function() return {host='aa.example.org',body='{"error":"Temporary partner failure"}'} end
        local _,err,kind=aa:fast({md5=hash},2)
        T.eq(kind,'api'); T.truth(err:find('domain_index=2',1,true)); T.truth(err:find('aa.example.org',1,true))
    end)
    T.test('terminal API errors classify separately',function()
        for _,message in ipairs({'Invalid key','Quota exhausted','No more domains','Domain index out of range','Not a member'}) do
            local aa=AA.new({},settings)
            aa.authenticated=function() return {host='aa.example.org',body=require('json').encode({error=message})} end
            local _,_,kind=aa:fast({md5=hash},0); T.eq(kind,'terminal')
        end
    end)
    T.test('search responses rotate cookies and ddg cookie does not block',function()
        local searches=0
        local c=H.new{cafile='test',transport=function(url,opts)
            if url:find('/account/',1,true) then
                return {code=302,url=url,host='aa.example.org',headers={location='/home',
                    ['set-cookie']='aa_one=x; Path=/, aa_two=y; Path=/'},body=''}
            end
            if url:find('/home',1,true) then
                T.eq(opts.headers.cookie,'aa_one=x; aa_two=y')
                return {code=200,url=url,host='aa.example.org',headers={},body=''}
            end
            searches=searches+1
            T.eq(opts.headers.cookie,searches==1 and 'aa_one=x; aa_two=y' or '__ddg1_=ok; aa_one=z; aa_two=y')
            return {code=200,url=url,host='aa.example.org',headers={['set-cookie']='aa_one=z; Path=/, __ddg1_=ok; Path=/'},body=''}
        end}
        local aa=AA.new(c,settings)
        T.truth(aa:search('book','','',1)); T.truth(aa:search('book','','',2)); T.eq(searches,2)
    end)
    T.test('LibGen download redirects allow own subdomains only',function()
        local calls=0
        local lg=LG.new({},settings)
        local c=H.new{cafile='test',transport=function(url)
            calls=calls+1
            local host=H.url(url).host
            if calls==1 then return {code=302,url=url,host=host,headers={location='https://cdn.lg.example.org/file'}} end
            return {code=302,url=url,host=host,headers={location='https://evil-lg.example.org/file'}}
        end}
        local _,err=c:request('https://lg.example.org/file',{origin_policy=lg:policy()})
        T.eq(calls,2); T.truth(err:find('evil-lg.example.org',1,true))
    end)
    T.test('Anna partner redirects retain HTTPS and bad-host policies',function()
        local calls=0
        local c=H.new{cafile='test',transport=function(url)
            calls=calls+1
            if calls==1 then return {code=302,url=url,host='partner.example.org',headers={location='https://other.example.org/file'}} end
            return {code=200,url=url,host='other.example.org',headers={},body='ok'}
        end}
        T.truth(c:request('https://partner.example.org/file')); T.eq(calls,2)
        c.bad_hosts['other.example.org']={at=os.time(),reason='TLS failure'}
        calls=0; T.eq(c:request('https://partner.example.org/file'),nil); T.eq(calls,1)
    end)
    T.test('missing or rejected login key is a terminal API error',function()
        local aa=AA.new({}, {key='',mirrors=settings.mirrors})
        local _,err,kind=aa:fast({md5=hash},1)
        T.eq(kind,'terminal'); T.truth(err:find('domain_index=1',1,true))
        local c=H.new{cafile='test',transport=function(url)
            return {code=200,url=url,host='aa.example.org',headers={},body='rejected'}
        end}
        local _,_,why=AA.new(c,settings):fast({md5=hash},0); T.eq(why,'terminal')
    end)

end
