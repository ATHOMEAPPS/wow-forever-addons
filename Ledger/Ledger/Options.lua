--[[
	Ledger - Options.lua
	The page under Options > AddOns > Ledger (Blizzard Settings API).
	Values live in LedgerDB.settings; UI.lua applies them.
]]

local ADDON, ns = ...

local category

ns.On("PLAYER_LOGIN", function()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then
		return
	end
	local settings = LedgerDB.settings
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("Ledger")

	local function Checkbox(variable, key, label, tooltip, onChange)
		local setting = Settings.RegisterProxySetting(category, variable, Settings.VarType.Boolean, label,
			settings[key] ~= false,
			function() return settings[key] ~= false end,
			function(value)
				settings[key] = value
				if onChange then
					onChange(value)
				end
			end)
		Settings.CreateCheckbox(category, setting, tooltip)
	end

	local function Percent(value)
		return format("%d%%", floor(value * 100 + 0.5))
	end

	local function Slider(variable, key, label, tooltip, default, minValue, maxValue, step, formatter)
		local setting = Settings.RegisterProxySetting(category, variable, Settings.VarType.Number, label, default,
			function() return settings[key] or default end,
			function(value)
				settings[key] = value
				ns.ApplyCounterSettings()
			end)
		local options = Settings.CreateSliderOptions(minValue, maxValue, step)
		if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter or Percent)
		end
		Settings.CreateSlider(category, setting, options, tooltip)
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

	Header("Coin earned counter")
	Checkbox("LEDGER_SHOW_COUNTER", "showCounter", "Show coin earned counter",
		"Show the on-screen box with gold earned, spent, net and gold per hour since the last reset.",
		function() ns.ApplyCounterSettings() end)
	Header("What the counter shows")
	local function Part(key, label, tooltip)
		Checkbox("LEDGER_" .. key:upper(), key, label, tooltip, function() ns.UpdateCounter() end)
	end
	Part("showEarned", "Gold earned (big number)", "The gold earned since the last reset.")
	Part("showCoinIcon", "Gold coin icon", "The coin picture next to the earned number.")
	Part("showSpent", "Spent", "Gold spent since the last reset.")
	Part("showNet", "Net", "Earned minus spent.")
	Part("showCurrent", "Current gold", "The gold your character has now, the same as in your bags.")
	Part("showTime", "Time running", "How long since the last reset.")
	Part("showPerHour", "Gold per hour", "Gold earned per hour since the last reset.")
	Part("showResetButton", "Reset button", "The small circle-arrow button on the counter. You can still reset here or with /ledger reset.")
	Slider("LEDGER_EARNED_SIZE", "earnedSize", "Gold earned text size",
		"How big the earned number is. Use Counter size to resize the whole box.", 16, 10, 40, 1,
		function(value) return tostring(floor(value + 0.5)) end)

	Header("Counter look")
	Checkbox("LEDGER_COUNTER_TOOLTIP", "counterTooltip", "Show tooltip on mouse-over",
		"Show the \"Coin earned\" help tooltip when the mouse is over the counter.")
	Checkbox("LEDGER_LOCK_COUNTER", "lockCounter", "Lock counter position",
		"Stop the counter from being dragged by accident.")
	Slider("LEDGER_COUNTER_SCALE", "counterScale", "Counter size",
		"How big the whole counter is. You can also hold Ctrl and use the mouse wheel over the counter.", 1, 0.5, 2, 0.05)
	Slider("LEDGER_COUNTER_ALPHA", "counterAlpha", "Background opacity",
		"How dark the counter's background is. 0% = only the text shows.", 0.75, 0, 1, 0.05)
	Button("Reset counter", "Reset", function()
		ns.ResetCounter()
		ns.Print("counter reset.")
	end, "Start counting from zero. The Ledger keeps everything.")
	Button("Counter position", "Move to top", function()
		ns.ResetCounterPosition()
	end, "Put the counter back at the top middle of the screen.")

	Header("Ledger")
	Button("Ledger", "Open Ledger", function()
		if SettingsPanel and SettingsPanel:IsShown() and HideUIPanel then
			HideUIPanel(SettingsPanel)
		end
		ns.ToggleLedger()
	end, "See where your gold came from and went, by day, week and month. Same as /ledger.")
	Button("Loot table", "Open Loot", function()
		if SettingsPanel and SettingsPanel:IsShown() and HideUIPanel then
			HideUIPanel(SettingsPanel)
		end
		SlashCmdList.LEDGER("loot")
	end, "What mobs dropped, what it sold for, and who drops the most of an item. Same as /ledger loot.")

	Header("Saved data")
	Button("Clear old data", "Clear...", function()
		ns.ShowClear()
	end, "Remove data older than 1 month, 3 months, 6 months or 1 year (or everything), for every character. You see how much goes before anything is removed. Same as /ledger clear.")

	Settings.RegisterAddOnCategory(category)
end)

function ns.OpenOptions()
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	end
end
