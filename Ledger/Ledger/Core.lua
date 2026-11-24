--[[
	Ledger - Core.lua
	Saved data, categories, recording entries, time periods, money text.

	LedgerDB = {
	  settings = { ... },
	  chars[guid] = {
	    name = "Name Surname", short = "Name", class = "PRIEST", money = copper,
	    days = { ["2026-11-23"] = { [cat] = { i = income, e = expense } } },   -- fast totals
	    log  = { { t = time, a = signed copper, c = cat, d = "detail", n = count } }, -- details
	    counter = { start = time, earned = copper, spent = copper },          -- on-screen counter
	  },
	  loot = { ... },   -- the loot table, account-wide (see Loot.lua)
	}
	Ledger was called GoldLedger up to v1.3; the saved file was copied to Ledger.lua.
	Transfers (own characters, Warband bank, guild bank) are logged but never
	counted as earned or spent.
]]

local ADDON, ns = ...

ns.me = nil


--[[ Events (several listeners per event, each protected) ]]--

local listeners = {}
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(listeners[event]) do
		local ok, err = pcall(fn, event, ...)
		if not ok then
			ns.Error(event, err)
		end
	end
end)

function ns.On(event, fn)
	if not listeners[event] then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			return -- this client doesn't have that event
		end
		listeners[event] = {}
	end
	tinsert(listeners[event], fn)
end

-- WoW Forever hides Lua errors, so keep the last few and tell the player once
local errorShown = false
function ns.Error(where, err)
	if not LedgerDB then
		return
	end
	LedgerDB.errors = LedgerDB.errors or {}
	tinsert(LedgerDB.errors, { t = time(), where = tostring(where), msg = tostring(err):sub(1, 300) })
	while #LedgerDB.errors > 10 do
		tremove(LedgerDB.errors, 1)
	end
	if not errorShown then
		errorShown = true
		ns.Print("hit an error (" .. tostring(where) .. "). /ledger errors shows it.")
	end
end

function ns.Print(msg)
	print("|cffffd100Ledger|r: " .. msg)
end


--[[ Money text ]]--

function ns.Money(copper, signed)
	copper = floor(copper or 0)
	local text = GetMoneyString and GetMoneyString(abs(copper), true) or GetCoinTextureString(abs(copper))
	if signed then
		if copper > 0 then
			return "|cff40ff40+|r" .. text
		elseif copper < 0 then
			return "|cffff5050-|r" .. text
		end
	end
	return (copper < 0 and "-" or "") .. text
end


--[[ Categories ]]--

-- label for income (+) and expense (-) of each category
ns.Categories = {
	loot     = { "Loot", "Loot" },
	quest    = { "Quests", "Quests" },
	vendor   = { "Vendor sales", "Vendor purchases" },
	repair   = { "Repairs", "Repairs" },
	auction  = { "Auction sales", "Auction house" },
	mail     = { "Mail received", "Mail sent" },
	postage  = { "Postage", "Postage" },
	trade    = { "Trade", "Trade" },
	taxi     = { "Flight paths", "Flight paths" },
	train    = { "Training", "Training" },
	barber   = { "Barber", "Barber" },
	transmog = { "Transmog", "Transmog" },
	guild    = { "Guild", "Guild" },
	other    = { "Other", "Other" },
	transfer = { "Transfers in", "Transfers out" },
}

function ns.CategoryLabel(cat, amount)
	local labels = ns.Categories[cat] or ns.Categories.other
	return amount >= 0 and labels[1] or labels[2]
end

-- loot and vendor sales come in many small bits: merge them into one line
local MERGE = { loot = true, vendor = true, quest = false }
local MERGE_SECONDS = 300


--[[ Characters ]]--

function ns.Char(key)
	return LedgerDB.chars[key or ns.me]
end

function ns.SortedChars()
	local keys = {}
	for key in pairs(LedgerDB.chars) do
		tinsert(keys, key)
	end
	local chars = LedgerDB.chars
	sort(keys, function(a, b)
		if a == ns.me then return true end
		if b == ns.me then return false end
		return (chars[a].name or a) < (chars[b].name or b)
	end)
	return keys
end

function ns.ClassColored(char)
	local name = char and char.name or "?"
	local color = char and char.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.class]
	if color and color.colorStr then
		return "|c" .. color.colorStr .. name .. "|r"
	end
	return name
end

