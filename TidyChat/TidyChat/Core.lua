--[[
	TidyChat - Core.lua
	Saved data, the Tells tab setup, easier-reading chat settings, whisper
	alerts, and saving whispers and party chat while you're AFK.

	TAINT RULE (why the Tells tab is made once, then /reload):
	Typing in chat ends in C_ChatInfo.SendChatMessage, which is restricted.
	Blizzard's FCF_* chat-window functions write fields and globals (for example
	LAST_ACTIVE_CHAT_EDIT_BOX) that the typing path reads. If addon code runs
	them, those values are tainted until the next /reload. So:
	  - The Tells tab is created only when the player asks (/tc setup or the
	    Options button), and TidyChat then asks for a /reload. After that the game
	    rebuilds the tab from its own saved chat settings; no addon code is involved.
	  - Every login, TidyChat only uses C methods on chat frames (SetFading) and
	    CVars. It never calls FCF_* or ChatFrameUtil functions, never writes fields
	    on chat frames, and never hooks chat functions.

	SECRET MESSAGES:
	While C_ChatInfo.InChatMessagingLockdown() is true (probably combat or boss
	fights in instances), chat event text and sender names are "secret": an
	addon can't read, compare or save them. Blizzard's chat tabs still show them.
	TidyChat checks every value with issecretvalue before using it. For a
	secret message it saves only the time, the kind and the lineID (never
	secret), and after lockdown ends tries C_ChatInfo.GetChatLineText(lineID).

	TidyChatDB = {
	  settings = { ... },
	  away = { start = time, stop = time or nil,
	           list = { { t = time, k = kind, from = "Name", class = "PRIEST", text = "..." ,
	                      line = lineID (only while waiting for a secret message) } } },
	  errors = { { t, where, msg } },
	}
]]

local ADDON, ns = ...

ns.TAB_NAME = "Tells"

-- what the Tells tab shows (Blizzard message groups)
-- (WHISPER also holds your own sent whispers; BN_WHISPER holds your sent Battle.net whispers)
ns.TAB_GROUPS = { "WHISPER", "BN_WHISPER", "PARTY", "PARTY_LEADER" }

-- kinds of captured messages: label and the chat colour group used to colour them
ns.KINDS = {
	whisper = { label = "Whisper", color = "WHISPER" },
	bnet    = { label = "Battle.net", color = "BN_WHISPER" },
	party   = { label = "Party", color = "PARTY" },
	leader  = { label = "Party leader", color = "PARTY_LEADER" },
}

local DEFAULTS = {
	capture = true,        -- save whispers and party chat while AFK
	showWhenBack = true,   -- open the "While you were away" window when you come back
	flash = true,          -- flash the WoW taskbar icon on a whisper
	loudSound = false,     -- also play the whisper sound on the Master channel
	noFade = true,         -- chat text stays instead of fading after 2 minutes
	tabFontSize = 14,      -- font size the Tells tab is created with
}

local function IsSecret(v)
	return issecretvalue and issecretvalue(v) or false
end
ns.IsSecret = IsSecret

function ns.Print(msg)
	print("|cff33ff99TidyChat|r: " .. msg)
end


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
	if not TidyChatDB then
		return
	end
	TidyChatDB.errors = TidyChatDB.errors or {}
	local msg = IsSecret(err) and "(secret value)" or tostring(err):sub(1, 300)
	tinsert(TidyChatDB.errors, { t = time(), where = tostring(where), msg = msg })
	while #TidyChatDB.errors > 10 do
		tremove(TidyChatDB.errors, 1)
	end
	if not errorShown then
		errorShown = true
		ns.Print("hit an error (" .. tostring(where) .. "). /tc errors shows it.")
	end
end


--[[ The Tells tab ]]--

local function MaxWindows()
	return (Constants and Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatWindows)
		or NUM_CHAT_WINDOWS or 10
end

