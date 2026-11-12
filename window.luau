--!strict
-- Chats: a left sidebar with every omp chat on every attached Tern host (this machine and remotes).
-- Click a chat to jump to it, even on another host; click the open chat for Rename / Reset name.
-- ⌃⌘C opens the same list as a search picker, ⌃⌘R renames the chat in front.
--
-- How: plugin blocks live in one host's daemon and vanish when the window switches host, so the
-- sidebar is built from status-line segments (window chrome, which stays on every host) and
-- chats.css turns the status line into a left column. The window half sees every attached host
-- through cx.hosts and cx.agents.
--
-- Names: a name you gave wins; else omp's own session title (made by its small model), cached
-- once Tern has shown it; else the folder.
local tern = require("tern")

-- Desktop only: on a phone the left column would take most of the screen. Without this the
-- plugin adds nothing there (its stylesheet is installed below, not by the manifest).
if tern.runtime.os == "ios" then
	return
end
tern.css("chats", tern.fs.read(tern.plugin.dir .. "/chats.css"))

-- Hidden commands can't be run with cx:action, so keep every command's function to call directly.
local runs: { [string]: (any) -> () } = {}
local function command(def)
	runs[def.id] = def.run
	tern.command(def)
end

local MAX_HOSTS = 6
local MAX_CHATS = 40
local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x" -- session id
local POLL_MS = 2000

local function base(path: string): string
	return path:match("([^/]+)/*$") or path
end

