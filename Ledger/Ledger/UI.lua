--[[
	Ledger - UI.lua
	1. The on-screen counter ("coin earned" since you pressed reset).
	2. The Ledger window: pick a character and a period, see totals per category
	   and every line with its details.
]]

local ADDON, ns = ...

local settings
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function SavePosition(frame, key)
	local point, _, relPoint, x, y = frame:GetPoint()
	settings[key] = { point, relPoint, x, y }
end

local function LoadPosition(frame, key, default)
	frame:ClearAllPoints()
	local p = settings[key]
	if p then
		frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		frame:SetPoint(unpack(default))
	end
end

local function Duration(seconds)
	seconds = max(0, floor(seconds))
	local h, m = floor(seconds / 3600), floor(seconds % 3600 / 60)
	if h > 0 then
		return format("%dh %02dm", h, m)
	end
	return format("%dm", m)
end


--[[ 1. Counter ]]--

local counter = CreateFrame("Button", "LedgerCounter", UIParent, "BackdropTemplate")
counter:SetSize(210, 58)
counter:SetFrameStrata("MEDIUM")
counter:SetClampedToScreen(true)
counter:SetMovable(true)
counter:EnableMouse(true)
counter:RegisterForDrag("LeftButton")
counter:RegisterForClicks("LeftButtonUp", "RightButtonUp")
counter:SetBackdrop(BACKDROP)
counter:SetBackdropColor(0, 0, 0, 0.75)
counter:SetBackdropBorderColor(0.8, 0.65, 0.2, 0.9)
counter:Hide()

local coin = counter:CreateTexture(nil, "ARTWORK")
coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
coin:SetSize(18, 18)
coin:SetPoint("TOPLEFT", 10, -10)

counter.earned = counter:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
counter.earned:SetJustifyH("LEFT")
local EARNED_FONT, _, EARNED_FLAGS = counter.earned:GetFont()

counter.line2 = counter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
counter.line2:SetJustifyH("LEFT")

counter.line3 = counter:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
counter.line3:SetJustifyH("LEFT")

local reset = CreateFrame("Button", nil, counter)
reset:SetSize(16, 16)
reset:SetPoint("TOPRIGHT", -8, -9)
reset:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
reset:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
reset:SetScript("OnClick", function()
	ns.ResetCounter()
	ns.Print("counter reset.")
end)
reset:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Reset counter")
	GameTooltip:AddLine("Start counting from zero (for a new farm or dungeon run). The Ledger keeps everything.", 1, 1, 1, true)
	GameTooltip:Show()
end)
reset:SetScript("OnLeave", GameTooltip_Hide)

