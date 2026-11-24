--[[
	TidyBags - Options.lua
	The page under Options > AddOns > TidyBags (Blizzard Settings API).
	Values live in TidyBagsDB (shared by every character); TidyBags.lua applies them
	through ns.ApplySetting. Each checkbox matches a /tb command.
]]

local ADDON, ns = ...

local category

-- Loads after TidyBags.lua, so this PLAYER_LOGIN listener runs after ns.db is set.
ns.On("PLAYER_LOGIN", function()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then
		return
	end
	local db = ns.db
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("TidyBags")

	local function Header(text)
		if CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
		end
	end

	local function Checkbox(variable, key, label, tooltip)
		local setting = Settings.RegisterProxySetting(category, variable, Settings.VarType.Boolean, label,
			db[key] and true or false,
			function() return db[key] and true or false end,
			function(value)
				db[key] = value and true or false
				ns.ApplySetting(key)
			end)
		Settings.CreateCheckbox(category, setting, tooltip)
	end

	Header("Bags")
	Checkbox("TIDYBAGS_SHOW_KEYRING", "showKeyring", "Show keyring slots",
		"Show the keyring at the bottom of the bag window. Its slots only take keys. Same as /tb keyring.")
	Checkbox("TIDYBAGS_AUTO_SORT", "autoSort", "Auto sort bags",
		"Sort the bags every time the bag window opens (not in combat). Same as the Auto sort box in the window.")
	Checkbox("TIDYBAGS_BAG_TYPES", "bagTypes", "Profession bag colours",
		"A light colour and the bag's icon on herb, mining, leather and other profession bag slots. Same as /tb bagtypes.")

	Header("Quest items")
	Checkbox("TIDYBAGS_QUEST_SECTION", "questSection", "Quest items at the top",
		"Put quest items in their own section at the top of the windows. Same as /tb questfirst.")
	Checkbox("TIDYBAGS_QUEST_GLOW", "questGlow", "Gold glow on quest items",
		"A gold glow around quest items. Same as /tb questglow.")
	Checkbox("TIDYBAGS_QUEST_WARN", "questWarn", "Warn when a quest item goes in the bank",
		"Screen text, a chat line and a sound when a quest item goes into either bank. Same as /tb questwarn.")

	Header("Tooltips")
	Checkbox("TIDYBAGS_TOOLTIP_COUNTS", "tooltipCounts", "Item counts in tooltips",
		"Show how many of an item each character has in their bags and bank. Same as /tb counts.")

	Settings.RegisterAddOnCategory(category)
end)

function ns.OpenOptions()
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	end
end
