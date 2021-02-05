local pretty = require 'cc.pretty'

local place_i
local place_left = 0
local function place_fill(f)
	if place_left <= 0 then
		local slots = {}
		local cobble_i, granite_i, diorite_i, andesite_i
		for i = 1, 16 do
			local d = turtle.getItemDetail(i)
			if d then
				slots[d.name] = slots[d.name] or i
			end
		end
		local i
		for _, name in ipairs {
			'minecraft:cobblestone';
			'minecraft:granite';
			'minecraft:andesite';
			'minecraft:diorite';
			'minecraft:netherrack';
			'minecraft:basalt';
			'minecraft:blackstone';
		} do
			if slots[name] then
				i = slots[name]
				break
			end
		end
		assert(i, 'TODO: no fill')
		place_i = i
		place_left = turtle.getItemCount(i)
	end
	turtle.select(place_i)
	place_left = place_left - 1
	return f()
end

local function check_block()
	local e, d = turtle.inspect()
	if e and d.name:match('ore') then
		turtle.dig()
		place_fill(turtle.place)
	elseif not e or d.name  == 'minecraft:water' or d.name == 'minecraft:lava' then
		place_fill(turtle.place)
	end
end

local function dig_shaft()
	local n = 0
	while true do
		check_block()
		turtle.digDown()
		if not turtle.down() then break end
		n = n + 1
	end
	check_block()
	turtle.turnRight()
	for i = 1, n do
		check_block()
		turtle.digUp()
		assert(turtle.up(), 'TODO')
	end
	check_block()
	turtle.turnRight()
	for i = 1, n do
		check_block()
		turtle.digDown()
		assert(turtle.down(), 'TODO')
	end
	check_block()
	turtle.turnRight()
	for i = 1, n do
		check_block()
		turtle.digUp()
		assert(turtle.up(), 'TODO')
		place_fill(turtle.placeDown)
	end
	check_block()
	turtle.turnRight()
end

turtle.digDown()
assert(turtle.down(), 'TODO')
dig_shaft()
assert(turtle.up(), 'TODO')
place_fill(turtle.placeDown)
local n = 0
for i = 1, 16 do
	if turtle.getItemCount(i) == 0 then
		n = n + 1
	end
end
if n < 4 then
	turtle.digUp()
	turtle.select(16)
	turtle.placeUp()
	turtle.select(1)
	for i = 1, 16 do
		local d = turtle.getItemDetail(i)
		if d and d.name ~= 'minecraft:barrel' and d.name ~= 'minecraft:cobblestone' then
			turtle.select(i)
			if not turtle.refuel(0) then
				turtle.dropUp()
			end
		end
	end
end

-- 1 stack fuel
-- 1 stack barrels
-- 5 stack cobble

-- closest point within base
-- manhattan distance from that point to the destination
-- if that is greater than acceptable then request expansion






--[[
x + 3y ≡ 0 mod 5

dimensions of "square": 1 + 3 ⋅ (2 ⋅ n - 1)
	n = 3 ⇒ exactly 16×16
	requires that chunk coords ≡ 0 mod 5
	n = 2 is better
]]
