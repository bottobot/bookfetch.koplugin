-- Copyright (c) 2026 bottobot. MIT licensed.
-- Streaming RFC 1321 implementation for LuaJIT, bounded to a single block buffer.
local bit = require('bit')
local band, bor, bxor, bnot, rol, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit
local M = {}
local shifts = {7,12,17,22, 5,9,14,20, 4,11,16,23, 6,10,15,21}
local constants = {}
for i = 1, 64 do constants[i] = tobit(math.floor(math.abs(math.sin(i)) * 4294967296)) end
local function word(s, p)
    local a,b,c,d = s:byte(p,p+3)
    return tobit(a + b*256 + c*65536 + d*16777216)
end
local function le(n)
    return string.char(band(n,255), band(bit.rshift(n,8),255), band(bit.rshift(n,16),255), band(bit.rshift(n,24),255))
end
local Context = {}
Context.__index = Context
function M.new()
    return setmetatable({a=0x67452301,b=tobit(0xefcdab89),c=tobit(0x98badcfe),d=0x10325476,
        buffer='', length=0}, Context)
end
function Context:block(s, p)
    local x = {}
    for j=0,15 do x[j] = word(s,p+j*4) end
    local a,b,c,d = self.a,self.b,self.c,self.d
    for i=0,63 do
        local f,g,r
        if i<16 then f,g,r=bor(band(b,c),band(bnot(b),d)),i,0
        elseif i<32 then f,g,r=bor(band(d,b),band(bnot(d),c)),(5*i+1)%16,4
        elseif i<48 then f,g,r=bxor(b,c,d),(3*i+5)%16,8
        else f,g,r=bxor(c,bor(b,bnot(d))),(7*i)%16,12 end
        a,b,c,d = d,tobit(b + rol(tobit(a + f + constants[i+1] + x[g]), shifts[r+i%4+1])),b,c
    end
    self.a,self.b,self.c,self.d=tobit(self.a+a),tobit(self.b+b),tobit(self.c+c),tobit(self.d+d)
end
function Context:update(s)
    assert(not self.finished, 'MD5 context already finalized')
    self.length = self.length + #s
    local data = self.buffer .. s
    local full = #data - #data%64
    for p=1,full,64 do self:block(data,p) end
    self.buffer=data:sub(full+1)
    return self
end
function Context:finish()
    if self.finished then return self.finished end
    local bits = self.length * 8
    local pad = '\128' .. string.rep('\0', (55-self.length)%64)
        .. le(bits%4294967296) .. le(math.floor(bits/4294967296))
    self:update(pad)
    self.finished = (le(self.a)..le(self.b)..le(self.c)..le(self.d)):gsub('.', function(c)
        return string.format('%02x', c:byte()) end)
    return self.finished
end
function M.sum(s) return M.new():update(s):finish() end
function M.native_backend()
    local ok,sha=pcall(require,'ffi/sha2')
    if ok and type(sha)=='table' and type(sha.md5)=='function' then
        local ready,feed=pcall(sha.md5)
        if ready and type(feed)=='function' then return feed,'ffi/sha2.md5' end
    end
    return nil,'bookfetch.md5'
end
function M.file(path, progress)
    local f,err=io.open(path,'rb')
    if not f then return nil,err end
    local feed=M.native_backend()
    local ctx,count=M.new(),0
    while true do
        local chunk, readerr=f:read(65536)
        if not chunk then
            f:close()
            if readerr then return nil,readerr end
            break
        end
        if feed then feed(chunk) else ctx:update(chunk) end
        count=count+#chunk
        if progress then progress(count) end
    end
    return feed and feed() or ctx:finish()
end
return M
