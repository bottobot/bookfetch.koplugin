-- Runtime integration: run from the Kobo KOReader install directory.
require('setupkoenv')
local script=debug.getinfo(1,'S').source:sub(2)
local root=script:match('^(.*)/spec/run_ko.lua$') or '.'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
require('spec.harness')(root,true,{'http','config','download','adapters','ui','runtime'})
