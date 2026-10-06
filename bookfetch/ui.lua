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
function M.new(owner,config) return setmetatable({owner=owner,config=config,sessions={}},M) end
function M:message(text) UIManager:show(InfoMessage:new{text=Http.redact(text,self.config:get('key'))}) end
local function bytes(n)
    if not n then return '?' end
    return string.format('%.2f MB',n/1000000)
end
local function quota_text(quota)
    if quota==nil then return '' end
    if type(quota)~='table' then return '\nDaily quota: '..tostring(quota) end
    -- The API's account information may contain several quota/account fields.
    local out={}
    for _,key in ipairs({'downloads_left','remaining','daily_downloads_left','downloads_remaining','remaining_downloads',
        'daily_limit','daily_download_limit','downloads_per_day','downloads_today'}) do
        local value=quota[key]
        if type(value)=='number' or type(value)=='string' then out[#out+1]=key:gsub('_',' ')..': '..value end
    end
    if #out==0 then return '\nDaily quota information received; see your Anna\'s Archive account for details.' end
    return '\nDaily quota: '..table.concat(out,', ')
end
function M:work(title,task,done)
    if busy then self:message('A Book Fetch task is already running.'); return end
    NetworkMgr:runWhenOnline(function()
        if busy then self:message('A Book Fetch task is already running.'); return end
        local settings=self.config:snapshot()
        if not settings.cafile then self:message('KOReader data/ca-bundle.crt was not found.'); return end
        busy=true
        local progress_path=os.tmpname()
        if not progress_path then busy=false; self:message('Could not create a progress channel.'); return end
        local dialog,discard,last_status,last_raw
        local function cancel(remove)
            discard=remove
            if dialog.dismiss_callback then dialog.dismiss_callback() end
        end
        dialog=ButtonDialog:new{title=title..'\nConnecting…',dismissable=false,buttons={{
            {text='Cancel',callback=function() cancel(false) end},
            {text='Discard partial',callback=function() cancel(true) end},
        }}}
        UIManager:show(dialog)
        local function poll()
            local f=io.open(progress_path,'rb')
            if f then
                local raw=f:read(65536); f:close()
                local ok,status=pcall(json.decode,raw or '')
                if ok and type(status)=='table' and raw~=last_raw then
                    last_raw=raw
                    last_status=status
                    dialog:setTitle(title..'\n'..(status.phase or 'Connecting')..'\n'..(status.host or '')..'\n'
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
            UIManager:close(dialog)
            busy=false
            if result then
                self.sessions=result.sessions or self.sessions
                self.config:merge_bad(result.bad_hosts)
            elseif last_status then self.config:merge_bad(last_status.bad_hosts) end
            os.remove(progress_path); os.remove(progress_path..'.tmp')
            if not completed then
                if discard and last_status and last_status.part then
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
        {text='Cancel',id='close',callback=function() UIManager:close(dialog) end},
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
            UIManager:close(dialog)
            self:search(query,format,language,1)
        end},
    }}}
    UIManager:show(dialog); dialog:onShowKeyboard()
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
        items[#items+1]={text=b.title..(b.author~='' and ' — '..b.author or '')
            ..(#details>0 and ' ('..table.concat(details,', ')..')' or ''),callback=function() self:detail(b) end}
    end
    local menu
    if #items==0 then items[1]={text='No results on this page',enabled=false} end
    if data.page>1 then items[#items+1]={text='Previous page',callback=function()
        UIManager:close(menu); self:search(query,format,language,data.page-1) end} end
    items[#items+1]={text='Next page',callback=function()
        UIManager:close(menu); self:search(query,format,language,data.page+1) end}
    menu=Menu:new{title='Book Fetch — Page '..data.page,item_table=items,
        width=require('device').screen:getWidth(),height=require('device').screen:getHeight(),
        is_popout=false,is_borderless=true}
    UIManager:show(menu)
end
function M:detail(book)
    local dialog
    local text={book.title,book.author}
    for _,name in ipairs({'publisher','year','language','format','size','md5'}) do
        if book[name] then text[#text+1]=name..': '..book[name] end
    end
    dialog=ButtonDialog:new{title=table.concat(text,'\n'),buttons={{
        {text='Download',callback=function() UIManager:close(dialog); self:download(book,false) end},
        {text='Try LibGen',callback=function() UIManager:close(dialog); self:download(book,true) end},
    },{{text='Cancel',callback=function() UIManager:close(dialog) end}}}}
    UIManager:show(dialog)
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
                    local result,issue,kind=Download.fetch(client,url,job,publish)
                    if result then return result end
                    if kind=='integrity' or kind=='local' then return nil,issue end
                    errors[#errors+1]=issue
                else errors[#errors+1]=why end
            end
        else
            for index=0,6 do
                local info,why,kind=aa:resolve(book,index)
                if not info then
                    errors[#errors+1]=why
                    if kind=='api' then break end
                else
                    local result,issue,kind=Download.fetch(client,info.url,job,publish)
                    if result then result.quota=info.quota; return result end
                    if kind=='integrity' or kind=='local' then return nil,issue end
                    errors[#errors+1]=issue
                end
            end
        end
        return nil,table.concat(errors,'\n')
    end,function(result)
        local FileManager=require('apps/filemanager/filemanager')
        if FileManager.instance and not FileManager.instance.tearing_down then FileManager.instance:onRefresh() end
        local dialog
        dialog=ButtonDialog:new{title='Downloaded and MD5 verified:\n'..result.path..quota_text(result.quota),buttons={{
            {text='Open now',callback=function()
                UIManager:close(dialog)
                require('apps/reader/readerui'):showReader(result.path)
            end},
            {text='Close',callback=function() UIManager:close(dialog) end},
        }}}
        UIManager:show(dialog)
    end)
end
function M:edit(name,title,secret,validate)
    local value=self.config:get(name)
    if type(value)=='table' then value=table.concat(value,'\n') end
    local dialog
    dialog=InputDialog:new{title=title,input=value,text_type=secret and 'password' or nil,
        allow_newline=not secret,disable_clipboard_snippet_edit=secret,buttons={{
            {text='Cancel',id='close',callback=function() UIManager:close(dialog) end},
            {text='Save',is_enter_default=true,callback=function()
                local input=dialog:getInputText()
                local parsed,err=input,nil
                if validate then parsed,err=validate(input) end
                if not parsed then self:message(err); return end
                self.config:set(name,parsed)
                if name=='key' or name=='mirrors' then self.sessions={} end
                UIManager:close(dialog)
            end},
        }}}
    UIManager:show(dialog); dialog:onShowKeyboard()
end
function M:settings_menu()
    return {
        {text='Secret key',callback=function() self:edit('key','Anna\'s Archive secret key',true,function(s)
            if s:find('%c') then return nil,'The key cannot contain control characters.' end
            return s:match('^%s*(.-)%s*$') end) end},
        {text='Anna\'s Archive mirrors',callback=function() self:edit('mirrors','HTTPS mirrors — one per line',false,Config.mirrors) end},
        {text='LibGen mirrors',callback=function() self:edit('libgen_mirrors','LibGen HTTPS mirrors — one per line',false,Config.mirrors) end},
        {text='Download folder',callback=function()
            UIManager:show(require('ui/widget/pathchooser'):new{path=self.config:get('download_folder'),select_file=false,
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