function ns.UpdateCounter()
	local char = ns.Char and ns.me and ns.Char()
	if not char or not counter:IsShown() then
		return
	end
	local o = settings or {}
	local function On(key) return o[key] ~= false end
	local c = char.counter
	local elapsed = time() - (c.start or time())
	local net = c.earned - c.spent
	local perHour = elapsed >= 60 and (c.earned / elapsed * 3600) or 0

	-- which parts to show (each can be turned off in Options > AddOns > Ledger)
	local parts2, parts3 = {}, {}
	if On("showSpent") then tinsert(parts2, "|cffff7070Spent|r " .. ns.Money(c.spent)) end
	if On("showNet") then tinsert(parts2, "|cffffd100Net|r " .. ns.Money(net, true)) end
	if On("showTime") then tinsert(parts3, Duration(elapsed)) end
	if On("showPerHour") then tinsert(parts3, ns.Money(perHour) .. " / hour") end
	local showEarned, showIcon, showReset = On("showEarned"), On("showCoinIcon"), On("showResetButton")

	-- lay out top to bottom
	local size = o.earnedSize or 16
	counter.earned:SetFont(EARNED_FONT, size, EARNED_FLAGS)
	local pad, y, width = 9, -9, 0
	local left = pad
	coin:SetShown(showEarned and showIcon)
	reset:SetShown(showReset)
	counter.earned:SetShown(showEarned)
	if showEarned then
		if showIcon then
			coin:SetSize(size + 2, size + 2)
			coin:ClearAllPoints()
			coin:SetPoint("TOPLEFT", pad, y)
			left = pad + size + 8
		end
		counter.earned:ClearAllPoints()
		counter.earned:SetPoint("TOPLEFT", left, y - 1)
		counter.earned:SetText(ns.Money(c.earned))
		width = left + counter.earned:GetStringWidth() + (showReset and 26 or 0)
		y = y - max(size + 2, showReset and 16 or 0) - 4
	end
	for _, line in ipairs({ { counter.line2, parts2 }, { counter.line3, parts3 } }) do
		local fs, parts = line[1], line[2]
		fs:SetShown(#parts > 0)
		if #parts > 0 then
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", pad, y)
			fs:SetText(table.concat(parts, "   "))
			width = max(width, pad + fs:GetStringWidth() + ((not showEarned and showReset and fs == counter.line2) and 26 or 0))
			y = y - fs:GetStringHeight() - 3
		end
	end
	if not showEarned and #parts2 == 0 and #parts3 == 0 then
		counter.line2:Show()
		counter.line2:ClearAllPoints()
		counter.line2:SetPoint("TOPLEFT", pad, y)
		counter.line2:SetText("|cff999999(all parts hidden)|r")
		width = pad + counter.line2:GetStringWidth() + 26
		y = y - 16
	end
	counter:SetWidth(max(60, width + pad))
	counter:SetHeight(-y + 6)
end
ns.OnRecorded = function()
	ns.UpdateCounter()
	if ns.RefreshLedger then
		ns.RefreshLedger()
	end
end

counter:SetScript("OnDragStart", function(self)
	if settings and settings.lockCounter then
		return
	end
	self:StartMoving()
end)
counter:SetScript("OnDragStop", function(self)
	self.dragEnd = GetTime()
	self:StopMovingOrSizing()
	SavePosition(self, "counterPos")
end)
counter:SetScript("OnClick", function(self, button)
	if self.dragEnd and GetTime() - self.dragEnd < 0.3 then
		return -- that was a drag, not a click
	end
	if button == "LeftButton" then
		ns.ToggleLedger()
	end
end)
counter:SetScript("OnEnter", function(self)
	if settings and settings.counterTooltip == false then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:SetText("Coin earned")
	GameTooltip:AddLine("Gold earned and spent since you last pressed reset (the circle arrow). Gold moved between your own characters or banks isn't counted.", 1, 1, 1, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click: open the Ledger", 0.6, 0.8, 1)
	GameTooltip:AddLine("Ctrl + mouse wheel: bigger / smaller", 0.6, 0.8, 1)
	GameTooltip:AddLine(settings and settings.lockCounter and "Locked (unlock in Options > AddOns > Ledger)" or "Drag: move", 0.6, 0.8, 1)
	GameTooltip:Show()
end)
counter:SetScript("OnLeave", GameTooltip_Hide)

-- refresh the time and gold/hour every few seconds
local tick = 0
counter:SetScript("OnUpdate", function(_, elapsed)
	tick = tick + elapsed
	if tick > 5 then
		tick = 0
		ns.UpdateCounter()
	end
end)
counter:SetScript("OnShow", function() ns.UpdateCounter() end)

-- Ctrl + mouse wheel over the counter: make it bigger or smaller
-- the wheel is only taken while Ctrl is held, so camera zoom still works over the counter
counter:EnableMouseWheel(false)
counter:SetScript("OnEvent", function(self)
	self:EnableMouseWheel(IsControlKeyDown() and true or false)
end)
counter:HookScript("OnEnter", function(self)
	self:RegisterEvent("MODIFIER_STATE_CHANGED")
	self:EnableMouseWheel(IsControlKeyDown() and true or false)
end)
counter:HookScript("OnLeave", function(self)
	self:UnregisterEvent("MODIFIER_STATE_CHANGED")
	self:EnableMouseWheel(false)
end)
counter:SetScript("OnMouseWheel", function(_, delta)
	if not IsControlKeyDown() or not settings then
		return
	end
	settings.counterScale = max(0.5, min(2, floor(((settings.counterScale or 1) + delta * 0.05) * 20 + 0.5) / 20))
	ns.ApplyCounterSettings()
end)

-- used by the options page
ns.counter = counter
function ns.ResetCounterPosition()
	settings.counterPos = nil
	LoadPosition(counter, "counterPos", { "TOP", UIParent, "TOP", 0, -120 })
end
function ns.ApplyCounterSettings()
	counter:SetShown(settings.showCounter)
	counter:SetScale(settings.counterScale or 1)
	counter:SetBackdropColor(0, 0, 0, settings.counterAlpha or 0.75)
	counter:SetBackdropBorderColor(0.8, 0.65, 0.2, (settings.counterAlpha or 0.75) > 0.05 and 0.9 or 0)
	ns.UpdateCounter()
end


--[[ 2. Ledger window ]]--

local ROWS = 16
local ROW_HEIGHT = 18

local ledger = CreateFrame("Frame", "LedgerFrame", UIParent, "BackdropTemplate")
ledger:SetSize(860, 520)
ledger:SetFrameStrata("HIGH")
ledger:SetToplevel(true)
ledger:SetClampedToScreen(true)
ledger:SetMovable(true)
ledger:EnableMouse(true)
ledger:RegisterForDrag("LeftButton")
ledger:SetBackdrop(BACKDROP)
ledger:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
ledger:SetBackdropBorderColor(0.8, 0.65, 0.2, 1)
ledger:Hide()
tinsert(UISpecialFrames, "LedgerFrame")
ledger:SetScript("OnDragStart", ledger.StartMoving)
ledger:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	SavePosition(self, "ledgerPos")
end)

-- resize grip (bottom right): dragging it changes the window's scale, so the
-- lists, buttons and text all grow and shrink together. The top-left corner stays put.
do
	local grip = CreateFrame("Button", nil, ledger)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetFrameLevel(ledger:GetFrameLevel() + 20)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	local startX, startWidth, startScale, left, top
	local function Resizing()
		local x = GetCursorPosition()
		local scale = startScale * (startWidth + (x - startX)) / startWidth
		scale = max(0.5, min(2, floor(scale * 100 + 0.5) / 100))
		ledger:SetScale(scale)
		local eff = ledger:GetEffectiveScale()
		ledger:ClearAllPoints()
		ledger:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / eff, top / eff)
		settings.ledgerScale = scale
	end
	grip:SetScript("OnMouseDown", function()
		local eff = ledger:GetEffectiveScale()
		startX = GetCursorPosition()
		startWidth = ledger:GetWidth() * eff
		startScale = ledger:GetScale()
		left, top = ledger:GetLeft() * eff, ledger:GetTop() * eff
		grip:SetScript("OnUpdate", Resizing)
	end)
	grip:SetScript("OnMouseUp", function()
		grip:SetScript("OnUpdate", nil)
		SavePosition(ledger, "ledgerPos")
	end)
	grip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize")
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", GameTooltip_Hide)
end

-- mode: "gold" (where gold came from and went) or "loot" (the loot table)
ledger.view = { char = nil, period = "today", cat = nil, sign = nil, offset = 0,
	mode = "gold", mob = nil, lootOffset = 0, mobOffset = 0 }

local title = ledger:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("Ledger")

