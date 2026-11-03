--!strict
-- Ekko's pane verbs and a pane-first menu, on Tern's session model.

local recent: { number } = {}

local function track(pane: number)
	for i, id in ipairs(recent) do
		if id == pane then
			table.remove(recent, i)
			break
		end
	end
	table.insert(recent, 1, pane)
	while #recent > 64 do
		table.remove(recent)
	end
end

local function by_id(cx: WindowCx): { [number]: PaneInfo }
	local map: { [number]: PaneInfo } = {}
	for _, info in ipairs(cx.session:panes()) do
		map[info.pane] = info
	end
	return map
end

local function name_of(info: PaneInfo): string
	if info.title ~= "" then
		return info.title
	end
	return info.program or ("block " .. info.pane)
end

tern.on("window_start", function(cx: WindowCx)
	recent = {}
	for _, info in ipairs(cx.session:panes()) do
		if info.focused then
			track(info.pane)
		end
	end
end)

tern.on("focus", function(ev: FocusEvent)
	track(ev.pane)
end)

local pending: { [number]: any } = {}

local function pick(cx: WindowCx, opts: PickOptions, fn: (item: PickItem?, cx: WindowCx) -> ())
	local handle = cx:pick(opts)
	pending[handle.id] = handle
	handle:next(function(item, err, fresh)
		pending[handle.id] = nil
		if err then
			if fresh then
				fresh:toast("error", "Pick failed", err)
			end
			return
		end
		fn(item, fresh or cx)
	end)
end

local function tab_of(cx: WindowCx, pane: number): number?
	for _, info in ipairs(cx.session:panes()) do
		if info.pane == pane then
			return info.tab
		end
	end
	return nil
end

local function leaves(tree: TabTree, out: { number }): { number }
	if tree.pane then
		table.insert(out, tree.pane)
		return out
	end
	for i = 1, 2 do
		local sub = tree[i]
		if sub then
			leaves(sub, out)
		end
	end
	return out
end

local function even_tab(cx: WindowCx, tab: number?)
	if tab then
		cx.layout:even(tab)
	end
end

local function own_tab(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if not info or info.floating or info.parked then
		return
	end
	local tab = cx.session:tab_of(pane)
	local layout = tab and cx.session:layout(tab)
	if layout and layout.root.split then
		cx.layout:move_to_new_tab(pane)
	end
end

local function new_card(cx: WindowCx): boolean
	local focus = cx.session:focused()
	local info = focus and cx.session:pane(focus)
	local cwd = info and info.cwd ~= "" and info.cwd or nil
	cx.layout:new_tab({ cwd = cwd })
	return true
end

tern.override("split_right", new_card)
tern.override("split_down", new_card)

tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
	own_tab(cx, ev.pane)
	tern.timer(80, function(fresh)
		own_tab(fresh or cx, ev.pane)
	end)
end)

local function sweep(cx: WindowCx)
	for _, tab in ipairs(cx.session:tabs()) do
		local layout = cx.session:layout(tab.id)
		if layout and layout.root.split then
			local ids = leaves(layout.root, {})
			for i = 2, #ids do
				cx.layout:move_to_new_tab(ids[i], nil, { focus = false })
			end
		end
	end
end

tern.on("window_start", sweep)
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	sweep(cx)
end)

local function read_proc(path: string): string
	local ok, text = pcall(tern.fs.read, path)
	return ok and text or ""
end

local sys: { StatusSegment } = {}
local cpu_prev: { number }? = nil
local net_prev: { number }? = nil
local gpu_line = ""
local gpu_busy = false
local tick_gen = 0
local TICK_MS = 500
local function bucket(v: number): string
	return "-b" .. math.clamp(math.floor(v * 10 + 0.5), 0, 10)
end

local function level(role: string, v: number): string
	return role .. (v >= 0.9 and "-hot" or (v >= 0.75 and "-warm" or "")) .. bucket(v)
end

local function human(bytes: number): string
	if bytes >= 1048576 then
		return string.format("%.1fM", bytes / 1048576)
	elseif bytes >= 1024 then
		return string.format("%.0fK", bytes / 1024)
	end
	return string.format("%dB", math.floor(bytes))
end

