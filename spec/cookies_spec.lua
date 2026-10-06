return function(T)
    local Jar=require('bookfetch.cookies')
    local H=require('bookfetch.http')
    T.test('cookie rotation merges multiple cookie names',function()
        local jar=Jar.new()
        jar:update('https://aa.org/account/','aa_session=one; Path=/, aa_other=two; Path=/')
        jar:update('https://aa.org/search','aa_session=three; Path=/')
        T.eq(jar:header('https://aa.org/search'),'aa_other=two; aa_session=three')
    end)
    T.test('cookie deletion honors max-age and expires',function()
        local jar=Jar.new()
        jar:update('https://aa.org/','aa_x=one; Path=/, aa_y=two; Path=/')
        jar:update('https://aa.org/','aa_x=gone; Path=/; Max-Age=0, aa_y=gone; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT')
        T.eq(jar:header('https://aa.org/'),nil); T.eq(jar:has_session(),false)
        jar:update('https://aa.org/','aa_x=one; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT; Max-Age=60')
        T.eq(jar:header('https://aa.org/'),'aa_x=one')
    end)
    T.test('cookie domain and path boundaries',function()
        local jar=Jar.new()
        jar:update('https://aa.org/account/','aa_host=x; Path=/, scoped=y; Domain=aa.org; Path=/account, evil=z; Domain=evil.org; Path=/')
        T.eq(jar:header('https://sub.aa.org/account/page'),'scoped=y')
        T.eq(jar:header('https://aa.org/accounting'),'aa_host=x')
        T.eq(jar:header('https://evilaa.org/account/'),nil)
    end)
    T.test('login redirect sends all captured cookies on next hop',function()
        local jar=Jar.new(); local calls=0
        local client=H.new{cafile='test',transport=function(url,opts)
            calls=calls+1
            if calls==1 then
                T.eq(opts.method,'POST')
                return {code=302,host='aa.org',url=url,headers={location='/search',
                    ['set-cookie']='aa_one=1; Path=/, aa_two=2; Path=/'}}
            end
            T.eq(opts.method,'GET'); T.eq(opts.body,nil)
            T.eq(opts.headers.cookie,'aa_one=1; aa_two=2')
            return {code=200,host='aa.org',url=url,headers={['set-cookie']='aa_one=3; Path=/'},body='ok'}
        end}
        T.truth(client:request('https://aa.org/account/',{method='POST',body='key=x',cookie_jar=jar,same_origin=true}))
        T.eq(calls,2); T.eq(jar:header('https://aa.org/search'),'aa_one=3; aa_two=2')
    end)
end
