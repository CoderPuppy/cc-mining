if false then
	local Tchest = T {
		name = T.string;
		num_slots = T.int;
		empties = T.map(T.int, T.lit(true));
		item_types = T.map(Titem_type, T.lit(true));
	}
	local Titem_type = T {
		key = T.string;
		example = T.any;
		number = T.int;
		chests = T.map(Tchest, T.map(T.int, T.int));
		partials = T.map(Tchest, T.int);
	}
	local Tsave = T {
		id = T.int;
		item_types = T.map(T.string, T {
			name = T.string;
			nbt = T.union(T.string, T.null);
			example = T.any;
			number = T.int;
			chests = T.map(T.string, T.map(T.int, T.int));
			partials = T.map(T.string, T.int);
		});
		chests = T.map(T.string, T {
			num_slots = T.int;
			empties = T.map(T.int, T.lit(true));
			item_types = T.map(T.string, T.lit(true));
		});
		chest_room = T.map(T.string, T.lit(true));
	}
end

local log; do
	local f = fs.open('log', 'a')
	function log(msg)
		f.write(os.date'%F %T\t' .. msg .. '\n')
		f.flush()
	end
	log 'start'
end

local state
local locked

-- the transaction log records virtual updates which are not saved to disk otherwise
-- in flight records slots which may be different from the virtual records

local function item_type_key(stack)
	return string.format('%q%q', stack.name, stack.nbt)
end

local function serialize(v)
	local t = type(v)
	if t == 'string' then
		return string.format('%q', v)
	elseif t == 'number' or t == 'boolean' then
		return tostring(v)
	elseif t == 'table' then
		local s = '{'
		for k, v in pairs(v) do
			s = string.format('%s[%s]=%s;', s, serialize(k), serialize(v))
		end
		return s .. '}'
	else
		error(string.format('unhandled type: %q', t))
	end
end

-- TODO: one function which writes to the transaction log and performs the transaction
local function track_add_chest(name, num_slots)
	local chest = {
		name = name;
		num_slots = num_slots;
		empties = {};
		item_types = {};
	}
	state.chests[chest.name] = chest
	state.chest_room[chest] = true
	for slot = 1, chest.num_slots do
		chest.empties[slot] = true
	end
	state.num_slots = state.num_slots + chest.num_slots
	state.num_slots_free = state.num_slots_free + chest.num_slots
	return chest
end
local function track_add_item_type(itk, detail)
	-- there's no good reason for itk to be passed in
	-- just because it was already computed in `insert`
	-- where this was extracted from
	local item_type = {
		key = itk;
		example = detail;
		number = 0;
		chests = {};
		partials = {};
	}
	state.item_types[itk] = item_type
	return item_type
end
local function track_insert(chest, slot, item_type, num, full)
	item_type.partials[chest] = not full and slot or nil
	if chest.empties[slot] then
		chest.empties[slot] = nil
		state.num_slots_free = state.num_slots_free - 1
		if not next(chest.empties) then
			state.chest_room[chest] = nil
		end
	end
	chest.item_types[item_type] = true
	local chest_stacks = item_type.chests[chest]
	if not chest_stacks then
		chest_stacks = {}
		item_type.chests[chest] = chest_stacks
	end
	chest_stacks[slot] = (chest_stacks[slot] or 0) + num
	item_type.number = item_type.number + num
	state.total_number = state.total_number + num
end
local function track_extract(chest, slot, item_type, num)
	local chest_slots = item_type.chests[chest]
	local slot_num = chest_slots[slot]
	chest_slots[slot] = slot_num - num
	item_type.number = item_type.number - num
	state.total_number = state.total_number - num
	if num >= slot_num then
		assert(num == slot_num)
		assert(item_type.partials[chest] == slot)
		item_type.partials[chest] = nil
		chest_slots[slot] = nil
		if not next(chest_slots) then
			item_type.chests[chest] = nil
			chest.item_types[item_type] = nil
		end
		chest.empties[slot] = true
		state.num_slots_free = state.num_slots_free + 1
		state.chest_room[chest] = true
	else
		item_type.partials[chest] = slot
	end
end

local function acquire()
	while locked do
		os.pullEvent()
	end
	locked = true
	return function()
		locked = false
	end
end

local function fs_paths(dir)
	return {
		save_new = fs.combine(dir, 'save-new');
		save = fs.combine(dir, 'save');
		transaction_log = fs.combine(dir, 'transaction-log');
		in_flight = fs.combine(dir, 'in-flight');
	}
