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
local save_id
local item_types
local chests
local chest_room
local transaction_log
local locked

-- the transaction log records virtual updates which are not saved to disk otherwise
-- TODO: in flight records physical updates which are in progress

-- TODO: track numbers of slots and total number of items

local function item_type_key(name, nbt)
	return string.format('%q%q', name, nbt)
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
end
local function track_extract(chest, slot, item_type, num)
	local chest_slots = item_type.chests[chest]
	local slot_num = chest_slots[slot]
	chest_slots[slot] = slot_num - num
	item_type.number = item_type.number - num
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

local function initialize()
	local release = acquire()

	if state and state.transaction_log then
		state.transaction_log.close()
	end

	-- TODO: filesystem layout
	if fs.exists('inv-save-new') then
		assert(not fs.isDir('inv-save-new'))
		fs.delete('inv-save')
		fs.move('inv-save-new', 'inv-save')
	end
	local h = fs.open('inv-save', 'r')
	if h then
		local save = textutils.unserialize(h.readAll())
		h.close()
		state = {
			save_id = save.id;
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
		state.chest_room = {}
		for name in pairs(save.chest_room) do
			state.chest_room[state.chests[name]] = true
		end
	else
		state = {
			save_id = -1;
			item_types = {};
			chests = {};
			chest_room = {};
		}
	end

	local n = 0
	-- TODO: filesystem layout
	local h = fs.open('inv-transaction-log', 'r')
	if h then
		assert(tostring(state.save_id) == h.readLine(), 'transaction log for different save')
		while true do
			local line = h.readLine(true)
			if not line then break end
			local entry = textutils.unserialize(line)
			log('replay: ' .. textutils.serialize(entry))
			if entry.type == 'add_chest' then
				-- TODO: this is quite limited
				-- see `add_chest` for more about this
				local chest = {
					name = entry.name;
					num_slots = entry.num_slots;
					empties = {};
					item_types = {};
				}
				chests[chest.name] = chest
				for i = 1, chest.num_slots do
					chest.empties[i] = true
				end
				chest_room[chest] = true
			elseif entry.type == 'add_item_type' then
				track_add_item_type(entry.item_type_key, entry.detail)
			elseif entry.type == 'insert' then
				track_insert(
					chests[entry.chest_name], entry.slot,
					item_types[entry.item_type_key],
					entry.num, entry.full
				)
			elseif entry.type == 'extract' then
				track_extract(
					chests[entry.chest_name], entry.slot,
					item_types[entry.item_type_key],
					entry.num
				)
			else
				error(string.format('unhandled transaction type: %q', entry.type)) 
			end
			n = n + 1
		end
		h.close()
		-- TODO: filesystem layout
		state.transaction_log = fs.open('inv-transaction-log', 'a')
	else
		-- TODO: filesystem layout
		state.transaction_log = fs.open('inv-transaction-log', 'w')
		state.transaction_log.write(string.format('%d\n', state.save_id))
		state.transaction_log.flush()
	end

	-- TODO: in flight

	release()
	
	return n
end
local function save()
	local release = acquire()

	state.transaction_log.close()

	local save = {
		id = save_id + 1;
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

	-- TODO: filesystem layout
	local h = fs.open('inv-save-new', 'w')
	h.write(textutils.serialize(save))
	h.close()
	fs.delete('inv-save')
	fs.move('inv-save-new', 'inv-save')
	state.save_id = save.id

	-- TODO: filesystem layout
	state.transaction_log = fs.open('inv-transaction-log', 'w')
	state.transaction_log.write(string.format('%d\n', state.save_id))
	state.transaction_log.flush()

	release()
end
local function reset()
	local release = acquire()
	if state and state.transaction_log then
		state.transaction_log.close()
	end
	state = nil
	-- TODO: filesystem layout
	fs.delete('inv-save')
	fs.delete('inv-save-new')
	fs.delete('inv-transaction-log')
	release()
end
local function close()
	local release = acquire()
	state.transaction_log.close()
	state = nil
	release()
end

-- must be locked externally
local function identify(detail, add)
	local itk = item_type_key(detail.name, detail.nbt)
	local item_type = state.item_types[itk]
	if not item_type and add then
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
	end
	return item_type
end

local function add_chest(name)
	local release = acquire()

	local inv = peripheral.wrap(name)
	local chest = {
		name = name;
		num_slots = inv.size();
		empties = {};
		item_types = {};
	}
	assert(not state.chests[chest.name], 'chest already registered')
	state.chests[chest.name] = chest
	local contents = inv.list()
	local has_room = false
	for i = 1, chest.num_slots do
		if contents[i] then
			error 'TODO'
			-- it can't just index it, because there are rules (specifically about only one partial per item type and chest)
			-- maybe just return nil, saying we can't add this chest
			-- or it could move items around to maintain the rules
			-- remember to change the transaction log stuff if implementing this
		else
			has_room = true
			chest.empties[i] = true
		end
	end
	if has_room then
		state.chest_room[chest] = true
	end
	state.transaction_log.write(string.format('{ type = "add_chest"; name = %q; num_slots = %d; }\n', name, chest.num_slots))
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
		-- TODO: in flight
		local n = inv.pushItems(dst_chest.name, slot, remaining, dst_slot)
		track_insert(dst_chest, dst_slot, item_type, n, n < remaining)
		state.transaction_log.write(string.format(
			'{'
				.. ' type = "insert";'
				.. ' chest_name = %q;'
				.. ' slot = %d;'
				.. ' item_type_key = %q;'
				.. ' num = %d;'
				.. ' full = %s;'
			.. '}\n',
			dst_chest.name, dst_slot, item_type.key, n, n < remaining
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
		local chest_slots = item_type.chests[chest]
		local slot_num = chest_slots[slot]
		local pull = slot_num < remaining and slot_num or remaining
		-- TODO: in flight
		local n = inv.pullItems(chest.name, slot, pull, dst_slot)
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