local function sample()
	local nums: { number } = {}
	for n in (read_proc("/proc/stat"):match("^cpu%s+([^\n]+)") or ""):gmatch("%d+") do
		table.insert(nums, tonumber(n) :: number)
	end
	local cpu = 0
	if #nums >= 5 then
		local total, idle = 0, nums[4] + nums[5]
		for _, n in ipairs(nums) do
			total += n
		end
		if cpu_prev and total > cpu_prev[1] then
			cpu = 1 - (idle - cpu_prev[2]) / (total - cpu_prev[1])
		end
		cpu_prev = { total, idle }
	end

	local mem = read_proc("/proc/meminfo")
	local mtotal = tonumber(mem:match("MemTotal:%s+(%d+)")) or 0
	local used = mtotal - (tonumber(mem:match("MemAvailable:%s+(%d+)")) or 0)
	local mshare = mtotal > 0 and used / mtotal or 0

	local rx, tx = 0, 0
	for name, r, t in read_proc("/proc/net/dev"):gmatch("\n%s*([^:%s]+):%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)") do
		if name ~= "lo" then
			rx += tonumber(r) :: number
			tx += tonumber(t) :: number
		end
	end
	local down, up = 0, 0
	if net_prev then
		down = math.max(0, rx - net_prev[1]) * 1000 / TICK_MS
		up = math.max(0, tx - net_prev[2]) * 1000 / TICK_MS
	end
	net_prev = { rx, tx }

	local out: { StatusSegment } = {
		{ text = os.date("%H:%M:%S") :: string, tone = "time" },
		{ text = string.upper(os.date("%a %d %b") :: string), tone = "date" },
		{ text = string.format("%d%%", math.floor(cpu * 100 + 0.5)), tone = level("m-cpu", cpu) },
		{ text = string.format("%.0f/%.0fG", used / 1048576, mtotal / 1048576), tone = level("m-mem", mshare) },
	}
	local util, gused, gtotal, temp = gpu_line:match("(%d+),%s*(%d+),%s*(%d+),%s*(%d+)")
	if util then
		local g = (tonumber(util) :: number) / 100
		local v = (tonumber(gused) :: number) / (tonumber(gtotal) :: number)
		table.insert(out, { text = string.format("%d%% · %s°", math.floor(g * 100 + 0.5), temp), tone = level("m-gpu", g) })
		table.insert(out, { text = string.format("%.1f/%.0fG", (tonumber(gused) :: number) / 1024, (tonumber(gtotal) :: number) / 1024), tone = level("m-vram", v) })
	else
		table.insert(out, { text = "—", tone = "m-gpu" })
		table.insert(out, { text = "—", tone = "m-vram" })
	end
	table.insert(out, { text = "↓" .. human(down) .. "  ↑" .. human(up), tone = "m-net" })
	table.insert(out, { text = read_proc("/proc/loadavg"):match("^(%S+ %S+ %S+)") or "?", tone = "m-load" })
	sys = out
end

local function poll_gpu()
	if gpu_busy then
		return
	end
	gpu_busy = true
	tern.process.run({ "nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu", "--format=csv,noheader,nounits" }, function(result)
		gpu_busy = false
		if result.status == 0 then
			gpu_line = result.stdout
		end
	end)
end

local cards: { TabInfo } = {}
local card_count = 0
local sync_cards: (WindowCx) -> ()
local snapshot_cards: (WindowCx) -> ()

local function tick(gen: number)
	if gen ~= tick_gen then
		return
	end
	poll_gpu()
	sample()
	tern.chrome.refresh()
	tern.timer(TICK_MS, function(cx)
		if cx then
			sweep(cx)
			sync_cards(cx)
		end
		tick(gen)
	end)
end

function sync_cards(cx: WindowCx)
	cards = cx.session:tabs()
	card_count = #cards
end

function snapshot_cards(cx: WindowCx)
	sync_cards(cx)
	tern.chrome.refresh()
end

local function cards_event(_ev: any, cx: WindowCx?)
	if cx then
		snapshot_cards(cx)
	end
end

local function clip(s: string, n: number): string
	local len = utf8.len(s)
	if not len or len <= n then
		return s
	end
	local byte = utf8.offset(s, n + 1)
	return (byte and s:sub(1, byte - 1) or s) .. "…"
end

local function deck_segment(pane: number?): StatusSegment?
	if not pane then
		return nil
	end
	for _, t in ipairs(cards) do
		if t.pane == pane then
			local label = (t.name and t.name ~= "") and t.name or t.title
			label = clip(label, 18)
			local text = string.format("%d/%d %s", t.position, card_count, label)
			if t.busy then
				text = text .. " ●"
			end
			return {
				text = text,
				icon = "layers",
				tone = t.busy and "deck-busy" or "deck",
				command = "plugin.ekko.cards",
			}
		end
	end
	return nil
end

local function focused_pane(cx: WindowCx): number?
	local f = cx.session:focused()
	if type(f) == "number" then
		return f
	end
	if type(f) == "table" then
		return ((f :: any).pane) :: number?
	end
	return nil
end

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local out: { StatusSegment } = {}
	local card = deck_segment((pane :: any).pane)
	if card then
		table.insert(out, card)
	end
	for _, s in ipairs(sys) do
		table.insert(out, s)
	end
	return out
