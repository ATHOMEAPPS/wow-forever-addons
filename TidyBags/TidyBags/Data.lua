--[[
	TidyBags - Data.lua
	Saves every character's bags and bank (and the shared Warband bank) into
	TidyBagsData, and adds "how many do I have" lines to item tooltips.

	Saved format (TidyBagsData):
	  chars[key] = { name, class, money, bagTime, bankTime,
	                 bags = { [bagID] = container }, bank = { [bagID] = container },
	                 bankOrder = { bagID, ... } }
	  warband    = { time, bags = { [bagID] = container }, order = { bagID, ... } }
	  container  = { size = n, [slot] = { id, c = count, l = link, i = icon, q = quality } }
]]

local ADDON, ns = ...

ns.atBank = false
ns.me = nil


--[[ Tiny event helper shared by both files ]]--

local listeners = {}
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(listeners[event]) do
		fn(event, ...)
	end
end)

function ns.On(event, fn)
	if not listeners[event] then
		-- some events may not exist on this client; skip those quietly
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			return
		end
		listeners[event] = {}
	end
	tinsert(listeners[event], fn)
end


--[[ Bag lists ]]--

function ns.InventoryBags()
	local list = {}
	for bag = 0, NUM_TOTAL_BAG_FRAMES or NUM_BAG_SLOTS or 4 do
		tinsert(list, bag)
	end
	if KEYRING_CONTAINER and C_ActionBar and C_ActionBar.ShouldShowKeyring and C_ActionBar.ShouldShowKeyring() then
		tinsert(list, KEYRING_CONTAINER)
	end
	return list
end

-- the bank bags this character has bought, in Blizzard's order (live only)
function ns.LiveBankBags(bankType)
	local list = {}
	if C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.CanViewBank(bankType) then
		for _, tab in ipairs(C_Bank.FetchPurchasedBankTabData(bankType) or {}) do
			tinsert(list, tab.ID)
		end
	end
	return list
end


--[[ Reading the live game ]]--

-- quest items: the game's quest flag, an item that starts a quest, or the
-- "Quest" item class
function ns.IsQuestItem(id, questInfo)
	if questInfo and (questInfo.isQuestItem or questInfo.questID) then
		return true
	end
	if id and C_Item and C_Item.GetItemInfoInstant and Enum.ItemClass then
		local classID = select(6, C_Item.GetItemInfoInstant(id))
		return classID == Enum.ItemClass.Questitem
	end
	return false
end

local function ReadSlot(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if info and info.itemID then
		local isQuest = ns.IsQuestItem(info.itemID, C_Container.GetContainerItemQuestInfo(bag, slot))
		return { id = info.itemID, c = info.stackCount or 1, l = info.hyperlink, i = info.iconFileID, q = info.quality,
			qi = isQuest or nil }
	end
end

local function ReadContainer(bag)
	local size = C_Container.GetContainerNumSlots(bag) or 0
	local container = { size = size }
	for slot = 1, size do
		container[slot] = ReadSlot(bag, slot)
	end
	return container
end


--[[ Characters ]]--

local function ClassColored(char)
	local color = char and char.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.class]
	local name = char and char.name or "?"
	if color and color.colorStr then
		return "|c" .. color.colorStr .. name .. "|r"
	end
	return name
end
ns.ClassColored = ClassColored

function ns.GetChar(key)
	return TidyBagsData.chars[key or ns.me]
end

function ns.SortedCharKeys()
	local keys = {}
	for key in pairs(TidyBagsData.chars) do
		tinsert(keys, key)
	end
	local chars = TidyBagsData.chars
	sort(keys, function(a, b)
		if a == ns.me then return true end
		if b == ns.me then return false end
		return (chars[a].name or a) < (chars[b].name or b)
	end)
	return keys
end

function ns.ForgetChar(key)
	if key and key ~= ns.me then
		TidyBagsData.chars[key] = nil
		ns.Invalidate(key)
	end
end


--[[ Saving ]]--

function ns.SaveInventory()
	local char = ns.GetChar()
	if not char then
		return
	end
	-- the backpack always has slots; 0 means bag data isn't loaded (login, logout).
	-- Saving then would wipe this character's bags (seen in-game 2026-11-23).
	if (C_Container.GetContainerNumSlots(0) or 0) == 0 then
		return
	end
	char.bags = {}
	for _, bag in ipairs(ns.InventoryBags()) do
		char.bags[bag] = ReadContainer(bag)
	end
	char.money = GetMoney()
	char.bagTime = time()
	ns.Invalidate(ns.me)
end

-- quest items in a set of saved containers: { [itemID] = { count, link } }
local function QuestItems(containers)
	local found = {}
	for _, container in pairs(containers or {}) do
		for slot = 1, container.size or 0 do
			local item = container[slot]
			if item and item.qi then
				local entry = found[item.id] or { 0, item.l }
				entry[1] = entry[1] + (item.c or 1)
				found[item.id] = entry
			end
		end
	end
	return found
end

