-- Copyright (c) 2026 bottobot. MIT licensed.
local UIManager=require('ui/uimanager')
local InputDialog=require('ui/widget/inputdialog')
local MultiInputDialog=require('ui/widget/multiinputdialog')
local ButtonDialog=require('ui/widget/buttondialog')
local InfoMessage=require('ui/widget/infomessage')
local Menu=require('ui/widget/menu')
local Trapper=require('ui/trapper')
local NetworkMgr=require('ui/network/manager')
local Config=require('bookfetch.config')
local Http=require('bookfetch.http')
local AA=require('bookfetch.sources.aa')
local LibGen=require('bookfetch.sources.libgen')
local Download=require('bookfetch.download')
local json=require('json')
local logger=require('logger')
local M={}
M.__index=M
-- Shared module state protects partial files across ReaderUI/FileManager instances.
local busy=false
function M.new(owner,config) return setmetatable({owner=owner,config=config,sessions={},widgets={}},M) end
function M:show(widget)
    if not self.widgets[widget] then
        local on_close=widget.onCloseWidget
        widget.onCloseWidget=function(w,...)
            self.widgets[w]=nil
            if on_close then return on_close(w,...) end
        end
    end
    self.widgets[widget]=true
    UIManager:show(widget)
end
function M:close(widget)
    if widget and self.widgets[widget] then
        self.widgets[widget]=nil
        UIManager:close(widget)
    end
