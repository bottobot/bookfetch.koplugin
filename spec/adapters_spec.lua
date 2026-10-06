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
                return {code=200,host='aa.example.org',url=url,headers={['set-cookie']='aa_account=x; HttpOnly, aa_other=y; Path=/'},body='ok'}
            end
            T.truth(url:find('q=A%26B',1,true)); T.truth(url:find('page=2',1,true)); T.eq(opts.headers.cookie,'aa_account=x; aa_other=y')
            return {code=200,host='aa.example.org',url=url,headers={},body=T.fixture('search.html')}
        end}
        local aa=AA.new(c,settings)
        T.eq(#assert(aa:search('A&B','epub','en',2)).books,3); T.eq(calls,2)
    end)
    T.test('AA reauthenticates once after forbidden',function()
        local login,search=0,0
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then
                login=login+1
                return {code=200,headers={['set-cookie']='aa_session=x'},body='',host='aa.example.org',url=url}
            end
            search=search+1
            return {code=search==1 and 403 or 200,headers={},body='',host='aa.example.org',url=url}
        end}
        T.truth(AA.new(c,settings):search('book','','',1)); T.eq(login,2); T.eq(search,2)
    end)
    T.test('blocked mirror falls through without solving challenge',function()
        local seen={}
        local c=H.new{cafile='test',transport=function(url)
            seen[#seen+1]=url
            if url:find('aa.example.org',1,true) then
                return {code=302,headers={location='/?check=1'},body='',host='aa.example.org',url=url}
            elseif url:find('/account/',1,true) then
                return {code=200,headers={['set-cookie']='aa_session=x'},body='',host='backup.example.org',url=url}
            end
            return {code=200,headers={},body='',host='backup.example.org',url=url}
        end}
        local result=assert(AA.new(c,settings):search('book','','',1))
        T.eq(result.mirror,'https://backup.example.org'); T.eq(#seen,3)
        for _,url in ipairs(seen) do T.eq(url:find('check=1',1,true),nil) end
    end)
    T.test('fast API alternate domain and quota',function()
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x'},body='',host='aa.example.org',url=url} end
            T.truth(url:find('domain_index=3',1,true)); T.truth(url:find('path_index=0',1,true))
            return {code=200,headers={},host='aa.example.org',url=url,
                body='{"download_url":"https://partner.example.org/book","account_fast_download_info":{"downloads_left":7}}'}
        end}
        local result=assert(AA.new(c,settings):fast({md5=hash},3)); T.eq(result.quota.downloads_left,7)
    end)
    T.test('unconfigured book mirror never receives key',function()
        local c=H.new{cafile='test',transport=function(url)
            T.eq(url:find('evil.example.org',1,true),nil)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x'},body='',host='aa.example.org',url=url} end
            return {code=200,headers={},host='aa.example.org',url=url,body='{"download_url":"https://partner.example.org/book"}'}
        end}
        T.truth(AA.new(c,settings):fast({md5=hash,mirror='https://evil.example.org'},0))
    end)
    T.test('API errors stop alternates and redact secrets',function()
        local c=H.new{cafile='test',transport=function(url)
            if url:find('/account/',1,true) then return {code=200,headers={['set-cookie']='aa_session=x'},body='',host='aa.example.org',url=url} end
            return {code=200,headers={},host='aa.example.org',url=url,body='{"error":"No more domains test-secret"}'}
        end}
        local result,err,kind=AA.new(c,settings):fast({md5=hash},6)
        T.eq(result,nil); T.eq(kind,'api'); T.eq(err:find('test-secret',1,true),nil)
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
end
