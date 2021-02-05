local first_chest = ...
local I = dofile 'cc/mining/inventory.lua'
I.initialize()
I.add_chest(first_chest)
peripheral.find('minecraft:barrel', function(name, handle)
	if I.state().chests[name] then return end
	for slot, stack in pairs(handle.list()) do
		local n = I.insert(handle, slot, stack.count, stack)
		assert(n == stack.count, 'failed to insert')
	end
	I.add_chest(name)
end)
I.save()
I.close()
