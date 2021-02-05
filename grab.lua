local inv = false
local function grab(file)
	file.delete(file)
	shell.run(('wget https://raw.githubusercontent.com/CoderPuppy/cc-mining/master/%s %s'):format(file, file))
end
if inv then
	grab 'inventory.lua'
	grab 'inventory-ui.lua'
	grab 'inv-test.lua'
	grab 'inv-reindex.lua'
end
