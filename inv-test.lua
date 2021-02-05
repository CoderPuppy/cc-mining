local I = dofile 'cc/mining/inventory.lua'
xpcall(function()
	dofile 'cc/mining/inventory-ui.lua' (I, peripheral.wrap 'minecraft:chest_2')
end, function(err)
	if err == 'Terminated' then return end
	sleep(3)
	term.setTextColor(colors.red)
	term.setBackgroundColor(colors.black)
	term.clear()
	term.setCursorPos(1, 1)
	print(err)
	local i = 3
	while true do
		local _, msg = pcall(error, '@', i)
		if msg == '@' then
			break
		end
		if i > 10 then break end
		print(i, msg)
		i = i + 1
	end
end)
