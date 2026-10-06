-- Run from the plugin directory with the Kobo's KOReader LuaJIT runtime.
-- This harness uses no network and writes only below its temporary test directory.
-- setupkoenv configures library paths without starting or modifying KOReader.
require('setupkoenv')
local script=debug.getinfo(1,'S').source:sub(2)
local root=script:match('^(.*)/spec/run.lua$') or '.'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local passed,failed=0,0
local T={root=root}
function T.eq(actual,expected)
    assert(actual==expected,string.format('Expected %s; got %s',tostring(expected),tostring(actual)))
end
function T.truth(value,message) assert(value,message or 'Expected truthy value') end
function T.test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1; io.write('PASS ',name,'\n')
    else failed=failed+1; io.write('FAIL ',name,': ',tostring(err),'\n') end
end
function T.fixture(name)
    local f=assert(io.open(root..'/spec/fixtures/'..name,'rb'))
    local text=f:read('*a'); f:close(); return text
end
for _,name in ipairs({'names','md5','parse','http','config','download','adapters','ui'}) do
    local ok,err=pcall(function() require('spec.'..name..'_spec')(T) end)
    if not ok then failed=failed+1; io.write('FAIL suite ',name,': ',tostring(err),'\n') end
end
io.write(string.format('\n%d passed; %d failed\n',passed,failed))
os.exit(failed==0 and 0 or 1)
