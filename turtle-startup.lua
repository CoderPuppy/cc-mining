-- load last state from file
-- repeatedly transmit it and wait for a message

-- TODO
local TURTLE_CONTROL_CHANNEL = 141
local TURTLE_REPORT_CHANNEL = 671
local TURTLE_REPORT_INTERVAL = 1

local log_file = fs.open('log', 'a')
local function log(msg)
	log_file.write(msg .. '\n')
	log_file.flush()
	print(msg)
end
local errors = { n = 0; }
-- TODO
-- local state = dofile 'last-state.lua'
local state = { 'state1' }
local id = os.getComputerID()
local label = os.getComputerLabel()
log(('ID: %d, Label: %s'):format(id, label))
local pos, pos_co, pos_co_resume, pos_co_filter, pos_start; do
	function pos_start()
		pos_co = coroutine.create(function()
			while not pos do
				log('attempting to gps locate')
				local x, y, z = gps.locate()
				log(('gps result: %d %d %d'):format(x, y, z))
				if x then
					pos = { x = x; y = y; z = z; }
				end
			end
		end)
		pos_co_resume()
	end
	function pos_co_resume(...)
		local ok, filter = coroutine.resume(pos_co, ...)
		if ok then
			pos_co_filter = filter
		else
			errors.n = errors.n + 1
			errors[errors.n] = { type = 'gps'; err = filter; }
			log('gps error: ' .. tostring(filter))
		end
	end
	pos_start()
end
local m = peripheral.wrap 'left'
m.open(TURTLE_CONTROL_CHANNEL)
local t = os.startTimer(0)
while true do
	local evt = table.pack(os.pullEvent())
	if coroutine.status(pos_co) ~= 'dead' and (not pos_co_filter or pos_co_filter == evt[1]) then
		pos_co_resume(table.unpack(evt, 1, evt.n))
	end
	if evt[1] == 'timer' and evt[2] == t then
		m.transmit(TURTLE_REPORT_CHANNEL, 0, {
			state = state;
			id = id;
			label = label;
			pos = pos;
			errors = errors;
		})
		t = os.startTimer(TURTLE_REPORT_INTERVAL)
	elseif evt[1] == 'modem_message' and evt[3] == TURTLE_CONTROL_CHANNEL then
		local msg = evt[5]
		if type(msg) == 'table' and msg.dst_id == id then
			do
				local ok, ser = pcall(textutils.serialize, msg)
				if ok then
					log('got control: ' .. ser)
				else
					errors.n = errors.n + 1
					errors[errors.n] = { type = 'message serialize'; msg = msg; err = ser; }
					log('error serializing message: ' .. tostring(ser))
				end
			end
			local ok, fn, err = pcall(load, msg.code, 'turtle remote control')
			if not ok then
				errors.n = errors.n + 1
				errors[errors.n] = { type = 'load'; msg = msg; err = fn; }
				log('load error: ' .. tostring(fn))
			elseif not fn then
				errors.n = errors.n + 1
				errors[errors.n] = { type = 'parse'; msg = msg; err = err; }
				log('parse error: ' .. tostring(err))
			else
				log('running code')
				if type(msg.args) ~= 'table' then msg.args = {} end
				local ok, err = pcall(fn, table.unpack(msg.args, 1, msg.args.n))
				if not ok then
					errors.n = errors.n + 1
					errors[errors.n] = { type = 'runtime'; msg = msg; err = err; }
					log('runtime error: ' .. tostring(err))
				end
				pos = nil
				pos_start()
			end
		end
	end
end
