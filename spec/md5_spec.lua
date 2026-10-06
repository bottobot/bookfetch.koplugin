return function(T)
    local M=require('bookfetch.md5')
    local vectors={
        {'','d41d8cd98f00b204e9800998ecf8427e'},
        {'a','0cc175b9c0f1b6a831c399e269772661'},
        {'abc','900150983cd24fb0d6963f7d28e17f72'},
        {'message digest','f96b697d7cb7938d525a2f31aaf161d0'},
        {'abcdefghijklmnopqrstuvwxyz','c3fcd3d76192e4007dfb496cca67e13b'},
        {'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789','d174ab98d277d9f5a5611c2c9f419d9f'},
        {string.rep('1234567890',8),'57edf4a22be3c955ac49da2e2107b67a'},
    }
    for i,v in ipairs(vectors) do T.test('RFC 1321 vector '..i,function() T.eq(M.sum(v[1]),v[2]) end) end
    T.test('million-a vector',function()
        local c=M.new(); for _=1,1000 do c:update(string.rep('a',1000)) end
        T.eq(c:finish(),'7707d6ae4e027c70eea2a935c2296f21'); T.eq(#c.buffer,0)
    end)
    T.test('streaming every chunk boundary',function()
        local data=string.rep('0123456789\0水',90)
        for size=1,80 do
            local c=M.new(); for pos=1,#data,size do c:update(data:sub(pos,pos+size-1)) end
            T.eq(c:finish(),M.sum(data)); T.eq(c:finish(),M.sum(data))
        end
    end)
end
