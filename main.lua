-- Copyright (c) 2026 bottobot. MIT licensed.
local WidgetContainer=require('ui/widget/container/widgetcontainer')
local Dispatcher=require('dispatcher')
local Config=require('bookfetch.config')
local UI=require('bookfetch.ui')
local BookFetch=WidgetContainer:extend{name='bookfetch',is_doc_only=false}
function BookFetch:init()
    self.bookfetch_ui=UI.new(self,Config.open())
    Dispatcher:registerAction('bookfetch_search',{category='none',event='BookFetchSearch',title='Book Fetch',general=true})
    self.ui.menu:registerToMainMenu(self)
end
function BookFetch:onBookFetchSearch()
    self.bookfetch_ui:search_dialog()
    return true
end
function BookFetch:addToMainMenu(menu_items)
    menu_items.bookfetch={text='Book Fetch',sorting_hint='tools',sub_item_table={
        {text='Search',callback=function() self:onBookFetchSearch() end},
        {text='Settings',sub_item_table=self.bookfetch_ui:settings_menu()},
    }}
end
return BookFetch
