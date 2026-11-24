--[[
	Ledger - Loot.lua
	The loot table: what every mob dropped, what it sold for, and who drops the
	most of an item. Account-wide (every character gets the same drops).

	LedgerDB.loot = {
	  mobs   = { [mobKey] = { n = name, z = zone } },
	  items  = { [itemID] = { n = name, l = link, p = vendor price, q = quality } },
	  names  = { [lower-case item name] = itemID },          -- AH mail only gives the name
	  days   = { ["2026-11-24"] = { [charKey] = { [mobKey] = {
	               k = corpses looted, c = coin copper,
	               i = { [itemID] = { n = looted, s = sold, v = sold for (copper) } } } } } },
	  unsold = { [itemID] = { { d = day, c = charKey, m = mobKey, n = count }, ... } },  -- oldest first
	}
	charKey: the looting character's GUID (ns.me). Loot recorded before v2.1 had no
	character; it was moved under "old" and shows on EVERY character's view
	(never hidden, never deleted: the user's rule is that updates keep all data).
	A sale is credited to the character who LOOTED the item (its own lots first,
	then other characters' lots, e.g. silk mailed to an alt and sold there).
	mobKey: the creature's npc ID ("1234"), "g:<zone>" for herbs/ore/chests,
	"f:<zone>" for fishing, "?" when the source can't be told.

	How a drop is recorded:
	  LOOT_READY / LOOT_OPENED  -> read every slot (item, count, which corpse)
	  LOOT_SLOT_CLEARED         -> that slot was taken (only taken items count)
	  LOOT_CLOSED               -> write it all (by then we know if it came from a bag)
	A sale (vendor or AH mail) is matched in Tracker.lua and then taken from the
	oldest unsold looted items of that kind.

	Rules: never save or compare a secret value (UnitGUID/UnitName can be secret).
	Nothing here touches Blizzard frames; it only reads loot APIs.
]]

local ADDON, ns = ...

local UNSOLD_MAX = 100     -- per item; older unsold lots fall off (they were banked, used ...)
local COIN_SECONDS = 4     -- coin arriving this soon after looting belongs to that corpse
local SLOT_MONEY = Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2
local SLOT_ITEM = Enum and Enum.LootSlotType and Enum.LootSlotType.Item or 1

local db
local nameCache = {}      -- npcID -> name, seen on target / mouseover / nameplates
local seenCorpses = {}    -- corpse GUID -> true (this session): a 2nd open (skinning) isn't a new kill
local session             -- the loot window being looted now
local lastCoin            -- { mob = key, t = GetTime() }

local function Secret(v)
	return issecretvalue and issecretvalue(v) or false
end

local function Debug(...)
	if ns.lootDebug then
		print("|cff80c0ffLedger loot|r:", ...)
	end
end


--[[ Who is this? ]]--

-- GUID -> kind ("Creature", "GameObject" ...), npc ID
local function ParseGUID(guid)
	if not guid or Secret(guid) or type(guid) ~= "string" then
		return nil
	end
	local kind, _, _, _, _, id = strsplit("-", guid)
	return kind, id
end

local function IsCreature(kind)
	return kind == "Creature" or kind == "Vehicle"
end

local function CacheUnit(unit)
	if not UnitExists(unit) then
		return
	end
	local guid = UnitGUID(unit)
	local kind, id = ParseGUID(guid)
	if not IsCreature(kind) or not id then
		return
	end
	local name = UnitName(unit)
	if name and not Secret(name) and name ~= "" then
		nameCache[id] = name
	end
end

ns.On("PLAYER_TARGET_CHANGED", function() CacheUnit("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() CacheUnit("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(_, unit) CacheUnit(unit) end)

-- the dead creature you are most likely looting (used when the game doesn't say)
local function DeadUnitGUID()
	for _, unit in ipairs({ "target", "mouseover" }) do
		if UnitExists(unit) then
			local dead = UnitIsDead(unit)
			if not Secret(dead) and dead then
				local guid = UnitGUID(unit)
				if guid and not Secret(guid) then
					CacheUnit(unit)
					return guid
				end
			end
		end
	end
end

local function GatherKey(prefix)
	return prefix .. (ns.Zone and ns.Zone() or "?")
end

-- source GUID -> mob key (and remember its name and zone)
local function MobKey(guid)
	local kind, id = ParseGUID(guid)
	if IsCreature(kind) and id then
		local mob = db.mobs[id] or {}
		db.mobs[id] = mob
		mob.n = nameCache[id] or mob.n
		mob.z = ns.Zone and ns.Zone() or mob.z
		return id, true
	elseif kind == "GameObject" then
		return GatherKey("g:"), false
	end
	return "?", false
end


--[[ Reading the loot window ]]--

-- days[day][char][mob], created when missing
local function MobRecord(day, char, key)
	local dayData = db.days[day] or {}
	db.days[day] = dayData
	local charData = dayData[char] or {}
	dayData[char] = charData
	local m = charData[key]
	if not m then
		m = { k = 0, c = 0, i = {} }
		charData[key] = m
	end
	return m
end

local function Me()
	return ns.me or "?"
end

local function ItemID(link)
	return link and tonumber(link:match("|Hitem:(%d+)"))
end

local Commit

local function Snapshot(event, autoLoot, fromItem)
	if session and GetTime() - session.t > 30 then
		Commit() -- a LOOT_CLOSED went missing: don't let it block later loot
	end
	if session then
		if event == "LOOT_OPENED" then
			session.fromItem = fromItem
		end
		return
	end
	session = { t = GetTime(), slots = {}, taken = {}, fromItem = (event == "LOOT_OPENED") and fromItem or nil }
	local fishing = IsFishingLoot and IsFishingLoot()
	local hasSourceAPI = type(GetLootSourceInfo) == "function"
	local fallback = (not hasSourceAPI) and DeadUnitGUID() or nil
	Debug(event, "slots", GetNumLootItems(), "GetLootSourceInfo", hasSourceAPI and "yes" or "NO",
		"fishing", tostring(fishing), "fromItem", tostring(fromItem), "fallback", tostring(fallback))

	for slot = 1, GetNumLootItems() do
		local slotType = GetLootSlotType(slot)
		local link = GetLootSlotLink(slot)
		local _, name, quantity, _, quality = GetLootSlotInfo(slot)
		if Secret(link) then link = nil end
		if Secret(name) then name = nil end
		if Secret(quantity) then quantity = nil end

		-- which corpse(s) it came from: { guid, count, guid, count ... }
		local sources = {}
		if fishing then
			sources = { { key = GatherKey("f:"), n = quantity or 1 } }
		else
			local list = hasSourceAPI and { GetLootSourceInfo(slot) } or {}
			for i = 1, #list, 2 do
				local guid, count = list[i], list[i + 1]
				if guid and not Secret(guid) then
					tinsert(sources, { guid = guid, n = (not Secret(count) and count) or quantity or 1 })
				end
			end
			if #sources == 0 then
				tinsert(sources, { guid = fallback, n = quantity or 1 })
			end
		end
		session.slots[slot] = {
			type = slotType, link = link, id = ItemID(link), name = name,
			quality = quality, sources = sources,
		}
		Debug(" slot", slot, "type", tostring(slotType), link or name or "?", "x" .. tostring(quantity),
			"from", (sources[1] and (sources[1].key or tostring(sources[1].guid))) or "?",
			#sources > 1 and ("(+" .. (#sources - 1) .. " more)") or "")
	end
end

ns.On("LOOT_READY", Snapshot)
ns.On("LOOT_OPENED", Snapshot)

ns.On("LOOT_SLOT_CLEARED", function(_, slot)
	local info = session and session.slots[slot]
	if info then
		session.taken[slot] = true
		Debug(" taken slot", slot)
		-- coin arrives before the window closes: remember whose it is now
		if info.type == SLOT_MONEY and not session.fromItem and db then
			local src = info.sources[1]
			lastCoin = { mob = src and (src.key or MobKey(src.guid)) or "?", t = GetTime() }
		end
	end
end)

-- write what was taken
function Commit()
	local s = session
	session = nil
	if not s or not db then
		return
	end
	if s.fromItem then
		Debug("from a bag or box: not recorded")
		return
	end
	local day = ns.DayKey(time())
	local me = Me()
	local counted = {}

	local function Mob(key)
		return MobRecord(day, me, key)
	end

	for slot, info in pairs(s.slots) do
		for _, src in ipairs(info.sources) do
			local key, creature = src.key, false
			if not key then
				key, creature = MobKey(src.guid)
			end
			src.key = key
			-- a corpse counts once, whether or not you took everything
			local id = src.guid or key
			if not counted[id] and not (src.guid and seenCorpses[src.guid]) then
				counted[id] = true
				Mob(key).k = Mob(key).k + 1
			end
			if src.guid then
				seenCorpses[src.guid] = true
			end

			if s.taken[slot] and info.type ~= SLOT_MONEY and info.id then
				local item = db.items[info.id] or {}
				db.items[info.id] = item
				item.l = info.link or item.l
				local iname = info.name or (info.link and info.link:match("|h%[(.-)%]|h"))
				if iname then
					item.n = iname
					db.names[iname:lower()] = info.id
				end
				item.q = info.quality or item.q
				local price = select(11, C_Item.GetItemInfo(info.link or info.id))
				if price and not Secret(price) then
					item.p = price
				end

				local count = src.n or 1
				local rec = Mob(key).i[info.id] or { n = 0, s = 0, v = 0 }
				Mob(key).i[info.id] = rec
				rec.n = rec.n + count

				-- waiting to be sold
				local lots = db.unsold[info.id] or {}
				db.unsold[info.id] = lots
				local last = lots[#lots]
				if last and last.d == day and last.m == key and last.c == me then
					last.n = last.n + count
				else
					tinsert(lots, { d = day, c = me, m = key, n = count })
				end
				while #lots > UNSOLD_MAX do
					tremove(lots, 1)
				end
				Debug(" recorded", info.link or iname, "x" .. count, "from", key, db.mobs[key] and db.mobs[key].n or "")
			end
		end
	end
	if ns.RefreshLedger then
		ns.RefreshLedger()
	end
end

ns.On("LOOT_CLOSED", function()
	Commit()
end)

-- coin: Core's ns.Record calls this for every "loot" gold change
function ns.OnLootCoin(amount)
	if not db or not lastCoin or GetTime() - lastCoin.t > COIN_SECONDS then
		return
	end
	local m = MobRecord(ns.DayKey(time()), Me(), lastCoin.mob)
	m.c = (m.c or 0) + amount
	Debug(" coin", amount, "from", lastCoin.mob)
	lastCoin = nil
end


--[[ Sales ]]--

-- itemID may be nil (AH mail gives only the name). received: copper for all `count`.
function ns.OnItemSold(itemID, name, count, received)
	if not db then
		return
	end
	if not itemID and name and not Secret(name) then
		itemID = db.names[name:lower()]
	end
	local lots = itemID and db.unsold[itemID]
	if not lots or #lots == 0 or not count or count <= 0 then
		return
	end
	local each = (received or 0) / count
	local left = count
	local me = Me()
	for pass = 1, 2 do
		local i = 1
		while left > 0 and i <= #lots do
			local lot = lots[i]
			if pass == 2 or lot.c == me then
				local take = min(left, lot.n)
				local byChar = db.days[lot.d] and db.days[lot.d][lot.c or "old"]
				local rec = byChar and byChar[lot.m] and byChar[lot.m].i[itemID]
				if rec then
					rec.s = rec.s + take
					rec.v = rec.v + floor(each * take + 0.5)
				end
				lot.n = lot.n - take
				left = left - take
				if lot.n <= 0 then
					tremove(lots, i)
				else
					i = i + 1
				end
			else
				i = i + 1
			end
		end
	end
	if #lots == 0 then
		db.unsold[itemID] = nil
	end
end


--[[ Reading the table (used by the Loot view) ]]--

function ns.MobName(key)
	if key == "?" then
		return "Unknown source"
	end
	local prefix, zone = key:match("^([gf]):(.*)$")
	if prefix == "g" then
		return "Gathering: " .. zone
	elseif prefix == "f" then
		return "Fishing: " .. zone
	end
	local mob = db and db.mobs[key]
	return (mob and mob.n) or nameCache[key] or ("Creature #" .. key)
end

function ns.MobZone(key)
	local mob = db and db.mobs[key]
	return mob and mob.z or ""
end

function ns.LootItem(id)
	return db and db.items[id]
end

-- everything looted between two times by these characters, added up.
-- chars: a list of character keys, or nil for every character (including "old").
-- mobs[key] = { k, c, n (items), s, v, i[itemID] = { n, s, v } }
function ns.LootTotals(from, to, chars)
	local fromKey = from == 0 and "0000" or ns.DayKey(from)
	local toKey = ns.DayKey(min(to, 2 ^ 31 - 1) - 1)
	local wanted
	if chars then
		wanted = {}
		for _, c in ipairs(chars) do wanted[c] = true end
		-- loot from before 2.1 has no character: show it on every character,
		-- so nothing the player already had ever looks gone
		wanted.old = true
	end
	local mobs = {}
	for day, byChar in pairs(db and db.days or {}) do
		if day >= fromKey and day <= toKey then
			for char, list in pairs(byChar) do
			if not wanted or wanted[char] then
			for key, m in pairs(list) do
				local t = mobs[key] or { k = 0, c = 0, n = 0, s = 0, v = 0, i = {} }
				mobs[key] = t
				t.k = t.k + (m.k or 0)
				t.c = t.c + (m.c or 0)
				for id, rec in pairs(m.i or {}) do
					local r = t.i[id] or { n = 0, s = 0, v = 0 }
					t.i[id] = r
					r.n, r.s, r.v = r.n + rec.n, r.s + rec.s, r.v + rec.v
					t.n, t.s, t.v = t.n + rec.n, t.s + rec.s, t.v + rec.v
				end
			end
			end
			end
		end
	end
	return mobs
end


--[[ Clearing old data (called from Core) ]]--

function ns.LootCountBefore(cutKey)
	local n = 0
	for day in pairs(db and db.days or {}) do
		if day < cutKey then n = n + 1 end
	end
	return n
end

function ns.LootClearBefore(cutKey)
	if not db then
		return
	end
	for day in pairs(db.days) do
		if day < cutKey then db.days[day] = nil end
	end
	for id, lots in pairs(db.unsold) do
		for i = #lots, 1, -1 do
			if lots[i].d < cutKey then tremove(lots, i) end
		end
		if #lots == 0 then db.unsold[id] = nil end
	end
	-- forget mobs and items nothing points to any more
	local usedMobs, usedItems = {}, {}
	for _, byChar in pairs(db.days) do
		for _, list in pairs(byChar) do
			for key, m in pairs(list) do
				usedMobs[key] = true
				for id in pairs(m.i or {}) do usedItems[id] = true end
			end
		end
	end
	for key in pairs(db.mobs) do
		if not usedMobs[key] then db.mobs[key] = nil end
	end
	for id in pairs(db.items) do
		if not usedItems[id] then db.items[id] = nil end
	end
	for name, id in pairs(db.names) do
		if not db.items[id] then db.names[name] = nil end
	end
end


--[[ Startup ]]--

ns.On("PLAYER_LOGIN", function()
	LedgerDB.loot = LedgerDB.loot or {}
	db = LedgerDB.loot
	db.mobs = db.mobs or {}
	db.items = db.items or {}
	db.names = db.names or {}
	db.days = db.days or {}
	db.unsold = db.unsold or {}
	-- v2.0 saved days[day][mob]; v2.1 saves days[day][character][mob].
	-- Old records had no character: they go under "old" (shown with All characters).
	for day, list in pairs(db.days) do
		for _, v in pairs(list) do
			if type(v) == "table" and v.k ~= nil then
				db.days[day] = { old = list }
			end
			break
		end
	end
end)
