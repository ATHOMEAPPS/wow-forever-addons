--[[
	TidyChat - Options.lua
	The page under Options > AddOns > TidyChat (Blizzard Settings API).
	TidyChat's own values live in TidyChatDB.settings. Timestamps and class
	colours are Blizzard's own chat settings (CVars), shown here as shortcuts.
]]

local ADDON, ns = ...

local category

ns.On("PLAYER_LOGIN", function()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then
		return
	end
	local settings = TidyChatDB.settings
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("TidyChat")

	local function Checkbox(variable, label, tooltip, get, set)
		local setting = Settings.RegisterProxySetting(category, variable, Settings.VarType.Boolean, label, get(), get, set)
		Settings.CreateCheckbox(category, setting, tooltip)
	end

	local function Own(key)
		return function() return settings[key] ~= false end,
			function(value) settings[key] = value end
	end

	local function Button(label, buttonText, onClick, tooltip)
		if CreateSettingsButtonInitializer then
			layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
		end
	end

	local function Header(text)
		if CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
		end
	end

	-- (the Options window is not closed from here: HideUIPanel is Blizzard's panel
	-- code. The away window and reload prompt sit above it instead.)
	Header("Tells tab")
	Button("Tells tab", "Make the tab", function()
		ns.SafeCreateTab()
	end, "Make a chat tab named \"" .. ns.TAB_NAME .. "\" that shows whispers, Battle.net whispers and party chat. "
		.. "Then reload. They also stay in your General tab. Same as /tc setup.")

	Header("While you were away")
	local get, set = Own("capture")
	Checkbox("TIDYCHAT_CAPTURE", "Save whispers and party chat while AFK", "While you are AFK, keep every whisper, "
		.. "Battle.net whisper and party message, with the time. Kept after logout.", get, set)
	get, set = Own("showWhenBack")
	Checkbox("TIDYCHAT_SHOW_WHEN_BACK", "Show the list when I come back", "Open the \"While you were away\" window "
		.. "when you stop being AFK, if anything was said. /tc opens it any time.", get, set)
	Button("Away messages", "Show list", function()
		ns.ShowAway()
	end, "Show what was said while you were away. Same as /tc.")

	Header("Whisper alerts")
	get, set = Own("flash")
	Checkbox("TIDYCHAT_FLASH", "Flash the taskbar on a whisper", "Flash the WoW icon on the Windows taskbar when "
		.. "someone whispers you while you're in another window.", get, set)
	get, set = Own("loudSound")
	Checkbox("TIDYCHAT_LOUD_SOUND", "Whisper sound on the Master channel", "Also play the whisper sound on the "
		.. "Master volume channel, so you hear it even with sound effects turned down.", get, set)

	Header("Easier reading")
	get, set = Own("noFade")
	Checkbox("TIDYCHAT_NO_FADE", "Chat text doesn't fade", "Keep chat lines on screen instead of fading them out "
		.. "after 2 minutes.", get, function(value)
			settings.noFade = value
			ns.ApplyFading()
		end)
	Checkbox("TIDYCHAT_TIMESTAMPS", "Timestamps", "Show the time in front of every chat line "
		.. "(Blizzard's own setting, also in Options > Social).", ns.TimestampsOn, ns.SetTimestamps)
	Checkbox("TIDYCHAT_CLASS_COLORS", "Names in class colours", "Show player names in chat in their class colour "
		.. "(Blizzard's own setting).", ns.ClassColorsOn, ns.SetClassColors)

	Settings.RegisterAddOnCategory(category)
end)

function ns.OpenOptions()
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	end
end