local close = CreateFrame("Button", nil, ledger, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

-- Gold / Loot buttons
local modeButtons = {}
do
	local last = title
	for _, m in ipairs({ { "gold", "Gold" }, { "loot", "Loot" } }) do
		local b = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
		b:SetSize(64, 22)
		b:SetText(m[2])
		b:SetPoint("LEFT", last, "RIGHT", last == title and 14 or 2, 0)
		b:SetScript("OnClick", function()
			ledger.view.mode = m[1]
			ns.RefreshLedger()
		end)
		modeButtons[m[1]] = b
		last = b
	end
end

-- character picker
local charButton = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
charButton:SetSize(170, 22)
charButton:SetPoint("LEFT", modeButtons.loot, "RIGHT", 12, 0)

-- period buttons
local periodButtons = {}
local prev
for _, period in ipairs(ns.Periods) do
	local b = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
	b:SetSize(96, 22)
	b:SetText(period.label)
	if prev then
		b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
	else
		b:SetPoint("TOPLEFT", 14, -40)
	end
	b:SetScript("OnClick", function()
		ledger.view.period = period.key
		ledger.view.offset = 0
		ns.RefreshLedger()
	end)
	periodButtons[period.key] = b
	prev = b
end

-- summary line
local summary = ledger:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
summary:SetPoint("TOPLEFT", 16, -72)
summary:SetPoint("RIGHT", -16, 0)
summary:SetJustifyH("LEFT")

-- search box (top right)
local search = CreateFrame("EditBox", "LedgerSearchBox", ledger, "SearchBoxTemplate")
search:SetSize(180, 20)
search:SetPoint("TOPRIGHT", -36, -13)
search:HookScript("OnTextChanged", function(self)
	local text = strtrim(self:GetText() or ""):lower()
	if text ~= (ledger.view.search or "") then
		ledger.view.search = text
		ledger.view.offset = 0
		ledger.view.lootOffset = 0
		if text ~= "" then
			ledger.view.mob = nil -- searching an item looks at every mob
		end
		ns.RefreshLedger()
	end
end)
search:HookScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:SetText("Search")
	if ledger.view.mode == "loot" then
		GameTooltip:AddLine("Type an item name (for example silk) to see which mobs dropped the most of it. Searches the period you picked; choose All time for everything.", 1, 1, 1, true)
	else
		GameTooltip:AddLine("Find lines by item, player, sender, zone, quest, category or character. Searches the period you picked; choose All time to search everything.", 1, 1, 1, true)
	end
	GameTooltip:Show()
end)
search:HookScript("OnLeave", GameTooltip_Hide)

-- plain text of a line, for searching (links and colours removed)
local function PlainText(entry, charKey)
	local text = (entry.d or "")
		:gsub("|c[nN][^:]*:", "")
		:gsub("|c%x%x%x%x%x%x%x%x", "")
		:gsub("|H.-|h", "")
		:gsub("|[hr]", "")
	local char = LedgerDB.chars[charKey]
	return (text .. " " .. ns.CategoryLabel(entry.c, entry.a) .. " " .. (char and char.name or "")):lower()
end

local rangeText = ledger:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
rangeText:SetPoint("LEFT", charButton, "RIGHT", 12, 0)

-- left: categories
local catPanel = CreateFrame("Frame", nil, ledger, "BackdropTemplate")
catPanel:SetPoint("TOPLEFT", 12, -94)
catPanel:SetSize(230, 382)
catPanel:SetBackdrop(BACKDROP)
catPanel:SetBackdropColor(0, 0, 0, 0.4)
catPanel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

local catRows = {}
local function CatRow(i)
	local row = catRows[i]
	if not row then
		row = CreateFrame("Button", nil, catPanel)
		row:SetSize(214, 18)
		row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 19)
		row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.label:SetPoint("LEFT")
		row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.amount:SetPoint("RIGHT")
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0, 0.15)
		row:SetScript("OnClick", function(self)
			local view = ledger.view
			if not self.cat or (view.cat == self.cat and view.sign == self.sign) then
				view.cat, view.sign = nil, nil -- click again (or a heading) to show everything
			else
				view.cat, view.sign = self.cat, self.sign
			end
			view.offset = 0
			ns.RefreshLedger()
		end)
		catRows[i] = row
	end
	return row
end

-- right: detail list
local listPanel = CreateFrame("Frame", nil, ledger, "BackdropTemplate")
listPanel:SetPoint("TOPLEFT", catPanel, "TOPRIGHT", 6, 0)
listPanel:SetPoint("BOTTOMRIGHT", -12, 16)
listPanel:SetBackdrop(BACKDROP)
listPanel:SetBackdropColor(0, 0, 0, 0.4)
listPanel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
listPanel:EnableMouseWheel(true)

local listHeader = listPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
listHeader:SetPoint("TOPLEFT", 10, -8)

local pageText = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
pageText:SetPoint("BOTTOMRIGHT", -10, 8)

local scroll = CreateFrame("Slider", nil, listPanel)
scroll:SetOrientation("VERTICAL")
scroll:SetPoint("TOPRIGHT", -6, -26)
scroll:SetPoint("BOTTOMRIGHT", -6, 24)
scroll:SetWidth(12)
scroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
local track = scroll:CreateTexture(nil, "BACKGROUND")
track:SetAllPoints()
track:SetColorTexture(1, 1, 1, 0.06)
scroll:SetValueStep(1)
scroll:SetObeyStepOnDrag(true)
scroll:SetScript("OnValueChanged", function(_, value)
	value = floor(value + 0.5)
	if value ~= ledger.view.offset then
		ledger.view.offset = value
		ns.RefreshLedger(true)
	end
end)

listPanel:SetScript("OnMouseWheel", function(_, delta)
	local lo, hi = scroll:GetMinMaxValues()
	scroll:SetValue(max(lo, min(hi, ledger.view.offset - delta * 3)))
end)