end

local function initialize(dir)
	assert(dir, 'no directory')

	local release = acquire()

	if state and state.transaction_log then
		state.transaction_log.close()
	end

	local paths = fs_paths(dir)
	if not fs.isDir(dir) then
		fs.makeDir(dir)
	end

	if fs.exists(paths.save_new) then
		assert(not fs.isDir(paths.save_new))
		fs.delete(paths.save)
		fs.move(paths.save_new, paths.save)
	end
	local h = fs.open(paths.save, 'r')
	if h then
		local save = textutils.unserialize(h.readAll())
		h.close()
		state = {
			dir = dir;
			paths = paths;
			save_id = save.id;
			total_number = save.total_number;
			num_slots = save.num_slots;
			num_slots_free = save.num_slots_free;
			item_types = {};
			chests = {};
			chest_room = {};
		}
		for name, save_chest in pairs(save.chests) do
			local chest = {
				name = name;
				num_slots = save_chest.num_slots;
				empties = save_chest.empties;
				item_types = {};
			}
			state.chests[name] = chest
		end
		for key, save_item_type in pairs(save.item_types) do
			local item_type = {
				key = key;
				example = save_item_type.example;
				number = save_item_type.number;
				chests = {};
				partials = {};
			}
			for chest_name, slots in pairs(save_item_type.chests) do
				item_type.chests[state.chests[chest_name]] = slots
			end
			for chest_name, slot in pairs(save_item_type.partials) do
				item_type.partials[state.chests[chest_name]] = slot
			end
			state.item_types[item_type.key] = item_type
		end
		for name, save_chest in pairs(save.chests) do
			local chest = state.chests[name]
			for itk in pairs(save_chest.item_types) do
				chest.item_types[state.item_types[itk]] = true
			end
		end
		for name in pairs(save.chest_room) do
			state.chest_room[state.chests[name]] = true
		end
	else
		state = {
			dir = dir;
			paths = paths;
			save_id = -1;
			total_number = 0;
			num_slots = 0;
			num_slots_free = 0;
			item_types = {};
			chests = {};
			chest_room = {};
		}
	end

	local n = 0
	local h = fs.open(paths.transaction_log, 'r')
	if h then
		assert(tostring(state.save_id) == h.readLine(), 'transaction log for different save')
		while true do
			local line = h.readLine(true)
			if not line then break end
			local entry = textutils.unserialize(line)
			log('replay: ' .. textutils.serialize(entry))
			if entry.type == 'add_chest' then
				track_add_chest(entry.name, entry.num_slots)
			elseif entry.type == 'add_item_type' then
				track_add_item_type(entry.item_type_key, entry.detail)
			elseif entry.type == 'insert' then
				track_insert(
					state.chests[entry.chest_name], entry.slot,
					state.item_types[entry.item_type_key],
					entry.num, entry.full
				)
			elseif entry.type == 'extract' then
				track_extract(
					state.chests[entry.chest_name], entry.slot,
					state.item_types[entry.item_type_key],
					entry.num
				)
			else
				error(string.format('unhandled transaction type: %q', entry.type)) 
			end
			n = n + 1
		end
		h.close()
		state.transaction_log = fs.open(paths.transaction_log, 'a')
	else
		state.transaction_log = fs.open(paths.transaction_log, 'w')
		state.transaction_log.write(string.format('%d\n', state.save_id))
		state.transaction_log.flush()
	end

	local h = fs.open(paths.in_flight, 'r')
	if h then
		local in_flight = textutils.unserialize(h.readAll())
		h.close()

		local item_type = state.item_types[in_flight.item_type_key]
		local chest = state.chests[in_flight.chest_name]
		local slot = in_flight.slot
		local expected = item_type.chests[chest][slot]
		local actual = peripheral.call(chest.name, 'getItemDetail', slot).count
		if actual < expected then
			local n = expected - actual
			track_extract(chest, slot, item_type, n)
			state.transaction_log.write(string.format(
				'{'
					.. ' type = "extract";'
					.. ' chest_name = %q;'
					.. ' slot = %d;'
					.. ' item_type_key = %q;'
					.. ' num = %d;'
				.. '}\n',
				chest.name, slot, item_type.key, n
			))
			state.transaction_log.flush()
		elseif stack.count > chest_slots[slot] then
			local n = actual - expected
			-- saying it is not full should always be safe
			-- the only case in which it would break things is if another slot is partial
			-- but that shouldn't happen
			local full = false
			track_insert(chest, slot, item_type, n, full)
			state.transaction_log.write(string.format(
				'{'
					.. ' type = "insert";'
					.. ' chest_name = %q;'
					.. ' slot = %d;'
					.. ' item_type_key = %q;'
					.. ' num = %d;'
					.. ' full = %s;'
				.. '}\n',
				dst_chest.name, dst_slot, item_type.key, n, full
			))
			state.transaction_log.flush()
		end

		f.delete(paths.in_flight)
	end

	release()
	
	return n
