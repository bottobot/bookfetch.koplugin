-- Read-only runtime inventory; no device/UI startup or network.
require('setupkoenv')
local script=debug.getinfo(1,'S').source:sub(2)
local root=script:match('^(.*)/spec/probe.lua$') or '.'
package.path=root..'/?.lua;'..package.path
for _,name in ipairs({'ffi/sha2','md5','socket.http','ssl.https','ltn12','libs/libkoreader-lfs'}) do
    local ok,module=pcall(require,name)
    io.write(name,': ',ok and 'available' or 'unavailable','\n')
    if name=='ffi/sha2' and ok then io.write('ffi/sha2.md5: ',type(module.md5),'\n') end
end
local _,backend=require('bookfetch.md5').native_backend()
io.write('Streaming MD5 backend: ',backend,'\n')
local f=io.open('data/ca-bundle.crt','rb')
io.write('CA bundle: ',f and 'present' or 'missing','\n')
if f then f:close() end