local listRows = {}
for i = 1, ROWS do
	local row = CreateFrame("Frame", nil, listPanel)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_HEIGHT + 3))
	row:SetPoint("RIGHT", scroll, "LEFT", -6, 0)
	row:EnableMouse(true)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)

	row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.when:SetPoint("LEFT", 2, 0)
	row.when:SetWidth(78)
	row.when:SetJustifyH("LEFT")

	row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.amount:SetPoint("RIGHT", -2, 0)
	row.amount:SetJustifyH("RIGHT")

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.detail:SetPoint("LEFT", row.when, "RIGHT", 4, 0)
	row.detail:SetPoint("RIGHT", row.amount, "LEFT", -8, 0)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)

	row:SetScript("OnEnter", function(self)
		if not self.entry then
			return
		end
		local e = self.entry
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetText(ns.CategoryLabel(e.c, e.a))
		GameTooltip:AddLine(e.d, 1, 1, 1, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Amount", ns.Money(e.a, true), 0.8, 0.8, 0.8, 1, 1, 1)
		if e.n and e.n > 1 then
			GameTooltip:AddDoubleLine("Times", tostring(e.n), 0.8, 0.8, 0.8, 1, 1, 1)
		end
		GameTooltip:AddDoubleLine("When", date("%Y-%m-%d %H:%M", e.t), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("Character", ns.ClassColored(LedgerDB.chars[self.charKey]), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	listRows[i] = row
end

local empty = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("CENTER")
empty:SetText("Nothing recorded for this period yet.")

-- under the categories: clear old data
local clearButton = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
clearButton:SetSize(140, 22)
clearButton:SetPoint("TOPLEFT", catPanel, "BOTTOMLEFT", 0, -4)
clearButton:SetText("Clear old data...")
clearButton:SetScript("OnClick", function() ns.ShowClear() end)


--[[ 3. Loot view (shares the window's period buttons and search box) ]]--

local MIN_CORPSES = 5   -- fewer than this: the drop rate is a guess, so rank it lower
local MOB_ROWS = 19

local function Panel()
	local p = CreateFrame("Frame", nil, ledger, "BackdropTemplate")
	p:SetBackdrop(BACKDROP)
	p:SetBackdropColor(0, 0, 0, 0.4)
	p:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	p:Hide()
	p:EnableMouseWheel(true)
	return p
end

-- left: mobs in this period
local mobPanel = Panel()
mobPanel:SetAllPoints(catPanel)
local mobRows = {}
for i = 1, MOB_ROWS do
	local row = CreateFrame("Button", nil, mobPanel)
	row:SetSize(214, 18)
	row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 19)
	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.label:SetPoint("LEFT")
	row.label:SetPoint("RIGHT", -36, 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.count:SetPoint("RIGHT")
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	row.selected:SetColorTexture(1, 0.82, 0, 0.15)
	row:SetScript("OnClick", function(self)
		local view = ledger.view
		view.mob = (self.mob ~= view.mob) and self.mob or nil
		view.lootOffset = 0
		if view.mob and view.search and view.search ~= "" then
			search:SetText("") -- picking a mob shows all of its drops
		end
		ns.RefreshLedger()
	end)
	row:SetScript("OnEnter", function(self)
		if not self.mob then
			return
		end
		local t = self.data
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(ns.MobName(self.mob))
		if ns.MobZone(self.mob) ~= "" then
			GameTooltip:AddLine(ns.MobZone(self.mob), 0.7, 0.7, 0.7)
		end
		GameTooltip:AddDoubleLine("Looted", tostring(t.k), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("Items taken", tostring(t.n), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("Coin", ns.Money(t.c), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("Items sold for", ns.Money(t.v), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddLine("Click to see everything it dropped.", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	mobRows[i] = row
end

-- right: the table
local lootPanel = Panel()
lootPanel:SetAllPoints(listPanel)

local lootHeader = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lootHeader:SetPoint("TOPLEFT", 10, -8)
lootHeader:SetPoint("RIGHT", -10, 0)
lootHeader:SetJustifyH("LEFT")
lootHeader:SetWordWrap(false)

local lootPage = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
lootPage:SetPoint("BOTTOMRIGHT", -10, 8)

local lootEmpty = lootPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
lootEmpty:SetPoint("CENTER")
lootEmpty:SetWidth(420)

local lootScroll = CreateFrame("Slider", nil, lootPanel)
lootScroll:SetOrientation("VERTICAL")
lootScroll:SetPoint("TOPRIGHT", -6, -44)
lootScroll:SetPoint("BOTTOMRIGHT", -6, 24)
lootScroll:SetWidth(12)
lootScroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
do
	local t = lootScroll:CreateTexture(nil, "BACKGROUND")
	t:SetAllPoints()
	t:SetColorTexture(1, 1, 1, 0.06)
end
lootScroll:SetValueStep(1)
lootScroll:SetObeyStepOnDrag(true)
lootScroll:SetScript("OnValueChanged", function(_, value)
	value = floor(value + 0.5)
	if value ~= ledger.view.lootOffset then
		ledger.view.lootOffset = value
		ns.RefreshLedger(true)
	end
end)
lootPanel:SetScript("OnMouseWheel", function(_, delta)
	local lo, hi = lootScroll:GetMinMaxValues()
	lootScroll:SetValue(max(lo, min(hi, ledger.view.lootOffset - delta * 3)))
end)
mobPanel:SetScript("OnMouseWheel", function(_, delta)
	ledger.view.mobOffset = max(0, ledger.view.mobOffset - delta * 3)
	ns.RefreshLedger()
end)

-- columns: a wide name column, then four on the right
local COL_WIDTHS = { 62, 70, 96, 116 }
local function Columns(parent, font)
	local cols, right = {}, nil
	for c = #COL_WIDTHS, 1, -1 do
		local fs = parent:CreateFontString(nil, "OVERLAY", font)
		fs:SetWidth(COL_WIDTHS[c])
		fs:SetJustifyH("RIGHT")
		fs:SetWordWrap(false)
		if right then
			fs:SetPoint("RIGHT", right, "LEFT", -4, 0)
		else
			fs:SetPoint("RIGHT", -2, 0)
		end
		cols[c] = fs
		right = fs
	end
	local name = parent:CreateFontString(nil, "OVERLAY", font)
	name:SetPoint("LEFT", 2, 0)
	name:SetPoint("RIGHT", cols[1], "LEFT", -6, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	return name, cols
end

local colHeader = CreateFrame("Frame", nil, lootPanel)
colHeader:SetHeight(16)
colHeader:SetPoint("TOPLEFT", 8, -24)
colHeader:SetPoint("RIGHT", lootScroll, "LEFT", -6, 0)
colHeader.name, colHeader.cols = Columns(colHeader, "GameFontNormalSmall")

local lootRows = {}
for i = 1, ROWS do
	local row = CreateFrame("Button", nil, lootPanel)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 8, -44 - (i - 1) * (ROW_HEIGHT + 2))
	row:SetPoint("RIGHT", lootScroll, "LEFT", -6, 0)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.name, row.cols = Columns(row, "GameFontHighlightSmall")
	row:SetScript("OnClick", function(self)
		local d = self.data
		if not d then
			return
		end
		if d.kind == "item" then
			local item = ns.LootItem(d.id)
			search:SetText(item and item.n or "") -- shows who drops it
		elseif d.kind == "mob" then
			ledger.view.mob = d.key
			ledger.view.lootOffset = 0
			search:SetText("")
			ns.RefreshLedger()
		end
	end)
	row:SetScript("OnEnter", function(self)
		local d = self.data
		if not d then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if d.kind == "item" then
			local item = ns.LootItem(d.id)
			if item and item.l then
				GameTooltip:SetHyperlink(item.l)
			else
				GameTooltip:SetText(item and item.n or "?")
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("Looted", tostring(d.n), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Sold", d.s .. " for " .. ns.Money(d.v), 0.8, 0.8, 0.8, 1, 1, 1)
			if d.n > d.s and item and item.p and item.p > 0 then
				GameTooltip:AddDoubleLine("Not sold yet", (d.n - d.s) .. " (vendor " .. ns.Money((d.n - d.s) * item.p) .. ")", 0.8, 0.8, 0.8, 1, 1, 1)
			end
			for i, top in ipairs(d.top or {}) do
				if i > 3 then break end
				GameTooltip:AddDoubleLine(i == 1 and "Dropped most by" or " ", ns.MobName(top[1]) .. " (" .. top[2] .. ")", 0.8, 0.8, 0.8, 1, 1, 1)
			end
			GameTooltip:AddLine("Click: who drops it", 0.6, 0.8, 1)
		else
			GameTooltip:SetText(ns.MobName(d.key))
			if ns.MobZone(d.key) ~= "" then
				GameTooltip:AddLine(ns.MobZone(d.key), 0.7, 0.7, 0.7)
			end
			GameTooltip:AddDoubleLine("Looted", tostring(d.k), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Dropped", tostring(d.n), 0.8, 0.8, 0.8, 1, 1, 1)
			if d.k < MIN_CORPSES then
				GameTooltip:AddLine("Only " .. d.k .. " looted: the rate is a rough guess until " .. MIN_CORPSES .. ".", 1, 0.6, 0.3, true)
			end
			GameTooltip:AddLine("Click: everything it dropped", 0.6, 0.8, 1)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	lootRows[i] = row
end

local function Rate(n, k)
	if not k or k <= 0 then
		return "-"
	end
	local r = n / k
	return r >= 10 and format("%.0f", r) or format("%.2f", r)
end

local function ItemText(id)
	local item = ns.LootItem(id)
	return item and (item.l or item.n) or ("item " .. id)
end

local function Unsold(id, n, s)
	local item = ns.LootItem(id)
	if n > s and item and item.p and item.p > 0 then
		return "|cff999999~" .. ns.Money((n - s) * item.p) .. "|r"
	end
	return ""
end

local lootList = {}

-- build the table and the mob list for this period
local function BuildLoot(from, to)
	local view = ledger.view
	local mobs = ns.LootTotals(from, to)
	local list = {}
	local text = view.search or ""

	-- summary across everything
	local corpses, taken, soldFor, unsoldWorth, coin = 0, 0, 0, 0, 0
	for _, t in pairs(mobs) do
		corpses, coin = corpses + t.k, coin + t.c
		for id, r in pairs(t.i) do
			taken, soldFor = taken + r.n, soldFor + r.v
			local item = ns.LootItem(id)
			if item and item.p and r.n > r.s then
				unsoldWorth = unsoldWorth + (r.n - r.s) * item.p
			end
		end
	end
	summary:SetText(format("|cffffd100Looted|r %d     |cffffd100Items taken|r %d     |cff40ff40Items sold for|r %s     |cff999999Not sold yet ~%s (vendor price)|r     |cffffd100Coin|r %s",
		corpses, taken, ns.Money(soldFor), ns.Money(unsoldWorth), ns.Money(coin)))

	local heads
	if text ~= "" then
		-- who drops it
		for key, t in pairs(mobs) do
			local n, s, v = 0, 0, 0
			for id, r in pairs(t.i) do
				local item = ns.LootItem(id)
				if item and item.n and item.n:lower():find(text, 1, true) then
					n, s, v = n + r.n, s + r.s, v + r.v
				end
			end
			if n > 0 then
				tinsert(list, { kind = "mob", key = key, k = t.k, n = n, s = s, v = v,
					name = ns.MobName(key) .. "  |cff999999" .. ns.MobZone(key) .. "|r",
					cols = { tostring(t.k), tostring(n), Rate(n, t.k), ns.Money(v) } })
			end
		end
		sort(list, function(a, b)
			local ra, rb = a.k >= MIN_CORPSES, b.k >= MIN_CORPSES
			if ra ~= rb then return ra end
			local pa, pb = a.n / max(a.k, 1), b.n / max(b.k, 1)
			if pa ~= pb then return pa > pb end
			return a.n > b.n
		end)
		heads = { "Mob  (best first; click for all its drops)", "Looted", "Dropped", "Per corpse", "Sold for" }
		lootHeader:SetText(format("Who drops \"%s\"  |cff999999(mobs looted fewer than %d times are listed last)|r", text, MIN_CORPSES))
	elseif view.mob and mobs[view.mob] then
		-- one mob's drops
		local t = mobs[view.mob]
		for id, r in pairs(t.i) do
			tinsert(list, { kind = "item", id = id, n = r.n, s = r.s, v = r.v, name = ItemText(id),
				cols = { tostring(r.n), Rate(r.n, t.k), r.s > 0 and ns.Money(r.v) or "", Unsold(id, r.n, r.s) } })
		end
		sort(list, function(a, b) return a.n > b.n end)
		heads = { "Item  (click: who else drops it)", "Dropped", "Per corpse", "Sold for", "Not sold (vendor)" }
		lootHeader:SetText(format("%s  |cff999999%s|r   looted %d, coin %s  |cff999999(click the mob again to show all)|r",
			ns.MobName(view.mob), ns.MobZone(view.mob), t.k, ns.Money(t.c)))
	else
		-- every item looted
		view.mob = nil
		local items = {}
		for key, t in pairs(mobs) do
			for id, r in pairs(t.i) do
				local a = items[id] or { n = 0, s = 0, v = 0, top = {} }
				items[id] = a
				a.n, a.s, a.v = a.n + r.n, a.s + r.s, a.v + r.v
				tinsert(a.top, { key, r.n })
			end
		end
		for id, a in pairs(items) do
			sort(a.top, function(x, y) return x[2] > y[2] end)
			tinsert(list, { kind = "item", id = id, n = a.n, s = a.s, v = a.v, top = a.top, name = ItemText(id),
				cols = { tostring(a.n), tostring(a.s), a.s > 0 and ns.Money(a.v) or "", Unsold(id, a.n, a.s) } })
		end
		sort(list, function(a, b)
			if a.v ~= b.v then return a.v > b.v end
			return a.n > b.n
		end)
		heads = { "Item  (click: who drops it)", "Looted", "Sold", "Sold for", "Not sold (vendor)" }
		lootHeader:SetText("Everything looted from mobs, all characters  |cff999999(type an item in Search to see who drops it)|r")
	end
	colHeader.name:SetText(heads[1])
	for c = 1, 4 do
		colHeader.cols[c]:SetText(heads[c + 1])
	end
	lootEmpty:SetText(text ~= "" and ("No mob dropped \"" .. text .. "\" in this period. Try All time.")
		or "No loot recorded for this period yet. Loot a mob and it shows up here.")

	-- left list: mobs, most looted first
	local mobList = {}
	for key, t in pairs(mobs) do
		tinsert(mobList, { key, t })
	end
	sort(mobList, function(a, b)
		if a[2].k ~= b[2].k then return a[2].k > b[2].k end
		return ns.MobName(a[1]) < ns.MobName(b[1])
	end)
	view.mobOffset = min(view.mobOffset, max(0, #mobList + 1 - MOB_ROWS))
	for i, row in ipairs(mobRows) do
		local index = view.mobOffset + i - 1 -- 0 = "All mobs"
		if index == 0 then
			row.mob, row.data = nil, nil
			row.label:SetText("|cffffd100All mobs|r")
			row.count:SetText("")
			row.selected:SetShown(not view.mob)
			row:Show()
		elseif mobList[index] then
			local key, t = mobList[index][1], mobList[index][2]
			row.mob, row.data = key, t
			row.label:SetText(ns.MobName(key))
			row.count:SetText(tostring(t.k))
			row.selected:SetShown(view.mob == key)
			row:Show()
		else
			row.mob, row.data = nil, nil
			row:Hide()
		end
	end
	return list
end

local function ShowLootRows()
	local view = ledger.view
	for i, row in ipairs(lootRows) do
		local d = lootList[view.lootOffset + i]
		row.data = d
		if d then
			row.name:SetText(d.name)
			for c = 1, 4 do
				row.cols[c]:SetText(d.cols[c])
			end
			row:Show()
		else
			row:Hide()
		end
	end
	lootEmpty:SetShown(#lootList == 0)
	lootPage:SetText(#lootList > 0 and format("%d-%d of %d", view.lootOffset + 1, min(view.lootOffset + ROWS, #lootList), #lootList) or "")
end

local function RefreshLoot(from, to, scrollOnly)
	if not scrollOnly then
		lootList = BuildLoot(from, to)
		local maxOffset = max(0, #lootList - ROWS)
		lootScroll:SetMinMaxValues(0, maxOffset)
		lootScroll:SetShown(maxOffset > 0)
		ledger.view.lootOffset = min(ledger.view.lootOffset, maxOffset)
		lootScroll:SetValue(ledger.view.lootOffset)
	end
	ShowLootRows()
end


--[[ 4. Clear old data window ]]--

local clearFrame = CreateFrame("Frame", "LedgerClearFrame", UIParent, "BackdropTemplate")
clearFrame:SetSize(420, 330)
clearFrame:SetPoint("CENTER", 0, 60)
clearFrame:SetFrameStrata("FULLSCREEN_DIALOG")
clearFrame:SetToplevel(true)
clearFrame:EnableMouse(true)
clearFrame:SetBackdrop(BACKDROP)
clearFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
clearFrame:SetBackdropBorderColor(0.9, 0.3, 0.2, 1)
clearFrame:Hide()
tinsert(UISpecialFrames, "LedgerClearFrame")
do
	local t = clearFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	t:SetPoint("TOP", 0, -14)
	t:SetText("Clear old Ledger data")
	local sub = clearFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOP", t, "BOTTOM", 0, -6)
	sub:SetWidth(380)
	sub:SetText("Pick how much to keep. This is for every character, and covers gold lines, gold totals and the loot table.")
end

local clearInfo = clearFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
clearInfo:SetPoint("TOPLEFT", 20, -210)
clearInfo:SetPoint("RIGHT", -20, 0)
clearInfo:SetJustifyH("LEFT")

local clearYes = CreateFrame("Button", nil, clearFrame, "UIPanelButtonTemplate")
clearYes:SetSize(120, 24)
clearYes:SetPoint("BOTTOMRIGHT", clearFrame, "BOTTOM", -6, 14)
clearYes:SetText("Clear it")

local clearNo = CreateFrame("Button", nil, clearFrame, "UIPanelButtonTemplate")
clearNo:SetSize(120, 24)
clearNo:SetPoint("BOTTOMLEFT", clearFrame, "BOTTOM", 6, 14)
clearNo:SetText("Cancel")
clearNo:SetScript("OnClick", function() clearFrame:Hide() end)

local clearChoice
local clearButtons = {}
for i, choice in ipairs(ns.ClearChoices) do
	local b = CreateFrame("Button", nil, clearFrame, "UIPanelButtonTemplate")
	b:SetSize(240, 22)
	b:SetPoint("TOP", 0, -72 - (i - 1) * 26)
	b:SetText(choice.label)
	b:SetScript("OnClick", function()
		clearChoice = choice
		for _, other in ipairs(clearButtons) do
			other:SetEnabled(other ~= b)
		end
		local cutoff = ns.ClearCutoff(choice.months)
		local lines, days, lootDays = ns.CountBefore(cutoff)
		local what = choice.months == 0 and "|cffff5050Everything|r will be removed"
			or ("Everything before |cffffd100" .. date("%B %d, %Y", cutoff) .. "|r will be removed")
		if lines + days + lootDays == 0 then
			clearInfo:SetText(what .. ":\n\nnothing is that old yet.")
			clearYes:Disable()
		else
			clearInfo:SetText(format("%s:\n%d gold lines, %d days of gold totals, %d days of loot table.\n|cffff7070All time totals go down by that much. This can't be undone.|r\nThe coin earned counter isn't changed.",
				what, lines, days, lootDays))
			clearYes:Enable()
		end
	end)
	clearButtons[i] = b
end

clearYes:SetScript("OnClick", function()
	if not clearChoice then
		return
	end
	local cutoff = ns.ClearCutoff(clearChoice.months)
	local lines, days, lootDays = ns.CountBefore(cutoff)
	ns.ClearBefore(cutoff)
	ns.Print(format("cleared %d gold lines, %d days of gold totals and %d days of loot table.", lines, days, lootDays))
	clearFrame:Hide()
end)

function ns.ShowClear()
	clearChoice = nil
	for _, b in ipairs(clearButtons) do
		b:Enable()
	end
	clearInfo:SetText("Nothing is removed until you press Clear it.")
	clearYes:Disable()
	clearFrame:Show()
end


--[[ Filling the window ]]--

local function ViewChars()
	if ledger.view.char == "all" then
		return ns.SortedChars()
	end
	return { ledger.view.char or ns.me }
end

local function CurrentPeriod()
	for _, period in ipairs(ns.Periods) do
		if period.key == ledger.view.period then
			return period
		end
	end
	return ns.Periods[1]
end

local cachedEntries

function ns.RefreshLedger(scrollOnly)
	if not ledger:IsShown() then
		return
	end
	local view = ledger.view
	local chars = ViewChars()
	local period = CurrentPeriod()
	local from, to = period.range(time())

	if not scrollOnly then
		-- header buttons
		local who = view.char == "all" and "All characters" or ns.ClassColored(ns.Char(view.char))
		charButton:SetText(who)
		for key, b in pairs(periodButtons) do
			b:SetEnabled(key ~= view.period)
		end
		if from > 0 then
			local last = to - 1
			local same = date("%Y-%m-%d", from) == date("%Y-%m-%d", last)
			rangeText:SetText(same and date("%A %b %d, %Y", from) or (date("%b %d", from) .. " - " .. date("%b %d, %Y", last)))
		else
			rangeText:SetText("since install")
		end

		-- Gold or Loot
		local loot = view.mode == "loot"
		for key, b in pairs(modeButtons) do
			b:SetEnabled(key ~= view.mode)
		end
		catPanel:SetShown(not loot)
		listPanel:SetShown(not loot)
		mobPanel:SetShown(loot)
		lootPanel:SetShown(loot)
		charButton:SetEnabled(not loot)
		if loot then
			charButton:SetText("All characters") -- the loot table is shared
			RefreshLoot(from, to)
			return
		end

		-- totals
		local byCat, income, expense, tIn, tOut = ns.Totals(chars, from, to)
		local net = income - expense
		local text = "|cff40ff40Earned|r " .. ns.Money(income)
			.. "     |cffff5050Spent|r " .. ns.Money(expense)
			.. "     |cffffd100Net|r " .. ns.Money(net, true)
		if tIn + tOut > 0 then
			text = text .. "     |cff999999Moved between own characters/banks: in " .. ns.Money(tIn) .. ", out " .. ns.Money(tOut) .. "|r"
		end
		summary:SetText(text)

		-- category list: income, then expenses, then transfers
		local rows = {}
		local function Section(heading, sign, includeTransfer)
			local items = {}
			for cat, sum in pairs(byCat) do
				local value = sign > 0 and sum.i or sum.e
				if value > 0 and ((cat == "transfer") == includeTransfer) then
					tinsert(items, { cat, value })
				end
			end
			sort(items, function(a, b) return a[2] > b[2] end)
			if #items > 0 then
				tinsert(rows, { heading = heading })
				for _, item in ipairs(items) do
					tinsert(rows, { cat = item[1], sign = sign, value = item[2] })
				end
			end
		end
		Section("|cff40ff40Earned from|r", 1, false)
		Section("|cffff5050Spent on|r", -1, false)
		Section("|cff999999Moved in|r", 1, true)
		Section("|cff999999Moved out|r", -1, true)

		for i, data in ipairs(rows) do
			local row = CatRow(i)
			row.cat, row.sign = data.cat, data.sign
			if data.heading then
				row.label:SetText(data.heading)
				row.amount:SetText("")
				row.selected:Hide()
			else
				row.label:SetText("   " .. ns.CategoryLabel(data.cat, data.sign))
				row.amount:SetText(ns.Money(data.value))
				row.selected:SetShown(view.cat == data.cat and view.sign == data.sign)
			end
			row:Show()
		end
		for i = #rows + 1, #catRows do
			catRows[i]:Hide()
		end

		cachedEntries = ns.Entries(chars, from, to, view.cat, view.sign)
		local filter = view.cat and (" - " .. ns.CategoryLabel(view.cat, view.sign) .. "  |cff999999(click it again to show all)|r") or ""
		if view.search and view.search ~= "" then
			local found, plus, minus = {}, 0, 0
			for _, item in ipairs(cachedEntries) do
				if PlainText(item[1], item[2]):find(view.search, 1, true) then
					tinsert(found, item)
					if item[1].a > 0 then
						plus = plus + item[1].a
					else
						minus = minus - item[1].a
					end
				end
			end
			cachedEntries = found
			filter = filter .. format("  |cffffffff\"%s\": %d found|r", view.search, #found)
			if #found > 0 then
				filter = filter .. "  |cff40ff40+" .. ns.Money(plus) .. "|r  |cffff5050-" .. ns.Money(minus) .. "|r"
			end
		end
		listHeader:SetText("Details" .. filter)

		local maxOffset = max(0, #cachedEntries - ROWS)
		scroll:SetMinMaxValues(0, maxOffset)
		scroll:SetShown(maxOffset > 0)
		view.offset = min(view.offset, maxOffset)
		scroll:SetValue(view.offset)
	end

	if view.mode == "loot" then
		RefreshLoot(from, to, true)
		return
	end

	-- rows
	local list = cachedEntries or {}
	local showAll = view.char == "all"
	for i, row in ipairs(listRows) do
		local item = list[view.offset + i]
		if item then
			local e, charKey = item[1], item[2]
			row.entry, row.charKey = e, charKey
			local sameDay = date("%Y-%m-%d", e.t) == date("%Y-%m-%d")
			row.when:SetText(sameDay and date("%H:%M", e.t) or date("%b %d %H:%M", e.t))
			local prefix = showAll and (ns.ClassColored(LedgerDB.chars[charKey]) .. ": ") or ""
			local times = (e.n and e.n > 1) and (" |cff999999(" .. e.n .. "x)|r") or ""
			row.detail:SetText(prefix .. e.d .. times)
			row.amount:SetText(ns.Money(e.a, true))
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	empty:SetText((view.search and view.search ~= "") and "No lines match your search in this period. Try All time."
		or "Nothing recorded for this period yet.")
	empty:SetShown(#list == 0)
	pageText:SetText(#list > 0 and format("%d-%d of %d", view.offset + 1, min(view.offset + ROWS, #list), #list) or "")
end

charButton:SetScript("OnClick", function(self)
	MenuUtil.CreateContextMenu(self, function(_, root)
		root:CreateTitle("Show")
		root:CreateRadio("All characters",
			function() return ledger.view.char == "all" end,
			function() ledger.view.char = "all"; ledger.view.offset = 0; ns.RefreshLedger() end)
		for _, key in ipairs(ns.SortedChars()) do
			root:CreateRadio(ns.ClassColored(LedgerDB.chars[key]),
				function(k) return (ledger.view.char or ns.me) == k end,
				function(k) ledger.view.char = k; ledger.view.offset = 0; ns.RefreshLedger() end, key)
		end
	end)
end)

ledger:SetScript("OnShow", function()
	ns.RefreshLedger()
end)

function ns.ToggleLedger()
	ledger:SetShown(not ledger:IsShown())
end


--[[ Startup and commands ]]--

ns.On("PLAYER_LOGIN", function()
	settings = LedgerDB.settings
	if settings.showCounter == nil then
		settings.showCounter = true
	end
	LoadPosition(counter, "counterPos", { "TOP", UIParent, "TOP", 0, -120 })
	settings.ledgerScale = settings.ledgerScale or 1
	ledger:SetScale(settings.ledgerScale)
	LoadPosition(ledger, "ledgerPos", { "CENTER", UIParent, "CENTER", 0, 40 })
	if settings.counterTooltip == nil then
		settings.counterTooltip = true
	end
	settings.lockCounter = settings.lockCounter or false
	settings.counterScale = settings.counterScale or 1
	settings.counterAlpha = settings.counterAlpha or 0.75
	ns.ApplyCounterSettings()
	ns.UpdateCounter()

	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if loaded and loaded("AllemanoLedger") then
		ns.Print("Allemano Ledger is also on, and it may take the /ledger command (use /gl). You can turn it off at character select.")
	end
end)

SLASH_LEDGER1 = "/ledger"
SLASH_LEDGER2 = "/gl"
SlashCmdList.LEDGER = function(msg)
	local cmd = strtrim(msg or ""):lower()
	if cmd == "" or cmd == "ledger" or cmd == "gold" then
		if cmd == "gold" then
			ledger.view.mode = "gold"
			ledger:Show()
			ns.RefreshLedger()
		else
			ns.ToggleLedger()
		end
	elseif cmd == "loot" then
		ledger.view.mode = "loot"
		ledger:Show()
		ns.RefreshLedger()
	elseif cmd == "clear" then
		ns.ShowClear()
	elseif cmd == "lootinfo" then
		ns.lootDebug = not ns.lootDebug
		ns.Print("loot details in chat " .. (ns.lootDebug and "ON: loot a few mobs, skin one, then type /ledger lootinfo again to stop." or "off."))
	elseif cmd == "counter" then
		settings.showCounter = not settings.showCounter
		counter:SetShown(settings.showCounter)
		ns.Print("counter " .. (settings.showCounter and "shown" or "hidden"))
	elseif cmd == "reset" then
		ns.ResetCounter()
		ns.Print("counter reset.")
	elseif cmd == "options" or cmd == "config" then
		if ns.OpenOptions then
			ns.OpenOptions()
		end
	elseif cmd == "errors" then
		local list = LedgerDB.errors or {}
		if #list == 0 then
			ns.Print("no errors recorded.")
		end
		for _, e in ipairs(list) do
			print(date("%H:%M", e.t) .. " " .. e.where .. ": " .. e.msg)
		end
	else
		ns.Print("commands (/gl works too):")
		print("  /ledger           - open or close the Ledger")
		print("  /ledger gold      - open the gold view")
		print("  /ledger loot      - open the loot table")
		print("  /ledger clear     - clear old data")
		print("  /ledger counter   - show or hide the on-screen counter")
		print("  /ledger reset     - reset the counter")
		print("  /ledger options   - open the options (also in Options > AddOns)")
		print("  /ledger errors    - show recent errors")
		print("  /ledger lootinfo  - print loot details in chat (for testing)")
	end
end
