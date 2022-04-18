local log; do
	local f = fs.open('log', 'a')
	function log(msg)
		f.write(os.date'%F %T\t' .. msg .. '\n')
		f.flush()
	end
	log 'start'
end
local function serialize(v, visited)
	visited = visited or {}
	if visited[v] then
		error 'cyclic'
	end
	visited[v] = true
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

local path_save = 'save'
local path_save_new = 'save-new'
local path_transaction_log = 'transaction-log'
local path_in_flight = 'in-flight'

local save_id
local open_tickets
local overdue = {}
local heap = { n = 0; }
local transaction_log
local num_transactions
local due_timer
local next_due = math.huge

local function heap_up(ticket)
	if ticket.heap_i == 1 then return end
	local parent_i = math.floor(ticket.heap_i/2)
	local parent = heap[parent_i]
	if parent.due <= ticket.due then return end
	heap[parent_i], heap[ticket.heap_i] = ticket, parent
	parent.heap_i = ticket.heap_i
	ticket.heap_i = parent_i
	return heap_up(ticket)
end
local function heap_down(ticket)
	local left_i = ticket.heap_i * 2
	local right_i = left_i + 1
	local left, right = heap[left_i], heap[right_i]
	local left_up = left and left.due < ticket.due
	local right_up = right and right.due < ticket.due
	if left_up and right_up then
		if left.due < right.due then
			right_up = false
		else
			left_up = false
		end
	end
	if left_up or right_up then
		local child = left_up and left or right
		heap[ticket.heap_i] = child
		heap[child.heap_i] = ticket
		ticket.heap_i, child.heap_i = child.heap_i, ticket.heap_i
		return heap_down(child)
	end
end
local function remove_top()
	local new_root = heap[heap.n]
	heap[1] = new_root
	heap[heap.n] = nil
	heap.n = heap.n - 1
	heap_down(new_root)
end
local function update_due()
	local root = heap[1]
	if root then
		if root.due < next_due then
			if due_timer then
				os.cancelTimer(due_timer)
			end
			next_due = root.due
			local now = os.epoch'ingame'
			local time = (next_due - now)/72000 + 1
			if time < 0 then
				time = 0
			end
			due_timer = os.startTimer(time)
		end
	else
		if due_timer then
			os.cancelTimer(due_timer)
		end
		due_timer = nil
		next_due = math.huge
	end
end
local function track(ticket)
	log('track: ' .. textutils.serialize(ticket))
	if ticket.revoked then
		open_tickets[ticket.id] = nil
	else
		open_tickets[ticket.id] = ticket
		heap.n = heap.n + 1
		heap[heap.n] = ticket
		ticket.heap_i = heap.n
		heap_up(ticket)
		update_due()
	end
end

local function save()
	transaction_log.close()
	save_id = save_id + 1
	local h = fs.open(path_save_new, 'w')
	h.write(textutils.serialize({
		id = save_id;
		open_tickets = open_tickets;
	}))
	h.close()
	fs.delete(path_save)
	fs.move(path_save_new, path_save)
	transaction_log = fs.open(path_transaction_log, 'w')
	transaction_log.write(string.format('%d\n', save_id))
	transaction_log.flush()
	num_transactions = 0
end

local function issue(ticket)
	local h = fs.open(path_in_flight, 'w')
	h.write(textutils.serialize({ type = 'issue'; ticket = ticket; }))
	h.close()

	commands.exec(string.format(
		'forceload add %d %d %d %d',
		ticket.x1, ticket.z1,
		ticket.x2, ticket.z2
	))

	ticket.issued = {
		ingame = os.epoch 'ingame';
		utc = os.epoch 'utc';
	}
	ticket.due = ticket.issued.ingame + ticket.duration * 72000

	track(ticket)
	transaction_log.write(serialize({ type = 'issue'; ticket = ticket; }) .. '\n')
	transaction_log.flush()
	num_transactions = num_transactions + 1
	if num_transactions > 16 then
		save()
	end

	fs.delete(path_in_flight)
end
local function revoke(ticket)
	local h = fs.open(path_in_flight, 'w')
	h.write(textutils.serialize({ type = 'revoke'; id = ticket.id; }))
	h.close()

	commands.exec(string.format(
		'forceload remove %d %d %d %d',
		ticket.x1, ticket.z1,
		ticket.x2, ticket.z2
	))

	ticket.revoked = {
		ingame = os.epoch 'ingame';
		utc = os.epoch 'utc';
	}

	track(ticket)
	transaction_log.write(serialize({ type = 'revoke'; id = ticket.id; time = ticket.revoked; }) .. '\n')
	transaction_log.flush()
	num_transactions = num_transactions + 1
	if num_transactions > 16 then
		save()
	end

	fs.delete(path_in_flight)
