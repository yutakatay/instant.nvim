local client

local base64 = {}

local websocketkey

events = {}

iptable = {}

local fragmented = ""
local remaining = 0
local first_chunk

frames = {}

-- this global variable can be set to a local scope once 
-- autocommands registration is natively supported in
-- lua
has_attached = {} 

local detach = {}

prev = { "" }

-- pos = [(num, site)]
local MAXINT = 2^15 -- can be adjusted
local startpos, endpos = {{0, 0}}, {{MAXINT, 0}}
-- line = [pos]
-- pids = [line]
pids = {}

ops = {}
local agent = 0

local ignores = {}

local single_buffer

local initialized

local old_namespace

local b64 = 0
for i=string.byte('a'), string.byte('z') do base64[b64] = string.char(i) b64 = b64+1 end
for i=string.byte('A'), string.byte('Z') do base64[b64] = string.char(i) b64 = b64+1 end
for i=string.byte('0'), string.byte('9') do base64[b64] = string.char(i) b64 = b64+1 end
base64[b64] = '+' b64 = b64+1
base64[b64] = '/'


local GenerateWebSocketKey -- we must forward declare local functions because otherwise it picks the global one

local OpAnd, OpOr, OpRshift, OpLshift

local ConvertToBase64

local ConvertBytesToString

local SendText

local OpXor

local nocase

local genPID

local isLower

function GenerateWebSocketKey()
	key = {}
	for i =0,15 do
		table.insert(key, math.floor(math.random()*255))
	end
	
	return key
end

function OpAnd(a, b)
	return vim.api.nvim_call_function("and", {a, b})
end

function OpOr(a, b)
	return vim.api.nvim_call_function("or", {a, b})
end

function OpRshift(a, b)
	return math.floor(a/math.pow(2, b))
end

function OpLshift(a, b)
	return a*math.pow(2, b)
end