-- warn when a quest item shows up in a bank it wasn't in before
local function WarnNewQuestItems(before, after, where)
	if not before or (TidyBagsDB and TidyBagsDB.questWarn == false) then
		return -- first time this bank was saved: nothing to compare against
	end
	local old = QuestItems(before)
	for id, entry in pairs(QuestItems(after)) do
		if entry[1] > (old[id] and old[id][1] or 0) then
			local link = entry[2] or ("item " .. id)
			print("|cff33ff99TidyBags|r: |cffffd100Quest item put in the " .. where .. ":|r " .. link)
			UIErrorsFrame:AddMessage("Quest item put in the " .. where .. "!", 1, 0.82, 0)
			PlaySound(SOUNDKIT.RAID_WARNING)
		end
	end
end

function ns.SaveBank()
	if not ns.atBank or not C_Bank then
		return
	end

	local char = ns.GetChar()
	if char and C_Bank.CanViewBank(Enum.BankType.Character) then
		local before = char.bank
		char.bank, char.bankOrder = {}, ns.LiveBankBags(Enum.BankType.Character)
		for _, bag in ipairs(char.bankOrder) do
			char.bank[bag] = ReadContainer(bag)
		end
		char.bankTime = time()
		ns.Invalidate(ns.me)
		WarnNewQuestItems(before, char.bank, "bank")
	end

	if C_Bank.CanViewBank(Enum.BankType.Account) then
		local before = TidyBagsData.warband and TidyBagsData.warband.bags
		local warband = { bags = {}, order = ns.LiveBankBags(Enum.BankType.Account), time = time() }
		for _, bag in ipairs(warband.order) do
			warband.bags[bag] = ReadContainer(bag)
		end
		TidyBagsData.warband = warband
		ns.Invalidate("warband")
		WarnNewQuestItems(before, warband.bags, "Warband bank")
	end
end


--[[ Item counts (index is rebuilt only when that character's data changes) ]]--

local index = {}

function ns.Invalidate(key)
	index[key] = nil
end

local function Tally(containers, out)
	for _, container in pairs(containers or {}) do
		for slot = 1, container.size or 0 do
			local item = container[slot]
			if item and item.id then
				out[item.id] = (out[item.id] or 0) + (item.c or 1)
			end
		end
	end
	return out
end

local function GetIndex(key)
	if not index[key] then
		if key == "warband" then
			local warband = TidyBagsData.warband
			index[key] = { bank = Tally(warband and warband.bags, {}) }
		else
			local char = TidyBagsData.chars[key] or {}
			index[key] = { bags = Tally(char.bags, {}), bank = Tally(char.bank, {}) }
		end
	end
	return index[key]
end

local function AddCounts(tip, id)
	local lines, total = {}, 0

	for _, key in ipairs(ns.SortedCharKeys()) do
		local idx = GetIndex(key)
		local bags, bank = idx.bags[id] or 0, idx.bank[id] or 0
		if bags + bank > 0 then
			local parts = {}
			if bags > 0 then tinsert(parts, "Bags " .. bags) end
			if bank > 0 then tinsert(parts, "Bank " .. bank) end
			tinsert(lines, { ClassColored(TidyBagsData.chars[key]), table.concat(parts, ", ") })
			total = total + bags + bank
		end
	end

	local warband = GetIndex("warband").bank[id] or 0
	if warband > 0 then
		tinsert(lines, { "|cff66bbffWarband bank|r", tostring(warband) })
		total = total + warband
	end

	if total == 0 then
		return
	end

	tip:AddLine(" ")
	for _, line in ipairs(lines) do
		tip:AddDoubleLine(line[1], line[2], 1, 1, 1, 1, 1, 1)
	end
	if #lines > 1 then
		tip:AddDoubleLine("Total", tostring(total), 1, 0.82, 0, 1, 0.82, 0)
	end
	tip:Show()
end

local function OnTooltipItem(tip, data)
	if not TidyBagsDB or not TidyBagsDB.tooltipCounts then
		return
	end
	if tip ~= GameTooltip and tip ~= ItemRefTooltip then
		return
	end
	if tip.IsForbidden and tip:IsForbidden() then
		return
	end
	local id = data and data.id
	if not id or (issecretvalue and issecretvalue(id)) then
		return
	end
	pcall(AddCounts, tip, id)
end


--[[ Startup and saving triggers ]]--

ns.On("PLAYER_LOGIN", function()
	TidyBagsData = TidyBagsData or {}
	TidyBagsData.chars = TidyBagsData.chars or {}

	-- saved under the character's permanent ID, so a name or surname change can't
	-- create a second copy (which would double-count items)
	ns.me = UnitGUID("player")

	-- on this client the second value is the character's surname (Bagnon does the same)
	local name, extra = UnitFullName("player")
	local char = TidyBagsData.chars[ns.me] or {}
	char.name = (extra and extra ~= "") and (name .. " " .. extra) or name
	char.class = select(2, UnitClass("player"))
	TidyBagsData.chars[ns.me] = char

	ns.SaveInventory()

	if TooltipDataProcessor and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
	end
end)

ns.On("BAG_UPDATE_DELAYED", function()
	ns.SaveInventory()
	ns.SaveBank()
end)

ns.On("PLAYER_MONEY", function()
	local char = ns.GetChar()
	if char then
		char.money = GetMoney()
	end
end)

for _, event in ipairs({ "BANK_TABS_CHANGED", "PLAYERBANKSLOTS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" }) do
	ns.On(event, function()
		ns.SaveBank()
	end)
end