end
function M:teardown()
    self.tearing_down=true
    if self.cancel_work then self.cancel_work(false) end
    local owned={}; for widget in pairs(self.widgets) do owned[#owned+1]=widget end
    for _,widget in ipairs(owned) do self:close(widget) end
    self.results_menu=nil; self.detail_dialog=nil
end
function M:safe(text)
    return Http.redact(text,self.config:get('key'))
end
function M:message(text) self:show(InfoMessage:new{text=Http.redact(text,self.config:get('key'))}) end
local function bytes(n)
    if type(n)~='number' or n~=n or n<0 or n==math.huge then return '?' end
    return string.format('%.2f MB',n/1000000)
end
local function quota_text(quota,secret)
    local function safe(value)
        if type(value)=='number' and value==value and math.abs(value)<math.huge then return tostring(value) end
        if type(value)=='string' then return Http.redact(value,secret):gsub('%c',' '):sub(1,80) end
    end
    if quota==nil then return '' end
    if type(quota)~='table' then local value=safe(quota); return value and '\nDaily quota: '..value or '' end
    -- The API's account information may contain several quota/account fields.
    local out={}
    for _,key in ipairs({'downloads_left','remaining','daily_downloads_left','downloads_remaining','remaining_downloads',
        'daily_limit','daily_download_limit','downloads_per_day','downloads_today'}) do
        local value=quota[key]
        value=safe(value)
        if value then out[#out+1]=key:gsub('_',' ')..': '..value end
    end
    if #out==0 then return '\nDaily quota information received; see your Anna\'s Archive account for details.' end
    return '\nDaily quota: '..table.concat(out,', ')
end
function M.progress_title(dialog,title)
    local previous=dialog.movable.dimen
    -- ButtonDialog:setTitle dirties "all" in KOReader. Rebuild the title and
    -- invalidate only the old/new dialog rectangles instead.
    dialog.title=title
    dialog:reinit()
    UIManager:setDirty(nil,'ui',previous)
    UIManager:setDirty(dialog,function() return 'ui',dialog.movable.dimen end)
end
function M:work(title,task,done)
    if self.tearing_down then return end
    if busy then self:message('A Book Fetch task is already running.'); return end
    NetworkMgr:runWhenOnline(function()
        if self.tearing_down then return end
        if busy then self:message('A Book Fetch task is already running.'); return end
        local settings=self.config:snapshot()
        if not settings.cafile then self:message('KOReader data/ca-bundle.crt was not found.'); return end
        busy=true
        local progress_path=os.tmpname()
        if not progress_path then busy=false; self:message('Could not create a progress channel.'); return end
        local dialog,discard,last_status,last_raw,last_draw,cancelled
        title=self:safe(title):gsub('%c',' ')
        local function cancel(remove)
            discard=remove; cancelled=true
            if dialog.dismiss_callback then dialog.dismiss_callback() end
        end
        self.cancel_work=cancel
        dialog=ButtonDialog:new{title=title..'\nConnecting…\n\n? / ?\n?/s',dismissable=false,buttons={{
            {text='Cancel',callback=function() cancel(false) end},
            {text='Discard partial',callback=function() cancel(true) end},
        }}}
        self:show(dialog)
        last_draw=os.time()
        local function poll()
            local f=io.open(progress_path,'rb')
            if f then
                local raw=f:read(65536); f:close()
                local ok,status=pcall(json.decode,raw or '')
                if ok and type(status)=='table' then
                    last_status=status
                end
                if ok and type(status)=='table' and raw~=last_raw and (not last_draw or os.time()-last_draw>=4) then
                    last_draw=os.time()
                    last_raw=raw
                    last_status=status
                    local function line(value) return self:safe(value):gsub('%c',' ') end
                    M.progress_title(dialog,title..'\n'..line(status.phase or 'Connecting')..'\n'..line(status.host or '')..'\n'
                        ..bytes(status.bytes)..' / '..bytes(status.total)..'\n'..bytes(status.speed)..'/s')
                end
            end
            UIManager:scheduleIn(1,poll)
        end
        UIManager:scheduleIn(1,poll)
        -- This MUST stay inside wrap: Trapper otherwise falls back to a blocking call.
        Trapper:wrap(function()
            local completed,result=Trapper:dismissableRunInSubprocess(function()
                local state={phase='Connecting',bad_hosts=settings.bad_hosts}
                local last=0
                local function publish(update,force)
                    for k,v in pairs(update or {}) do state[k]=v end
                    if not force and os.time()==last then return end
                    last=os.time()
                    local f=io.open(progress_path..'.tmp','wb')
                    if f then
                        f:write(json.encode(state)); f:close()
                        os.rename(progress_path..'.tmp',progress_path)
                    end
                end
                local client=Http.new{cafile=settings.cafile,secret=settings.key,bad_hosts=settings.bad_hosts,
                    on_host=function(host) publish({host=host},true) end,
                    on_bad=function(hosts) publish({bad_hosts=hosts},true) end}
                local aa=AA.new(client,settings,self.sessions)
                local lg=LibGen.new(client,settings)
                local ok,value,err=pcall(task,client,aa,lg,settings,publish)
                if not ok then err=Http.redact(value,settings.key); value=nil end
                return {value=value,error=Http.redact(err or '',settings.key),sessions=aa.sessions,bad_hosts=client.bad_hosts}
            end,dialog)
            UIManager:unschedule(poll)
            -- Collect the last atomic status before removing the progress channel.
            local f=io.open(progress_path,'rb')
            if f then
                local raw=f:read(65536); f:close()
                local ok,state=pcall(json.decode,raw or '')
                if ok and type(state)=='table' then last_status=state end
            end
            self:close(dialog)
            busy=false; self.cancel_work=nil
            if result then
                self.sessions=result.sessions or self.sessions
                self.config:merge_bad(result.bad_hosts)
            elseif last_status then self.config:merge_bad(last_status.bad_hosts) end
            os.remove(progress_path); os.remove(progress_path..'.tmp')
            if self.tearing_down then return end
            if not completed then
                if not cancelled then self:message('Could not start background worker')
                elseif discard and last_status and last_status.part then
                    local ok,err=Download.discard(last_status.part)
                    self:message(ok and 'Partial download discarded.' or err)
                else self:message('Cancelled. Any partial download is kept for resuming.') end
                return
            end
            if not result or not result.value then
                local err=result and result.error~='' and result.error or 'The background worker did not return a result.'
                logger.dbg('Book Fetch:',Http.redact(err,settings.key))
                self:message(err); return
            end
            done(result.value)
        end)
    end)
end
function M:search_dialog()
    local dialog
    dialog=MultiInputDialog:new{title='Book Fetch — Search',fields={
        {text='',description='Title, author, or ISBN'},
        {text=self.config:get('preferred_format'),description='Format: any (blank), epub, pdf, mobi, azw3'},
        {text='',description='Language: any (blank), en, fr, de, es, …'},
    },buttons={{
        {text='Cancel',id='close',callback=function() self:close(dialog) end},
        {text='Search',is_enter_default=true,callback=function()
            local fields=dialog:getFields()
            local query=fields[1]:match('^%s*(.-)%s*$')
            local format=fields[2]:lower():match('^%s*(.-)%s*$')
            local language=fields[3]:match('^%s*(.-)%s*$')
            if format=='any' then format='' end
            if language=='any' then language='' end
            if query=='' then self:message('Enter a search query.'); return end
            if not ({['']=true,epub=true,pdf=true,mobi=true,azw3=true})[format] then self:message('Choose a supported format filter.'); return end
            if language~='' and not language:match('^[%a%-]+$') then self:message('Enter a language code such as en.'); return end
            self:close(dialog)
            self:search(query,format,language,1)
        end},
    }}}
    self:show(dialog); dialog:onShowKeyboard()
end
function M:search(query,format,language,page)
    self:work('Searching Anna\'s Archive',function(_,aa)
        return aa:search(query,format,language,page)
    end,function(data) self:results(data,query,format,language) end)
end
function M:results(data,query,format,language)
    local items={}
    for _,book in ipairs(data.books) do
        local b=book
        local details={}
        for _,v in ipairs({b.year or '',b.format or '',b.size or ''}) do if v~='' then details[#details+1]=v end end
        items[#items+1]={text=self:safe(b.title..(b.author and b.author~='' and ' — '..b.author or '')
            ..(#details>0 and ' ('..table.concat(details,', ')..')' or '')),callback=function() self:detail(b) end}
    end
    local menu
    if #items==0 then items[1]={text='No results on this page',enabled=false} end
    if data.page>1 then items[#items+1]={text='Previous page',callback=function()
        self:close(menu); self:search(query,format,language,data.page-1) end} end
    items[#items+1]={text='Next page',callback=function()
        self:close(menu); self:search(query,format,language,data.page+1) end}
    self:close(self.results_menu)
    menu=Menu:new{title=self:safe('Book Fetch — Page '..data.page),item_table=items,
        width=require('device').screen:getWidth(),height=require('device').screen:getHeight(),
        is_popout=false,is_borderless=true}
    self.results_menu=menu
    self:show(menu)
end
function M:detail(book)
    local dialog
    local text={book.title,book.author}
    for _,name in ipairs({'publisher','year','language','format','size','md5'}) do
        if book[name] then text[#text+1]=name..': '..book[name] end
    end
    self:close(self.detail_dialog)
    dialog=ButtonDialog:new{title=self:safe(table.concat(text,'\n')),buttons={{
        {text='Download',callback=function() self:close(dialog); self:download(book,false) end},
        {text='Try LibGen',callback=function() self:close(dialog); self:download(book,true) end},
    },{{text='Cancel',callback=function() self:close(dialog) end}}}}
    self.detail_dialog=dialog
    self:show(dialog)
end
function M.retryable(kind)
    return kind=='transport' or kind=='connect' or kind=='tls' or kind=='body' or kind=='http_retry'
end
function M:download(book,use_libgen)
    self:work(use_libgen and 'Downloading via LibGen' or 'Downloading via Anna\'s Archive',function(client,aa,lg,settings,publish)
        local job,err=Download.prepare(settings.download_folder,book,settings.key)
        if not job then return nil,err end
        publish({part=job.part,bytes=0,phase='Resolving download'},true)
        local errors={}
        if use_libgen then
            for _,base in ipairs(settings.libgen_mirrors) do
                local url,why=lg:resolve(book,base)
                if url then
                    local result,issue,kind=Download.fetch(client,url,job,publish,lg:policy())
                    if result then return result end
                    if not M.retryable(kind) then Download.cleanup_empty(job); return nil,issue end
                    errors[#errors+1]=issue
                else errors[#errors+1]=why end
            end
        else
            for index=0,6 do
                local info,why,kind=aa:resolve(book,index)
                if not info then
                    errors[#errors+1]=why
                    if kind=='terminal' then break end
                else
                    local result,issue,kind=Download.fetch(client,info.url,job,publish)
                    if result then result.quota=info.quota; return result end
                    if not M.retryable(kind) then Download.cleanup_empty(job); return nil,issue end
                    errors[#errors+1]='domain_index='..index..': '..issue
                end
            end
        end
        Download.cleanup_empty(job)
        return nil,table.concat(errors,'\n')
    end,function(result)
        local FileManager=require('apps/filemanager/filemanager')
        if FileManager.instance and not FileManager.instance.tearing_down then FileManager.instance:onRefresh() end
        local dialog
        dialog=ButtonDialog:new{title=self:safe('Downloaded and MD5 verified:\n'..result.path..quota_text(result.quota,self.config:get('key'))),buttons={{
            {text='Open now',callback=function()
                self:close(dialog)
                self:close(self.detail_dialog); self:close(self.results_menu)
                self.detail_dialog=nil; self.results_menu=nil
                require('apps/reader/readerui'):showReader(result.path)
            end},
            {text='Close',callback=function() self:close(dialog) end},
        }}}
        self:show(dialog)
    end)
end
function M:edit(name,title,secret,validate)
    local value=self.config:get(name)
    if type(value)=='table' then value=table.concat(value,'\n') end
    local dialog
    dialog=InputDialog:new{title=title,input=value,text_type=secret and 'password' or nil,
        allow_newline=not secret,buttons={{
            {text='Cancel',id='close',callback=function() self:close(dialog) end},
            {text='Save',is_enter_default=true,callback=function()
                local input=dialog:getInputText()
                local parsed,err=input,nil
                if validate then parsed,err=validate(input) end
                if not parsed then self:message(err); return end
                self.config:set(name,parsed)
                if name=='key' or name=='mirrors' then self.sessions={} end
                self:close(dialog)
            end},
        }}}
    self:show(dialog); dialog:onShowKeyboard()
end
function M:settings_menu()
    return {
        {text='Secret key',callback=function() self:edit('key','Anna\'s Archive secret key',true,function(s)
            if s:find('%c') then return nil,'The key cannot contain control characters.' end
            return s:match('^%s*(.-)%s*$') end) end},
        {text='Anna\'s Archive mirrors',callback=function() self:edit('mirrors','HTTPS mirrors — one per line',false,Config.mirrors) end},
        {text='LibGen mirrors',callback=function() self:edit('libgen_mirrors','LibGen HTTPS mirrors — one per line',false,Config.mirrors) end},
        {text='Download folder',callback=function()
            self:show(require('ui/widget/pathchooser'):new{path=self.config:get('download_folder'),select_file=false,
                show_files=false,onConfirm=function(path) self.config:set('download_folder',path) end})
        end},
        {text='Preferred format',sub_item_table=(function()
            local choices={}
            for _,format in ipairs({'','epub','pdf','mobi','azw3'}) do
                local f=format
                choices[#choices+1]={text=f=='' and 'Any' or f,checked_func=function() return self.config:get('preferred_format')==f end,
                    callback=function() self.config:set('preferred_format',f) end}
            end
            return choices
        end)()},
        {text='Clear bad-host list',callback=function() self.config:set('bad_hosts',{}); self:message('Bad-host list cleared.') end},
        {text='About',callback=function() self:message('Book Fetch 0.1.0\n© 2026 bottobot — MIT License\n'
            ..'For public-domain, openly licensed, or owner-entitled books.\nFast downloads require an Anna\'s Archive membership.\n'
            ..'Searches and downloads use HTTPS; your secret key stays in Book Fetch settings.') end},
    }
end
return M
