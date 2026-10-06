-- Pure logic: no KOReader setup or device/UI modules required.
local script=debug.getinfo(1,'S').source:sub(2)
local root=script:match('^(.*)/spec/run.lua$') or '.'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
require('spec.harness')(root,false,{'names','md5','parse','http','cookies'})