end

local function initialize()
	if fs.exists(path_save_new) then
		assert(not fs.isDir(path_save_new))
		fs.delete(path_save)
		fs.move(path_save_new, path_save)
	end
	local h = fs.open(path_save, 'r')
	if h then
		local save = textutils.unserialize(h.readAll())
		h.close()
		save_id = save.id
		open_tickets = save.open_tickets
		local now = os.epoch 'ingame'
		for id, ticket in pairs(open_tickets) do
			if ticket.due < now then
				overdue[ticket] = true
			else
				heap.n = heap.n + 1
				heap[heap.n] = ticket
			end
		end
		for i = heap.n, 1, -1 do
			heap_down(heap[i])
		end
		update_due()
	else
		save_id = -1
		open_tickets = {}
		by_due = {}
	end

	local h = fs.open(path_transaction_log, 'r')
	if h then
		assert(tostring(save_id) == h.readLine(), 'transaction log for different save')
		num_transactions = 0
		while true do
			local line = h.readLine(true)
			if not line then break end
			local entry = textutils.unserialize(line)
			num_transactions = num_transactions + 1
			log('replay: ' .. textutils.serialize(entry))
			if entry.type == 'issue' then
				track(entry.ticket)
			elseif entry.type == 'revoke' then
				local ticket = open_tickets[entry.id]
				if ticket then
					ticket.revoked = entry.time
					track(ticket)
				end
			else
				error(string.format('unknown transaction type: %q', entry.type))
			end
		end
		h.close()
		transaction_log = fs.open(path_transaction_log, 'a')
	else
		transaction_log = fs.open(path_transaction_log, 'w')
		transaction_log.write(string.format('%d\n', save_id))
		transaction_log.flush()
		num_transactions = 0
	end

	local h = fs.open(path_in_flight, 'r')
	if h then
		local in_flight = textutils.unserialize(h.readAll())
		h.close()
		if in_flight.type == 'issue' then
			issue(in_flight.ticket)
		elseif in_flight.type == 'revoke' then
			revoke(open_tickets[in_flight.id])
		else
			error(string.format('unknown in flight type: %q', entry.type))
		end
		fs.delete(path_in_flight)
	end
end

initialize()

local m = peripheral.find 'modem'
m.open(4352)
while true do
	local evt = table.pack(os.pullEvent())
	if evt[1] == 'modem_message' then
		repeat
			local msg = evt[5]
			local ok, str = pcall(textutils.serialize, msg)
			if not ok then
				log('dropped non-serializable message: ' .. tostring(str))
				break
			end
			log('msg: ' .. str)
			if type(msg) ~= 'table' then break end
			if type(msg.id) ~= 'string' then break end
			if msg.revoke then
				if open_tickets[msg.id] then
					log('revoking: ' .. msg.id)
					revoke(open_tickets[msg.id])
				end
				break
			end
			if type(msg.x1) ~= 'number' then break end
			if type(msg.x2) ~= 'number' then break end
			if type(msg.z1) ~= 'number' then break end
			if type(msg.z2) ~= 'number' then break end
			if type(msg.duration) ~= 'number' then break end
			if msg.dimension ~= 'overworld' then break end
			if open_tickets[msg.id] then break end
			log('issuing')
			local ticket = {
				id = msg.id;
				duration = msg.duration; -- in seconds
				from = msg.from;
				x1 = msg.x1; z1 = msg.z1;
				x2 = msg.x2; z2 = msg.z2;
			}
			issue(ticket)
		until true
	elseif evt[1] == 'timer' and evt[2] == due_timer then
		local now = os.epoch'ingame'
		local root = heap[1]
		while root and (root.revoked or root.due < now) do
			remove_top()
			if not root.revoked then
				log('overdue: ' .. root.id)
				overdue[root] = true
				commands.say(string.format(
					'chunkloading ticket overdue: %s from %s by %ds',
					root.id, textutils.serialize(root.from), (now - root.due)/72000
				))
			end
			root = heap[1]
		end
		update_due()
	end
end
