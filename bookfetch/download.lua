-- Copyright (c) 2026 bottobot. MIT licensed.
local lfs=require('libs/libkoreader-lfs')
local Names=require('bookfetch.names')
local Parse=require('bookfetch.parse')
local MD5=require('bookfetch.md5')
local Http=require('bookfetch.http')
local M={MAX_BYTES=500000000}
local function exists(path) return lfs.symlinkattributes(path)~=nil end
local function read(path,n)
    local f=io.open(path,'rb'); if not f then return nil end
    local s=f:read(n or '*a'); f:close(); return s
end
local function write(path,data)
    local f,err=io.open(path,'wb'); if not f then return nil,err end
    local ok,why=f:write(data)
    local closed,closeerr=f:close()
    return ok and closed,why or closeerr
end
function M.mkdir(path)
    if type(path)~='string' or path:sub(1,1)~='/' or path:find('%c') then return nil,'Download folder must be an absolute path' end
    local current=''
    for part in path:gmatch('[^/]+') do
        if part=='..' then return nil,'Parent path components are not allowed' end
        if part~='.' then
            current=current..'/'..part
            local mode=lfs.attributes(current,'mode')
            if not mode then local ok,err=lfs.mkdir(current); if not ok then return nil,err end
            elseif mode~='directory' then return nil,'Not a directory: '..current end
        end
    end
    return true
end
function M.free_space(path)
    local ok,util=pcall(require,'ffi/util')
    if ok and util.df then
        local worked,_,_,available=pcall(util.df,path)
        if worked then return available end
    end
    -- Older KOReader versions do not expose statvfs through ffi/util.
    return nil
end
function M.prepare(folder,book,secret)
    if not Parse.is_md5(book.md5) then return nil,'Invalid expected MD5' end
    if not Parse.formats[book.format or ''] then return nil,'Unsupported or missing file format' end
    local ok,err=M.mkdir(folder); if not ok then return nil,err end
    local safe={title=Http.redact(book.title,secret),author=Http.redact(book.author,secret),format=book.format}
    local md5=book.md5:lower()
    for i=1,10000 do
        local final=folder..'/'..Names.filename(safe,i)
        local part=final..'.part'
        local attr=lfs.symlinkattributes(part)
        if not exists(final) then
            if attr and attr.mode=='file' and read(part..'.md5',64)==md5 then
                if attr.size>M.MAX_BYTES then return nil,'Partial file exceeds 500 MB' end
                return {final=final,part=part,marker=part..'.md5',book=safe,md5=md5,folder=folder}
            elseif not attr and not exists(part..'.md5') then
                local saved,why=write(part..'.md5',md5)
                if not saved then return nil,why end
                return {final=final,part=part,marker=part..'.md5',book=safe,md5=md5,folder=folder}
            end
        end
    end
    return nil,'Too many filename collisions'
end
local function quarantine(job,reason)
    local bad=job.final..'.bad'; local i=1
    while exists(bad) do i=i+1; bad=job.final..'.bad.'..i end
    local ok,err=os.rename(job.part,bad)
    if not ok then return nil,reason..'; could not preserve rejected file: '..tostring(err) end
    os.remove(job.marker)
    return nil,reason..'; preserved as '..bad,'integrity'
end
function M.finish(job,content_type,progress)
    local prefix=read(job.part,4096)
    if not prefix then return nil,'Could not read partial file for verification' end
    local valid,why=Parse.magic(prefix,job.book.format,content_type)
    if not valid then return quarantine(job,why) end
    local size=lfs.attributes(job.part,'size')
    if not size or size>M.MAX_BYTES then return quarantine(job,'File exceeds 500 MB') end
    if progress then progress{phase='Verifying MD5',bytes=size,total=size,part=job.part} end
    local digest,err=MD5.file(job.part,function(count)
        if progress then progress{phase='Verifying MD5',bytes=count,total=size,part=job.part} end
    end)
    if not digest then return nil,'MD5 read failed: '..tostring(err) end
    if digest~=job.md5 then return quarantine(job,'MD5 mismatch (expected '..job.md5..', received '..digest..')') end
    local final=job.final
    if exists(final) then
        final,err=Names.available(job.folder,job.book,function(p) return exists(p) or exists(p..'.part') end)
        if not final then return nil,err end
    end
    local ok,why_rename=os.rename(job.part,final)
    if not ok then return nil,'Could not rename verified file: '..tostring(why_rename) end
    os.remove(job.marker)
    return {path=final,bytes=size,md5=digest}
