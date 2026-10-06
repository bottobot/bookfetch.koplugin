-- Common source interface: new(http, settings), search(...), resolve(book, index).
local AA=require('bookfetch.aa')
AA.resolve=AA.fast
return AA
