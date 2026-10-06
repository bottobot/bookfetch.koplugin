-- Copyright (c) 2026 bottobot. MIT licensed.
local M = {}

function M.truncate(s, limit)
    local pos, last = 1, 0
    while pos <= #s do
        local b = s:byte(pos)
        local n = b < 128 and 1 or b >= 194 and b <= 223 and 2
            or b >= 224 and b <= 239 and 3 or b >= 240 and b <= 244 and 4 or 0
        if n == 0 or pos + n - 1 > #s or pos + n - 1 > limit then break end
        for i = pos + 1, pos + n - 1 do
            if s:byte(i) < 128 or s:byte(i) > 191 then return s:sub(1, last) end
        end
        local second=s:byte(pos+1)
        if n==3 and (b==224 and second<160 or b==237 and second>=160)
            or n==4 and (b==240 and second<144 or b==244 and second>143) then return s:sub(1,last) end
        last, pos = pos + n - 1, pos + n
    end
    return s:sub(1, last)
end

function M.clean(s, limit)
    s = tostring(s or ""):gsub('%s+', ' '):gsub('[\\/:*?"<>|%z\1-\31\127]', '')
        :gsub('\194\160', ' '):gsub('%s+', ' '):gsub('^[ %.]+', ''):gsub('[ %.]+$', '')
    s = M.truncate(s, limit or 120):gsub('[ %.]+$', '')
    if s == '' then s = 'Untitled' end
    -- Windows/vfat reserved basenames are unsafe even with an extension.
    local stem = s:match('^[^.]+'):upper()
    if stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL'
        or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$') then s = '_' .. s end
    return M.truncate(s, limit or 120)
end

function M.filename(book, index)
    local ext = tostring(book.format or ''):lower()
    assert(ext:match('^[a-z][a-z0-9]*$') and #ext <= 8, 'Unsupported filename extension')
    local suffix = (index and index > 1 and ' (' .. index .. ')' or '') .. '.' .. ext
    local title = book.title or 'Untitled'
    if book.author and book.author ~= '' then title = title .. ' - ' .. book.author end
    return M.clean(title, 120 - #suffix) .. suffix
end

function M.available(folder, book, occupied)
    for i = 1, 10000 do
        local path = folder .. '/' .. M.filename(book, i)
        if not occupied(path) then return path end
    end
    return nil, 'Too many filename collisions'
end
return M
