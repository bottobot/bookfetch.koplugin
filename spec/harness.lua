return function(root,integration,suites)
    local passed,failed,skipped=0,0,0
    local skip_tag={}
    local require_runtime=os.getenv('BOOKFETCH_REQUIRE_RUNTIME')=='1'
    local T={root=root,integration=integration}
    function T.eq(actual,expected)
        assert(actual==expected,string.format('Expected %s; got %s',tostring(expected),tostring(actual)))
    end
    function T.truth(value,message) assert(value,message or 'Expected truthy value') end
    function T.skip(reason)
        if require_runtime then error('Required runtime unavailable: '..tostring(reason),0) end
        error({tag=skip_tag,reason=tostring(reason)},0)
    end
    function T.test(name,fn)
        local ok,err=pcall(fn)
        if ok then passed=passed+1; io.write('PASS ',name,'\n')
        elseif type(err)=='table' and err.tag==skip_tag then
            skipped=skipped+1; io.write('SKIP ',name,': ',err.reason,'\n')
        else failed=failed+1; io.write('FAIL ',name,': ',tostring(err),'\n') end
    end
    function T.fixture(name)
        local f=assert(io.open(root..'/spec/fixtures/'..name,'rb'))
        local text=f:read('*a'); f:close(); return text
    end
    for _,name in ipairs(suites) do
        local ok,err=pcall(function() require('spec.'..name..'_spec')(T) end)
        if not ok then failed=failed+1; io.write('FAIL suite ',name,': ',tostring(err),'\n') end
    end
    io.write(string.format('\n%d passed; %d failed; %d skipped\n',passed,failed,skipped))
    os.exit(failed==0 and 0 or 1)

end