end
local function save()
	local release = acquire()

	state.transaction_log.close()

	local save = {
		id = state.save_id + 1;
		total_number = state.total_number;
		num_slots = state.num_slots;
		num_slots_free = state.num_slots_free;
		item_types = {};
		chests = {};
		chest_room = {};
	}
	for key, item_type in pairs(state.item_types) do
		local save_item_type = {
			example = item_type.example;
			number = item_type.number;
			chests = {};
			partials = {};
		}
		for chest, slots in pairs(item_type.chests) do
			save_item_type.chests[chest.name] = slots
		end
		for chest, slot in pairs(item_type.partials) do
			save_item_type.partials[chest.name] = slot
		end
		save.item_types[key] = save_item_type
	end
	for name, chest in pairs(state.chests) do
		local save_chest = {
			num_slots = chest.num_slots;
			empties = chest.empties;
			item_types = {};
		}
		for item_type in pairs(chest.item_types) do
			save_chest.item_types[item_type.key] = true
		end
		save.chests[chest.name] = save_chest
	end
	for chest in pairs(state.chest_room) do
		save.chest_room[chest.name] = true
	end

	local h = fs.open(state.paths.save_new, 'w')
	h.write(textutils.serialize(save))
	h.close()
	fs.delete(state.paths.save)
	fs.move(state.paths.save_new, state.paths.save)
	state.save_id = save.id

	state.transaction_log = fs.open(state.paths.transaction_log, 'w')
	state.transaction_log.write(string.format('%d\n', state.save_id))
	state.transaction_log.flush()

	release()
end
local function reset()
	local release = acquire()
	local paths = dir and fs_paths(dir) or state.paths
	if state and state.transaction_log then
		state.transaction_log.close()
	end
	state = nil
	fs.delete(paths.save)
	fs.delete(paths.save_new)
	fs.delete(paths.transaction_log)
	release()
end
local function close()
	local release = acquire()
	state.transaction_log.close()
	state = nil
	release()
end

local function identify(detail, add)
	local itk = item_type_key(detail)
	local item_type = state.item_types[itk]
	if not item_type and add then
		local release = not locked and acquire()
		if not detail.displayName then
			detail = add()
		end
		log(('add item type: %s'):format(textutils.serialize(detail)))
		-- create the item type if none exists
		item_type = track_add_item_type(itk, detail)
		state.transaction_log.write(string.format(
			'{'
				.. ' type = "add_item_type";'
				.. ' item_type_key = %q;'
				.. ' detail = %s;'
			.. '}\n',
			itk, serialize(detail)
		))
		state.transaction_log.flush()
		if release then release() end
	end
	return item_type
end

local function add_chest(name)
	local release = acquire()

	assert(not state.chests[name], 'chest already registered')

	local inv = peripheral.wrap(name)
	local num_slots = inv.size()
	local contents = inv.list()
	local slots = {}
	local partials = {}
	for slot = 1, num_slots do
		local stack = contents[slot]
		if stack then
			local item_type = identify(stack, function()
				return inv.getItemDetail(slot)
			end)
			local number = stack.count
			local prev_slot = partials[item_type]
			if prev_slot then
				local n = inv.pushItems(name, slot, number, prev_slot)
				number = number - n
				slots[prev_slot][2] = slots[prev_slot][2] + n
			end
			if number > 0 then
				slots[slot] = {item_type, number}
				partials[item_type] = slot
			end
		end
	end
	local chest = track_add_chest(name, num_slots)
	local trans_str = string.format('{ type = "add_chest"; name = %q; num_slots = %d; }\n', name, num_slots)
	for slot = 1, num_slots do
		local rec = slots[slot]
		if rec then
			local item_type, number = rec[1], rec[2]
			local full = partials[item_type] ~= slot
			track_insert(chest, slot, item_type, number, full)
			trans_str = string.format(
				'%s{'
					.. ' type = "insert";'
					.. ' chest_name = %q;'
					.. ' slot = %d;'
					.. ' item_type_key = %q;'
					.. ' num = %d;'
					.. ' full = %s;'
				.. '}\n',
				trans_str,
				name, slot, item_type.key, number, full
			)
		end
	end
	state.transaction_log.write(trans_str)
	state.transaction_log.flush()

	release()
	return chest
