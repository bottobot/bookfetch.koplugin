-- Compile every plugin Lua file without executing it or starting KOReader.
require('setupkoenv')
local lfs=require('libs/libkoreader-lfs')
local root=arg[1] or '/tmp/bookfetch-test'
local count,failed=0,0
local function scan(path)
    for name in lfs.dir(path) do
        if name~='.' and name~='..' and name~='.git' and name~='.agents' and name~='.codex' and name~='.aws' then
            local file=path..'/'..name
            if lfs.attributes(file,'mode')=='directory' then scan(file)
            elseif name:sub(-4)=='.lua' then
                count=count+1
                local compiled,err=loadfile(file)
                if not compiled then failed=failed+1; io.write(err,'\n') end
            end
        end
    end
end
scan(root)
io.write(string.format('%d Lua files syntax-checked; %d errors\n',count,failed))
os.exit(failed==0 and 0 or 1)