end)

tern.on("window_start", function(cx: WindowCx)
	snapshot_cards(cx)
end)

tick_gen += 1
tick(tick_gen)

tern.on("focus", function(ev: any, cx: WindowCx?)
	cards_event(ev, cx)
end)

tern.on("tab_created", function(ev: any, cx: WindowCx?)
	cards_event(ev, cx)
end)

tern.on("tab_closed", function(ev: any, cx: WindowCx?)
	cards_event(ev, cx)
end)

tern.on("command_started", function(ev: any, cx: WindowCx?)
	cards_event(ev, cx)
end)

tern.on("command_finished", function(ev: any, cx: WindowCx?)
	cards_event(ev, cx)
end)

local function cards(cx: WindowCx)
	local items: { PickItem } = {}
	local here = focused_pane(cx)
	for _, t in ipairs(cx.session:tabs()) do
		local label = (t.name and t.name ~= "" and t.name) or t.title
		local parts: { string } = {}
		if t.program and t.program ~= "" then
			table.insert(parts, t.program)
		end
		if t.panes > 1 then
			table.insert(parts, t.panes .. " panes")
		end
		if t.cwd and t.cwd ~= "" then
			table.insert(parts, t.cwd)
		end
		table.insert(items, {
			label = string.format("%d · %s", t.position, label),
			detail = #parts > 0 and table.concat(parts, " · ") or nil,
			icon = t.busy and "play" or nil,
			current = t.pane == here or nil,
			pane = t.pane,
		})
	end
	if #items == 0 then
		return
	end
	pick(cx, { items = items, placeholder = "card", icon = "layers", action = "focus" }, function(item, fresh)
		if item then
			(fresh or cx).layout:focus(item.pane)
		end
	end)
end

tern.command({
	id = "cards",
	title = "Cards (deck)",
	icon = "layers",
	keys = { "ctrl+p>c" },
	run = cards,
})

tern.on("window_start", function(cx: WindowCx)
	tick_gen += 1
	tick(tick_gen)
end)

local function toggle_float(cx: WindowCx)
	local focus = cx.session:focused()
	if not focus then
		return
	end
	local info = by_id(cx)[focus]
	local ok, why
	if info and info.floating then
		ok, why = cx.layout:dock(focus)
	else
		ok, why = cx.layout:float(focus, nil, "tl")
	end
	if not ok then
		cx:toast("error", "Could not move the block", why)
	end
end

