--[[
	TidyBags - TidyBags.lua (windows)

	TAINT RULES (why Bagnon got "blocked from an action"):
	Blizzard's item click code (ContainerFrameItemButton_OnClick) reads fields and
	methods off the button: GetBagID(), bagID, count, hasItem ... If addon code ever
	WRITES a Lua field or method onto a LIVE item button, that value is tainted and
	the click that uses the item is blocked.

	So LIVE buttons (ContainerFrameItemButtonTemplate) are never given fields:
	  - bag id  -> parent frame :SetID(bag)  (C method; Blizzard's GetBagID() falls
	               back to self:GetParent():GetID())
	  - slot    -> button:SetID(slot)        (C method)
	  - visuals -> only textures / font strings / C methods
	  - our data -> side tables (liveBag[button])
	Blizzard's own frames (ContainerFrames, BankFrame, the buy button) are only
	reparented / repositioned (C methods), never given fields.

	SAVED-view buttons (other characters, bank when you're not at the bank) are our
	own plain ItemButtons; they can't use items, only show them.

	Buying a bank slot is a restricted action, so the Buy button IS Blizzard's own
	button (BankPanel.PurchasePrompt.TabCostFrame.PurchaseButton) moved into our
	window. It reads the bank type from the "overrideBankType" attribute.
]]

local ADDON, ns = ...

local BUTTON_SIZE = 37
local SPACING = 4
local PADDING = 10
local HEADER = 58     -- title row + search row
local FOOTER = 36     -- character button + money
local SLOTROW = 40    -- bank bag-slot row (bank only, at the bank)
local SLOT_SIZE = 30
local MIN_WIDTH = 330

local CHARACTER = Enum.BankType and Enum.BankType.Character or 0
local ACCOUNT = Enum.BankType and Enum.BankType.Account or 2

local DEFAULTS = {
	columns = 10, bankColumns = 14, scale = 1, bankScale = 1,
	autoSort = false, autoSortBank = false, tooltipCounts = true,
	questSection = true, questGlow = true, questWarn = true, bagTypes = true,
	pos = {},
}

local db
local liveBag = {}     -- liveBag[liveButton] = bag id (never stored on the button)
local savedItem = {}   -- savedItem[savedButton] = saved item table or false
local savedContainer = {} -- savedContainer[savedButton] = the saved container it belongs to
local questGlow = {}   -- questGlow[button] = glow texture (side table, never on the button)
local buttonCount = 0
local syncing = false
local inventory, bank  -- the two windows

local function Print(msg)
	print("|cff33ff99TidyBags|r: " .. msg)
end

local function MoneyText(copper)
	copper = copper or 0
	if GetMoneyString then
		return GetMoneyString(copper, true)
	end
	return GetCoinTextureString(copper)
end

local function QualityColor(quality)
	if C_Item and C_Item.GetItemQualityColor then
		return C_Item.GetItemQualityColor(quality)
	elseif GetItemQualityColor then
		return GetItemQualityColor(quality)
	end
	return 1, 1, 1
end

local function ItemName(id, link)
	if id and C_Item and C_Item.GetItemNameByID then
		local name = C_Item.GetItemNameByID(id)
		if name then
			return name
		end
	end
	if link then
		return link:match("%[(.-)%]")
	end
end


-- bright gold glow around quest items. CreateTexture is a C method and the
-- texture is kept in a side table, so live buttons stay untainted.
local function SetQuestGlow(b, on)
	local glow = questGlow[b]
	if not glow then
		if not on then
			return
		end
		glow = b:CreateTexture(nil, "OVERLAY", nil, 7)
		glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		glow:SetBlendMode("ADD")
		glow:SetVertexColor(1, 0.82, 0)
		glow:SetPoint("CENTER")
		glow:SetSize(BUTTON_SIZE * 1.8, BUTTON_SIZE * 1.8)
		questGlow[b] = glow
	end
	glow:SetShown(on and true or false)
end

-- Profession bags. GetContainerNumFreeSlots returns the bag's type (bagFamily);
-- 0 is a normal bag. Forever uses its own numbers, so only numbers read in game
-- go in FOREVER_BAG_TYPES (see tmp/resources/bag-types.md). Any other non-zero
-- type still gets a colour from PALETTE, so every kind of bag looks different.
local FOREVER_BAG_TYPES = {
	[33554432] = { name = "Leatherworking bag", color = { 0.95, 0.45, 0.10 } }, -- Apprentice's Skinning Satchel, seen 2026-11-23
}
local PALETTE = {
	{ 0.20, 0.85, 0.25 }, { 0.75, 0.55, 0.30 }, { 0.70, 0.35, 1.00 }, { 0.95, 0.85, 0.20 },
	{ 1.00, 0.35, 0.60 }, { 0.35, 0.80, 0.90 }, { 0.25, 0.55, 1.00 }, { 0.85, 0.85, 0.85 },
}

local function BagType(family)
	if type(family) ~= "number" or family == 0 then
		return nil
	end
	local known = FOREVER_BAG_TYPES[family]
	if known then
		return known
	end
	return { name = "Bag type " .. family, color = PALETTE[family % #PALETTE + 1] }
end
ns.BagType = BagType

-- the icon of the bag item itself, for a bag the player is wearing
local function BagIcon(bag)
	local ok, inv = pcall(C_Container.ContainerIDToInventoryID, bag)
	return ok and inv and GetInventoryItemTexture("player", inv) or nil
end
ns.BagIcon = BagIcon

-- Every slot in a profession bag gets a light colour wash; empty slots also
-- show the bag's own icon, faded. Textures live in
-- a side table and are changed only with C methods, so live buttons stay untainted.
local bagTypeLook = {}  -- bagTypeLook[button] = { wash, icon }
local function SetBagTypeLook(b, family, empty, bagIcon)
	local t = db.bagTypes and BagType(family)
	local look = bagTypeLook[b]
	if not look then
		if not t then
			return
		end
		local wash = b:CreateTexture(nil, "ARTWORK", nil, 6)
		wash:SetPoint("TOPLEFT", 2, -2)
		wash:SetPoint("BOTTOMRIGHT", -2, 2)
		local icon = b:CreateTexture(nil, "ARTWORK", nil, 7)
		icon:SetPoint("TOPLEFT", 6, -6)
		icon:SetPoint("BOTTOMRIGHT", -6, 6)
		icon:SetAlpha(0.45)
		look = { wash = wash, icon = icon }
		bagTypeLook[b] = look
	end
	if not t then
		look.wash:Hide()
		look.icon:Hide()
		return
	end
	local r, g, bl = t.color[1], t.color[2], t.color[3]
	look.wash:SetColorTexture(r, g, bl, empty and 0.30 or 0.15)
	look.wash:Show()
	if empty and bagIcon then
		look.icon:SetTexture(bagIcon)
		look.icon:Show()
	else
		look.icon:Hide()
	end
end

local function SavedIsQuest(item)
	return item and (item.qi or ns.IsQuestItem(item.id)) or false
end


--[[ Window base ]]--

local Window = {}

function Window:IsMine()
	return self.owner == nil or self.owner == ns.me
end

function Window:IsLive()
	if not self:IsMine() then
		return false
	end
	if self.kind == "inventory" then
		return true
	end
	return ns.atBank and C_Bank and C_Bank.CanViewBank(self.bankType) or false
end

function Window:Matches(id, link, name, isQuest)
	if self.searchText == "" then
		return true
	end
	if self.searchText == "quest" then
		return isQuest and true or false
	end
	name = name or ItemName(id, link)
	if not name then
		return true -- not loaded yet; GET_ITEM_INFO_RECEIVED will refresh
	end
	return name:lower():find(self.searchText, 1, true) ~= nil
end

-- the live bags this window shows
function Window:LiveBags()
	if self.kind == "inventory" then
		return ns.InventoryBags()
	end
	return ns.LiveBankBags(self.bankType)
end

-- the saved containers this window shows, in order: { {bag, container}, ... }
function Window:SavedContainers()
	local list = {}
	local containers, order

	if self.kind == "inventory" then
		local char = ns.GetChar(self.owner)
		containers = char and char.bags
	elseif self.bankType == ACCOUNT then
		local warband = TidyBagsData.warband
		containers, order = warband and warband.bags, warband and warband.order
	else
		local char = ns.GetChar(self.owner)
		containers, order = char and char.bank, char and char.bankOrder
	end

	if not containers then
		return list
	end

	if not order then
		order = {}
		for bag in pairs(containers) do
			tinsert(order, bag)
		end
		sort(order, function(a, b)
			if a < 0 then return false end -- keyring last
			if b < 0 then return true end
			return a < b
		end)
	end

	for _, bag in ipairs(order) do
		if containers[bag] then
			tinsert(list, { bag, containers[bag] })
		end
	end
	return list
end


--[[ Live item buttons (Blizzard template - follow the TAINT RULES) ]]--

function Window:GetBagFrame(bag)
	local f = self.bagFrames[bag]
	if not f then
		f = CreateFrame("Frame", nil, self.content)
		f:SetID(bag) -- Blizzard's GetBagID() reads this
		f:SetAllPoints(self.content)
		self.bagFrames[bag] = f
	end
	return f
end

local function DepositToWarband(button, mouseButton)
	-- At the bank, Blizzard's right-click deposits into the bank type its own (hidden)
	-- bank window has selected, which is the character bank. When our bank window
	-- shows the Warband bank, deposit there instead. Runs in PreClick, which is a
	-- separate handler, so it can't taint Blizzard's OnClick.
	if mouseButton ~= "RightButton" or IsModifiedClick() or not ns.atBank then
		return
	end
	if not (bank and bank:IsShown() and bank.bankType == ACCOUNT and bank:IsLive()) then
		return
	end
	if BankFrame and BankFrame.GetActiveBankType and BankFrame:GetActiveBankType() == ACCOUNT then
		return
	end
	local bag = liveBag[button]
	if bag and C_Bank.CanUseBank(ACCOUNT) then
		C_Container.UseContainerItem(bag, button:GetID(), nil, ACCOUNT)
	end
end

function Window:GetLiveButton(bag, slot)
	self.live[bag] = self.live[bag] or {}
	local b = self.live[bag][slot]
	if not b then
		buttonCount = buttonCount + 1
		b = CreateFrame("ItemButton", "TidyBagsItem" .. buttonCount, self:GetBagFrame(bag), "ContainerFrameItemButtonTemplate")
		b:SetID(slot)
		liveBag[b] = bag
		if self.kind == "inventory" then
			b:SetScript("PreClick", DepositToWarband)
		end
		self.live[bag][slot] = b
	end
	return b
end

function Window:UpdateLiveButton(b, bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local texture = info and info.iconFileID
	local quality = info and info.quality

	SetItemButtonTexture(b, texture) -- empty slot gets Blizzard's slot background
	if b.EmptyBagIcon then
		b.EmptyBagIcon:Hide()
	end

	local count = info and info.stackCount or 0
	if count > 1 then
		b.Count:SetText(count)
		b.Count:Show()
	else
		b.Count:Hide()
	end

	SetItemButtonDesaturated(b, info and info.isLocked or false)

	if texture and quality and quality >= 2 then
		local r, g, bl = QualityColor(quality)
		b.IconBorder:SetVertexColor(r, g, bl)
		b.IconBorder:Show()
	else
		b.IconBorder:Hide()
	end

	local quest = C_Container.GetContainerItemQuestInfo(bag, slot)
	b:UpdateQuestItem(quest and quest.isQuestItem, quest and quest.questID, quest and quest.isActive)
	local isQuest = texture ~= nil and ns.IsQuestItem(info.itemID, quest)
	SetQuestGlow(b, db.questGlow and isQuest)
	SetBagTypeLook(b, self.bagFamily[bag], texture == nil, self.bagIcon[bag])
	b:UpdateNewItem(quality)
	b:UpdateJunkItem(quality, info and info.hasNoValue)

	local cooldown = b.Cooldown or _G[b:GetName() .. "Cooldown"]
	if texture and cooldown then
		local start, duration, enable = C_Container.GetContainerItemCooldown(bag, slot)
		CooldownFrame_Set(cooldown, start, duration, enable)
		local off = enable == 0 or enable == false
		if duration and duration > 0 and off then
			SetItemButtonTextureVertexColor(b, 0.4, 0.4, 0.4)
		else
			SetItemButtonTextureVertexColor(b, 1, 1, 1)
		end
	elseif cooldown then
		cooldown:Hide()
	end

	b.searchOverlay:SetShown(texture ~= nil and not self:Matches(info.itemID, info.hyperlink, info.itemName, isQuest))

	if GameTooltip:IsOwned(b) then
		if texture then
			b:UpdateTooltip()
		else
			GameTooltip:Hide()
		end
	end
end


--[[ Saved-view item buttons (our own, display only) ]]--

local function SavedOnEnter(self)
	local item = savedItem[self]
	if item and item.l then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(item.l)
		GameTooltip:Show()
	end
end

local function SavedOnClick(self)
	local item = savedItem[self]
	if item and item.l and IsModifiedClick() then
		HandleModifiedItemClick(item.l)
	end
end

function Window:GetSavedButton(i)
	local b = self.saved[i]
	if not b then
		b = CreateFrame("ItemButton", nil, self.content)
		b:SetSize(BUTTON_SIZE, BUTTON_SIZE)
		b.emptyBackgroundAtlas = "bags-item-slot64" -- our own button, fields are fine here
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnEnter", SavedOnEnter)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:SetScript("OnClick", SavedOnClick)
		self.saved[i] = b
	end
	return b
end

function Window:UpdateSavedButton(b)
	local item = savedItem[b]
	SetItemButtonTexture(b, item and item.i or nil)

	if item and (item.c or 1) > 1 then
		b.Count:SetText(item.c)
		b.Count:Show()
	else
		b.Count:Hide()
	end

	if item and item.q and item.q >= 2 then
		local r, g, bl = QualityColor(item.q)
		b.IconBorder:SetVertexColor(r, g, bl)
		b.IconBorder:Show()
	else
		b.IconBorder:Hide()
	end

	local isQuest = SavedIsQuest(item)
	SetQuestGlow(b, db.questGlow and isQuest)
	local container = savedContainer[b]
	SetBagTypeLook(b, container and container.f, not (item and item.i), container and container.fi)
	b.searchOverlay:SetShown(item and not self:Matches(item.id, item.l, nil, isQuest) or false)
end


--[[ Layout and update ]]--

function Window:Columns()
	return self.kind == "bank" and db.bankColumns or db.columns
end

function Window:Layout()
	if not self:IsShown() then
		return
	end

	-- Only hide buttons that are leaving. Hiding a live button runs Blizzard's
	-- OnHide (closes an open stack-split box, drops the tooltip), so buttons that
	-- stay are never hidden and re-shown.
	local keep = {}
	wipe(self.shownLive)
	wipe(self.shownSaved)

	-- 1. collect every slot, split into quest items and everything else
	local questList, restList = {}, {}
	local splitQuests = db.questSection

	self.isLive = self:IsLive()
	wipe(self.bagFamily)
	wipe(self.bagIcon)
	if self.isLive then
		for _, bag in ipairs(self:LiveBags()) do
			local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
			self.bagFamily[bag] = ok and family or nil
			self.bagIcon[bag] = BagType(self.bagFamily[bag]) and BagIcon(bag) or nil
			for slot = 1, C_Container.GetContainerNumSlots(bag) do
				local b = self:GetLiveButton(bag, slot)
				local entry = { b, bag, slot }
				tinsert(self.shownLive, entry)
				local isQuest = splitQuests and ns.IsQuestItem(C_Container.GetContainerItemID(bag, slot),
					C_Container.GetContainerItemQuestInfo(bag, slot))
				tinsert(isQuest and questList or restList, b)
			end
		end
	else
		local n = 0
		for _, entry in ipairs(self:SavedContainers()) do
			local container = entry[2]
			for slot = 1, container.size or 0 do
				n = n + 1
				local b = self:GetSavedButton(n)
				local item = container[slot] or false
				savedItem[b] = item
				savedContainer[b] = container
				tinsert(self.shownSaved, b)
				tinsert((splitQuests and SavedIsQuest(item)) and questList or restList, b)
			end
		end
	end

	-- 2. place them: "Quest items" section first (only if there are any)
	local cols = self:Columns()
	local y, i, widest = 0, 0, 0
	local function PlaceSection(list, header)
		if header then
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", self.content, "TOPLEFT", 2, -y)
			header:Show()
			y = y + 16
		end
		for n, b in ipairs(list) do
			local col, row = (n - 1) % cols, floor((n - 1) / cols)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", self.content, "TOPLEFT", col * (BUTTON_SIZE + SPACING), -(y + row * (BUTTON_SIZE + SPACING)))
			b:Show()
			keep[b] = true
			i = i + 1
		end
		if #list > 0 then
			y = y + ceil(#list / cols) * (BUTTON_SIZE + SPACING) + 4
			widest = max(widest, min(cols, #list))
		end
	end

	self.questHeader:Hide()
	self.itemsHeader:Hide()
	if #questList > 0 then
		PlaceSection(questList, self.questHeader)
		PlaceSection(restList, self.itemsHeader)
	else
		PlaceSection(restList)
	end

	for _, slots in pairs(self.live) do
		for _, b in pairs(slots) do
			if not keep[b] and b:IsShown() then
				b:Hide()
			end
		end
	end
	for _, b in ipairs(self.saved) do
		if not keep[b] and b:IsShown() then
			b:Hide()
		end
	end

	local width = max(widest, 1) * (BUTTON_SIZE + SPACING) - SPACING
	local height = max(y - SPACING - 4, 20)
	self.content:SetSize(width, height)
	self.empty:SetShown(i == 0)

	local slotRow = self.kind == "bank" and self.isLive and SLOTROW or 0
	self:SetSize(max(width + PADDING * 2, MIN_WIDTH), HEADER + height + slotRow + FOOTER)

	self:RefreshControls()
	self:UpdateAll()
end

function Window:UpdateAll()
	if not self:IsShown() then
		return
	end

	local free, total = 0, 0
	for _, entry in ipairs(self.shownLive) do
		local b, bag, slot = entry[1], entry[2], entry[3]
		self:UpdateLiveButton(b, bag, slot)
		if bag ~= KEYRING_CONTAINER then
			total = total + 1
			if not C_Container.GetContainerItemID(bag, slot) then
				free = free + 1
			end
		end
	end
	for _, b in ipairs(self.shownSaved) do
		self:UpdateSavedButton(b)
		total = total + 1
		if not savedItem[b] then
			free = free + 1
		end
	end
	self.freeText:SetFormattedText("%d / %d free", free, total)

	if self.kind == "inventory" then
		local char = ns.GetChar(self.owner)
		self.money:SetText(MoneyText(self:IsMine() and GetMoney() or (char and char.money)))
	end

	if self.kind == "bank" then
		self:UpdateBagSlots()
	end
end

function Window:UpdateLiveSlot(bag, slot)
	if self:IsShown() and self.isLive and self.live[bag] and self.live[bag][slot] then
		self:UpdateLiveButton(self.live[bag][slot], bag, slot)
	end
end

-- titles, owner button, which buttons are visible
function Window:RefreshControls()
	local char = ns.GetChar(self.owner)
	local who = ns.ClassColored(char)

	if self.kind == "inventory" then
		self.title:SetText(self:IsMine() and "Bags" or (who .. "'s bags"))
	else
		local what = self.bankType == ACCOUNT and "Warband bank" or (self:IsMine() and "Bank" or (who .. "'s bank"))
		local when = ""
		if not self.isLive then
			local saved = self.bankType == ACCOUNT and TidyBagsData.warband or char
			local t = saved and (self.bankType == ACCOUNT and saved.time or saved.bankTime)
			when = t and ("  |cff999999(saved " .. date("%b %d %H:%M", t) .. ")|r") or "  |cff999999(never opened)|r"
		end
		self.title:SetText(what .. when)
		self.tabChar:SetEnabled(self.bankType ~= CHARACTER)
		self.tabWarband:SetEnabled(self.bankType ~= ACCOUNT)
	end

	self.ownerButton:SetText(who)
	if self.sort then
		self.sort:SetShown(self.isLive)
	end
end


--[[ Character menu (bottom left) ]]--

local function OpenOwnerMenu(button)
	local w = button:GetParent()
	MenuUtil.CreateContextMenu(button, function(_, root)
		root:CreateTitle("Show character")
		for _, key in ipairs(ns.SortedCharKeys()) do
			local char = TidyBagsData.chars[key]
			root:CreateRadio(ns.ClassColored(char),
				function(k) return (w.owner or ns.me) == k end,
				function(k)
					w.owner = (k ~= ns.me) and k or nil
					w:Layout()
				end, key)
		end

		local others = {}
		for _, key in ipairs(ns.SortedCharKeys()) do
			if key ~= ns.me then
				tinsert(others, key)
			end
		end
		if #others > 0 then
			root:CreateDivider()
			local forget = root:CreateButton("Forget a character")
			for _, key in ipairs(others) do
				local name = TidyBagsData.chars[key].name or "?"
				forget:CreateButton(ns.ClassColored(TidyBagsData.chars[key]), function()
					ns.ForgetChar(key)
					for _, win in ipairs({ inventory, bank }) do
						if win.owner == key then
							win.owner = nil
						end
						win:Layout()
					end
					Print("forgot " .. name)
				end)
			end
		end
	end)
end


--[[ Building a window ]]--

local function CreateWindow(kind, globalName)
	local w = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
	Mixin(w, Window) -- our own frame, so fields and methods are fine here
	w.kind = kind
	w.live, w.saved, w.bagFrames = {}, {}, {}
	w.shownLive, w.shownSaved = {}, {}
	w.bagFamily = {} -- bagFamily[bag] = bag type number of each live bag (set in Layout)
	w.bagIcon = {}   -- bagIcon[bag] = icon of a profession bag (set in Layout)
	w.searchText = ""
	w.bankType = CHARACTER

	w:Hide()
	w:SetFrameStrata("MEDIUM")
	w:SetToplevel(true)
	w:SetClampedToScreen(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:RegisterForDrag("LeftButton")
	w:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	w:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
	w:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	tinsert(UISpecialFrames, globalName) -- ESC closes it

	w:SetScript("OnDragStart", w.StartMoving)

	-- resize grip (bottom right): dragging it changes the window's scale, so the
	-- slots, icons and text all grow and shrink together. The top-left corner stays put.
	local scaleKey = kind == "bank" and "bankScale" or "scale"
	local grip = CreateFrame("Button", nil, w)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetFrameLevel(w:GetFrameLevel() + 10)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	local startX, startWidth, startScale, left, top
	local function Resizing()
		local x = GetCursorPosition()
		local scale = startScale * (startWidth + (x - startX)) / startWidth
		scale = max(0.5, min(2, floor(scale * 100 + 0.5) / 100))
		w:SetScale(scale)
		local eff = w:GetEffectiveScale()
		w:ClearAllPoints()
		w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / eff, top / eff)
		db[scaleKey] = scale
	end
	grip:SetScript("OnMouseDown", function()
		local eff = w:GetEffectiveScale()
		startX = GetCursorPosition()
		startWidth = w:GetWidth() * eff
		startScale = w:GetScale()
		left, top = w:GetLeft() * eff, w:GetTop() * eff
		grip:SetScript("OnUpdate", Resizing)
	end)
	grip:SetScript("OnMouseUp", function()
		grip:SetScript("OnUpdate", nil)
		local point, _, relPoint, x, y = w:GetPoint()
		db.pos[kind] = { point, relPoint, x, y }
	end)
	grip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize")
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", GameTooltip_Hide)
	w:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.pos[kind] = { point, relPoint, x, y }
	end)

	-- title row
	w.title = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	w.title:SetPoint("TOPLEFT", PADDING + 2, -11)
	w.title:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	w.freeText = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	w.freeText:SetPoint("RIGHT", close, "LEFT", -2, 0)

	-- search row
	w.search = CreateFrame("EditBox", globalName .. "Search", w, "SearchBoxTemplate")
	w.search:SetHeight(20)
	w.search:SetPoint("TOPLEFT", PADDING + 6, -31)
	w.search:SetPoint("TOPRIGHT", -PADDING - 120, -31)
	w.search:HookScript("OnTextChanged", function(self)
		w.searchText = (self:GetText() or ""):lower()
		w:UpdateAll()
	end)

	local function SortNow()
		if InCombatLockdown() or not w.isLive then
			return
		end
		if kind == "inventory" then
			if C_Container.SortBags then
				C_Container.SortBags()
			end
		elseif C_Container.SortBank then
			C_Container.SortBank(w.bankType)
		elseif C_Container.SortBankBags then
			C_Container.SortBankBags()
		end
	end
	w.SortNow = SortNow

	local settingKey = kind == "inventory" and "autoSort" or "autoSortBank"

	w.sort = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	w.sort:SetSize(50, 22)
	w.sort:SetPoint("TOPRIGHT", -PADDING, -30)
	w.sort:SetText("Sort")
	w.sort:SetScript("OnClick", SortNow)

	w.auto = CreateFrame("CheckButton", nil, w, "UICheckButtonTemplate")
	w.auto:SetSize(24, 24)
	w.auto:SetPoint("TOPRIGHT", -PADDING - 88, -29)
	local autoLabel = w.auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	autoLabel:SetPoint("LEFT", w.auto, "RIGHT", 0, 1)
	autoLabel:SetText("Auto")
	w.auto:SetScript("OnClick", function(self)
		db[settingKey] = self:GetChecked() and true or false
		if db[settingKey] then
			SortNow()
		end
	end)
	w.auto:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Auto sort")
		GameTooltip:AddLine("Sort every time this window opens (not in combat).", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	w.auto:SetScript("OnLeave", GameTooltip_Hide)

	-- item grid
	w.content = CreateFrame("Frame", nil, w)
	w.content:SetPoint("TOPLEFT", PADDING, -HEADER)
	w.content:SetSize(1, 1)

	w.questHeader = w.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	w.questHeader:SetText("Quest items")
	w.questHeader:SetTextColor(1, 0.82, 0)
	w.itemsHeader = w.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	w.itemsHeader:SetText("Everything else")
	w.itemsHeader:SetTextColor(0.7, 0.7, 0.7)

	w.empty = w.content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	w.empty:SetPoint("TOPLEFT", 4, -2)
	w.empty:SetText("Nothing saved yet.")

	-- footer: character button (bottom left) and money (bottom right)
	w.ownerButton = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	w.ownerButton:SetSize(130, 22)
	w.ownerButton:SetPoint("BOTTOMLEFT", PADDING, 9)
	w.ownerButton:SetScript("OnClick", OpenOwnerMenu)
	w.ownerButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Character")
		GameTooltip:AddLine("Pick whose items to show. Other characters show what was saved the last time they logged in or opened their bank.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	w.ownerButton:SetScript("OnLeave", GameTooltip_Hide)

	w:SetScript("OnShow", function(self)
		PlaySound(kind == "inventory" and SOUNDKIT.IG_BACKPACK_OPEN or SOUNDKIT.IG_MAINMENU_OPEN)
		self:Layout()
		if db[settingKey] then
			SortNow()
		end
	end)

	return w
end


--[[ Inventory window ]]--

local function BuildInventory()
	local w = CreateWindow("inventory", "TidyBagsFrame")

	w.money = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	w.money:SetPoint("BOTTOMRIGHT", -PADDING - 14, 14)

	-- mouse over money: everyone's gold
	local moneyHover = CreateFrame("Frame", nil, w)
	moneyHover:SetAllPoints(w.money)
	moneyHover:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Gold")
		local total = 0
		for _, key in ipairs(ns.SortedCharKeys()) do
			local char = TidyBagsData.chars[key]
			local money = key == ns.me and GetMoney() or (char.money or 0)
			total = total + money
			GameTooltip:AddDoubleLine(ns.ClassColored(char), MoneyText(money), 1, 1, 1, 1, 1, 1)
		end
		GameTooltip:AddDoubleLine("Total", MoneyText(total), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:Show()
	end)
	moneyHover:SetScript("OnLeave", GameTooltip_Hide)

	-- Bank button next to the character button: look at the bank from anywhere
	local bankButton = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	bankButton:SetSize(56, 22)
	bankButton:SetPoint("LEFT", w.ownerButton, "RIGHT", 4, 0)
	bankButton:SetText("Bank")
	bankButton:SetScript("OnClick", function()
		if bank:IsShown() then
			bank:Hide()
		else
			bank.owner = w.owner
			bank:Show()
		end
	end)

	w:HookScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE)
		if not syncing then
			-- closed by us (X / ESC): close Blizzard's bags too, next frame
			C_Timer.After(0, function()
				if ns.AnyInventoryBagOpen() then
					CloseAllBags()
				end
			end)
		end
	end)

	return w
end


--[[ Bank window ]]--

local function SlotContainer(bankType)
	return bankType == ACCOUNT and Enum.BagIndex.Accountbanktab or Enum.BagIndex.Characterbanktab
end

function Window:UpdateBagSlots()
	local show = self.isLive
	self.slotLabel:SetShown(show)
	self.costText:SetShown(false)
	if self.buy then
		self.buy:Hide()
	end
	for _, b in ipairs(self.slotButtons) do
		b:Hide()
	end
	if not show then
		return
	end

	local bankType = self.bankType
	local maxTabs = C_Bank.FetchMaxNumBankTabs(bankType) or 0
	local owned = C_Bank.FetchPurchasedBankTabData(bankType) or {}
	local container = SlotContainer(bankType)

	-- slot 1 is the bank itself; 2..max are bag slots
	local prev
	for n = 2, maxTabs do
		local b = self.slotButtons[n]
		if not b then
			b = CreateFrame("ItemButton", nil, self)
			b:SetSize(SLOT_SIZE, SLOT_SIZE)
			b.emptyBackgroundAtlas = "bags-item-slot64"
			b.lock = b:CreateTexture(nil, "OVERLAY")
			b.lock:SetAtlas("bankslot-icon-lock")
			b.lock:SetAllPoints()
			b:RegisterForDrag("LeftButton")
			b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			local function Pickup(btn)
				if btn.owned then
					C_Container.PickupContainerItem(btn.container, btn.n)
				end
			end
			b:SetScript("OnClick", Pickup)
			b:SetScript("OnDragStart", Pickup)
			b:SetScript("OnReceiveDrag", Pickup)
			b:SetScript("OnEnter", function(btn)
				GameTooltip:SetOwner(btn, "ANCHOR_TOP")
				if not btn.owned then
					GameTooltip:SetText("Bag slot not bought yet")
					GameTooltip:AddLine("Use the Buy button to the right.", 1, 1, 1, true)
				elseif not GameTooltip:SetBagItem(btn.container, btn.n) then
					GameTooltip:SetText("Empty bank bag slot")
					GameTooltip:AddLine("Drag a bag here.", 1, 1, 1, true)
				end
				GameTooltip:Show()
			end)
			b:SetScript("OnLeave", GameTooltip_Hide)
			self.slotButtons[n] = b
		end

		b.n, b.container, b.owned = n, container, owned[n] ~= nil
		local info = b.owned and C_Container.GetContainerItemInfo(container, n)
		SetItemButtonTexture(b, info and info.iconFileID or nil)
		b.lock:SetShown(not b.owned)

		b:ClearAllPoints()
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else
			b:SetPoint("LEFT", self.slotLabel, "RIGHT", 6, 0)
		end
		b:Show()
		prev = b
	end
	self.slotLabel:SetShown(maxTabs > 1)

	-- buy the next slot (Blizzard's own button)
	local nextTab = not C_Bank.HasMaxBankTabs(bankType) and C_Bank.FetchNextPurchasableBankTabData(bankType)
	if self.buy and nextTab and not InCombatLockdown() then
		self.buy:SetAttribute("overrideBankType", bankType)
		self.buy:SetEnabled(nextTab.canAfford)
		self.buy:Show()
		self.costText:SetText(MoneyText(nextTab.tabCost))
		if nextTab.canAfford then
			self.costText:SetTextColor(1, 1, 1)
		else
			self.costText:SetTextColor(1, 0.2, 0.2)
		end
		self.costText:Show()
	end
end

local function BuildBank()
	local w = CreateWindow("bank", "TidyBagsBankFrame")

	-- Character / Warband tabs on the title row
	local function SetBankType(bankType)
		w.bankType = bankType
		w:Layout()
		if w.isLive and db.autoSortBank then
			w.SortNow()
		end
	end

	w.tabChar = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	w.tabChar:SetSize(78, 20)
	w.tabChar:SetText("Character")
	w.tabChar:SetScript("OnClick", function() SetBankType(CHARACTER) end)

	w.tabWarband = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	w.tabWarband:SetSize(78, 20)
	w.tabWarband:SetText("Warband")
	w.tabWarband:SetScript("OnClick", function() SetBankType(ACCOUNT) end)

	w.tabWarband:SetPoint("RIGHT", w.freeText, "LEFT", -8, 0)
	w.tabChar:SetPoint("RIGHT", w.tabWarband, "LEFT", -2, 0)
	w.title:SetPoint("RIGHT", w.tabChar, "LEFT", -6, 0)
	w.title:SetWordWrap(false)

	-- bag-slot row (only at the bank)
	w.slotButtons = {}
	w.slotLabel = w:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	w.slotLabel:SetPoint("BOTTOMLEFT", PADDING + 2, FOOTER + 13)
	w.slotLabel:SetText("Bag slots:")

	w.costText = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

	local blizzBuy = BankPanel and BankPanel.PurchasePrompt and BankPanel.PurchasePrompt.TabCostFrame
		and BankPanel.PurchasePrompt.TabCostFrame.PurchaseButton
	if not blizzBuy then
		-- same Blizzard template, created by us as a fallback
		local ok, button = pcall(CreateFrame, "Button", nil, w, "BankPanelPurchaseButtonScriptTemplate, UIPanelButtonTemplate")
		blizzBuy = ok and button or nil
	end
	if blizzBuy then
		blizzBuy:SetParent(w)
		blizzBuy:ClearAllPoints()
		blizzBuy:SetPoint("BOTTOMRIGHT", -PADDING, FOOTER + 6)
		blizzBuy:SetSize(70, 22)
		blizzBuy:SetText("Buy")
		blizzBuy:Hide()
		w.buy = blizzBuy
		w.costText:SetPoint("RIGHT", blizzBuy, "LEFT", -6, 0)
	end

	w:SetScript("OnHide", function()
		PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
		if not syncing and ns.atBank then
			-- closed by us (X / ESC) while at the bank: close the bank, next frame
			C_Timer.After(0, function()
				if ns.atBank then
					C_Bank.CloseBankFrame()
				end
			end)
		end
	end)

	return w
end


--[[ Follow Blizzard's bags: open / closed ]]--

-- Blizzard frames are moved into this hidden frame. They still "open" and "close"
-- normally (IsBagOpen keeps working), they just can't be seen.
local hider = CreateFrame("Frame")
hider:Hide()

-- Blizzard's bank window goes here instead: still "shown" (so the bank stays open
-- and its OnShow / OnHide still run) but too small to see or click.
local tiny = CreateFrame("Frame", nil, UIParent)
tiny:SetScale(0.001)
tiny:SetAlpha(0)
tiny:SetSize(1, 1)
tiny:SetPoint("BOTTOMLEFT")

local inventoryBagSet = {}
local origParent = {}

local function Claim(frame)
	if not frame then
		return
	end
	if origParent[frame] == nil then
		origParent[frame] = frame:GetParent() or UIParent
	end
	if frame == ContainerFrameCombinedBags or inventoryBagSet[frame:GetID()] then
		frame:SetParent(hider)
	else
		frame:SetParent(origParent[frame])
	end
end

function ns.AnyInventoryBagOpen()
	for bag in pairs(inventoryBagSet) do
		if IsBagOpen(bag) then
			return true
		end
	end
	return false
end

local function SetShownQuietly(w, show)
	if show ~= w:IsShown() then
		syncing = true
		w:SetShown(show)
		syncing = false
	end
end

local syncDriver = CreateFrame("Frame")
syncDriver:Hide()
syncDriver:SetScript("OnUpdate", function(self)
	self:Hide()
	local open = ns.AnyInventoryBagOpen()
	if open and not inventory:IsShown() then
		-- opening the bags always starts on the logged-in character
		inventory.owner = nil
	end
	SetShownQuietly(inventory, open)
end)

local function QueueSync()
	syncDriver:Show()
end

local function HookBlizzard()
	for _, bag in ipairs(ns.InventoryBags()) do
		inventoryBagSet[bag] = true
	end

	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G["ContainerFrame" .. i]
		if frame then
			Claim(frame)
			hooksecurefunc(frame, "SetID", Claim)
			hooksecurefunc(frame, "Show", QueueSync)
			hooksecurefunc(frame, "Hide", QueueSync)
		end
	end

	if ContainerFrameCombinedBags then
		Claim(ContainerFrameCombinedBags)
		hooksecurefunc(ContainerFrameCombinedBags, "Show", QueueSync)
		hooksecurefunc(ContainerFrameCombinedBags, "Hide", QueueSync)
	end

	for _, name in ipairs({ "OpenBag", "CloseBag", "ToggleBag", "OpenBackpack", "CloseBackpack",
			"ToggleBackpack", "OpenAllBags", "CloseAllBags", "ToggleAllBags" }) do
		if _G[name] then
			hooksecurefunc(name, QueueSync)
		end
	end

	-- the bank
	if BankFrame then
		BankFrame:SetParent(tiny)
		BankFrame:HookScript("OnShow", function()
			ns.atBank = true
			ns.SaveBank()
			bank.owner = nil
			bank.bankType = C_Bank.CanViewBank(CHARACTER) and CHARACTER or ACCOUNT
			if bank:IsShown() then
				bank:Layout()
			else
				SetShownQuietly(bank, true)
			end
		end)
		BankFrame:HookScript("OnHide", function()
			ns.atBank = false
			if bank:IsShown() then
				if bank.isLive then
					SetShownQuietly(bank, false)
				else
					bank:Layout()
				end
			end
			inventory:Layout()
		end)
	end
end


--[[ Events ]]--

local function ForWindows(fn)
	for _, w in ipairs({ inventory, bank }) do
		if w and w:IsShown() then
			fn(w)
		end
	end
end

local pendingUpdate = CreateFrame("Frame")
pendingUpdate:Hide()
pendingUpdate:SetScript("OnUpdate", function(self)
	self:Hide()
	ForWindows(function(w) w:UpdateAll() end)
end)

ns.On("PLAYER_LOGIN", function()
	TidyBagsDB = TidyBagsDB or {}
	db = TidyBagsDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then
			db[k] = type(v) == "table" and {} or v
		end
	end

	inventory = BuildInventory()
	bank = BuildBank()
	ns.inventory, ns.bank = inventory, bank

	for kind, w in pairs({ inventory = inventory, bank = bank }) do
		w:SetScale(kind == "bank" and db.bankScale or db.scale)
		w:ClearAllPoints()
		local p = db.pos[kind]
		if p then
			w:SetPoint(p[1], UIParent, p[2], p[3], p[4])
		elseif kind == "inventory" then
			w:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -60, 120)
		else
			w:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 60, -120)
		end
	end
	inventory.auto:SetChecked(db.autoSort)
	bank.auto:SetChecked(db.autoSortBank)

	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if loaded and loaded("Bagnon") then
		Print("Bagnon is also enabled. Disable Bagnon and BagBrother, then /reload.")
	end

	HookBlizzard()
end)

for _, event in ipairs({ "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE", "BANK_TABS_CHANGED",
		"PLAYERBANKSLOTS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" }) do
	ns.On(event, function()
		ForWindows(function(w) w:Layout() end)
	end)
end

ns.On("ITEM_LOCK_CHANGED", function(_, bag, slot)
	if bag and slot then
		ForWindows(function(w) w:UpdateLiveSlot(bag, slot) end)
	end
end)

for _, event in ipairs({ "BAG_UPDATE_COOLDOWN", "QUEST_ACCEPTED", "UNIT_QUEST_LOG_CHANGED", "PLAYER_MONEY",
		"BAG_NEW_ITEMS_UPDATED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
	ns.On(event, function()
		pendingUpdate:Show() -- once per frame at most
	end)
end


--[[ Slash command ]]--

SLASH_TIDYBAGS1 = "/tidybags"
SLASH_TIDYBAGS2 = "/tb"
SlashCmdList.TIDYBAGS = function(msg)
	local cmd, value = strsplit(" ", strtrim(msg or ""):lower(), 2)
	value = tonumber(value)

	if cmd == "cols" and value then
		db.columns = max(4, min(30, floor(value)))
		inventory:Layout()
		Print("bag columns = " .. db.columns)
	elseif cmd == "bankcols" and value then
		db.bankColumns = max(4, min(30, floor(value)))
		bank:Layout()
		Print("bank columns = " .. db.bankColumns)
	elseif cmd == "scale" and value then
		db.scale = max(0.5, min(2, value))
		db.bankScale = db.scale
		inventory:SetScale(db.scale)
		bank:SetScale(db.bankScale)
		Print("scale = " .. db.scale .. " (or drag the corner at the bottom right of a window)")
	elseif cmd == "autosort" then
		db.autoSort = not db.autoSort
		inventory.auto:SetChecked(db.autoSort)
		Print("auto sort bags " .. (db.autoSort and "on" or "off"))
	elseif cmd == "bank" then
		if bank:IsShown() then
			bank:Hide()
		else
			bank:Show()
		end
	elseif cmd == "questfirst" then
		db.questSection = not db.questSection
		inventory:Layout()
		bank:Layout()
		Print("quest items section " .. (db.questSection and "on" or "off"))
	elseif cmd == "questglow" then
		db.questGlow = not db.questGlow
		inventory:UpdateAll()
		bank:UpdateAll()
		Print("quest item glow " .. (db.questGlow and "on" or "off"))
	elseif cmd == "baginfo" then
		-- prints each bag's name and its bag type number (bagFamily), to find the
		-- real numbers Forever uses for herb, mining, skinning ... bags
		local bags = ns.InventoryBags()
		if ns.atBank then
			for _, t in ipairs({ CHARACTER, ACCOUNT }) do
				for _, bag in ipairs(ns.LiveBankBags(t)) do
					tinsert(bags, bag)
				end
			end
		end
		Print("bag types (0 = normal bag):")
		for _, bag in ipairs(bags) do
			local size = C_Container.GetContainerNumSlots(bag) or 0
			if size > 0 and bag ~= 0 and bag ~= KEYRING_CONTAINER then
				local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
				local okInv, inv = pcall(C_Container.ContainerIDToInventoryID, bag)
				local link = okInv and inv and GetInventoryItemLink("player", inv)
				local t = BagType(family)
				print(("  bag %d: %s, %d slots, type %s%s"):format(bag, link or "?", size,
					tostring(ok and family or "?"), t and (" (" .. t.name .. ")") or ""))
			end
		end
	elseif cmd == "bagtypes" then
		db.bagTypes = not db.bagTypes
		inventory:UpdateAll()
		bank:UpdateAll()
		Print("profession bag colours " .. (db.bagTypes and "on" or "off"))
	elseif cmd == "questwarn" then
		db.questWarn = not db.questWarn
		Print("warning when a quest item goes in the bank " .. (db.questWarn and "on" or "off"))
	elseif cmd == "counts" then
		db.tooltipCounts = not db.tooltipCounts
		Print("tooltip item counts " .. (db.tooltipCounts and "on" or "off"))
	elseif cmd == "reset" then
		wipe(db.pos)
		inventory:ClearAllPoints()
		inventory:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -60, 120)
		bank:ClearAllPoints()
		bank:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 60, -120)
		Print("windows moved back")
	else
		Print("commands:")
		print("  /tb bank          - open or close the bank window (works anywhere)")
		print("  /tb cols <4-30>   - bag slots per row (now " .. db.columns .. ")")
		print("  /tb bankcols <4-30> - bank slots per row (now " .. db.bankColumns .. ")")
		print("  /tb scale <0.5-2> - window size (now " .. db.scale .. ")")
		print("  /tb autosort      - sort bags every time they open (now " .. (db.autoSort and "on" or "off") .. ")")
		print("  /tb counts        - item counts in tooltips (now " .. (db.tooltipCounts and "on" or "off") .. ")")
		print("  /tb questfirst    - quest items in their own section at the top (now " .. (db.questSection and "on" or "off") .. ")")
		print("  /tb questglow     - gold glow around quest items (now " .. (db.questGlow and "on" or "off") .. ")")
		print("  /tb baginfo       - list your bags and their bag type numbers")
		print("  /tb bagtypes      - colour and icon on herb, mining, leather ... bag slots (now " .. (db.bagTypes and "on" or "off") .. ")")
		print("  /tb questwarn     - warn when a quest item goes in the bank (now " .. (db.questWarn and "on" or "off") .. ")")
		print("  /tb reset         - move the windows back")
	end
end
