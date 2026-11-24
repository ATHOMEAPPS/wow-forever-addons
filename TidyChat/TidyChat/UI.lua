--[[
	TidyChat - UI.lua
	1. The "While you were away" window (our own frame).
	2. A small on-screen notice while you're AFK and messages are waiting.
	3. The "please /reload" prompt after the Tells tab is made.
	4. /tc commands.

	Nothing here clicks into Blizzard's chat (no reply-on-click, no SetItemRef),
	so typing in chat is never touched by addon code.
]]

local ADDON, ns = ...

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function Hex(r, g, b)
	return format("ff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

local function KindColor(kind)
	local group = ns.KINDS[kind] and ns.KINDS[kind].color
	local info = group and ChatTypeInfo and ChatTypeInfo[group]
	if info and info.r then
		return info.r, info.g, info.b
	end
	return 1, 0.5, 1
end

local function ClassHex(class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return color and color.colorStr or "ffffffff"
end


--[[ 1. "While you were away" window ]]--

local away = CreateFrame("Frame", "TidyChatAwayFrame", UIParent, "BackdropTemplate")
away:SetSize(520, 320)
away:SetFrameStrata("DIALOG") -- above the Options window, so Options doesn't need closing
away:SetToplevel(true)
away:SetClampedToScreen(true)
away:SetMovable(true)
away:EnableMouse(true)
away:RegisterForDrag("LeftButton")
away:SetBackdrop(BACKDROP)
away:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
away:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
away:Hide()
tinsert(UISpecialFrames, "TidyChatAwayFrame") -- Esc closes it
away:SetScript("OnDragStart", away.StartMoving)
away:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	TidyChatDB.settings.awayPos = { point, relPoint, x, y }
end)

local title = away:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("While you were away")

local when = away:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
when:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
when:SetJustifyH("LEFT")

local close = CreateFrame("Button", nil, away, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local box = CreateFrame("Frame", nil, away, "BackdropTemplate")
box:SetPoint("TOPLEFT", 10, -52)
box:SetPoint("BOTTOMRIGHT", -10, 40)
box:SetBackdrop(BACKDROP)
box:SetBackdropColor(0, 0, 0, 0.5)
box:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

local lines = CreateFrame("ScrollingMessageFrame", nil, box)
lines:SetPoint("TOPLEFT", 8, -8)
lines:SetPoint("BOTTOMRIGHT", -8, 8)
lines:SetFontObject(ChatFontNormal)
lines:SetJustifyH("LEFT")
lines:SetFading(false)
lines:SetMaxLines(400)
lines:SetInsertMode("BOTTOM")
lines:SetIndentedWordWrap(true)
lines:SetHyperlinksEnabled(true)
lines:EnableMouseWheel(true)
lines:SetScript("OnMouseWheel", function(self, delta)
	if delta > 0 then
		self:ScrollUp()
	else
		self:ScrollDown()
	end
end)
-- item links show their tooltip on mouse-over (no clicking into chat)
lines:SetScript("OnHyperlinkEnter", function(self, link)
	if type(link) == "string" and link:match("^item:") then
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetHyperlink(link)
		GameTooltip:Show()
	end
end)
lines:SetScript("OnHyperlinkLeave", GameTooltip_Hide)

local empty = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("CENTER")
empty:SetText("Nothing was said while you were away.")

local clearButton = CreateFrame("Button", nil, away, "UIPanelButtonTemplate")
clearButton:SetSize(90, 22)
clearButton:SetPoint("BOTTOMLEFT", 12, 10)
clearButton:SetText("Clear")
clearButton:SetScript("OnClick", function()
	TidyChatDB.away = nil
	ns.RefreshAway()
	ns.UpdateNotice()
end)

local closeButton = CreateFrame("Button", nil, away, "UIPanelButtonTemplate")
closeButton:SetSize(90, 22)
closeButton:SetPoint("BOTTOMRIGHT", -26, 10)
closeButton:SetText("Close")
closeButton:SetScript("OnClick", function() away:Hide() end)

local hint = away:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("LEFT", clearButton, "RIGHT", 10, 0)
hint:SetPoint("RIGHT", closeButton, "LEFT", -10, 0)
hint:SetJustifyH("LEFT")
hint:SetText("Reply from the " .. ns.TAB_NAME .. " tab or with /r.")

-- resize grip (bottom right): changes the window's scale, so the text grows too
do
	local grip = CreateFrame("Button", nil, away)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetFrameLevel(away:GetFrameLevel() + 10)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	local startX, startWidth, startScale, left, top
	local function Resizing()
		local x = GetCursorPosition()
		local scale = startScale * (startWidth + (x - startX)) / startWidth
		scale = max(0.5, min(2, floor(scale * 100 + 0.5) / 100))
		away:SetScale(scale)
		local eff = away:GetEffectiveScale()
		away:ClearAllPoints()
		away:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / eff, top / eff)
		TidyChatDB.settings.awayScale = scale
	end
	grip:SetScript("OnMouseDown", function()
		local eff = away:GetEffectiveScale()
		startX = GetCursorPosition()
		startWidth = away:GetWidth() * eff
		startScale = away:GetScale()
		left, top = away:GetLeft() * eff, away:GetTop() * eff
		grip:SetScript("OnUpdate", Resizing)
	end)
	grip:SetScript("OnMouseUp", function()
		grip:SetScript("OnUpdate", nil)
		local point, _, relPoint, x, y = away:GetPoint()
		TidyChatDB.settings.awayPos = { point, relPoint, x, y }
	end)
	grip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to resize")
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", GameTooltip_Hide)
end

function ns.RefreshAway()
	if not away:IsShown() then
		return
	end
	lines:Clear()
	local data = TidyChatDB.away
	local list = data and data.list or {}

	if data and data.start then
		local stop = data.stop and date("%H:%M", data.stop) or "now"
		when:SetText(format("%s, %s to %s  |  %d message%s", date("%a %b %d", data.start),
			date("%H:%M", data.start), stop, #list, #list == 1 and "" or "s"))
	else
		when:SetText("")
	end

	for _, e in ipairs(list) do
		local r, g, b = KindColor(e.k)
		local kind = ns.KINDS[e.k] and ns.KINDS[e.k].label or e.k
		local from = e.from or "?"
		lines:AddMessage(format("|cff999999%s|r |c%s[%s]|r |c%s%s|r: %s", date("%H:%M", e.t), Hex(r, g, b), kind,
			ClassHex(e.class), from, e.text or ""), r, g, b)
	end
	lines:ScrollToBottom()
	empty:SetShown(#list == 0)
end

function ns.ShowAway()
	away:Show()
end

away:SetScript("OnShow", function()
	ns.RefreshAway()
	ns.UpdateNotice()
end)


--[[ 2. On-screen notice while AFK ]]--

local notice = CreateFrame("Button", "TidyChatNotice", UIParent, "BackdropTemplate")
notice:SetSize(240, 28)
notice:SetPoint("TOP", UIParent, "TOP", 0, -90)
notice:SetFrameStrata("MEDIUM")
notice:SetBackdrop(BACKDROP)
notice:SetBackdropColor(0, 0, 0, 0.8)
notice:SetBackdropBorderColor(1, 0.5, 1, 0.9)
notice:Hide()
local noticeText = notice:CreateFontString(nil, "OVERLAY", "GameFontNormal")
noticeText:SetPoint("CENTER")
notice:SetScript("OnClick", function() ns.ShowAway() end)

function ns.UpdateNotice()
	local data = TidyChatDB and TidyChatDB.away
	local count = data and data.list and #data.list or 0
	if ns.isAway and TidyChatDB.settings.capture then
		if count > 0 then
			noticeText:SetFormattedText("TidyChat: %d new message%s (click)", count, count == 1 and "" or "s")
		else
			noticeText:SetText("TidyChat: AFK, saving whispers and party chat")
		end
		notice:SetWidth(noticeText:GetStringWidth() + 30)
		notice:Show()
	else
		notice:Hide()
	end
end


--[[ 3. Reload prompt (our own frame; ReloadUI runs from a button click) ]]--

local prompt = CreateFrame("Frame", "TidyChatReloadPrompt", UIParent, "BackdropTemplate")
prompt:SetSize(380, 110)
prompt:SetPoint("CENTER", 0, 120)
prompt:SetFrameStrata("FULLSCREEN_DIALOG")
prompt:SetBackdrop(BACKDROP)
prompt:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
prompt:SetBackdropBorderColor(1, 0.82, 0, 1)
prompt:Hide()
local promptText = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
promptText:SetPoint("TOP", 0, -16)
promptText:SetWidth(340)
promptText:SetText("TidyChat made the " .. ns.TAB_NAME .. " tab.\n|cffff4040Reload before you type in chat.|r")
local reloadButton = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
reloadButton:SetSize(120, 24)
reloadButton:SetPoint("BOTTOMRIGHT", prompt, "BOTTOM", -6, 14)
reloadButton:SetText("Reload now")
reloadButton:SetScript("OnClick", function() ReloadUI() end)
local laterButton = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
laterButton:SetSize(120, 24)
laterButton:SetPoint("BOTTOMLEFT", prompt, "BOTTOM", 6, 14)
laterButton:SetText("Later")
laterButton:SetScript("OnClick", function()
	prompt:Hide()
	ns.Print("|cffff4040don't type in chat until you /reload.|r")
end)

function ns.ShowReloadPrompt()
	prompt:Show()
end


--[[ 3b. Welcome box: offers to make the Tells tab while it doesn't exist ]]--

local welcome = CreateFrame("Frame", "TidyChatWelcome", UIParent, "BackdropTemplate")
welcome:SetSize(400, 150)
welcome:SetPoint("CENTER", 0, 140)
welcome:SetFrameStrata("DIALOG")
welcome:SetBackdrop(BACKDROP)
welcome:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
welcome:SetBackdropBorderColor(1, 0.5, 1, 1)
welcome:Hide()
local welcomeTitle = welcome:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
welcomeTitle:SetPoint("TOP", 0, -14)
welcomeTitle:SetText("TidyChat")
local welcomeText = welcome:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
welcomeText:SetPoint("TOP", welcomeTitle, "BOTTOM", 0, -8)
welcomeText:SetWidth(360)
welcomeText:SetText("Make a \"" .. ns.TAB_NAME .. "\" chat tab for whispers and party chat?\n"
	.. "|cff999999It's made once, then the game reloads.|r")
local makeButton = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
makeButton:SetSize(116, 24)
makeButton:SetPoint("BOTTOMLEFT", 14, 14)
makeButton:SetText("Make the tab")
makeButton:SetScript("OnClick", function()
	welcome:Hide()
	ns.SafeCreateTab()
end)
local notNowButton = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
notNowButton:SetSize(116, 24)
notNowButton:SetPoint("BOTTOM", 0, 14)
notNowButton:SetText("Not now")
notNowButton:SetScript("OnClick", function()
	welcome:Hide()
	ns.Print("I'll ask again next time. Or type |cffffff00/tc setup|r any time.")
end)
local neverButton = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
neverButton:SetSize(116, 24)
neverButton:SetPoint("BOTTOMRIGHT", -14, 14)
neverButton:SetText("Don't ask again")
neverButton:SetScript("OnClick", function()
	welcome:Hide()
	TidyChatDB.settings.tabDeclined = true
	ns.Print("OK. You can still make it with |cffffff00/tc setup|r or in Options > AddOns > TidyChat.")
end)

-- a few seconds after login, so the game has loaded its chat windows first
local function OfferTab()
	if ns.FindTab() or TidyChatDB.settings.tabDeclined then
		return
	end
	if InCombatLockdown() then
		C_Timer.After(5, OfferTab)
		return
	end
	welcome:Show()
end


--[[ Startup ]]--

ns.On("PLAYER_LOGIN", function()
	local s = TidyChatDB.settings
	away:SetScale(s.awayScale or 1)
	away:ClearAllPoints()
	local p = s.awayPos
	if p then
		away:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		away:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	end
	s.tabOffered = nil -- (1.0-1.2 setting, replaced by the welcome box)
	if C_Timer and C_Timer.After then
		C_Timer.After(4, function()
			local ok, err = pcall(OfferTab)
			if not ok then
				ns.Error("welcome", err)
			end
		end)
	end
end)


--[[ 4. Commands ]]--

SLASH_TIDYCHAT1 = "/tidychat"
SLASH_TIDYCHAT2 = "/tc"
SlashCmdList.TIDYCHAT = function(msg)
	local cmd = strlower(strtrim(msg or ""))
	if cmd == "" or cmd == "away" then
		if away:IsShown() then
			away:Hide()
		else
			ns.ShowAway()
		end
	elseif cmd == "setup" then
		ns.SafeCreateTab()
	elseif cmd == "options" or cmd == "config" then
		ns.OpenOptions()
	elseif cmd == "clear" then
		TidyChatDB.away = nil
		ns.RefreshAway()
		ns.UpdateNotice()
		ns.Print("away list cleared.")
	elseif cmd == "test" then
		ns.AddTestMessages()
		ns.ShowAway()
		ns.Print("added 4 test messages. /tc clear removes them.")
	elseif cmd == "status" then
		local afk = UnitIsAFK("player")
		local afkText = ns.IsSecret(afk) and "hidden by the game right now" or (afk and "yes" or "no")
		local data = TidyChatDB.away
		ns.Print("status:")
		print("  AFK flag: " .. afkText .. "   chat lockdown: " .. (ns.InLockdown() and "ON" or "off"))
		print("  saving now: " .. (ns.isAway and "yes" or "no") .. "   saving while AFK is " .. (TidyChatDB.settings.capture and "on" or "OFF (Options)"))
		print("  away list: " .. (data and data.list and #data.list or 0) .. " message(s)")
		print("  Tells tab: " .. (ns.FindTab() and "yes" or "not made yet (/tc setup)"))
		local log = TidyChatDB.log or {}
		print("  last AFK checks:")
		for i = max(1, #log - 7), #log do
			print("    " .. date("%H:%M:%S", log[i].t) .. "  " .. log[i].what)
		end
	elseif cmd == "errors" then
		local errors = TidyChatDB.errors or {}
		if #errors == 0 then
			ns.Print("no errors.")
		end
		for _, e in ipairs(errors) do
			print(format("  %s %s: %s", date("%H:%M", e.t), e.where, e.msg))
		end
	else
		ns.Print("commands:")
		print("  /tc          - show or hide what was said while you were away")
		print("  /tc setup    - make the " .. ns.TAB_NAME .. " tab (whispers and party chat), then /reload")
		print("  /tc options  - open the options (also Options > AddOns > TidyChat)")
		print("  /tc clear    - clear the away list")
		print("  /tc test     - add test messages to see the window")
		print("  /tc status   - is TidyChat saving right now? (and the last AFK checks)")
		print("  /tc errors   - show recent errors")
		print("  Font size and background of a tab: right-click the tab.")
	end
end