-- the chat window number of the Tells tab, or nil. Reads only (GetChatWindowInfo is a C function).
function ns.FindTab()
	for i = 1, MaxWindows() do
		local name = GetChatWindowInfo(i)
		if name == ns.TAB_NAME then
			return i
		end
	end
end

-- Runs Blizzard's own "new chat window" code, so it taints the chat input until
-- the next /reload. Only ever called when the player asks for it.
function ns.CreateTab()
	if ns.FindTab() then
		ns.Print("the " .. ns.TAB_NAME .. " tab already exists.")
		return false
	end
	if InCombatLockdown() then
		ns.Print("can't make the tab in combat. Try again after the fight.")
		return false
	end
	if not FCF_OpenNewWindow then
		ns.Print("this client has no chat window function (FCF_OpenNewWindow).")
		return false
	end
	local chatFrame, index = FCF_OpenNewWindow(ns.TAB_NAME, true)
	if not chatFrame then
		ns.Print("no free chat window. Close a chat tab (right-click it > Close Chat Window) and try again.")
		return false
	end
	for _, group in ipairs(ns.TAB_GROUPS) do
		chatFrame:AddMessageGroup(group)
	end
	local size = TidyChatDB.settings.tabFontSize
	if FCF_SetChatWindowFontSize and size then
		FCF_SetChatWindowFontSize(nil, chatFrame, size)
	end
	ns.Print("made the " .. ns.TAB_NAME .. " tab (window " .. tostring(index) .. "). |cffff4040Don't type in chat until you /reload.|r")
	ns.needsReload = true
	if ns.ShowReloadPrompt then
		ns.ShowReloadPrompt()
	end
	return true
end


-- the commands and the Options button call this, so a failure shows in /tc errors
function ns.SafeCreateTab()
	local ok, err = pcall(ns.CreateTab)
	if not ok then
		ns.Error("setup", err)
		ns.Print("couldn't make the tab. /tc errors shows why.")
	end
end


--[[ Easier reading ]]--

-- C methods on Blizzard's chat frames only (no fields, no FCF_ calls)
function ns.ApplyFading()
	local noFade = TidyChatDB.settings.noFade
	for i = 1, MaxWindows() do
		local frame = _G["ChatFrame" .. i]
		if frame and frame.SetFading then
			frame:SetFading(not noFade)
		end
	end
end

local function GetCVarValue(name)
	if C_CVar and C_CVar.GetCVar then
		return C_CVar.GetCVar(name)
	end
	return GetCVar(name)
end

local function SetCVarValue(name, value)
	if C_CVar and C_CVar.SetCVar then
		return C_CVar.SetCVar(name, value)
	end
	return SetCVar(name, value)
end

