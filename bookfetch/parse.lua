-- Copyright (c) 2026 bottobot. MIT licensed.
local M = {}
local entities = {amp='&',lt='<',gt='>',quot='"',apos="'",nbsp=' ',ndash='–',mdash='—',hellip='…',copy='©'}
local function utf8(n)
    if not n or n < 0 or n > 0x10ffff or n >= 0xd800 and n <= 0xdfff then return '�' end
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
    if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
    return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end
function M.entities(s)
    return (s or ''):gsub('&(#?[%w]+);',function(e)
        if e:sub(1,2):lower()=='#x' then return utf8(tonumber(e:sub(3),16)) end
        if e:sub(1,1)=='#' then return utf8(tonumber(e:sub(2))) end
        return entities[e] or '&'..e..';'
    end)
end
function M.text(s)
    return M.entities((s or ''):gsub('<[^>]*>',' ')):gsub('\194\160',' '):gsub('%s+',' '):match('^%s*(.-)%s*$')
end
function M.attribute(tag, name)
    for key,quote,value in tag:gmatch('([%w_:%-]+)%s*=%s*([\'"])(.-)%2') do
        if key:lower()==name then return M.entities(value) end
    end
end
function M.is_md5(s) return type(s)=='string' and #s==32 and not s:find('[^%x]') end
local formats = {epub=true,pdf=true,mobi=true,azw=true,azw3=true,djvu=true,fb2=true,txt=true,cbz=true,docx=true}
M.formats=formats
function M.search(html)
    -- A small tree preserves card scope without depending on a full DOM library.
    -- Comments may contain Anna's deferred result markup, so unwrap them first.
    html=html:gsub('<!%-%-(.-)%-%->','%1')
    local root={tag='root',children={}}
    local stack={root}
    local pos=1
    for start,tag,stop in html:gmatch('()<([^>]+)>()') do
        local parent=stack[#stack]
        if start>pos then table.insert(parent.children,html:sub(pos,start-1)) end
        local closing=tag:match('^/%s*([%w]+)')
        if closing then
            for i=#stack,2,-1 do
                if stack[i].tag==closing:lower() then for j=#stack,i,-1 do stack[j]=nil end; break end
            end
        else
            local name=tag:match('^%s*([%w]+)')
            if name then
                name=name:lower()
                local node={tag=name,attrs=tag,children={},parent=parent}
                table.insert(parent.children,node)
                if not tag:match('/%s*$') and not ({img=true,br=true,hr=true,input=true,meta=true,link=true})[name] then
                    table.insert(stack,node)
                end
            end
        end
        pos=stop
    end
    local function text(node)
        if type(node)=='string' then return node end
        local out={}
        for _,child in ipairs(node.children) do out[#out+1]=text(child) end
        return table.concat(out,' ')
    end
    local function walk(node,fn)
        if type(node)=='table' then fn(node); for _,c in ipairs(node.children) do walk(c,fn) end end
    end
    local links={}
    walk(root,function(n)
        if n.tag=='a' then
            local h=M.attribute(n.attrs,'href') or ''
            local hash=h:match('^/md5/(%x+)[/?#]?')
            if M.is_md5(hash) then links[#links+1]={node=n,md5=hash:lower()} end
        end
    end)
    local results,seen={},{}
    for _,link in ipairs(links) do
        local n=link.node
        local title=M.text(text(n))
        if title~='' and not seen[link.md5] then
            local card=n.parent or n
            -- Select the nearest ancestor containing exactly one distinct result.
            local ancestor=card
            for _=1,6 do
                if not ancestor or ancestor==root then break end
                local hashes={}
                walk(ancestor,function(c)
                    local h=c.tag=='a' and M.attribute(c.attrs,'href') or ''
                    local m=h and h:match('^/md5/(%x+)')
                    if M.is_md5(m) then hashes[m]=true end
                end)
                local count=0; for _ in pairs(hashes) do count=count+1 end
                if count>1 then break end
                card=ancestor; ancestor=ancestor.parent
            end
            -- Older result markup nests title and metadata inside the MD5 anchor.
            walk(n,function(child)
                local class=M.attribute(child.attrs or '', 'class') or ''
                if child.tag=='h3' or class:find('text%-xl') or class:find('text%-lg') then
                    local candidate=M.text(text(child))
                    if candidate~='' then title=candidate end
                end
            end)
            local book={md5=link.md5,title=title,author=''}
            walk(card,function(c)
                local class=M.attribute(c.attrs,'class') or ''
                if c.tag=='a' and c~=n and (class:find('author',1,true) or text(c):find('mdi--user-edit',1,true)
                    or c.attrs:find('search%?q=') and class:find('italic',1,true)) then book.author=M.text(text(c)) end
                if c.tag=='span' and c.attrs:find('mdi%-%-user%-edit') then
                    local a=c.parent
                    while a and a~=card and a.tag~='a' do a=a.parent end
                    if a and a.tag=='a' then book.author=M.text(text(a)) end
                end
                if class:find('publisher',1,true) or class:find('text%-xs') then
                    local t=M.text(text(c))
                    if not t:find('·',1,true) then book.publisher=book.publisher or t end
                end
                if (class:find('author',1,true) or class:find('italic',1,true)) and book.author=='' then
                    book.author=M.text(text(c))
                end
            end)
            local meta=M.text(text(card))
            book.language=meta:match('%[([%a%-]+)%]')
            book.year=meta:match('%f[%d]([12]%d%d%d)%f[^%d]')
            book.size=meta:match('(%d+%.?%d*%s*[KMG][Bb])')
            for token in meta:lower():gmatch('%f[%w]([%a][%w]*)%f[^%w]') do
                if formats[token] then book.format=token; break end
            end
            if book.title~='Cover' then results[#results+1]=book; seen[link.md5]=true end
        end
    end
    return results
end
function M.libgen(html, expected)
    for tag in html:gmatch('<[aA]%s+([^>]+)>') do
        local href=M.attribute(tag,'href')
        if href and href:find('get.php?',1,true) then
            local hash=href:match('[?&]md5=(%x+)')
            if M.is_md5(hash) and (not expected or hash:lower()==expected:lower()) then return href end
        end
    end
    return nil,'No LibGen download link found'
end
function M.blocked(code,headers,body)
    local loc=(headers or {}).location or ''
    local cookie=(headers or {})['set-cookie'] or ''
    local h=(body or ''):lower()
    return ((code==302 or code==307 or code==303) and loc:find('check=1',1,true)~=nil)
        or cookie:lower():find('__ddg',1,true)~=nil or h:find('ddos-guard',1,true)~=nil
end
function M.magic(prefix,format,content_type)
    local t=(content_type or ''):lower()
    local p=(prefix or ''):gsub('^\239\187\191',''):match('^%s*(.*)') or ''
    local lower=p:lower()
    if t:find('html',1,true) or lower:find('^<!doctype%s+html') or lower:find('^<html')
        or lower:find('^<head') or lower:find('^<body') then return nil,'Server returned HTML' end
    format=(format or ''):lower()
    local valid=(format=='epub' or format=='cbz' or format=='docx') and prefix:sub(1,4)=='PK\3\4'
        or format=='pdf' and prefix:sub(1,4)=='%PDF'
        or (format=='mobi' or format=='azw' or format=='azw3') and prefix:sub(61,68)=='BOOKMOBI'
        or format=='djvu' and prefix:sub(1,8)=='AT&TFORM'
        or format=='fb2' and (p:find('^<%?xml') or p:find('^<FictionBook'))
        or format=='txt' and not prefix:find('\0',1,true)
    if not valid then return nil,'File signature does not match '..format end
    return true
end
return M