end
local function insert(inv, slot, amt, detail)
	local release = acquire()

	local detail = detail or inv.getItemDetail(slot)

	log('insert: ' .. textutils.serialize(detail))

	-- find or create a corresponding item type
	local item_type = identify(detail, function()
		return inv.getItemDetail(slot)
	end)

	-- move the entire stack
	local remaining = amt or detail.count
	if remaining > detail.count then
		remaining = detail.count
	end
	while remaining > 0 do
		-- find a place to put it
		local dst_chest, dst_slot
		-- first try a slot with some of this item type (but not full)
		dst_chest, dst_slot = next(item_type.partials)
		if not dst_chest then
			-- otherwise find an empty slot
			for chest in pairs(state.chest_room) do
				dst_slot = next(chest.empties)
				if dst_slot then
					dst_chest = chest
					break
				end
			end
			assert(dst_chest, 'TODO: no room in system')
		end
		assert(not fs.exists(state.paths.in_flight))
		local h = fs.open(state.paths.in_flight, 'w')
		h.write(string.format(
			'{ item_type_key = %q; chest_name = %q; slot = %d; }',
			item_type.key, dst_chest.name, dst_slot
		))
		h.close()
		local n = inv.pushItems(dst_chest.name, slot, remaining, dst_slot)
		fs.delete(state.paths.in_flight)
		local full = n < remaining
		track_insert(dst_chest, dst_slot, item_type, n, full)
		state.transaction_log.write(string.format(
			'{'
				.. ' type = "insert";'
				.. ' chest_name = %q;'
				.. ' slot = %d;'
				.. ' item_type_key = %q;'
				.. ' num = %d;'
				.. ' full = %s;'
			.. '}\n',
			dst_chest.name, dst_slot, item_type.key, n, full
		))
		state.transaction_log.flush()
		remaining = remaining - n
	end

	release()
	return amt or detail.count, item_type
end
local function extract(item_type, inv, dst_slot, amt)
	local release = acquire()

	local transferred = 0
	local remaining = amt or item_type.number
	local function extract_part(chest, slot)
		local slot_num = item_type.chests[chest][slot]
		local pull = slot_num < remaining and slot_num or remaining
		assert(not fs.exists(state.paths.in_flight))
		local h = fs.open(state.paths.in_flight, 'w')
		h.write(string.format(
			'{ item_type_key = %q; chest_name = %q; slot = %d; }',
			item_type.key, dst_chest.name, dst_slot
		))
		h.close()
		local n = inv.pullItems(chest.name, slot, pull, dst_slot)
		fs.delete(state.paths.in_flight)
		remaining = remaining - n
		transferred = transferred + n
		track_extract(chest, slot, item_type, n)
		state.transaction_log.write(string.format(
			'{'
				.. ' type = "extract";'
				.. ' chest_name = %q;'
				.. ' slot = %d;'
				.. ' item_type_key = %q;'
				.. ' num = %d;'
			.. '}\n',
			chest.name, slot, item_type.key, n
		))
		state.transaction_log.flush()
		if n < pull then
			-- no more room in the destination slot
			-- this is a slightly hacky way to break out
			remaining = 0
		end
	end

	if remaining > 0 then
		for chest, slot in pairs(item_type.partials) do
			extract_part(chest, slot)
			if remaining <= 0 then
				assert(remaining == 0)
				break
			end
		end
	end
	if remaining > 0 then
		for chest, slots in pairs(item_type.chests) do
			for slot, number in pairs(slots) do
				extract_part(chest, slot)
				if remaining <= 0 then
					assert(remaining == 0)
					break
				end
			end
			if remaining <= 0 then
				assert(remaining == 0)
				break
			end
		end
	end

	release()
	return transferred
end

return {
	log = log;

	state = function() return state end;

	item_type_key = item_type_key;

	initialize = initialize;
	save = save;
	reset = reset;
	close = close;

	track_insert = track_insert;
	track_extract = track_extract;
	identify = identify;
	acquire = acquire;

	add_chest = add_chest;
	insert = insert;
	extract = extract;
}
