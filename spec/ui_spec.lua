-- Mock widgets and the scheduler; never initialize device UI in the headless suite.
return function(T)
    local saved={}
    local function stub(name,value) saved[name]={value=package.loaded[name]}; package.loaded[name]=value end
    local widget={new=function(_,value)
        value.setTitle=function(self,title) self.title=title end
        return value
    end}
    local shown,scheduled,network,wrapped,workers=0,{},0,false,0
    local manager={show=function() shown=shown+1 end,close=function() end,
        scheduleIn=function(_,_,fn) scheduled[fn]=true end,unschedule=function(_,fn) scheduled[fn]=nil end}
    stub('ui/uimanager',manager)
    for _,name in ipairs({'inputdialog','multiinputdialog','buttondialog','infomessage','menu'}) do stub('ui/widget/'..name,widget) end
    stub('ui/network/manager',{runWhenOnline=function(_,fn) network=network+1; fn() end})
    stub('ui/trapper',{wrap=function(_,fn) wrapped=true; fn(); wrapped=false end,
        dismissableRunInSubprocess=function(_,fn) T.truth(wrapped,'Subprocess must be wrapped'); workers=workers+1; return true,fn() end})
    stub('bookfetch.config',{})
    stub('logger',{dbg=function() end})
    stub('bookfetch.ui',nil)
    local UI=require('bookfetch.ui')
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
    end)
    for name,entry in pairs(saved) do package.loaded[name]=entry.value end
end