local function menu(cx: WindowCx)
	local map = by_id(cx)
	local tabs: { [number]: TabInfo } = {}
	for _, tab in ipairs(cx.session:tabs()) do
		tabs[tab.id] = tab
	end
	local items: { PickItem } = {}
	local seen: { [number]: boolean } = {}

	local function pane_row(info: PaneInfo)
		if seen[info.pane] then
			return
		end
		seen[info.pane] = true
		local tab = info.tab and tabs[info.tab]
		local where = tab and (tab.name or ("tab " .. tab.position)) or nil
		local parts: { string } = {}
		if info.cwd ~= "" then
			table.insert(parts, info.cwd)
		end
		if where then
			table.insert(parts, where)
		end
		items[#items + 1] = {
			label = name_of(info),
			detail = #parts > 0 and table.concat(parts, " · ") or nil,
			group = info.parked and "Parked" or "Panes",
			icon = info.parked and "park" or (info.floating and "float" or nil),
			current = info.focused or nil,
			pane = info.pane,
		}
	end

	for _, id in ipairs(recent) do
		local info = map[id]
		if info then
			pane_row(info)
		end
	end
	for _, info in ipairs(cx.session:panes()) do
		pane_row(info)
	end

	local function cmd(label: string, act: string)
		items[#items + 1] = { label = label, group = "Pane commands", act = act }
	end

	items[#items + 1] = { label = "Cards (deck)…", group = "Pane commands", deck = true }
	cmd("Zoom block", "zoom")
	cmd("Even out splits", "equalize")
	cmd("Close block", "close_pane")
	cmd("Park block", "park_pane")
	cmd("Parked blocks…", "parked_panes")
	items[#items + 1] = { label = "Toggle floating", group = "Pane commands", float = true }

	local function tab(label: string, act: string)
		items[#items + 1] = { label = label, group = "Tabs", act = act }
	end

	tab("New tab", "new_tab")
	tab("Rename tab…", "rename_tab")
	tab("Close tab", "close_tab")
	tab("Next tab", "next_tab_across_sessions")
	tab("Previous tab", "previous_tab_across_sessions")

	local function tern_row(label: string, act: string)
		items[#items + 1] = { label = label, group = "Tern", act = act }
	end

	tern_row("Close window", "close_window")
	tern_row("Command palette…", "palette")
	tern_row("Find in scrollback", "find")
	tern_row("New shell block", "new_shell_block")

	pick(cx, { items = items, placeholder = "ekko", icon = "layers", action = "run" }, function(item, cx)
		if not item then
			return
		end
		if item.pane then
			cx.layout:focus(item.pane)
		elseif item.deck then
			cards(cx)
		elseif item.float then
			toggle_float(cx)
		elseif item.act then
			cx:action(item.act)
		end
	end)
end

tern.command({
	id = "menu",
	title = "Ekko menu",
	icon = "layers",
	keys = { "ctrl+p>p", "ctrl+p>g", "ctrl+shift+u" },
	run = menu,
})

tern.command({
	id = "new_tab_key",
	title = "New tab",
	icon = "layers",
	keys = { "ctrl+p>n" },
	run = function(cx: WindowCx)
		cx:action("new_tab")
	end,
})

tern.command({
	id = "close_tab_key",
	title = "Close tab",
	icon = "layers",
	keys = { "ctrl+p>x" },
	run = function(cx: WindowCx)
		cx:action("close_tab")
	end,
})

tern.command({
	id = "switcher",
	title = "Switch block (recent)",
	icon = "history",
	keys = { "alt+tab" },
	available = function(cx: WindowCx): boolean
		return #cx.session:panes() > 1
	end,
	run = function(cx: WindowCx)
		local map = by_id(cx)
		local items: { PickItem } = {}
		for _, id in ipairs(recent) do
			local info = map[id]
			if info then
				items[#items + 1] = {
					label = name_of(info),
					detail = info.cwd ~= "" and info.cwd or nil,
					icon = info.floating and "float" or nil,
					current = info.focused or nil,
					pane = id,
				}
			end
		end
		if #items == 0 then
			return
		end
		pick(cx, { items = items, placeholder = "switch to", icon = "history", action = "focus" }, function(item, cx)
			if item then
				cx.layout:focus(item.pane)
			end
		end)
	end,
})

tern.command({
	id = "float",
	title = "Toggle floating block",
	icon = "float",
	keys = { "ctrl+p>t" },
	run = toggle_float,
})

tern.command({
	id = "alerts",
	title = "Jump to an unseen alert",
	icon = "bell",
	keys = { "ctrl+p>b", "ctrl+p>a" },
	available = function(cx: WindowCx): boolean
		for _, info in ipairs(cx.session:panes()) do
			if info.alert then
				return true
			end
		end
		return false
	end,
	run = function(cx: WindowCx)
		local items: { PickItem } = {}
		for _, info in ipairs(cx.session:panes()) do
			if info.alert then
				items[#items + 1] = {
					label = name_of(info),
					detail = info.cwd ~= "" and info.cwd or nil,
					pane = info.pane,
				}
			end
		end
		if #items == 0 then
			return
		end
		pick(cx, { items = items, placeholder = "alert", icon = "bell", action = "focus" }, function(item, cx)
			if item then
				cx.layout:focus(item.pane)
			end
		end)
	end,
})

local binder = {
	{ "n", "New card", "new_tab", false },
	{ "r", "New card", "new_tab", false },
	{ "d", "New card", "new_tab", false },
	{ "f", "Zoom block", "zoom", false },
	{ "e", "Even out splits", "equalize", false },
	{ "x", "Close block", "close_pane", false },
	{ "m", "Park block", "park_pane", false },
	{ "s", "Parked blocks\u{2026}", "parked_panes", false },
	{ "c", "Rename tab\u{2026}", "rename_tab", false },
	{ "h", "Focus left", "focus_pane:left", false },
	{ "j", "Focus down", "focus_pane:down", false },
	{ "k", "Focus up", "focus_pane:up", false },
	{ "l", "Focus right", "focus_pane:right", false },
	{ "shift+h", "Shrink left", "resize_split:left", false },
	{ "shift+l", "Shrink right", "resize_split:right", false },
	{ "shift+j", "Shrink down", "resize_split:down", false },
	{ "shift+k", "Shrink up", "resize_split:up", false },
	{ "tab", "Next tab", "next_tab_across_sessions", false },
	{ "shift+tab", "Previous tab", "previous_tab_across_sessions", false },
}

for i, b in ipairs(binder) do
	local id = (b[3]:gsub("[^%w]", "_"))
	tern.command({
		id = id .. "_" .. i,
		title = b[2],
		keys = { "ctrl+p>" .. b[1] },
		run = function(cx: WindowCx)
			cx:action(b[3])
			if b[4] then
				even_tab(cx, tab_of(cx, cx.session:focused() or 0))
			end
		end,
	})
end
