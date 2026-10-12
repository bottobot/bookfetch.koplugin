-- Real KOReader modules, with no network, paint, settings writes or real fork.
return function(T)
    T.test('runtime free-space API returns numeric total and free',function()
        local util=require('ffi/util')
        local total,free=util.df('/tmp')
        T.eq(type(total),'number'); T.eq(type(free),'number'); T.truth(total>=free and free>=0)
        T.eq(require('bookfetch.download').free_space('/tmp'),free)
    end)
    T.test('runtime ButtonDialog supports region-only title rebuild',function()
        local ok,dialog=pcall(require,'ui/widget/buttondialog')
        if not ok or type(dialog)~='table' then T.skip('ButtonDialog could not load: '..tostring(dialog)) end
        T.eq(type(dialog.setTitle),'function'); T.eq(type(dialog.reinit),'function')
        local ok2,uimgr=pcall(require,'ui/uimanager')
        if not ok2 then T.skip('UIManager could not load: '..tostring(uimgr)) end
        T.eq(type(uimgr.setDirty),'function')
    end)
    T.test('runtime Trapper reports false when fork cannot start',function()
        local ok,trap=pcall(require,'ui/trapper')
        if not ok or type(trap)~='table' then T.skip('Trapper could not load: '..tostring(trap)) end
        local util=require('ffi/util')
        local fork=util.runInSubProcess
        util.runInSubProcess=function() return false,'simulated fork failure' end
        local completed
        local thread=coroutine.create(function()
            completed=trap:dismissableRunInSubprocess(function() error('worker must not run') end,{})
        end)
        local ok,err=coroutine.resume(thread)
        util.runInSubProcess=fork
        assert(ok,err); T.eq(coroutine.status(thread),'dead'); T.eq(completed,false)
    end)
    T.test('runtime streaming MD5 backend agrees with Lua vectors and file digest',function()
        local MD5=require('bookfetch.md5')
        local feed,backend=MD5.native_backend()
        if backend=='ffi/sha2.md5' then
            feed('a'); feed('bc'); T.eq(feed(),'900150983cd24fb0d6963f7d28e17f72')
        else T.eq(backend,'bookfetch.md5') end
        local path=os.tmpname()
        local data=string.rep('native backend\0test',10000)
        local f=assert(io.open(path,'wb')); assert(f:write(data)); assert(f:close())
        local digest,err=MD5.file(path); os.remove(path)
        assert(digest,err); T.eq(digest,MD5.sum(data))
    end)
end
