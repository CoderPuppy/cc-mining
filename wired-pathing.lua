local log; do
	local f = fs.open('log', 'a')
	function log(msg)
		f.write(os.date'%F %T\t' .. msg .. '\n')
		f.flush()
	end
	log 'start'
end

local distance = math.huge
local function check()
	turtle.select(1)
	turtle.place()
	local m = peripheral.wrap 'front'
	m.open(2) -- TODO
	local t = os.startTimer(5) -- TODO
	local res = false
	while true do
		local evt = table.pack(os.pullEvent())
		if evt[1] == 'timer' and evt[2] == t then
			break
		elseif evt[1] == 'modem_message' and evt[2] == 'front' then
			-- TODO: verify identity
			if evt[6] < distance then
				distance = evt[6]
				print(distance)
				res = true
			end
			break
		end
	end
	turtle.dig()
	return res
end
local function find_dir()
	for i = 1, 4 do
		if check() then
			return true
		end
		turtle.turnRight()
	end
	return false
end
while distance > 4 do
	assert(find_dir())
	turtle.forward()
end
