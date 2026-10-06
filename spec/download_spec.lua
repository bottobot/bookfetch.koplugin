return function(T)
    local D=require('bookfetch.download')
    local MD5=require('bookfetch.md5')
    local lfs=require('libs/libkoreader-lfs')
    local scratch=os.tmpname(); os.remove(scratch); assert(lfs.mkdir(scratch))
    local oldfree=D.free_space; D.free_space=function() return 1000000000 end
    local function write(path,data) local f=assert(io.open(path,'wb')); assert(f:write(data)); assert(f:close()) end
    local function read(path) local f=assert(io.open(path,'rb')); local data=f:read('*a'); f:close(); return data end
    local sequence=0
    local payload='%PDF-1.7\n'..string.rep('Book data\n',100)
    local function job(hash)
        sequence=sequence+1
        return assert(D.prepare(scratch,{title='Book '..sequence,author='Ada',format='pdf',md5=hash or MD5.sum(payload)}))
    end
    local function client(code,headers,body,check)
        return {request=function(_,url,opts)
            if check then check(opts) end
            local response={code=code,headers=headers or {},host='example.org',url=url}
            local sink,err=opts.sink_factory(response)
            if err then return nil,err,'response' end
            if sink then
                for p=1,#body,23 do local ok,why=sink(body:sub(p,p+22)); if not ok then return nil,why end end
                local ok,why=sink(nil); if not ok then return nil,why end
            end
            return response
        end}
    end
    T.test('download stream verify and rename',function()
        local j=job(); local result=assert(D.fetch(client(200,{['content-length']=tostring(#payload)},payload),'https://example.org/file',j))
        T.eq(read(result.path),payload); T.eq(lfs.attributes(j.part),nil); T.eq(lfs.attributes(j.marker),nil)
    end)
    T.test('resume with validated 206',function()
        local j=job(); write(j.part,payload:sub(1,100))
        local result=assert(D.fetch(client(206,{['content-range']='bytes 100-'..(#payload-1)..'/'..#payload,
            ['content-length']=tostring(#payload-100)},payload:sub(101),function(o) T.eq(o.headers.range,'bytes=100-') end),'https://example.org/file',j))
        T.eq(read(result.path),payload)
    end)
    T.test('200 restarts existing partial',function()
        local j=job(); write(j.part,'old partial junk')
        local result=assert(D.fetch(client(200,{['content-length']=tostring(#payload)},payload),'https://example.org/file',j))
        T.eq(read(result.path),payload)
    end)
    T.test('incorrect 206 range preserves partial',function()
        local j=job(); write(j.part,'prior')
        T.eq(D.fetch(client(206,{['content-range']='bytes 0-9/10'},'ignored'),'https://example.org/',j),nil)
        T.eq(read(j.part),'prior')
    end)
    T.test('HTTP error preserves partial',function()
        local j=job(); write(j.part,'prior')
        T.eq(D.fetch(client(503,{},'<html>error</html>'),'https://example.org/',j),nil); T.eq(read(j.part),'prior')
    end)
    T.test('HTML MIME rejected before truncating',function()
        local j=job(); write(j.part,'prior')
        T.eq(D.fetch(client(200,{['content-type']='text/html'},'<html/>'),'https://example.org/',j),nil); T.eq(read(j.part),'prior')
    end)
    T.test('MD5 mismatch quarantined',function()
        local j=job(string.rep('0',32))
        local result,err,kind=D.fetch(client(200,{},payload),'https://example.org/',j)
        T.eq(result,nil); T.eq(kind,'integrity'); T.truth(err:find('MD5 mismatch',1,true)); T.eq(read(j.final..'.bad'),payload)
    end)
    T.test('signature failure quarantined',function()
        local j=job(MD5.sum('<html>challenge</html>'))
        T.eq(D.fetch(client(200,{},'<html>challenge</html>'),'https://example.org/',j),nil)
        T.truth(lfs.attributes(j.final..'.bad'))
    end)
    T.test('500 MB header limit preserves partial',function()
        local j=job(); write(j.part,'prior')
        T.eq(D.fetch(client(200,{['content-length']='500000001'},'ignored'),'https://example.org/',j),nil); T.eq(read(j.part),'prior')
    end)
    T.test('streamed size ceiling',function()
        local j=job(); local limit=D.MAX_BYTES; D.MAX_BYTES=20
        local result=D.fetch(client(200,{},payload),'https://example.org/',j)
        D.MAX_BYTES=limit; T.eq(result,nil); T.truth((lfs.attributes(j.part,'size') or 0)<=20)
    end)
    T.test('free space gate',function()
        local j=job(); D.free_space=function() return 0 end
        local result=D.fetch(client(200,{},payload),'https://example.org/',j)
        D.free_space=function() return 1000000000 end; T.eq(result,nil); T.eq(lfs.attributes(j.part),nil)
    end)
    T.test('complete partial accepted after 416',function()
        local j=job(); write(j.part,payload)
        local result=assert(D.fetch(client(416,{['content-range']='bytes */'..#payload},''),'https://example.org/',j))
        T.eq(read(result.path),payload)
    end)
    T.test('incomplete transfer stays resumable',function()
        local j=job()
        T.eq(D.fetch(client(200,{['content-length']=tostring(#payload)},payload:sub(1,60)),'https://example.org/',j),nil)
        T.eq(read(j.part),payload:sub(1,60)); T.eq(read(j.marker),j.md5)
    end)
    T.test('partial ownership prevents cross-book resume',function()
        local b={title='Identical',format='pdf',md5=MD5.sum(payload)}
        local a=assert(D.prepare(scratch,b)); write(a.part,'old')
        local same=assert(D.prepare(scratch,b)); T.eq(a.part,same.part)
        b.md5=string.rep('a',32); local other=assert(D.prepare(scratch,b)); T.truth(other.part~=a.part)
    end)
    T.test('final collision at rename preserved',function()
        local j=job(); write(j.part,payload); write(j.final,'existing')
        local result=assert(D.finish(j)); T.truth(result.path~=j.final); T.eq(read(j.final),'existing'); T.eq(read(result.path),payload)
    end)
    T.test('discard removes partial and sidecar only',function()
        local j=job(); write(j.part,'partial'); write(j.final,'keep')
        T.truth(D.discard(j.part)); T.eq(lfs.attributes(j.part),nil); T.eq(lfs.attributes(j.marker),nil); T.eq(read(j.final),'keep')
    end)
    T.test('secret cannot enter filenames',function()
        local j=assert(D.prepare(scratch,{title='abc SECRET xyz',author='SECRET',format='pdf',md5=MD5.sum(payload)},'SECRET'))
        T.eq(j.final:find('SECRET',1,true),nil)
    end)
    T.test('free space uses actual total free signature',function()
        local saved=package.loaded['ffi/util']
        package.loaded['ffi/util']={df=function(path) T.eq(path,scratch); return 2000000000,1234567 end}
        T.eq(oldfree(scratch),1234567)
        package.loaded['ffi/util']={df=function() return nil,'statvfs failed' end}
        T.eq(oldfree(scratch),nil)
        package.loaded['ffi/util']=saved
    end)
    T.test('local size and free space failures carry local kind',function()
        local j=job()
        local _,_,kind=D.fetch(client(200,{['content-length']='500000001'},''),'https://example.org/',j)
        T.eq(kind,'local')
        j=job(); local free=D.free_space; D.free_space=function() return 1048576 end
        local _,_,why=D.fetch(client(200,{['content-length']='2000000'},''),'https://example.org/',j)
        D.free_space=free; T.eq(why,'local')
    end)
    T.test('open write flush and close errors carry local kind',function()
        for _,failure in ipairs({'open','write','flush','close'}) do
            local j=job(); local open=io.open
            io.open=function(path,mode)
                if path~=j.part or mode~='wb' then return open(path,mode) end
                if failure=='open' then return nil,'disk full' end
                return {write=function(self) if failure=='write' then return nil,'disk full' end; return self end,
                    flush=function() if failure=='flush' then return nil,'disk full' end; return true end,
                    close=function() if failure=='close' then return nil,'disk full' end; return true end}
            end
            local ok,err=pcall(function()
                local _,_,kind=D.fetch(client(200,{},payload),'https://example.org/',j); T.eq(kind,'local')
            end)
            io.open=open; assert(ok,err)
        end
    end)
    T.test('HTTP transport kinds and retryable status propagate',function()
        for _,kind in ipairs({'transport','body','policy'}) do
            local j=job()
            local _,_,actual=D.fetch({request=function() return nil,'test',kind end},'https://example.org/',j)
            T.eq(actual,kind)
        end
        for _,code in ipairs({404,503,403}) do
            local _,_,kind=D.fetch(client(code,{},''),'https://example.org/',job())
            T.eq(kind,code==403 and 'response' or 'http_retry')
        end
    end)
    T.test('unknown metadata format selects verified extension',function()
        local j=assert(D.prepare(scratch,{title='Unknown',md5=MD5.sum(payload)}))
        local result=assert(D.fetch(client(200,{},payload),'https://example.org/',j))
        T.truth(result.path:match('%.pdf$')); T.eq(read(result.path),payload)
        local epub='PK\3\4mimetypeapplication/epub+zip'
        j=assert(D.prepare(scratch,{title='Unknown epub',md5=MD5.sum(epub)}))
        result=assert(D.fetch(client(200,{},epub),'https://example.org/',j)); T.truth(result.path:match('%.epub$'))
    end)
    T.test('unrecognized unknown format quarantines',function()
        local data='\0unrecognized'
        local j=assert(D.prepare(scratch,{title='Unknown binary',md5=MD5.sum(data)}))
        local _,_,kind=D.fetch(client(200,{},data),'https://example.org/',j)
        T.eq(kind,'integrity'); T.truth(lfs.attributes(j.final..'.bad'))
    end)
    T.test('sidecar-only reservation is reused for same MD5',function()
        local b={title='Sidecar',format='pdf',md5=MD5.sum(payload)}
        local j=assert(D.prepare(scratch,b)); os.remove(j.part)
        local reused=assert(D.prepare(scratch,b))
        T.eq(reused.part,j.part); T.eq(read(reused.part),'')
        b.md5=string.rep('f',32); local other=assert(D.prepare(scratch,b)); T.truth(other.part~=j.part)
    end)
    T.test('unmarked matching partial is adopted and MD5 verified',function()
        local b={title='Unmarked',format='pdf',md5=MD5.sum(payload)}
        local j=assert(D.prepare(scratch,b)); write(j.part,payload); os.remove(j.marker)
        local adopted=assert(D.prepare(scratch,b)); T.eq(adopted.part,j.part)
        T.truth(D.finish(adopted))
        j=assert(D.prepare(scratch,{title='Wrong unmarked',format='pdf',md5=string.rep('a',32)}))
        write(j.part,payload); os.remove(j.marker)
        adopted=assert(D.prepare(scratch,{title='Wrong unmarked',format='pdf',md5=string.rep('a',32)}))
        local _,_,kind=D.finish(adopted); T.eq(kind,'integrity')
    end)
    T.test('failed empty downloads release reservation and partial together',function()
        local j=job(); T.eq(read(j.part),''); T.eq(read(j.marker),j.md5)
        D.fetch({request=function() return nil,'refused','transport' end},'https://example.org/',j)
        T.eq(lfs.attributes(j.part),nil); T.eq(lfs.attributes(j.marker),nil)
    end)
    T.test('failed reservation creation leaves no empty orphan',function()
        local b={title='Failed reservation',format='pdf',md5=MD5.sum(payload)}
        local part=scratch..'/Failed reservation.pdf.part'
        local open=io.open
        io.open=function(path,mode)
            if path==part..'.md5' and mode=='wb' then return nil,'disk full' end
            return open(path,mode)
        end
        local ok,err=pcall(function()
            local _,_,kind=D.prepare(scratch,b); T.eq(kind,'local')
            T.eq(lfs.attributes(part),nil); T.eq(lfs.attributes(part..'.md5'),nil)
        end)
        io.open=open; assert(ok,err)
    end)
    D.free_space=oldfree
    for name in lfs.dir(scratch) do if name~='.' and name~='..' then assert(os.remove(scratch..'/'..name)) end end
    assert(lfs.rmdir(scratch))
end
