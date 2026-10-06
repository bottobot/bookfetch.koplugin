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
            if err then return nil,err end
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
    D.free_space=oldfree
    for name in lfs.dir(scratch) do if name~='.' and name~='..' then assert(os.remove(scratch..'/'..name)) end end
    assert(lfs.rmdir(scratch))
end