local function oneline(s: string?, n: number): string
	if not s or s == "" then
		return ""
	end
	s = s:gsub("%s+", " ")
	local len = utf8.len(s)
	if len and len > n then
		return s:sub(1, (utf8.offset(s, n) or #s + 1) - 1) .. "…"
	end
	return s
end

local function short_host(name: string): string
	name = name:gsub("^[^@]+@", "")
	return (name:gsub("%-%x%x%x%x%x+$", "")) -- drop a generated suffix: "laptop-3fa9c2e" -> "laptop"
end

-- omp's pane title: drop its leading icon and any "TAG: " prefix.
local function clean_title(t: string?): string?
	if not t then
		return nil
	end
	t = t:gsub("^[^%w%(%[]+", ""):gsub("^%u+:%s*", ""):gsub("%s+·%s+#%d+$", ""):gsub("%s+$", "")
	if t == "" or t == "omp" or t:match("^[%w._-]+@[%w._-]+:") then
		return nil
	end
	return t
end

-- kv: names you gave and titles seen, keyed "<host name>/<pane>"
local function store(kind: string): { [string]: string }
	return tern.kv.get(kind) or {}
end

local function key(hostname: string, pane: number): string
	return hostname .. "/" .. tostring(pane)
end

type Slot = { pane: number, host: number, hostname: string, current: boolean, label: string, menu: number? }
local chat_slots: { [number]: Slot } = {}
local host_slots: { [number]: number } = {}
local segments: { any } = {}
local focused_slot: number? = nil
local last_state: { [string]: string } = {} -- "<host>/<pane>" -> state at the last refresh
local unread: { [string]: boolean } = tern.kv.get("unread") or {} -- finished, not opened since
local tabs_css = "" -- the installed "tabs" sheet; reinstalling restyles the whole window
local segments_sig = "" -- what the sidebar last drew; unchanged rebuilds skip the redraw

-- Recent (closed) sessions per host, from `omp-recent` (in this folder) run on that machine.
local MAX_RECENT = 8
local RECENT_MS = 30000
type Recent = { id: string, title: string, cwd: string, mtime: number, parent: string?, last: string?, pane: number? }
-- Cached in kv so the section shows at once after a reload or restart, then refreshes.
local recent: { [string]: { Recent } } = tern.kv.get("recent") or {}
local lineage: { [string]: string } = tern.kv.get("lineage") or {} -- session id -> parent id, kept after delete
local recent_slots: { [number]: { host: number, hostname: string, item: Recent } } = {}
type MenuSlot = { host: number, item: Recent?, chat: number?, recent: number?, sure: boolean? }
local fork_slots: { [number]: MenuSlot } = {}
local armed_delete: string? = nil
local opened: { [string]: boolean } = {}

-- omp-recent ships inside this plugin. Locally it runs from here; on a remote host it is sent
-- over ssh to `python3 -` on stdin, so nothing has to be installed there.
local HELPER = tern.plugin.dir .. "/omp-recent"
local helper_src: string? = nil

local function shq(x: string): string
	return "'" .. x:gsub("'", "'\\''") .. "'"
end

local function recent_argv(h, args: { string }): ({ string }, string?)
	if h.kind == "local" then
		local argv = { "python3", HELPER }
		for _, a in args do
			table.insert(argv, a)
		end
		return argv, nil
	end
	helper_src = helper_src or tern.fs.read(HELPER)
	local remote = { "python3", "-" }
	for _, a in args do
		table.insert(remote, shq(a))
	end
	local alias = h.name:gsub("^[^@]+@", "")
	return { "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", alias, table.concat(remote, " ") }, helper_src
end

-- Runs omp-recent on host h with args; cb(result, cx) like tern.process.run.
local function helper(h, args: { string }, cb)
	local argv, stdin = recent_argv(h, args)
	tern.process.run(argv, { timeout_ms = 10000, stdin = stdin }, cb)
end

local rebuild

local folders: { [string]: { string } } = tern.kv.get("folders") or {} -- host -> project folders
local roots: { [string]: string } = tern.kv.get("roots") or {} -- host -> projects root (omp-recent --folders)
local homes: { [string]: string } = tern.kv.get("homes") or {} -- host -> its home folder

-- A path for display: that host's own home folder as "~" (another user's home stays spelled out).
local function tilde(path: string, hostname: string?): string
	local home = hostname and homes[hostname]
	if home and (path == home or path:sub(1, #home + 1) == home .. "/") then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

local inflight: { [string]: number } = {} -- host -> when its running session-list fetch began

-- Session lists (and, unless `sessions_only`, project folders) from every connected host.
local function fetch_recent(cx, sessions_only: boolean?)
	for _, h in cx.hosts:list() do
		if h.state == "connected" and not sessions_only then
			helper(h, { "--folders" }, function(res, _cx)
				if res.status == 0 then
					local list = {}
					for line in res.stdout:gmatch("[^\n]+") do
						local ok, item = pcall(tern.json.decode, line)
						if ok and type(item) == "table" and item.root then
							roots[h.name] = item.root
							homes[h.name] = item.home
							tern.kv.set("roots", roots)
							tern.kv.set("homes", homes)
						elseif ok and type(item) == "table" and item.path then
							table.insert(list, item.path)
						end
					end
					folders[h.name] = list
					tern.kv.set("folders", folders)
				end
			end)
		end
		if h.state == "connected" and os.time() - (inflight[h.name] or 0) > 20 then
			inflight[h.name] = os.time()
			helper(h, { tostring(MAX_RECENT + 6) }, function(res, cx2)
				inflight[h.name] = nil
				if res.status ~= 0 then
					return
				end
				local list = {}
				for line in res.stdout:gmatch("[^\n]+") do
					local ok, item = pcall(tern.json.decode, line)
					if ok and type(item) == "table" then
						table.insert(list, item)
					end
				end
				recent[h.name] = list
				-- Remember every fork link, so deleting a middle chat keeps its forks under the grandparent.
				local changed = false
				for _, it in list do
					if it.parent and lineage[it.id] ~= it.parent then
						lineage[it.id] = it.parent
						changed = true
					end
				end
				if changed then
					tern.kv.set("lineage", lineage)
				end
				opened = {} -- resumed chats are open now and filtered by title; closed again, they come back
				tern.kv.set("recent", recent)
				if cx2 then
					rebuild(cx2)
				end
			end)
		end
	end
end

-- A new, forked or reopened chat writes its session file a moment after it starts, and only
-- then can it be placed in the tree: fetch the session lists (not folders) soon after a pane
-- event; overlapping requests coalesce per host.
local function refresh_soon()
	for _, ms in { 500, 1500, 3500, 8000 } do
		tern.timer(ms, function(cx)
			if cx then
				fetch_recent(cx, true)
			end
		end)
	end
end

local function ago(t: number): string
	local d = os.time() - t
	if d < 3600 then
		return math.max(1, d // 60) .. "m"
	elseif d < 86400 then
		return d // 3600 .. "h"
	end
	return d // 86400 .. "d"
end

function rebuild(cx)
	local hosts = cx.hosts:list()
	table.sort(hosts, function(a, b)
		if (a.kind == "local") ~= (b.kind == "local") then
			return a.kind == "local"
		end
		return a.name < b.name
	end)
	local by_pane = {}
	for _, h in hosts do
		for _, p in h.panes do
			by_pane[p] = h
		end
	end
	local groups = {}
	for _, a in cx.agents:list() do
		local h = by_pane[a.pane]
		if h and a.state ~= "exited" then
			groups[h.id] = groups[h.id] or {}
			table.insert(groups[h.id], a)
		end
	end

	local names, titles = store("names"), store("titles")
	local titles_changed = false
	local focused = cx.session:focused()
	local segs = {}
	chat_slots, host_slots, focused_slot = {}, {}, nil
	recent_slots, fork_slots = {}, {}
	local nr, nf = 0, 0
	local n = 0
	for hi, h in hosts do
		if hi > MAX_HOSTS then
			break
		end
		host_slots[hi] = h.id
		local online = h.state == "connected"
		table.insert(segs, {
			text = short_host(h.name) .. (online and "" or "  " .. h.state),
			tone = h.current and "host-on" or "host",
			command = "plugin.chats.host" .. hi,
		})
		if online then
			table.insert(segs, { text = "+", tone = "host-add", command = "plugin.chats.new" .. hi })
		end
		-- Sessions on this host from omp-recent: id by title (to find an open chat's session) and
		-- which ids exist (a fork is indented only when its parent is listed too).
		local sessions = recent[h.name] or {}
		local id_by_title, known = {}, {}
		for _, item in sessions do
			known[item.id] = item
			local t = clean_title(item.title) or base(item.cwd)
			id_by_title[t] = id_by_title[t] or {}
			table.insert(id_by_title[t], item) -- newest first
		end
		-- Fork tree: orders nodes ({id, parent}) so each sits under its nearest *shown* ancestor,
		-- with its depth. A deleted or hidden ancestor is skipped, so the tree rebalances itself:
		-- delete a parent and its forks move up a level.
		local function tree(nodes): { { node: any, depth: number } }
			local shown = {}
			for _, x in nodes do
				if x.id then
					shown[x.id] = x
				end
			end
			local function up(x)
				local p, hops = x.parent, 0
				while p and not shown[p] and hops < 50 do
					-- A deleted session is gone from `known`; its remembered parent keeps the chain.
					p = (known[p] and known[p].parent) or lineage[p]
					hops += 1
				end
				return p and shown[p]
			end
			local kids, roots = {}, {}
			for _, x in nodes do
				local p = up(x)
				if p and p ~= x then
					kids[p] = kids[p] or {}
					table.insert(kids[p], x)
				else
					table.insert(roots, x)
				end
			end
			local out, seen = {}, {}
			local function walk(x, d, last)
				if seen[x] then
					return
				end
				seen[x] = true
				table.insert(out, { node = x, depth = math.min(d, 3), last = last })
				local list = kids[x] or {}
				for j, c in list do
					walk(c, d + 1, j == #list)
				end
			end
			for _, r in roots do
				walk(r, 0, false)
			end
			for _, x in nodes do -- a cycle can't hide anything
				walk(x, 0, false)
			end
			return out
		end
		-- Menu slot for a chat: clicking the open chat, or any closed chat, opens its menu
		-- (Tern sends no right-clicks to the status line, and overlaid buttons pass clicks through).
		local function menu_chip(slot: MenuSlot): number
			nf += 1
			fork_slots[nf] = slot
			return nf
		end
		local w = tern.kv.get("width") or 248
		local list = groups[h.id] or {}
		table.sort(list, function(a, b)
			return a.pane > b.pane
		end)
		local first_open = #segs + 1
		local entries = {} -- { seg, id, parent } per open chat, to move forks under their parent
		-- Exact pane -> session claims first, so a title guess never takes a session another pane
		-- really holds. Sources: omp-recent asked Tern which pane's process holds which file; or the
		-- pane's command line names it (`omp --resume <id>`, `--restore <file>`), which also works
		-- when Tern runs chats without its session daemon. `--fork <id>` is a new chat under <id>.
		local claim, fork_of, claimed = {}, {}, {}
		for _, a in list do
			local info = cx.session:pane(a.pane)
			local line = info and info.running and info.running.line or ""
			local flag, id = line:match("%-%-(%a+)[%s=]+%S-(" .. UUID .. ")")
			for _, it in sessions do
				if it.pane == a.pane or ((flag == "resume" or flag == "restore") and it.id == id) then
					claim[a.pane] = it
				end
			end
			if flag == "fork" and not claim[a.pane] then
				fork_of[a.pane] = id
			end
			if claim[a.pane] then
				claimed[claim[a.pane].id] = true
			end
		end
		local free_by_title = {}
		for t, items in id_by_title do
			free_by_title[t] = {}
			for _, it in items do
				if not claimed[it.id] then
					table.insert(free_by_title[t], it)
				end
			end
		end
		for _, a in list do
			if n >= MAX_CHATS then
				break
			end
			n += 1
			local k = key(h.name, a.pane)
			local info = cx.session:pane(a.pane)
			local seen = clean_title(info and info.title)
			if seen and titles[k] ~= seen then
				titles[k] = seen
				titles_changed = true
			end
			local label = names[k] or titles[k] or base(a.cwd)
			local on = a.pane == focused
			if on then
				focused_slot = n
			end
			chat_slots[n] = { pane = a.pane, host = h.id, hostname = h.name, current = h.current, label = label }
			local state = (a.state == "working" or a.state == "waiting_input") and a.state or "idle"
			-- Finished while you were elsewhere: "done-idle" (green) until you open the chat.
			local was = unread[k]
			if on or state ~= "idle" then
				unread[k] = nil
			elseif last_state[k] == "working" then
				unread[k] = true
			end
			if unread[k] ~= was then
				tern.kv.set("unread", unread)
			end
			last_state[k] = state
			if state == "idle" and unread[k] then
				state = "done-idle"
			end
			-- Which session file is this pane? An exact claim (above) wins; a new fork has no file yet
			-- and shows under its parent. Otherwise guess among same-titled sessions nobody claims,
			-- told apart by the start of the last reply, which both Tern and the file know.
			local session = claim[a.pane]
			local same = free_by_title[titles[k] or ""]
			local sure = session ~= nil or (same ~= nil and #same == 1)
			if not session and not fork_of[a.pane] and same then
				local mine = oneline(a.last_message, 60):gsub("…$", "")
				for j, it in same do
					if mine ~= "" and it.last and it.last:sub(1, #mine) == mine then
						session = table.remove(same, j)
						sure = true
						break
					end
				end
				-- No reply match: take a session that no other open pane's reply claims.
				if not session then
					for j, it in same do
						local taken = false
						for _, other in list do
							local o = oneline(other.last_message, 60):gsub("…$", "")
							if o ~= "" and it.last and it.last:sub(1, #o) == o then
								taken = true
							end
						end
						if not taken then
							session = table.remove(same, j)
							break
						end
					end
				end
				session = session or table.remove(same, 1)
			end
			-- One clickable card: the name, then a dim line with the folder and last message.
			-- Lines are cut here (CSS can't ellipsize each line of one element), sized to the sidebar width.
			local sub = oneline(a.last_message, 200)
			sub = oneline(base(a.cwd) .. (sub ~= "" and ("  ·  " .. sub) or ""), math.floor((w - 44) / 6.4))
			-- Text and indent are set in emit() below, once the nesting among open chats is known.
			local seg = { command = "plugin.chats.go" .. n }
			table.insert(segs, seg)
			table.insert(entries, {
				seg = seg, id = session and session.id, parent = session and session.parent or fork_of[a.pane],
				label = label, sub = sub, tone = (on and "on-" or ""), state = state,
			})
			chat_slots[n].menu = menu_chip({ host = h.id, item = session, chat = n, sure = sure })
		end
		-- Open chats as a tree: forks under the chat they came from.
		for j = #segs, first_open, -1 do
			table.remove(segs, j)
		end
		local open_ids = {}
		for _, row in tree(entries) do
			local e, d = row.node, row.depth
			local lvl = d > 0 and ("f" .. d .. (row.last and "L" or "") .. "-") or ""
			if e.id then
				open_ids[e.id] = true
			end
			local room = w - 44 - 16 * d
			e.seg.text = oneline(e.label, math.floor(room / 7.4))
				.. "\n" .. oneline(e.sub, math.floor(room / 6.4))
			e.seg.tone = e.tone .. lvl .. e.state
			table.insert(segs, e.seg)
		end
		-- Closed chats: every listed session that isn't open (by id, so a fork with its parent's
		-- name still shows), as their own tree.
		local closed = {}
		for _, item in sessions do
			if #closed < MAX_RECENT and not opened[item.id] and not open_ids[item.id] then
				table.insert(closed, { id = item.id, parent = item.parent, item = item, title = clean_title(item.title) or base(item.cwd) })
			end
		end
		local ordered = tree(closed)
		local folded = (tern.kv.get("folded") or {})[h.name]
		if #ordered > 0 then
			table.insert(segs, {
				text = (folded and "▸  " or "▾  ") .. "Closed  " .. #ordered,
				tone = "recent-head",
				command = "plugin.chats.fold" .. hi,
			})
		end
		for _, row in (folded and {} or ordered) do
			local c, d = row.node, row.depth
			local item, title = c.item, c.title
			nr += 1
			recent_slots[nr] = { host = h.id, hostname = h.name, item = item }
			local room = w - 44 - 16 * d
			table.insert(segs, {
				text = oneline(title, math.floor(room / 7.4)) .. "\n" .. oneline(base(item.cwd) .. "  ·  " .. ago(item.mtime), math.floor(room / 6.4)),
				tone = d > 0 and ("recent-f" .. d .. (row.last and "L" or "")) or "recent",
				command = "plugin.chats.resume" .. nr,
			})
			segs[#segs].command = "plugin.chats.more" .. menu_chip({ host = h.id, item = item, recent = nr })
		end
	end
	if titles_changed then
		tern.kv.set("titles", titles)
	end
	-- Shortcut legend, pinned to the bottom by chats.css: a label row, then its key chip on the same line.
	for i, row in {
		{ "Hide sidebar", "⌃⌘B", "plugin.chats.toggle" },
		{ "Search chats", "⌃⌘C", "plugin.chats.open" },
		{ "Rename chat", "⌃⌘R", "plugin.chats.rename" },
		{ "Fork chat", "⌃⌘F", "plugin.chats.fork_current" },
		{ "Delete chat", "⌃⌘⌫", "plugin.chats.delete_current" },
		{ "Close chat", "⌘W ⌘W", "close_pane" },
	} do
		table.insert(segs, { text = row[1], tone = i == 1 and "keys-first" or "keys", command = row[3] })
		table.insert(segs, { text = row[2], tone = "kbd", command = row[3] })
		if i == 1 then
			-- Width: two chips, the left one narrows and the right one widens.
			table.insert(segs, { text = "Width", tone = "keys", command = "plugin.chats.wider" })
			table.insert(segs, { text = "⌃⌘]", tone = "kbd", command = "plugin.chats.wider" })
			table.insert(segs, { text = "⌃⌘[", tone = "kbd-l", command = "plugin.chats.narrower" })
		end
	end
	-- Hovering a chat lights its tab, and hovering a tab lights its chats, as hovering them would.
	-- A row's title attribute is its command.
	local tab_pos = {}
	for _, t in cx.session:tabs() do
		tab_pos[t.id] = t.position
	end
	local tabs_lit, chats_lit = {}, {}
	for i, slot in chat_slots do
		local info = slot.current and cx.session:pane(slot.pane)
		local p = info and info.tab and tab_pos[info.tab]
		if p then
			local chat = string.format("#statusline .sl-plugin[title='plugin.chats.go%d']", i)
			local tab = string.format("#tabbar .tb-tabs > .tt:nth-child(%d)", p)
			table.insert(tabs_lit, string.format("html:has(%s:hover) %s", chat, tab))
			table.insert(chats_lit, string.format("html:has(%s:hover) %s", tab, chat))
		end
	end
	local css = #tabs_lit > 0 and (
		table.concat(tabs_lit, ",\n") .. " { color: var(--t1); background-color: var(--l1); }\n"
		.. table.concat(chats_lit, ",\n") .. " { background: rgba(255, 255, 255, 0.045) !important; }"
	) or ""
	if css ~= tabs_css then
		tabs_css = css
		tern.css("tabs", css)
	end
	-- Redraw only on change: a redraw restyles every pane's status line (heavy :has() rules).
	local parts = table.create(#segs)
	for i, s in segs do
		parts[i] = (s.text or "") .. "\1" .. (s.tone or "") .. "\1" .. (s.command or "")
	end
	local sig = table.concat(parts, "\2")
	segments = segs
	if sig ~= segments_sig then
		segments_sig = sig
		tern.chrome.refresh()
	end
end

-- Every pane shows the same sidebar.
tern.chrome.status(function(_pane)
	return segments
end)

local function rename(cx, slot: Slot?)
	if not slot then
		cx:toast("info", "Open a chat first")
		return
	end
	-- Renames the session in omp itself (`/rename`), so the tab, notifications, /resume and this
	-- sidebar all show the same name. Empty asks omp to name it again from the conversation.
	cx:prompt({ value = slot.label, placeholder = "Rename chat  ·  leave empty to let omp name it", icon = "pencil", action = "rename" })
		:next(function(text, _err, cx2)
			if text == nil or not cx2 then
				return
			end
			text = text:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			local names = store("names")
			names[key(slot.hostname, slot.pane)] = nil -- drop any sidebar-only name from before
			tern.kv.set("names", names)
			local ok, err = pcall(function()
				cx2:run(slot.pane, "/rename" .. (text ~= "" and (" " .. text) or "") .. "\r")
			end)
			if not ok then
				cx2:toast("error", "Couldn't rename that chat", tostring(err))
			end
			rebuild(cx2)
		end)
end

local function jump(cx, i: number)
	local slot = chat_slots[i]
	if not slot then
		return
	end
	if i == focused_slot and slot.menu then
		runs["more" .. slot.menu](cx)
		return
	end
	if not slot.current then
		cx.hosts:switch(slot.host)
	end
	local ok, err = pcall(function()
		cx.layout:focus(slot.pane)
	end)
	if not ok then
		cx:toast("error", "Couldn't open that chat", tostring(err))
	end
	rebuild(cx)
end

-- The focused pane when it is an idle shell (not an agent, nothing running) on `host`, else nil.
local function idle_shell(cx, host: number): number?
	for _, h in cx.hosts:list() do
		if h.id == host and not h.current then
			return nil
		end
	end
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	if not info or info.kind ~= "terminal" or info.busy then
		return nil
	end
	for _, a in cx.agents:list() do
		if a.pane == focused then
			return nil
		end
	end
	return focused
end

local function hidden()
	return false
end

for i = 1, MAX_CHATS do
	command({ id = "go" .. i, title = "Chat " .. i, available = hidden, run = function(cx)
		jump(cx, i)
	end })
end
for i = 1, MAX_HOSTS do
	command({ id = "host" .. i, title = "Host " .. i, available = hidden, run = function(cx)
		if host_slots[i] then
			cx.hosts:switch(host_slots[i])
			rebuild(cx)
		end
	end })
	command({ id = "fold" .. i, title = "Fold closed " .. i, available = hidden, run = function(cx)
		local h
		for _, x in cx.hosts:list() do
			if x.id == host_slots[i] then
				h = x
			end
		end
		if h then
			local folded = tern.kv.get("folded") or {}
			folded[h.name] = not folded[h.name] or nil
			tern.kv.set("folded", folded)
			rebuild(cx)
		end
	end })
	command({ id = "new" .. i, title = "New chat " .. i, available = hidden, run = function(cx)
		local host = host_slots[i]
		if not host then
			return
		end
		local hname
		for _, h in cx.hosts:list() do
			if h.id == host then
				hname = h.name
			end
		end
		-- Ask where: recent chat folders first, then every project folder, then any path.
		local items, seen = {}, {}
		-- Recent: where your last chats ran, with when. Projects: names only (they all live in
		-- the projects root, so the path adds nothing).
		for _, it in recent[hname or ""] or {} do
			local path = it.cwd
			if path and path ~= "" and not seen[path] and #items < 4 then
				seen[path] = true
				local root = roots[hname or ""]
				local inside = root and path:sub(1, #root + 1) == root .. "/"
				table.insert(items, {
					label = base(path), detail = inside and ago(it.mtime) .. " ago" or tilde(path, hname) .. "  ·  " .. ago(it.mtime) .. " ago",
					icon = "clock", group = "Recent", path = path,
				})
			end
		end
		for _, path in folders[hname or ""] or {} do
			if not seen[path] then
				seen[path] = true
				table.insert(items, { label = base(path), icon = "folder", group = "Projects", path = path })
			end
		end
		table.insert(items, { label = "Type a path…", icon = "folder-open", group = " ", other = true })
		local h
		for _, x in cx.hosts:list() do
			if x.id == host then
				h = x
			end
		end
		local function start(cx2, path: string)
			local pane = idle_shell(cx2, host)
			if pane then
				-- An empty shell is selected on that machine: start the chat in it, no new pane.
				cx2:run(pane, "cd " .. string.format("%q", path) .. " && omp\r")
			else
				cx2.hosts:switch(host)
				cx2.hosts:terminal(host, { cwd = path, command = "omp" })
			end
		end
		-- Finder-like walk: a folder's subfolders; ↵ on one goes in, "Start chat here" starts.
		local browse
		browse = function(cx2, dir: string)
			helper(h, { "--ls", dir }, function(res, cx3)
				if not cx3 then
					return
				end
				local here, rows = dir, {}
				for line in res.stdout:gmatch("[^\n]+") do
					local ok, it = pcall(tern.json.decode, line)
					if ok and type(it) == "table" then
						if it.here then
							here = it.here
						elseif it.error then
							cx3:toast("error", "Can't open that folder", it.error)
							return
						elseif it.name then
							table.insert(rows, { label = it.name, icon = "folder", group = "Folders", path = it.path, go = true })
						end
					end
				end
				local pretty = tilde(here, hname)
				local list = {
					{ label = "Start chat here", detail = pretty, icon = "play", act = "start" },
					{ label = "New folder…", icon = "plus", act = "mkdir" },
				}
				local parent = here:match("^(.*)/[^/]+$")
				if parent then
					table.insert(list, { label = "..", detail = "up to " .. (base(parent ~= "" and parent or "/")), icon = "arrow-up", path = parent ~= "" and parent or "/", go = true })
				end
				for _, r in rows do
					table.insert(list, r)
				end
				cx3:pick({ placeholder = short_host(hname or "") .. "  ·  " .. pretty, icon = "folder", action = "open", items = list })
					:next(function(item, _e, cx4)
						if not item or not cx4 then
							return
						end
						if item.go then
							browse(cx4, item.path)
						elseif item.act == "start" then
							start(cx4, here)
						elseif item.act == "mkdir" then
							cx4:prompt({ placeholder = "New folder in " .. pretty, icon = "plus", action = "create" })
								:next(function(name, _e2, cx5)
									if not name or name == "" or not cx5 then
										return
									end
									local path = here .. "/" .. name
									helper(h, { "--mkdir", path }, function(r2, cx6)
										if cx6 then
											if r2.status ~= 0 then
												cx6:toast("error", "Couldn't create the folder", r2.stderr)
											else
												browse(cx6, path)
											end
										end
									end)
								end)
						end
					end)
			end)
		end
		table.insert(items, 1, { label = "Browse…", detail = "any folder, or make one", icon = "folder-open", group = " ", browse = true })
		cx:pick({ placeholder = "Start a chat on " .. short_host(hname or "") .. " in…", icon = "folder", action = "open", items = items })
			:next(function(item, _err, cx2)
				if not item or not cx2 then
					return
				end
				if item.other then
					cx2:prompt({ placeholder = "Folder path on " .. short_host(hname or ""), icon = "folder", action = "open" })
						:next(function(path, _e, cx3)
							if path and path ~= "" and cx3 then
								browse(cx3, path)
							end
						end)
				elseif item.browse then
					browse(cx2, roots[hname or ""] or "~")
				else
					browse(cx2, item.path)
				end
			end)
	end })
end

for i = 1, MAX_HOSTS * MAX_RECENT do
	command({ id = "resume" .. i, title = "Resume " .. i, available = hidden, run = function(cx)
		local r = recent_slots[i]
		if not r then
			return
		end
		local cmd = "omp --resume " .. r.item.id
		-- Same machine and the focused pane is an idle shell: continue the chat right there.
		-- Otherwise (an agent or busy pane, or another machine) open it in a new tab.
		local focused = idle_shell(cx, r.host)
		if focused then
			cx:run(focused, "cd " .. string.format("%q", r.item.cwd) .. " && " .. cmd .. "\r")
		else
			cx.hosts:switch(r.host)
			cx.hosts:terminal(r.host, { cwd = r.item.cwd, command = cmd })
		end
		opened[r.item.id] = true -- hide it now; the open chat takes its place
		fetch_recent(cx)
	end })
	-- ⋯ menu: the actions a right-click would offer. Typing a row's letter filters to it.
	command({ id = "more" .. i, title = "Chat menu " .. i, available = hidden, run = function(cx)
		local m = fork_slots[i]
		if not m then
			return
		end
		local items = {}
		if m.chat then
			table.insert(items, { label = "Rename", detail = "R", icon = "pencil", act = "rename" })
		else
			table.insert(items, { label = "Reopen", detail = "O", icon = "arrow-right", act = "resume" })
		end
		if m.item then
			table.insert(items, { label = "Fork", detail = "F", icon = "branch", act = "fork" })
		end
		if m.chat then
			table.insert(items, { label = "Close", detail = "W", icon = "x", act = "close", group = " " })
			-- Delete only when this chat's session file is certain: two sessions with one title (a fork
			-- and its parent) could send the wrong file to the trash.
			if m.item and m.sure then
				table.insert(items, { label = "Delete", detail = "D", icon = "trash", act = "delete-open", tone = "danger", group = " " })
			end
		else
			table.insert(items, { label = "Delete", detail = "D", icon = "trash", act = "delete", tone = "danger", group = " " })
		end
		local title = m.chat and chat_slots[m.chat] and chat_slots[m.chat].label or (m.item and clean_title(m.item.title)) or "Chat"
		local function handle(item, _err, cx2)
			do
				if not item or not cx2 or not item.act then
					return
				end
				-- Delete is permanent: ask once more.
				if item.act:sub(1, 6) == "delete" and not item.confirmed then
					cx2:pick({ placeholder = "Delete \"" .. oneline(title, 40) .. "\" for good? This can't be undone.", icon = "trash", action = "choose", items = {
						{ label = "Cancel", icon = "undo" },
						{ label = "Delete permanently", icon = "trash", group = " ", act = item.act, confirmed = true },
					} }):next(handle)
					return
				end
				if item.act == "open" then
					runs["go" .. m.chat](cx2)
				elseif item.act == "rename" then
					rename(cx2, chat_slots[m.chat])
				elseif item.act == "resume" then
					runs["resume" .. m.recent](cx2)
				elseif item.act == "fork" then
					runs["fork" .. i](cx2)
				elseif item.act == "close" then
					local slot = chat_slots[m.chat]
					if slot then
						pcall(function()
							cx2.layout:close(slot.pane)
						end)
						fetch_recent(cx2)
					end
				elseif item.act == "delete-open" and m.item then
					-- Close the chat, then move its session file to the trash.
					local slot = chat_slots[m.chat]
					if slot then
						pcall(function()
							cx2.layout:close(slot.pane)
						end)
					end
					for _, h in cx2.hosts:list() do
						if h.id == m.host then
							helper(h, { "--delete", m.item.id }, function(res, cx3)
								if cx3 then
									if res.status ~= 0 then
										cx3:toast("error", "Couldn't delete that chat", res.stderr)
									end
									fetch_recent(cx3)
								end
							end)
						end
					end
				elseif item.act == "delete" and m.item then
					armed_delete = m.item.id -- chosen from the menu: no second click
					runs["delete" .. m.recent](cx2)
				end
			end
		end
		cx:pick({ placeholder = oneline(title, 48), icon = "sparkle", action = "run", items = items }):next(handle)
	end })
	-- ⑂: a new chat continuing from a copy of this one (omp --fork); the original is untouched.
	command({ id = "fork" .. i, title = "Fork " .. i, available = hidden, run = function(cx)
		local f = fork_slots[i]
		if not f then
			return
		end
		local cmd = "omp --fork " .. f.item.id
		local pane = idle_shell(cx, f.host)
		if pane then
			cx:run(pane, "cd " .. string.format("%q", f.item.cwd) .. " && " .. cmd .. "\r")
		else
			cx.hosts:switch(f.host)
			cx.hosts:terminal(f.host, { cwd = f.item.cwd, command = cmd })
		end
		fetch_recent(cx)
	end })
	-- × arms; a second click within 3 s moves the session file to ~/.omp/agent/sessions-trash.
	command({ id = "delete" .. i, title = "Delete " .. i, available = hidden, run = function(cx)
		local r = recent_slots[i]
		if not r then
			return
		end
		if armed_delete ~= r.item.id then
			armed_delete = r.item.id
			rebuild(cx)
			local id = r.item.id
			tern.timer(3000, function(cx2)
				if armed_delete == id then
					armed_delete = nil
					if cx2 then
						rebuild(cx2)
					end
				end
			end)
			return
		end
		armed_delete = nil
		local h
		for _, x in cx.hosts:list() do
			if x.id == r.host then
				h = x
			end
		end
		if not h then
			return
		end
		helper(h, { "--delete", r.item.id }, function(res, cx2)
			if cx2 then
				if res.status ~= 0 then
					cx2:toast("error", "Couldn't delete that chat", res.stderr)
				end
				fetch_recent(cx2)
			end
		end)
	end })
end

command({ id = "fork_current", title = "Fork chat", icon = "branch", keys = { "ctrl+cmd+f" }, run = function(cx)
	rebuild(cx)
	local slot = focused_slot and chat_slots[focused_slot]
	local m = slot and slot.menu and fork_slots[slot.menu]
	if not (m and m.item) then
		cx:toast("info", "Open a chat first", "Or wait a few seconds: a new chat is not saved yet")
		return
	end
	runs["fork" .. slot.menu](cx)
end })

command({ id = "delete_current", title = "Delete chat…", icon = "trash", keys = { "ctrl+cmd+backspace" }, run = function(cx)
	rebuild(cx)
	local slot = focused_slot and chat_slots[focused_slot]
	local m = slot and slot.menu and fork_slots[slot.menu]
	if not (m and m.item) then
		cx:toast("info", "Open a chat first", "Or wait a few seconds: a new chat is not saved yet")
		return
	end
	if not m.sure then
		cx:toast("info", "Can't tell this chat's file apart", "Close it, then delete it from Closed")
		return
	end
	cx:pick({ placeholder = "Delete \"" .. oneline(slot.label, 40) .. "\" for good? This can't be undone.", icon = "trash", action = "choose", items = {
		{ label = "Cancel", icon = "undo" },
		{ label = "Delete permanently", icon = "trash", group = " ", go = true },
	} }):next(function(item, _err, cx2)
		if not (item and item.go and cx2) then
			return
		end
		pcall(function()
			cx2.layout:close(slot.pane)
		end)
		for _, h in cx2.hosts:list() do
			if h.id == m.host then
				helper(h, { "--delete", m.item.id }, function(res, cx3)
					if cx3 then
						if res.status ~= 0 then
							cx3:toast("error", "Couldn't delete that chat", res.stderr)
						end
						fetch_recent(cx3)
					end
				end)
			end
		end
	end)
end })

command({ id = "rename", title = "Rename chat…", icon = "pencil", keys = { "ctrl+cmd+r" }, run = function(cx)
	rebuild(cx)
	rename(cx, focused_slot and chat_slots[focused_slot] or nil)
end })

-- ⌃⌘C: the same chats as a search picker.
command({ id = "open", title = "Chats…", icon = "sparkle", keys = { "ctrl+cmd+c" }, run = function(cx)
	rebuild(cx)
	local items = {}
	for i, slot in chat_slots do
		table.insert(items, { label = slot.label, group = short_host(slot.hostname), icon = "sparkle", i = i })
	end
	cx:pick({ placeholder = "Chats on every machine", icon = "sparkle", action = "open", items = items })
		:next(function(item, _err, cx2)
			if item and cx2 then
				jump(cx2, item.i)
			end
		end)
end })

local function poll_recent()
	tern.timer(RECENT_MS, function(cx)
		if cx then
			fetch_recent(cx)
		end
		poll_recent()
	end)
end
poll_recent()
tern.timer(500, function(cx)
	if cx then
		fetch_recent(cx)
	end
end)

local function poll()
	tern.timer(POLL_MS, function(cx)
		if cx then
			rebuild(cx)
		end
		poll()
	end)
end

local function start(cx)
	if cx.settings:get("status_bar") ~= true then
		cx.settings:set("status_bar", true)
	end
	rebuild(cx)
end

tern.on("window_start", start)
tern.timer(0, function(cx)
	if cx then
		start(cx)
	end
end)
-- Sidebar width and collapse: ⌘B hides/shows, ⌃⌘[ / ⌃⌘] narrower/wider; remembered.
local MIN_W, MAX_W, STEP_W = 180, 420, 24

local function apply_layout()
	local w = math.clamp(tern.kv.get("width") or 248, MIN_W, MAX_W)
	if tern.kv.get("collapsed") then
		tern.css("layout", "#statusline{display:none !important}#panel{left:3px !important}")
	else
		tern.css("layout", string.format("html:root{--chats-w:%dpx}", w))
	end
end

local function resize(delta: number)
	tern.kv.set("collapsed", nil)
	tern.kv.set("width", math.clamp((tern.kv.get("width") or 248) + delta, MIN_W, MAX_W))
	apply_layout()
end

local function toggle()
	tern.kv.set("collapsed", not tern.kv.get("collapsed") or nil)
	apply_layout()
end

tern.override("toggle_sidebar", function(_cx)
	toggle()
	return true
end)
command({ id = "toggle", title = "Chats: hide/show sidebar", icon = "sidebar", keys = { "ctrl+cmd+b" }, run = function(_cx) toggle() end })
command({ id = "narrower", title = "Chats: narrower sidebar", icon = "sidebar", keys = { "ctrl+cmd+[" }, run = function(_cx) resize(-STEP_W) end })
command({ id = "wider", title = "Chats: wider sidebar", icon = "sidebar", keys = { "ctrl+cmd+]" }, run = function(_cx) resize(STEP_W) end })
apply_layout()

-- Closing a block, tab or session that holds an omp chat asks first.
local function agents_in(cx, scope: string): { number }
	local agents = {}
	for _, a in cx.agents:list() do
		-- A chat with no messages yet has nothing to lose: it closes at once.
		local ok, msgs = pcall(function()
			return cx.agents:transcript(a.pane, { last = 1 })
		end)
		local empty = ok and type(msgs) == "table" and #msgs == 0
		if a.state ~= "exited" and not empty then
			agents[a.pane] = true
		end
	end
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local found = {}
	for _, p in cx.session:panes() do
		if agents[p.pane] and (scope == "session" or (scope == "tab" and cx.session:tab_of(p.pane) == tab) or p.pane == focused) then
			table.insert(found, p.pane)
		end
	end
	return found
end

-- First press shows a toast and arms; a second press of the same close within 3 s closes.
local armed: string? = nil
local KEYS = { close_pane = "⌘W", close_tab = "⌥⌘W", close_session = "the same command" }

for id, scope in { close_pane = "pane", close_tab = "tab", close_session = "session" } do
	tern.override(id, function(cx)
		local found = agents_in(cx, scope)
		if #found == 0 then
			return false -- nothing to lose: Tern closes it as usual
		end
		local mark = id .. ":" .. table.concat(found, ",")
		if armed == mark then
			armed = nil
			cx:command(id)
			return true
		end
		armed = mark
		local what = #found == 1 and "this chat" or (#found .. " chats")
		cx:toast("info", KEYS[id] .. " again to close " .. what)
		tern.timer(3000, function(_cx)
			if armed == mark then
				armed = nil
			end
		end)
		return true
	end)
end

-- Tern's events redraw at once. Pane changes and title changes (a chat names itself once its
-- session file exists; a rename) also refetch the session lists, a title burst only once.
local title_fetch = false
for _, name in { "focus", "title", "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev, cx)
		rebuild(cx)
		if name == "pane_created" or name == "pane_closed" then
			refresh_soon()
		elseif name == "title" and not title_fetch then
			title_fetch = true
			tern.timer(5000, function(_cx)
				title_fetch = false -- at most one title-driven fetch per 5 s (each may be an ssh trip)
			end)
			tern.timer(700, function(cx2)
				if cx2 then
					fetch_recent(cx2, true)
				end
			end)
		end
	end)
end
poll()
