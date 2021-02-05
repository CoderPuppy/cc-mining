--[[
-- this is a stupid approach
local function split_pat(pat)
	local initial = nil
		or pat:match '^%b[][?*+-]?'
		or pat:match '^%%.[?*+-]?'
		or pat:match '^[^[%%][?*+-]?'
	return initial, pat:sub(#initial + 1)
end
local function fuzzy_match(pat, str)
	local rest = pat
	local pat_pos = 1
	while #rest > 0 do
		local initial
		initial, rest = split_pat(rest)
		local last = initial:sub(#initial)
		if initial ~= '%*' and last == '*' then
			initial = initial:sub(1, #initial - 1) .. '+'
		elseif initial ~= '%?' and last == '?' then
			initial = initial:sub(1, #initial - 1)
		end
		for str_pos, m in str:gmatch('()(' .. initial .. ')') do
			local subpat = '^' .. initial
			local rest_run = rest
			local longest = m
			while true do
				local part
				part, rest_run = split_pat(rest_run)
				local try_pat = subpat .. part
				local m = str:match(try_pat, str_pos)
				if m then
					longest = m
					subpat = try_pat
				else
					break
				end
			end
		end
		pat_pos = pat_pos + #initial
	end
end
--]]

--[[
local function fuzzy_match(pat, str)
	local tbl = {}
	for pat_i = 1, #pat do
		local pat_c = pat:sub(pat_i, pat_i)
		for str_i = 1, #str do
			local str_c = str:sub(str_i, str_i)
			if str_c == pat_c then
			else
			end
		end
	end
end
--]]


return function(I, ext_chest)
	local width, height = term.getSize()

	local function format_count(n)
		local suffix = ''
		local decimal = false
		if n > 1000 then
			n = n / 1000
			suffix = 'k'
			decimal = n < 10000
		end
		return string.format(decimal and '%.1f%s' or '%d%s', n, suffix)
	end

	local keys_down = {}

	local list_model
	local function make_list_model()
		local model = {
			search = '';
			search_i = 1;
			list = {};
			list_i = 1;
			selected_i = 1;

			-- required fields:
			-- iter
			-- item_str = function(item) return 'display string' end;
			-- item_searchable = function(item) return 'string to search' end;
			-- order = function(a, b) return a < b end;
		}
		return model
	end
	local function list_model_draw_search()
		term.setCursorPos(1, 1)
		term.blit(
			list_model.search:sub(list_model.search_i) .. string.rep(' ', width - #list_model.search - list_model.search_i + 1),
			string.rep('f', width),
			string.rep('1', width)
		)
		term.setCursorPos(#list_model.search - list_model.search_i + 2, 1)
	end
	local function list_model_draw_item(i)
		if i < list_model.list_i or i > list_model.list_i + height - 2 then
			return
		end
		term.setCursorPos(1, i - list_model.list_i + 2)
		local item = list_model.list[i]
		local selected = i == list_model.selected_i
		if item then
			term.blit(
				list_model.item_str(item),
				string.rep(selected and '0' or '8', width),
				string.rep(selected and '8' or '7', width)
			)
		else
			term.blit(
				string.rep(' ', width),
				string.rep('c', width),
				string.rep('f', width)
			)
		end
	end
	local function list_model_fix_scroll(skip_draw)
		local old_list_i = list_model.list_i
		if list_model.list_i < 1 then
			list_model.list_i = 1
		elseif list_model.list_i ~= 1 and list_model.list_i > #list_model.list - height + 2 then
			list_model.list_i = #list_model.list - height + 2
		end
		if list_model.selected_i < 1 then
			list_model.selected_i = 1
		elseif list_model.selected_i > #list_model.list then
			list_model.selected_i = #list_model.list
		end
		if list_model.selected_i < list_model.list_i then
			list_model.list_i = list_model.selected_i
		elseif list_model.selected_i > list_model.list_i + height - 2 then
			list_model.list_i = list_model.selected_i - height + 2
		else
			return
		end
		if not skip_draw then
			term.scroll(list_model.list_i - old_list_i)
			if list_model.list_i < old_list_i then
				for i = list_model.list_i, math.min(list_model.list_i + height - 2, old_list_i) do
					list_model_draw_item(i)
				end
			elseif list_model.list_i > old_list_i then
				for i = math.max(list_model.list_i - height + 2, old_list_i), list_model.list_i + height - 2 do
					list_model_draw_item(i)
				end
			end
			list_model_draw_search()
		end
		return list_model.list_i ~= old_list_i
	end
	local function list_model_update_list()
		local prev_selected = list_model.list[list_model.selected_i]
		local new_select_i
		local new_list = { n = 0; }
		local ignore_case = not list_model.search:match '[A-Z]'
		for item in list_model.iter() do
			local name = list_model.item_searchable(item)
			-- item_type.example.displayName
			if ignore_case then
				name = string.lower(name)
			end
			local ok, match = pcall(string.match, name, list_model.search)
			if not ok then return end
			if match then
				new_list.n = new_list.n + 1
				new_list[new_list.n] = item
				if item == selected then
					new_select_i = new_list.n
				end
			end
		end
		table.sort(new_list, list_model.order)
		list_model.list = new_list
		list_model.selected_i = new_select_i or 1
		list_model_fix_scroll(true)
		for i = list_model.list_i, list_model.list_i + height - 2 do
			list_model_draw_item(i)
		end
	end
	local function list_model_full_update()
		list_model_update_list()
		list_model_draw_search()
		term.setCursorBlink(true)
	end
	function handle_list_model(evt)
		if not list_model then return end
		if evt[1] == 'key' then
			if evt[2] == keys.backspace then
				if keys_down.ctrl then
					if keys_down.shift then
						list_model.search = ''
					else
						list_model.search = list_model.search:gsub('[^%s]+[%s]*$', '')
					end
				else
					list_model.search = list_model.search:sub(1, #list_model.search - 1)
				end
				list_model_full_update()
			elseif evt[2] == keys.down then
				list_model.selected_i = list_model.selected_i + 1
				if not list_model_fix_scroll() then
					list_model_draw_item(list_model.selected_i)
				end
				list_model_draw_item(list_model.selected_i - 1)
			elseif evt[2] == keys.up then
				list_model.selected_i = list_model.selected_i - 1
				if not list_model_fix_scroll() then
					list_model_draw_item(list_model.selected_i)
				end
				list_model_draw_item(list_model.selected_i + 1)
			end
		elseif evt[1] == 'char' then
			if not keys_down.ctrl and not keys_down.alt then
				list_model.search = list_model.search .. evt[2]
				list_model_full_update()
			end
		end
	end

	local inv_list_model; do
		local function custom_next(s, prev_item)
			local key, item = next(s, prev_item and prev_item.key)
			-- if item and item.number <= 0 then
			-- 	return custom_next(s, item)
			-- else
				return item
			-- end
		end
		inv_list_model = make_list_model()
		function inv_list_model.iter()
			return custom_next, I.state().item_types
		end
		function inv_list_model.item_str(item)
			local name = item.example.displayName
			local count = format_count(item.number)
			return name .. string.rep(' ', width - #name - #count) .. count
		end
		function inv_list_model.item_searchable(item)
			return item.example.displayName
		end
		function inv_list_model.order(a, b)
			-- return a.example.displayName < b.example.displayName
			return a.number > b.number
		end
	end

	local ext_list_model, ext_handle; do
		ext_list_model = make_list_model()
		local function custom_next(s, prev_item)
			local slot, item = next(s, prev_item and prev_item.slot)
			if item then
				item.slot = slot
				item.item_type = I.identify(item, function()
					return ext_handle.getItemDetail(slot)
				end)
			end
			return item
		end
		function ext_list_model.iter()
			return custom_next, ext_handle.list()
		end
		function ext_list_model.item_str(item)
			local name = item.item_type.example.displayName
			local count = tostring(item.count)
			return name .. string.rep(' ', width - #name - #count) .. count
		end
		function ext_list_model.item_searchable(item)
			return item.item_type.example.displayName
		end;
		function ext_list_model.order(a, b)
			return a.slot < b.slot
		end
	end

	ext_handle = ext_chest
	-- TODO: this is a bit messy
	ext_handle.num_slots = ext_handle.size()
	-- list_model = ext_list_model
	list_model = inv_list_model

	list_model_full_update()
	while true do
		local evt = table.pack(os.pullEvent())
		if evt[1] == 'key' then
			keys_down[evt[2]] = true
		elseif evt[1] == 'key_up' then
			keys_down[evt[2]] = nil
		end
		keys_down.ctrl  = keys_down[keys.leftCtrl ] or keys_down[keys.rightCtrl ]
		keys_down.shift = keys_down[keys.leftShift] or keys_down[keys.rightShift]
		keys_down.alt   = keys_down[keys.leftAlt  ] or keys_down[keys.rightAlt  ]
		keys_down.mods = (keys_down.ctrl and 'c' or '') .. (keys_down.alt and 'a' or '') .. (keys_down.shift and 's' or '')

		-- I.log('ui evt: ' .. textutils.serialize {
		-- 	evt = evt;
		-- 	keys_down = keys_down;
		-- })
		if evt[1] == 'key' and evt[2] == keys.w and keys_down.mods == 'c' then
			I.save()
		elseif evt[1] == 'key' and evt[2] == keys.enter and list_model and not keys_down.shift then
			if list_model == ext_list_model then
				local item = list_model.list[list_model.selected_i]
				if not item then
					-- skip
				elseif keys_down.alt then
					local n = I.extract(item.item_type, ext_handle, item.slot, keys_down.ctrl and (item.item_type.example.maxCount - item.count) or 1)
					item.count = item.count + n
					list_model_draw_item(list_model.selected_i)
				else
					-- this will get refreshed anyways by list_model_full_update
					-- and it causes problem with inventory's logging
					-- because it's recursive
					item.item_type = nil
					local n = I.insert(ext_handle, item.slot, keys_down.ctrl and item.count or 1, item)
					item.count = item.count - n
					if item.count <= 0 then
						table.remove(list_model.list, list_model.selected_i)
						list_model_fix_scroll()
						for i = list_model.selected_i, list_model.list_i + height - 2 do
							list_model_draw_item(i)
						end
					else
						list_model_draw_item(list_model.selected_i)
					end
				end
			elseif list_model == inv_list_model then
				I.log('keys down: ' .. textutils.serialize(keys_down))
				local item_type = list_model.list[list_model.selected_i]
				if not item_type then
					-- skip
				elseif keys_down.alt then
					assert(ext_handle)
					local list = ext_handle.list()
					local remaining = keys_down.ctrl and item_type.example.maxCount or 1
					for slot = 1, ext_handle.num_slots do
						local stack = list[slot]
						if stack and I.item_type_key(stack) == item_type.key then
							local n = I.insert(ext_handle, slot, remaining)
							remaining = remaining - n
							if remaining <= 0 then
								break
							end
						end
					end
					list_model_draw_item(list_model.selected_i)
				else
					-- TODO: maybe this shouldn't reference ext_handle
					assert(ext_handle)
					local list = ext_handle.list()
					local remaining = keys_down.ctrl and item_type.example.maxCount or 1
					I.log(('extract: %d of %s'):format(remaining, textutils.serialize(item_type.example)))
					for slot = 1, ext_handle.num_slots do
						local stack = list[slot]
						if not stack or I.item_type_key(stack) == item_type.key then
							local n = I.extract(item_type, ext_handle, slot, remaining)
							remaining = remaining - n
							if remaining <= 0 then
								break
							end
						end
					end
					list_model_draw_item(list_model.selected_i)
				end
			end
		elseif evt[1] == 'key' and evt[2] == keys.tab and keys_down.mods == '' and list_model then
			if list_model == inv_list_model then
				list_model = ext_list_model
			elseif list_model == ext_list_model then
				list_model = inv_list_model
			end
			list_model_full_update()
		end

		handle_list_model(evt)
	end
end
