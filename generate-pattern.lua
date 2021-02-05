local width, height = 96, 96
for x = 0, width - 1 do
	local fwd = x % 2 == 0
	for y = (fwd and 0 or (height - 1)), (fwd and (height - 1) or 0), (fwd and 1 or -1) do
		if (x + 3 * y) % 5 == 0 then
			for i = 1, 16 do
				local d = turtle.getItemDetail(i)
				if d and d.name == 'minecraft:jack_o_lantern' then
					turtle.select(i)
					break
				end
			end
			turtle.placeDown()
		else
			turtle.digDown()
		end
		turtle.forward()
	end
	if x % 2 == 0 then
		turtle.turnRight()
		turtle.forward()
		turtle.turnRight()
	else
		turtle.turnLeft()
		turtle.forward()
		turtle.turnLeft()
	end
	turtle.forward()
end