end
function M.fetch(client,url,job,progress)
    local offset=lfs.attributes(job.part,'size') or 0
    if offset>M.MAX_BYTES then return nil,'Partial file exceeds 500 MB','local' end
    if not exists(job.marker) then
        local saved,why=write(job.marker,job.md5)
        if not saved then return nil,why,'local' end
    end
    local available=M.free_space(job.folder)
    if available and available<1024*1024 then return nil,'Insufficient free space in '..job.folder end
    local headers={}
    if offset>0 then headers.range='bytes='..offset..'-' end
    local file,file_sink,bytes,total,ctype,write_error
    local start=os.time()
    local response,err=client:request(url,{headers=headers,sink_factory=function(res)
        if res.code~=200 and res.code~=206 then return nil end
        ctype=res.headers['content-type'] or ''
        if ctype:lower():find('html',1,true) then return nil,'Server returned HTML on '..res.host end
        if res.headers['content-encoding'] and res.headers['content-encoding']:lower()~='identity' then
            return nil,'Encoded file responses cannot be resumed safely'
        end
        local length=tonumber(res.headers['content-length'])
        if res.code==206 then
            local first,last,size=(res.headers['content-range'] or ''):match('^bytes (%d+)%-(%d+)/(%d+)$')
            first,last,size=tonumber(first),tonumber(last),tonumber(size)
            if not first or first~=offset or last<first or size<=last or (length and length~=last-first+1) then
                return nil,'Invalid Content-Range on '..res.host
            end
            total=size; bytes=offset
        else total=length; bytes=0 end
        if total and total>M.MAX_BYTES then return nil,'File exceeds 500 MB' end
        local free=M.free_space(job.folder)
        local needed=(total or 1024*1024)-bytes
        if res.code==200 then needed=needed-offset end -- truncation releases the existing allocation
        if free and needed>free then return nil,'Insufficient free space for this download' end
        file,write_error=io.open(job.part,res.code==206 and 'ab' or 'wb')
        if not file then return nil,write_error end
        file_sink=require('ltn12').sink.file(file)
        if progress then progress{phase='Downloading',host=res.host,bytes=bytes,total=total,part=job.part} end
        return function(chunk,sinkerr)
            if sinkerr then return nil,sinkerr end
            if chunk then
                if bytes+#chunk>M.MAX_BYTES or total and bytes+#chunk>total then
                    write_error='Response exceeds declared size or 500 MB'; return nil,write_error
                end
                local ok,why=file_sink(chunk)
                if not ok then write_error=why or 'File write failed'; return nil,write_error end
                -- Flush every block: SIGKILL cancellation retains all acknowledged bytes.
                local flushed,flusherr=file:flush()
                if not flushed then write_error=flusherr or 'File flush failed'; return nil,write_error end
                bytes=bytes+#chunk
                if progress then progress{phase='Downloading',host=res.host,bytes=bytes,total=total,
                    speed=(bytes-(res.code==206 and offset or 0))/math.max(1,os.time()-start),part=job.part} end
            end
            return 1
        end
    end})
    if file then
        local closed,why=file:close()
        if not closed then write_error=why or 'File close failed' end
    end
    if write_error then return nil,write_error end
    if not response then return nil,err end
    if response.code==416 then
        local size=tonumber((response.headers['content-range'] or ''):match('^bytes %*/(%d+)$'))
        if offset>0 and size==offset then return M.finish(job,nil,progress) end
        return nil,'Server rejected resume range on '..response.host
    end
    if response.code~=200 and response.code~=206 then return nil,'HTTP '..response.code..' on '..response.host end
    if total and bytes~=total then return nil,'Incomplete download on '..response.host..' ('..bytes..'/'..total..' bytes)' end
    return M.finish(job,ctype,progress)
end
function M.discard(part)
    if type(part)~='string' or part:sub(-5)~='.part' then return nil,'Invalid partial path' end
    local attr=lfs.symlinkattributes(part)
    if attr and attr.mode~='file' then return nil,'Partial path is not a regular file' end
    if attr then local ok,err=os.remove(part); if not ok then return nil,err end end
    os.remove(part..'.md5')
    return true
end
return M