-- is this name (from mail or trade) one of my own characters?
function ns.IsOwnChar(name)
	if not name or name == "" then
		return false
	end
	name = name:gsub("%-.*$", ""):lower() -- drop "-Realm"
	local function Matches(full)
		if not full then
			return false
		end
		full = full:lower()
		return full == name or full:match("^(%S+)") == name
	end
	for key, char in pairs(LedgerDB.chars) do
		if key ~= ns.me and (Matches(char.name) or Matches(char.short)) then
			return true
		end
	end
	-- characters TidyBags knows about but that haven't logged in with Ledger yet
	if type(TidyBagsData) == "table" and type(TidyBagsData.chars) == "table" then
		for key, char in pairs(TidyBagsData.chars) do
			if key ~= ns.me and type(char) == "table" and Matches(char.name) then
				return true
			end
		end
	end
	return false
end


--[[ Recording ]]--

local function DayKey(t)
	return date("%Y-%m-%d", t)
end
ns.DayKey = DayKey

-- amount: signed copper. cat: category key. detail: text shown in the ledger.
function ns.Record(amount, cat, detail)
	amount = floor(amount or 0)
	if amount == 0 or not ns.me then
		return
	end
	local char = ns.Char()
	local now = time()
	cat = ns.Categories[cat] and cat or "other"
	detail = detail or ns.CategoryLabel(cat, amount)

	-- day totals
	local day = char.days[DayKey(now)] or {}
	char.days[DayKey(now)] = day
	local total = day[cat] or { i = 0, e = 0 }
	day[cat] = total
	if amount > 0 then
		total.i = total.i + amount
	else
		total.e = total.e - amount
	end

	-- detail line (merge small repeated bits)
	local last = char.log[#char.log]
	if MERGE[cat] and amount > 0 and last and last.c == cat and last.d == detail and last.a > 0
			and now - last.t < MERGE_SECONDS and DayKey(last.t) == DayKey(now) then
		last.a = last.a + amount
		last.n = (last.n or 1) + 1
		last.t = now
	else
		tinsert(char.log, { t = now, a = amount, c = cat, d = detail })
	end

	-- on-screen counter (transfers don't count)
	if cat ~= "transfer" then
		local counter = char.counter
		if amount > 0 then
			counter.earned = counter.earned + amount
		else
			counter.spent = counter.spent - amount
		end
	end

	-- coin from a corpse: the loot table credits it to that mob
	if cat == "loot" and amount > 0 and ns.OnLootCoin then
		ns.OnLootCoin(amount)
	end

	if ns.OnRecorded then
		ns.OnRecorded()
	end
end

function ns.ResetCounter()
	local char = ns.Char()
	char.counter = { start = time(), earned = 0, spent = 0 }
	if ns.OnRecorded then
		ns.OnRecorded()
	end
end


--[[ Time periods ]]--

local function Midnight(t)
	local d = date("*t", t)
	return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
end

local function AddDays(t, days)
	local d = date("*t", t)
	return time({ year = d.year, month = d.month, day = d.day + days, hour = 0 })
end

local function MonthStart(t, offset)
	local d = date("*t", t)
	return time({ year = d.year, month = d.month + (offset or 0), day = 1, hour = 0 })
end

-- each period: label, function(now) -> from, to   (to is exclusive)
ns.Periods = {
	{ key = "today",     label = "Today",      range = function(now) local m = Midnight(now) return m, AddDays(m, 1) end },
	{ key = "yesterday", label = "Yesterday",  range = function(now) local m = Midnight(now) return AddDays(m, -1), m end },
	{ key = "week",      label = "This week",  range = function(now)
		local m = Midnight(now)
		local wday = (date("*t", now).wday + 5) % 7 -- Monday = 0
		local start = AddDays(m, -wday)
		return start, AddDays(start, 7)
	end },
	{ key = "lastweek",  label = "Last week",  range = function(now)
		local m = Midnight(now)
		local wday = (date("*t", now).wday + 5) % 7
		local start = AddDays(m, -wday)
		return AddDays(start, -7), start
	end },
	{ key = "month",     label = "This month", range = function(now) return MonthStart(now), MonthStart(now, 1) end },
	{ key = "lastmonth", label = "Last month", range = function(now) return MonthStart(now, -1), MonthStart(now) end },
	{ key = "all",       label = "All time",   range = function() return 0, 2 ^ 31 end },
}

-- totals per category for a period: { [cat] = { i, e } }, plus overall income/expense
function ns.Totals(charKeys, from, to)
	local fromKey, toKey = DayKey(from), DayKey(to - 1)
	if from == 0 then fromKey = "0000" end
	local byCat, income, expense, transferIn, transferOut = {}, 0, 0, 0, 0
	for _, key in ipairs(charKeys) do
		local char = LedgerDB.chars[key]
		for dayKey, cats in pairs(char and char.days or {}) do
			if dayKey >= fromKey and dayKey <= toKey then
				for cat, total in pairs(cats) do
					local sum = byCat[cat] or { i = 0, e = 0 }
					byCat[cat] = sum
					sum.i = sum.i + total.i
					sum.e = sum.e + total.e
					if cat == "transfer" then
						transferIn, transferOut = transferIn + total.i, transferOut + total.e
					else
						income, expense = income + total.i, expense + total.e
					end
				end
			end
		end
	end
	return byCat, income, expense, transferIn, transferOut
end

-- detail lines for a period, newest first: { entry, charKey }
function ns.Entries(charKeys, from, to, filterCat, filterSign)
	local list = {}
	for _, key in ipairs(charKeys) do
		local char = LedgerDB.chars[key]
		for _, entry in ipairs(char and char.log or {}) do
			if entry.t >= from and entry.t < to
					and (not filterCat or entry.c == filterCat)
					and (not filterSign or (entry.a > 0) == (filterSign > 0)) then
				tinsert(list, { entry, key })
			end
		end
	end
	sort(list, function(a, b) return a[1].t > b[1].t end)
	return list
end


--[[ Clearing old data ]]--

local NEVER = 2 ^ 31

-- the choices offered in the Ledger window and the options page
ns.ClearChoices = {
	{ months = 1,  label = "Older than 1 month" },
	{ months = 3,  label = "Older than 3 months" },
	{ months = 6,  label = "Older than 6 months" },
	{ months = 12, label = "Older than 1 year" },
	{ months = 0,  label = "Everything (start fresh)" },
}

-- the first moment that is KEPT: midnight today minus N months (0 = clear everything)
function ns.ClearCutoff(months)
	if months == 0 then
		return NEVER
	end
	local d = date("*t")
	return time({ year = d.year, month = d.month - months, day = d.day, hour = 0 })
end

local function CutKey(cutoff)
	return cutoff >= NEVER and "9999" or DayKey(cutoff)
end

-- how much would go: gold lines, gold day totals, loot days. Changes nothing.
function ns.CountBefore(cutoff)
	local cutKey = CutKey(cutoff)
	local lines, days, lootDays = 0, 0, 0
	for _, char in pairs(LedgerDB.chars) do
		for _, e in ipairs(char.log or {}) do
			if e.t < cutoff then lines = lines + 1 end
		end
		for key in pairs(char.days or {}) do
			if key < cutKey then days = days + 1 end
		end
	end
	if ns.LootCountBefore then
		lootDays = ns.LootCountBefore(cutKey)
	end
	return lines, days, lootDays
end

-- remove every gold line, gold day total and loot day before the cutoff, for all characters
function ns.ClearBefore(cutoff)
	local cutKey = CutKey(cutoff)
	for _, char in pairs(LedgerDB.chars) do
		local kept = {}
		for _, e in ipairs(char.log or {}) do
			if e.t >= cutoff then tinsert(kept, e) end
		end
		char.log = kept
		for key in pairs(char.days or {}) do
			if key < cutKey then char.days[key] = nil end
		end
	end
	if ns.LootClearBefore then
		ns.LootClearBefore(cutKey)
	end
	if ns.OnRecorded then
		ns.OnRecorded()
	end
end


--[[ Startup ]]--

ns.On("PLAYER_LOGIN", function()
	LedgerDB = LedgerDB or {}
	LedgerDB.chars = LedgerDB.chars or {}
	LedgerDB.settings = LedgerDB.settings or {}

	ns.me = UnitGUID("player")
	local short, extra = UnitFullName("player")
	local char = LedgerDB.chars[ns.me] or {}
	char.short = short
	char.name = (extra and extra ~= "") and (short .. " " .. extra) or short
	char.class = select(2, UnitClass("player"))
	char.days = char.days or {}
	char.log = char.log or {}
	char.counter = char.counter or { start = time(), earned = 0, spent = 0 }
	LedgerDB.chars[ns.me] = char
end)
