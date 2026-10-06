-- Exercise callbacks and worker scheduling without painting or network calls.
return function(T)
    local saved={}
    local function stub(name,value) saved[name]={value=package.loaded[name]}; package.loaded[name]=value end
    local shown,closed,dirty,titles,scheduled={},{},{},{},{}
    local widget={new=function(_,value)
        value.movable={dimen={x=10,y=10,w=400,h=200}}
        value.setTitle=function() error('Full-screen setTitle must not be used') end
        value.reinit=function(self) titles[#titles+1]=self.title; self.movable={dimen={x=10,y=10,w=400,h=200}} end
        value.onShowKeyboard=function() end
        return value
    end}
    local network,wrapped,workers=0,false,0
    local manager={show=function(_,w) shown[#shown+1]=w end,close=function(_,w) closed[#closed+1]=w end,
        setDirty=function(_,target,mode,region)
            T.truth(target~='all','Only dialog regions may be dirty')
            if type(mode)=='function' then mode,region=mode() end
            T.truth(region); dirty[#dirty+1]={target=target,mode=mode,region=region}
        end,
        scheduleIn=function(_,delay,fn) scheduled[fn]=delay end,unschedule=function(_,fn) scheduled[fn]=nil end}
    stub('ui/uimanager',manager)
    for _,name in ipairs({'inputdialog','multiinputdialog','buttondialog','infomessage','menu'}) do stub('ui/widget/'..name,widget) end
    stub('ui/network/manager',{runWhenOnline=function(_,fn) network=network+1; fn() end})
    local trap={wrap=function(_,fn) wrapped=true; fn(); wrapped=false end,
        dismissableRunInSubprocess=function(_,fn) T.truth(wrapped,'Subprocess must be wrapped'); workers=workers+1; return true,fn() end}
    stub('ui/trapper',trap)
    stub('device',{screen={getWidth=function() return 1000 end,getHeight=function() return 1200 end}})
    stub('bookfetch.config',{})
    stub('logger',{dbg=function() end})
    stub('bookfetch.ui',nil)
    local UI=require('bookfetch.ui')
    local D=require('bookfetch.download')
    local config={get=function() return 'secret' end,snapshot=function() return {cafile='test',key='secret',bad_hosts={}} end,
        merge_bad=function() end}
    local ui=UI.new({},config)
    T.test('plugin UI module load has no network',function() T.eq(network,0); T.eq(workers,0) end)
    T.test('explicit work uses online gate and wrapped subprocess',function()
        local returned
        ui:work('Search',function() return {done=true} end,function(value) returned=value end)
        T.eq(network,1); T.eq(workers,1); T.truth(returned.done); T.eq(next(scheduled),nil)
    end)
    T.test('worker failures are safely returned to UI',function()
        local done=false
        ui:work('Search',function() error('secret') end,function() done=true end)
        T.eq(done,false); T.eq(network,2); T.eq(next(scheduled),nil)
        T.eq(shown[#shown].text:find('secret',1,true),nil)
    end)
    T.test('progress redraws every four seconds in dialog region with fixed lines',function()
        local time=os.time; local now=100; os.time=function() return now end
        titles={}; dirty={}
        local ok,err=pcall(function()
            ui:work('Download secret',function(_,_,_,_,publish)
                local initial=shown[#shown].title
                T.eq(select(2,initial:gsub('\n','')),4)
                for tick=1,8 do
                    now=100+tick
                    publish({phase='Downloading secret\nextra',host='https://host.org/?key=hidden',bytes=tick,total=100,speed=1},true)
                    local poll=next(scheduled); T.truth(poll); poll()
                end
                return {}
            end,function() end)
            T.eq(#titles,2); T.eq(#dirty,4)
            for _,title in ipairs(titles) do
                T.eq(select(2,title:gsub('\n','')),4)
                T.eq(title:find('secret',1,true),nil); T.eq(title:find('hidden',1,true),nil)
            end
            T.eq(next(scheduled),nil)
        end)
        os.time=time; assert(ok,err)
    end)
    T.test('fork failure is not labelled cancellation',function()
        local worker=trap.dismissableRunInSubprocess
        trap.dismissableRunInSubprocess=function() return false end
        ui:work('Search',function() error('must not start') end,function() error('must not complete') end)
        trap.dismissableRunInSubprocess=worker
        T.eq(shown[#shown].text,'Could not start background worker'); T.eq(next(scheduled),nil)
    end)
    T.test('user cancellation retains cancellation message',function()
        local worker=trap.dismissableRunInSubprocess
        trap.dismissableRunInSubprocess=function(_,_,dialog) dialog.buttons[1][1].callback(); return false end
        ui:work('Search',function() end,function() error('must not complete') end)
        trap.dismissableRunInSubprocess=worker
        T.truth(shown[#shown].text:find('Cancelled',1,true)); T.eq(next(scheduled),nil)
    end)
    local function retry_test(resolve,fetch,use_libgen,lg)
        local prepare,oldfetch,cleanup,work=D.prepare,D.fetch,D.cleanup_empty,ui.work
        local task,done
        D.prepare=function() return {part='/tmp/mock.part'} end
        D.fetch=fetch
        D.cleanup_empty=function() end
        ui.work=function(_,_,fn,callback) task,done=fn,callback end
        local ok,value,err=pcall(function()
            ui:download({md5=string.rep('a',32),title='Title',author='',format='pdf'},use_libgen)
            return task({}, {resolve=resolve},lg or {},{libgen_mirrors={'https://lg.org'}},function() end)
        end)
        D.prepare,D.fetch,D.cleanup_empty,ui.work=prepare,oldfetch,cleanup,work
        assert(ok,value)
        return value,err,done
    end
    T.test('disk full consumes exactly one fast-download request',function()
        local calls=0
        local _,err=retry_test(function(_,_,index) calls=calls+1; T.eq(index,0); return {url='https://partner.org/'} end,
            function() return nil,'disk full','local' end)
        T.eq(calls,1); T.eq(err,'disk full')
    end)
    T.test('transport failures retry all domain indexes zero through six',function()
        local calls=0
        local _,err=retry_test(function(_,_,index) T.eq(index,calls); calls=calls+1; return {url='https://partner.org/'} end,
            function() return nil,'failed on partner.org','transport' end)
        T.eq(calls,7); T.truth(err:find('domain_index=6',1,true)); T.truth(err:find('partner.org',1,true))
    end)
    T.test('retryable API errors continue through index six',function()
        local calls=0
        retry_test(function(_,_,index) T.eq(index,calls); calls=calls+1; return nil,'API busy','api' end,function() error('no URL') end)
        T.eq(calls,7)
    end)
    T.test('terminal API error ends domain loop',function()
        local calls=0
        retry_test(function(_,_,index) calls=calls+1; return nil,'no more domains',index==2 and 'terminal' or 'api' end,
            function() error('no URL') end)
        T.eq(calls,3)
    end)
    T.test('partner HTTP and integrity retry decisions are explicit',function()
        for _,kind in ipairs({'http_retry','body','response','integrity','policy'}) do
            local calls=0
            retry_test(function() calls=calls+1; return {url='https://partner.org/'} end,
                function() return nil,'failed',kind end)
            T.eq(calls,UI.retryable(kind) and 7 or 1)
        end
    end)
    T.test('LibGen download receives its allowlist policy',function()
        local policy=function() return true end
        local lg={resolve=function() return 'https://lg.org/book' end,policy=function() return policy end}
        retry_test(function() error('AA must not run') end,function(_,_,_,_,received)
            T.eq(received,policy); return nil,'disk full','local'
        end,true,lg)
    end)
    T.test('results details path and quota are redacted at UI boundaries',function()
        local book={title='secret title',author='secret author',year='2020',format='pdf',md5=string.rep('a',32)}
        ui:results({books={book},page=1},'','','')
        T.eq(ui.results_menu.item_table[1].text:find('secret',1,true),nil)
        ui:detail(book); T.eq(ui.detail_dialog.title:find('secret',1,true),nil)
        local _,_,done=retry_test(function() return nil,'stop','terminal' end,function() end)
        stub('apps/filemanager/filemanager',{})
        done({path='/Books/secret.pdf',quota={remaining='secret\n'..string.rep('x',200)}})
        local title=shown[#shown].title
        T.eq(title:find('secret',1,true),nil); T.truth(#title<220)
    end)
    T.test('Open now closes results and details before ReaderUI',function()
        local menu,detail=ui.results_menu,ui.detail_dialog
        T.truth(menu); T.truth(detail)
        local success=shown[#shown]; local opened=false
        stub('apps/reader/readerui',{showReader=function(_,path)
            T.eq(path,'/Books/secret.pdf'); opened=true
            local seen={}; for _,w in ipairs(closed) do seen[w]=true end
            T.truth(seen[menu]); T.truth(seen[detail]); T.truth(seen[success])
            T.eq(ui.results_menu,nil); T.eq(ui.detail_dialog,nil)
        end})
        success.buttons[1][1].callback(); T.truth(opened)
    end)
    T.test('teardown closes all owned widgets',function()
        ui:results({books={},page=1},'','',''); ui:detail({title='Book',author=''})
        local widgets={}; for w in pairs(ui.widgets) do widgets[#widgets+1]=w end
        ui:teardown(); T.eq(next(ui.widgets),nil)
        local seen={}; for _,w in ipairs(closed) do seen[w]=true end
        for _,w in ipairs(widgets) do T.truth(seen[w]) end
    end)
    T.test('native widget closure releases ownership',function()
        local w=widget:new{title='Temporary'}
        ui:show(w); T.truth(ui.widgets[w]); w:onCloseWidget(); T.eq(ui.widgets[w],nil)
    end)
    T.test('teardown prevents queued work from starting',function()
        local before=network
        ui:work('After teardown',function() error('must not start') end,function() error('must not complete') end)
        T.eq(network,before)
    end)
    T.test('secret editor omits the no-op clipboard option',function()
        ui:edit('key','Secret key',true)
        local dialog=shown[#shown]
        T.eq(dialog.text_type,'password'); T.eq(dialog.disable_clipboard_snippet_edit,nil)
    end)
    for name,entry in pairs(saved) do package.loaded[name]=entry.value end
end
