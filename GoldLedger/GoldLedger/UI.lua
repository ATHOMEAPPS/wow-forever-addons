--[[
	GoldLedger - UI.lua
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

local counter = CreateFrame("Button", "GoldLedgerCounter", UIParent, "BackdropTemplate")
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

	-- which parts to show (each can be turned off in Options > AddOns > GoldLedger)
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
	GameTooltip:AddLine(settings and settings.lockCounter and "Locked (unlock in Options > AddOns > GoldLedger)" or "Drag: move", 0.6, 0.8, 1)
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

local ledger = CreateFrame("Frame", "GoldLedgerFrame", UIParent, "BackdropTemplate")
ledger:SetSize(760, 520)
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
tinsert(UISpecialFrames, "GoldLedgerFrame")
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

ledger.view = { char = nil, period = "today", cat = nil, sign = nil, offset = 0 }

local title = ledger:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("Gold Ledger")

local close = CreateFrame("Button", nil, ledger, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

-- character picker
local charButton = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
charButton:SetSize(170, 22)
charButton:SetPoint("LEFT", title, "RIGHT", 16, 0)

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
local search = CreateFrame("EditBox", "GoldLedgerSearchBox", ledger, "SearchBoxTemplate")
search:SetSize(180, 20)
search:SetPoint("TOPRIGHT", -36, -13)
search:HookScript("OnTextChanged", function(self)
	local text = strtrim(self:GetText() or ""):lower()
	if text ~= (ledger.view.search or "") then
		ledger.view.search = text
		ledger.view.offset = 0
		ns.RefreshLedger()
	end
end)
search:HookScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:SetText("Search")
	GameTooltip:AddLine("Find lines by item, player, sender, zone, quest, category or character. Searches the period you picked; choose All time to search everything.", 1, 1, 1, true)
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
	local char = GoldLedgerDB.chars[charKey]
	return (text .. " " .. ns.CategoryLabel(entry.c, entry.a) .. " " .. (char and char.name or "")):lower()
end

local rangeText = ledger:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
rangeText:SetPoint("LEFT", charButton, "RIGHT", 12, 0)

-- left: categories
local catPanel = CreateFrame("Frame", nil, ledger, "BackdropTemplate")
catPanel:SetPoint("TOPLEFT", 12, -94)
catPanel:SetSize(230, 410)
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
		GameTooltip:AddDoubleLine("Character", ns.ClassColored(GoldLedgerDB.chars[self.charKey]), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	listRows[i] = row
end

local empty = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("CENTER")
empty:SetText("Nothing recorded for this period yet.")


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
			local prefix = showAll and (ns.ClassColored(GoldLedgerDB.chars[charKey]) .. ": ") or ""
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
			root:CreateRadio(ns.ClassColored(GoldLedgerDB.chars[key]),
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
	settings = GoldLedgerDB.settings
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
		ns.Print("Allemano Ledger is also on. You can turn it off at character select.")
	end
end)

SLASH_GOLDLEDGER1 = "/gl"
SLASH_GOLDLEDGER2 = "/goldledger"
SlashCmdList.GOLDLEDGER = function(msg)
	local cmd = strtrim(msg or ""):lower()
	if cmd == "" or cmd == "ledger" then
		ns.ToggleLedger()
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
		local list = GoldLedgerDB.errors or {}
		if #list == 0 then
			ns.Print("no errors recorded.")
		end
		for _, e in ipairs(list) do
			print(date("%H:%M", e.t) .. " " .. e.where .. ": " .. e.msg)
		end
	else
		ns.Print("commands:")
		print("  /gl          - open or close the Ledger")
		print("  /gl counter  - show or hide the on-screen counter")
		print("  /gl reset    - reset the counter")
		print("  /gl options  - open the options (also in Options > AddOns)")
		print("  /gl errors   - show recent errors")
	end
end
