return function(T)
    local old_settings,old_storage,old_config=package.loaded.luasettings,package.loaded.datastorage,package.loaded['bookfetch.config']
    local values,flushes={},0
    local store={readSetting=function(_,name) return values[name] end,saveSetting=function(_,name,value) values[name]=value end,
        flush=function() flushes=flushes+1 end}
    package.loaded.luasettings={open=function(_,path) T.eq(path,'/tmp/test-settings/bookfetch.lua'); return store end}
    package.loaded.datastorage={getSettingsDir=function() return '/tmp/test-settings' end}
    package.loaded['bookfetch.config']=nil
    local C=require('bookfetch.config')
    local c=C.open()
    T.test('settings defaults are isolated copies',function()
        local mirrors=c:get('mirrors'); mirrors[1]='changed'
        T.eq(c:get('mirrors')[1],'https://annas-archive.pk')
    end)
    T.test('mirror validation HTTPS base URLs only',function()
        T.eq(C.mirrors('http://example.org'),nil); T.eq(C.mirrors('https://example.org/path'),nil)
        T.eq(C.mirrors('https://example.org/?key=secret'),nil)
        local mirrors=assert(C.mirrors(' https://example.org/\nhttps://example.org\nhttps://b.org'))
        T.eq(#mirrors,2); T.eq(mirrors[1],'https://example.org')
    end)
    T.test('bad-host settings merge prunes expired entries',function()
        c:set('bad_hosts',{old={at=os.time()-86401,reason='old'}})
        c:merge_bad({fresh={at=os.time(),reason='TLS failed'}})
        T.eq(c:get('bad_hosts').old,nil); T.eq(c:get('bad_hosts').fresh.reason,'TLS failed'); T.eq(flushes,2)
    end)
    package.loaded.luasettings,package.loaded.datastorage,package.loaded['bookfetch.config']=old_settings,old_storage,old_config
end