-- timestamps in front of chat lines (Blizzard's own setting, CVar showTimestamps)
function ns.TimestampsOn()
	local value = GetCVarValue("showTimestamps")
	return value ~= nil and value ~= "none" and value ~= ""
end

function ns.SetTimestamps(on)
	SetCVarValue("showTimestamps", on and (TIMESTAMP_FORMAT_HHMM or "%I:%M ") or "none")
end

-- sender names in their class colour (Blizzard's own setting; "0" = class colours on)
function ns.ClassColorsOn()
	return GetCVarValue("chatClassColorOverride") == "0"
end

function ns.SetClassColors(on)
	SetCVarValue("chatClassColorOverride", on and "0" or "1")
end


--[[ AFK and capture ]]--

ns.isAway = false
local pending = 0       -- secret messages waiting for lockdown to end
local recoverTicker
local CheckAFK
ns.afkState = "unknown" -- what the last check saw: "afk", "back" or "hidden" (secret)

-- short log of AFK checks, saved in TidyChatDB.log, to see what happened
function ns.Log(what)
	if not TidyChatDB then
		return
	end
	TidyChatDB.log = TidyChatDB.log or {}
	tinsert(TidyChatDB.log, { t = time(), what = what })
	while #TidyChatDB.log > 40 do
		tremove(TidyChatDB.log, 1)
	end
end

local function InLockdown()
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
		local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
		return ok and locked == true
	end
	return false
end
ns.InLockdown = InLockdown

local function Away()
	return TidyChatDB.away
end

local function StartAway()
	ns.isAway = true
	local old = TidyChatDB.away
	if old and old.list and #old.list > 0 then
		old.stop = nil -- not cleared yet: keep adding to the same list
	else
		TidyChatDB.away = { start = time(), list = {} }
	end
	ns.Log("away: started saving")
	if TidyChatDB.settings.capture then
		ns.Print("you're AFK. Saving whispers and party chat until you're back.")
	end
	if ns.UpdateNotice then
		ns.UpdateNotice()
	end
end

local function EndAway()
	ns.isAway = false
	local away = Away()
	if not away then
		return
	end
	away.stop = time()
	ns.Log("back: " .. #away.list .. " saved")
	if ns.UpdateNotice then
		ns.UpdateNotice()
	end
	if #away.list > 0 and TidyChatDB.settings.showWhenBack and ns.ShowAway then
		ns.ShowAway()
	end
end

function CheckAFK(why)
	local afk = UnitIsAFK("player")
	if IsSecret(afk) then
		-- can't tell during chat lockdown; keep the current state
		if ns.afkState ~= "hidden" then
			ns.afkState = "hidden"
			ns.Log("AFK flag hidden by the game (lockdown " .. tostring(InLockdown()) .. ", " .. tostring(why) .. ")")
		end
		return
	end
	afk = afk and true or false
	local state = afk and "afk" or "back"
	if state ~= ns.afkState then
		ns.Log("AFK flag " .. state .. " (" .. tostring(why) .. ")")
		ns.afkState = state
	end
	if afk and not ns.isAway then
		StartAway()
	elseif not afk and ns.isAway then
		EndAway()
	end
end

-- after lockdown ends, fill in secret messages from their line IDs
local function Recover()
	if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		return
	end
	local away = Away()
	if away then
		for _, entry in ipairs(away.list) do
			if entry.line then
				local ok, text = pcall(C_ChatInfo.GetChatLineText, entry.line)
				if ok and type(text) == "string" and not IsSecret(text) and text ~= "" then
					entry.text = text
				else
					entry.text = "(sent during combat; see the " .. ns.TAB_NAME .. " tab)"
				end
				entry.line = nil
			end
		end
	end
	pending = 0
	if recoverTicker then
		recoverTicker:Cancel()
		recoverTicker = nil
	end
	if ns.RefreshAway then
		ns.RefreshAway()
	end
end

local function Capture(kind, text, sender, lineID, guid, bnSenderID)
	CheckAFK("message")
	if not (TidyChatDB.settings.capture and ns.isAway) then
		return
	end
	local away = Away()
	if not away then
		-- the list was cleared while still AFK: start a new one instead of dropping messages
		TidyChatDB.away = { start = time(), list = {} }
		away = TidyChatDB.away
		ns.Log("away: new list (old one was cleared while AFK)")
	end
	local entry = { t = time(), k = kind }

	if IsSecret(text) or IsSecret(sender) then
		-- can't read it now. Keep only the line ID (never secret) and try later.
		entry.from = "?"
		entry.text = "(message during combat; waiting)"
		if type(lineID) == "number" and not IsSecret(lineID) then
			entry.line = lineID
			pending = pending + 1
			if not recoverTicker and C_Timer and C_Timer.NewTicker then
				recoverTicker = C_Timer.NewTicker(2, Recover)
			end
		else
			entry.text = "(sent during combat; see the " .. ns.TAB_NAME .. " tab)"
		end
	else
		entry.text = text
		if kind == "bnet" then
			local name
			if C_BattleNet and C_BattleNet.GetAccountInfoByID and type(bnSenderID) == "number" and not IsSecret(bnSenderID) then
				local info = C_BattleNet.GetAccountInfoByID(bnSenderID)
				local tag = info and info.battleTag
				if type(tag) == "string" and not IsSecret(tag) then
					name = tag:match("^[^#]+")
				end
			end
			entry.from = name or "Battle.net friend"
		else
			entry.from = Ambiguate and Ambiguate(sender, "none") or sender
			if type(guid) == "string" and not IsSecret(guid) and guid ~= "" then
				local _, class = GetPlayerInfoByGUID(guid)
				if type(class) == "string" and not IsSecret(class) then
					entry.class = class
				end
			end
		end
	end

	tinsert(away.list, entry)
	while #away.list > 300 do
		tremove(away.list, 1)
	end
	if ns.UpdateNotice then
		ns.UpdateNotice()
	end
	if ns.RefreshAway then
		ns.RefreshAway()
	end
end

-- fake messages for testing the window without anyone whispering
function ns.AddTestMessages()
	if not ns.isAway then
		TidyChatDB.away = { start = time() - 600, stop = time(), list = {} }
	end
	local list = Away().list
	tinsert(list, { t = time() - 540, k = "whisper", from = "Testfriend", class = "MAGE", text = "Hey, want to run a dungeon?" })
	tinsert(list, { t = time() - 300, k = "party", from = "Testfriend", class = "MAGE", text = "We're at the summoning stone." })
	tinsert(list, { t = time() - 120, k = "leader", from = "Testleader", class = "WARRIOR", text = "Pulling in 1 minute." })
	tinsert(list, { t = time() - 60, k = "whisper", from = "?", text = "(sent during combat; see the " .. ns.TAB_NAME .. " tab)" })
end


--[[ Whisper alerts ]]--

local function Alert()
	local s = TidyChatDB.settings
	if s.flash and FlashClientIcon then
		FlashClientIcon()
	end
	if s.loudSound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then
		PlaySound(SOUNDKIT.TELL_MESSAGE, "Master")
	end
end


--[[ Startup and chat events ]]--

ns.On("PLAYER_LOGIN", function()
	TidyChatDB = TidyChatDB or {}
	TidyChatDB.settings = TidyChatDB.settings or {}
	for k, v in pairs(DEFAULTS) do
		if TidyChatDB.settings[k] == nil then
			TidyChatDB.settings[k] = v
		end
	end
	ns.ApplyFading()
	-- an AFK spell from the last session is over; keep its list for /tc
	if TidyChatDB.away and not TidyChatDB.away.stop then
		TidyChatDB.away.stop = time()
	end
	ns.Log("login")
	-- check AFK every 2 s as well as on events: the event can come while the
	-- flag is hidden (chat lockdown), and then no second event follows
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(2, function()
			local ok, err = pcall(CheckAFK, "timer")
			if not ok then
				ns.Error("timer", err)
			end
		end)
	end
end)

ns.On("PLAYER_ENTERING_WORLD", function()
	ns.ApplyFading()
	CheckAFK("entering world")
end)

ns.On("PLAYER_REGEN_ENABLED", function()
	CheckAFK("combat ended")
end)

ns.On("UPDATE_CHAT_WINDOWS", function()
	ns.ApplyFading()
end)

ns.On("PLAYER_FLAGS_CHANGED", function(_, unit)
	if unit == nil or IsSecret(unit) or unit == "player" then
		CheckAFK("flags event")
	end
end)

ns.On("CHAT_MSG_WHISPER", function(_, text, sender, _, _, _, _, _, _, _, _, lineID, guid)
	Alert()
	Capture("whisper", text, sender, lineID, guid)
end)

ns.On("CHAT_MSG_BN_WHISPER", function(_, text, sender, _, _, _, _, _, _, _, _, lineID, guid, bnSenderID)
	Alert()
	Capture("bnet", text, sender, lineID, guid, bnSenderID)
end)

ns.On("CHAT_MSG_PARTY", function(_, text, sender, _, _, _, _, _, _, _, _, lineID, guid)
	Capture("party", text, sender, lineID, guid)
end)

ns.On("CHAT_MSG_PARTY_LEADER", function(_, text, sender, _, _, _, _, _, _, _, _, lineID, guid)
	Capture("leader", text, sender, lineID, guid)
end)