function ConvertToBase64(array)
	local i
	local str = ""
	for i=0,#array-3,3 do
		local b1 = array[i+0+1]
		local b2 = array[i+1+1]
		local b3 = array[i+2+1]

		local c1 = OpRshift(b1, 2)
		local c2 = OpLshift(OpAnd(b1, 0x3), 4)+OpRshift(b2, 4)
		local c3 = OpLshift(OpAnd(b2, 0xF), 2)+OpRshift(b3, 6)
		local c4 = OpAnd(b3, 0x3F)

		str = str .. base64[c1]
		str = str .. base64[c2]
		str = str .. base64[c3]
		str = str .. base64[c4]
	end

	local rest = #array * 8 - #str * 6
	if rest == 8 then
		local b1 = array[#array]
	
		local c1 = OpRshift(b1, 2)
		local c2 = OpLshift(OpAnd(b1, 0x3), 4)
	
		str = str .. base64[c1]
		str = str .. base64[c2]
		str = str .. "="
		str = str .. "="
	
	elseif rest == 16 then
		local b1 = array[#array-1]
		local b2 = array[#array]
	
		local c1 = OpRshift(b1, 2)
		local c2 = OpLshift(OpAnd(b1, 0x3), 4)+OpRshift(b2, 4)
		local c3 = OpLshift(OpAnd(b2, 0xF), 2)
	
		str = str .. base64[c1]
		str = str .. base64[c2]
		str = str .. base64[c3]
		str = str .. "="
	end
	

	return str
end

function ConvertBytesToString(tab)
	local s = ""
	for _,el in ipairs(tab) do
		s = s .. string.char(el)
	end
	return s
end

function SendText(str)
	local mask = {}
	for i=1,4 do
		table.insert(mask, math.floor(math.random() * 255))
	end
	
	local masked = {}
	for i=0,#str-1 do
		local j = i%4
		local trans = OpXor(string.byte(string.sub(str, i+1, i+1)), mask[j+1])
		table.insert(masked, trans)
	end
	
	local frame = {
		0x81, 0x80
	}
	
	if #masked <= 125 then
		frame[2] = frame[2] + #masked
	elseif #masked < math.pow(2, 16) then
		frame[2] = frame[2] + 126
		local b1 = OpRshift(#masked, 8)
		local b2 = OpAnd(#masked, 0xFF)
		table.insert(frame, b1)
		table.insert(frame, b2)
	else
		frame[2] = frame[2] + 127
		for i=0,7 do
			local b = OpAnd(OpRshift(#masked, (7-i)*8), 0xFF)
			table.insert(frame, b)
		end
	end
	
	
	for i=1,4 do
		table.insert(frame, mask[i])
	end
	
	for i=1,#masked do
		table.insert(frame, masked[i])
	end
	
	local s = ConvertBytesToString(frame)
	
	client:write(s)
	
end

function OpXor(a, b)
	return vim.api.nvim_call_function("xor", {a, b})
end

function nocase (s)
	s = string.gsub(s, "%a", function (c)
		if string.match(c, "[a-zA-Z]") then
			return string.format("[%s%s]", 
				string.lower(c),
				string.upper(c))
		else
			return c
		end
	end)
	return s
end

function genPID(p, q, s, i)
	local a = (p[i] and p[i][1]) or 0
	local b = (q[i] and q[i][1]) or MAXINT

	if a+1 < b then
		return {{math.random(a+1,b-1), s}}
	end

	local G = genPID(p, q, s, i+1)
	table.insert(G, 1, {
		(p[i] and p[i][1]) or 0, 
		(p[i] and p[i][2]) or s})
	return G
end

local function afterPID(x, y)
	if x == #pids[y] then return pids[y+1][1]
	else return pids[y][x+1] end
end

local function findCharPosition(opid)
	local x, y = 1, 1
	local px, py = 1, 1
	for _,lpid in ipairs(pids) do
		x = 1 
		for _,pid in ipairs(lpid) do
			if not isLower(pid, opid) then 
				return px, py
			end
			px, py = x, y
			x = x + 1 
		end
		y = y + 1
	end
end

function isLower(a, b)
	for i, ai in ipairs(a) do
		if i > #b then return false end
		local bi = b[i]
		if ai[1] < bi[1] then return true
		elseif ai[1] > bi[1] then return false
		elseif ai[2] < bi[2] then return true
		elseif ai[2] > bi[2] then return false
		end
	end
	return true
end

local function Refresh()
	initialized = false
	table.insert(events, "sending request")
	local obj = {
		["type"] = "request",
	}
	local encoded = vim.api.nvim_call_function("json_encode", { obj })
	SendText(encoded)
	-- table.insert(events, "sent " .. encoded)
	
	
end



local function StartClient(first, appuri, port)
	local v, username = pcall(function() return vim.api.nvim_get_var("instant_username") end)
	if not v then
		error("Please specify a username in g:instant_username")
	end
	
	detach = {}
	
	local middlepos = genPID(startpos, endpos, agent, 1)
	pids = {
		{ startpos },
		{ middlepos },
		{ endpos },
	}
	
	initialized = false
	
	old_namespace = {}
	
	port = port or 80
	
	client = vim.loop.new_tcp()
	iptable = vim.loop.getaddrinfo(appuri)
	if #iptable == 0 then
		print("Could not resolve address")
		return
	end
	local ipentry = iptable[1]
	

	client:connect(ipentry.addr, port, vim.schedule_wrap(function(err) 
		if err then
			table.insert(events, "connection err " .. vim.inspect(err))
			error("There was an error during connection: " .. err)
			return
		end
		
		client:read_start(vim.schedule_wrap(function(err, chunk)
			if err then
				table.insert(events, "connection err " .. vim.inspect(err))
				error("There was an error during connection: " .. err)
			
				for _,bufhandle in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(bufhandle) then
						DetachFromBuffer(bufhandle)
					end
				end
				StopClient()
				
				return
			end
			
			table.insert(events, "err: " .. vim.inspect(err) .. " chunk: " .. vim.inspect(chunk))
			
			if chunk then
				if string.match(chunk, nocase("^HTTP")) then
					-- can be Sec-WebSocket-Accept or Sec-Websocket-Accept
					if string.match(chunk, nocase("Sec%-WebSocket%-Accept")) then
						table.insert(events, "handshake was successful")
						local obj = {
							["type"] = "available"
						}
						local encoded = vim.api.nvim_call_function("json_encode", { obj })
						SendText(encoded)
						-- table.insert(events, "sent " .. encoded)
						
						
					end
				else
					local opcode, fin
					if remaining == 0 then
						first_chunk = chunk
					end
					local b1 = string.byte(string.sub(first_chunk,1,1))
					table.insert(frames, "FIN " .. OpAnd(b1, 0x80))
					table.insert(frames, "OPCODE " .. OpAnd(b1, 0xF))
					local b2 = string.byte(string.sub(first_chunk,2,2))
					table.insert(frames, "MASK " .. OpAnd(b2, 0x80))
					opcode = OpAnd(b1, 0xF)
					fin = OpRshift(b1, 7)
					
					if opcode == 0x1 then -- TEXT
						if remaining == 0 then
							local paylen = OpAnd(b2, 0x7F)
							local paylenlen = 0
							if paylen == 126 then -- 16 bits length
								local b3 = string.byte(string.sub(first_chunk,3,3))
								local b4 = string.byte(string.sub(first_chunk,4,4))
								paylen = OpLshift(b3, 8) + b4
								paylenlen = 2
							elseif paylen == 127 then
								paylen = 0
								for i=0,7 do -- 64 bits length
									paylen = OpLshift(paylen, 8) 
									paylen = paylen + string.byte(string.sub(first_chunk,i+3,i+3))
								end
								paylenlen = 8
							end
							table.insert(frames, "PAYLOAD LENGTH " .. paylen)
							
							local text = string.sub(chunk, 2+paylenlen+1)
							if string.len(text) < 40 then
								table.insert(frames, "TEXT " .. text)
							else
								table.insert(frames, "TEXT " .. string.sub(text, 1, 15) .. " .. " .. string.sub(text, string.len(text)-15))
							end
							table.insert(frames, "TEXT LEN " .. string.len(text))
							
							fragmented = text
							remaining = paylen - string.len(text)
						else
							fragmented = fragmented .. chunk
							remaining = remaining - string.len(chunk)
						end
					
						if remaining == 0 then
							local decoded = vim.api.nvim_call_function("json_decode", {fragmented})
							
							if decoded then
								-- table.insert(events, "received " .. text)
								if decoded["type"] == "text" then
									local buf = vim.api.nvim_get_current_buf()
									local ops = decoded["ops"]
									local opline = 0
									for _,op in ipairs(ops) do
										local tick = vim.api.nvim_buf_get_changedtick(buf)+1
										ignores[buf][tick] = true
										
										table.insert(events, "op " .. vim.inspect(op))
										table.insert(events, "pids " .. vim.inspect(pids))
										if op[1] == "ins" then
											local x, y = findCharPosition(op[3])
											
											opline = y-2
											
											if op[2] == "\n" then table.insert(pids, y+1, { op[4] })
											else table.insert(pids[y], x+1, op[4] ) end
											
											if op[2] == "\n" then 
												vim.api.nvim_buf_set_lines(buf, y-1, y-1, true, { "" })
											else 
												local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
												curline = string.sub(curline, 1, x-1) .. op[2] .. string.sub(curline, x)
												vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { curline })
											end
											
											if op[2] == "\n" then 
												table.insert(prev, y, "")
											else 
												local curline = prev[y-1]
												curline = string.sub(curline, 1, x-1) .. op[2] .. string.sub(curline, x)
												prev[y-1] = curline
											end
											
											
										elseif op[1] == "del" then
											local sx, sy = findCharPosition(op[2])
											
											opline = sy-2
											
											if sx == 1 then
												table.remove(pids, sy)
											else
												table.remove(pids[sy], sx)
											end
											
											if sx == 1 then
												vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, {})
											else
												if sy > 1 then
													local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
													curline = string.sub(curline, 1, sx-2) .. string.sub(curline, sx)
													vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, { curline })
												end
											end
											
											if sx == 1 then
												table.remove(prev, sy-1)
											else
												if sy > 1 then
													local curline = prev[sy-1]
													curline = string.sub(curline, 1, sx-2) .. string.sub(curline, sx)
													prev[sy-1] = curline
												end
											end
											
											
										end
									end
									
									if old_namespace[decoded["author"]] then
										vim.api.nvim_buf_clear_namespace(
											vim.api.nvim_get_current_buf(),
											old_namespace[decoded["author"]],
											0, -1)
										old_namespace[decoded["author"]] = nil
									end
									
									old_namespace[decoded["author"]] = 
										vim.api.nvim_buf_set_virtual_text(
											vim.api.nvim_get_current_buf(),
											0, 
											math.max(opline, 0), 
											{{ " | " .. decoded["author"], "Special" }}, 
											{})
									
								end
								
								if decoded["type"] == "request" then
									local lines = vim.api.nvim_buf_get_lines(
										bufhandle,
										0, -1, true)
									
									local obj = {
										["type"] = "initial",
										["pids"] = pids,
										["content"] = table.concat(lines, '\n')
									}
									local encoded = vim.api.nvim_call_function("json_encode", { obj })
									
									SendText(encoded)
									-- table.insert(events, "sent " .. encoded)
									
								end
								
								if decoded["type"] == "initial" and not initialized then
									local lines = {}
									for line in vim.gsplit(decoded["content"], "\n") do
										table.insert(lines, line)
									end
									
									prev = {}
									
									for line in vim.gsplit(decoded["content"], "\n") do
										table.insert(prev, line)
									end
									
									pids = decoded["pids"]
									
									local buf = vim.api.nvim_get_current_buf()
									local tick = vim.api.nvim_buf_get_changedtick(buf)+1
									ignores[buf][tick] = true
									
									vim.api.nvim_buf_set_lines(
										vim.api.nvim_get_current_buf(),
										0, -1, false, lines)
									
									print("Connected!")
									initialized = true
								end
								
								if decoded["type"] == "response" then
									if decoded["is_first"] and first then
										agent = decoded["client_id"]
										
										print("Connected!")
										initialized = true
									elseif not decoded["is_first"] and not first then
										agent = decoded["client_id"]
										
										table.insert(events, "sending request")
										local obj = {
											["type"] = "request",
										}
										local encoded = vim.api.nvim_call_function("json_encode", { obj })
										SendText(encoded)
										-- table.insert(events, "sent " .. encoded)
										
										
									elseif decoded["is_first"] and not first then
										table.insert(events, "ERROR: Tried to join an empty server")
										print("ERROR: Tried to join an empty server")
										for _,bufhandle in ipairs(vim.api.nvim_list_bufs()) do
											if vim.api.nvim_buf_is_loaded(bufhandle) then
												DetachFromBuffer(bufhandle)
											end
										end
										StopClient()
										
									elseif not decoded["is_first"] and first then
										table.insert(events, "ERROR: Tried to start a server which is already busy")
										print("ERROR: Tried to start a server which is already busy")
										for _,bufhandle in ipairs(vim.api.nvim_list_bufs()) do
											if vim.api.nvim_buf_is_loaded(bufhandle) then
												DetachFromBuffer(bufhandle)
											end
										end
										StopClient()
										
									end
								end
								
								if decoded["type"] == "status" then
									table.insert(events, "Connected: " .. tostring(decoded["num_clients"]) .. " client(s).")
									print("Connected: " .. tostring(decoded["num_clients"]) .. " client(s).")
								end
								
							else
								table.insert(events, "Could not decode json " .. fragmented)
							end
							
						end
					end
					
					if opcode == 0x9 then -- PING
						local paylen = OpAnd(b2, 0x7F)
						local paylenlen = 0
						if paylen == 126 then -- 16 bits length
							local b3 = string.byte(string.sub(first_chunk,3,3))
							local b4 = string.byte(string.sub(first_chunk,4,4))
							paylen = OpLshift(b3, 8) + b4
							paylenlen = 2
						elseif paylen == 127 then
							paylen = 0
							for i=0,7 do -- 64 bits length
								paylen = OpLshift(paylen, 8) 
								paylen = paylen + string.byte(string.sub(first_chunk,i+3,i+3))
							end
							paylenlen = 8
						end
						table.insert(frames, "PAYLOAD LENGTH " .. paylen)
						
						table.insert(frames, "SENT PONG")
						local mask = {}
						for i=1,4 do
							table.insert(mask, math.floor(math.random() * 255))
						end
						
						local frame = {
							0x8A, 0x80,
						}
						for i=1,4 do 
							table.insert(frame, mask[i])
						end
						local s = ConvertBytesToString(frame)
						
						client:write(s)
						
						
					end
					
				end
			end
			
		end))
		client:write("GET / HTTP/1.1\r\n")
		client:write("Host: " .. appuri .. ":" .. port .. "\r\n")
		client:write("Upgrade: websocket\r\n")
		client:write("Connection: Upgrade\r\n")
		websocketkey = ConvertToBase64(GenerateWebSocketKey())
		client:write("Sec-WebSocket-Key: " .. websocketkey .. "\r\n")
		client:write("Sec-WebSocket-Version: 13\r\n")
		client:write("\r\n")
		
	end))
end

local function StopClient()
	local mask = {}
	for i=1,4 do
		table.insert(mask, math.floor(math.random() * 255))
	end
	
	local frame = {
		0x88, 0x80,
	}
	for i=1,4 do 
		table.insert(frame, mask[i])
	end
	local s = ConvertBytesToString(frame)
	
	client:write(s)
	
	
	client:close()
	
end


local function DetachFromBuffer(bufnr)
	table.insert(events, "Detaching from buffer...")
	detach[bufnr] = true
end


local function Start(first, cur_buffer, host, port)
	if client and client:is_active() then
		error("Client is already connected. Use InstantStop first to disconnect.")
	end

	single_buffer = cur_buffer

	StartClient(first, host, port)
	
	local bufhandle = vim.api.nvim_get_current_buf()
	ignores[bufhandle] = {}
	
	local attach_success = vim.api.nvim_buf_attach(bufhandle, false, {
		on_lines = function(_, buf, changedtick, firstline, lastline, new_lastline, bytecount)
			if detach[buf] then
				table.insert(events, "Detached from buffer " .. buf)
				detach[buf] = nil
				return true
			end
			
			if ignores[buf][changedtick] then
				ignores[buf][changedtick] = nil
				return
			end
			
			ops = {}
			
			local cur_range = ""
			for _,line in ipairs(vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)) do
				cur_range = cur_range .. "\n" .. line
			end
			
			local prev_range = ""
			for l=firstline,lastline-1 do
				if prev[l+1] then 
					prev_range = prev_range .. "\n" .. prev[l+1]
				end
			end
			
			if string.len(cur_range) > string.len(prev_range) then
				local x, y = 0, 0
				local toadd
				for i=1,#cur_range do
					local c = string.sub(cur_range, i, i)
					if c ~= string.sub(prev_range, i, i) then
						toadd = string.sub(cur_range, i, string.len(cur_range) - string.len(prev_range) + i - 1)
						break
					end
					if c == "\n" then 
						x = 0
						y = y + 1 
					else 
						x = x + 1
					end
				end
				
				if toadd then
					local px, py = x+1, firstline+y
					for c in vim.gsplit(toadd, "") do
						if c == "\n" then
							px = #pids[py+1]
							local before_pid = pids[py+1][px]
							local after_pid = afterPID(px, py+1)
							local new_pid = genPID(before_pid, after_pid, agent, 1)
							table.insert(pids, py+2, {new_pid})
							ops[#ops+1] = { "ins", "\n", before_pid, new_pid }
							
							table.insert(prev, py+1, "")
							py = py + 1
							px = 1
						else
							local before_pid = pids[py+1][px]
							local after_pid = afterPID(px, py+1)
							local new_pid = genPID(before_pid, after_pid, agent, 1)
							table.insert(pids[py+1], px+1, new_pid)
							ops[#ops+1] = { "ins", c, before_pid, new_pid }
							
							prev[py] = string.sub(prev[py], 1, px-1) .. c .. string.sub(prev[py], px)
							px = px + 1
						end
					end
					
				end
			
			else
				if string.len(cur_range) > 0 then
					cur_range = string.sub(cur_range, 2) .. "\n"
				end
				if string.len(prev_range) > 0 then
					prev_range = string.sub(prev_range, 2) .. "\n"
				end
				
				local x, y = 0, 0
				local todelete
				for i=1,#prev_range do
					local c = string.sub(prev_range, i, i)
					if c ~= string.sub(cur_range, i, i) then
						todelete = string.sub(prev_range, i, string.len(prev_range) - string.len(cur_range) + i - 1)
						break
					end
					if c == "\n" then 
						x = 0
						y = y + 1 
					else 
						x = x + 1
					end
				end
				
				if todelete then
					local px, py = x+1, firstline+y+1
					table.insert(events, "todelete " .. vim.inspect(todelete))
					for c in vim.gsplit(todelete, "") do
						if c == "\n" then
							table.insert(events, "delete line at " .. py+1)
							if #prev > 1 then
								ops[#ops+1] = { "del", pids[py+1][1] }
								table.remove(pids, py+1)
								
								table.remove(prev, py)
							end
						else
							py = math.min(py, #prev)
							ops[#ops+1] = { "del", pids[py+1][px+1] }
							table.remove(pids[py+1], px+1)
							
							prev[py] = string.sub(prev[py], 1, px-1) .. string.sub(prev[py], px+1)
						end
					end
					
				end
			end
			
			local obj = {
				["type"] = "text",
				["ops"] = ops,
				["author"] = vim.api.nvim_get_var("instant_username"),
			}
			local encoded = vim.api.nvim_call_function("json_encode", { obj })
			
			SendText(encoded)
			-- table.insert(events, "sent " .. encoded)
			
		end,
		on_detach = function(_, buf)
			table.insert(events, "detached " .. bufhandle)
			has_attached[bufhandle] = nil
		end
	})
	
	if attach_success then
		has_attached[bufhandle] = true
		table.insert(events, "has_attached[" .. bufhandle .. "] = true")
	end
	
	
end

local function Stop()
	if initialized then
		for _,bufhandle in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufhandle) then
				DetachFromBuffer(bufhandle)
			end
		end
		StopClient()
		
		print("Disconnected!")
		initialized = false
	end
end


local function Status()
	if client and client:is_active() then
		local obj = {
			["type"] = "status",
		}
		local encoded = vim.api.nvim_call_function("json_encode", { obj })
		SendText(encoded)
		-- table.insert(events, "sent " .. encoded)
		
		
	else
		print("Disconnected")
	end
end


return {
Start = Start,
Stop = Stop,

Refresh = Refresh,

Status = Status,

}

