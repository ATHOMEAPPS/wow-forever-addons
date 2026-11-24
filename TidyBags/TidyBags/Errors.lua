--[[
	TidyBags - Errors.lua  (loads first)
	Saves problems so they can be fixed later. WoW Forever hides Lua errors and
	the "blocked from an action / Disable or Ignore" box doesn't say much.

	TidyBagsDB.errors = { { t = time, kind = "lua"|"event"|"blocked", where, msg, combat, item, mouse }, ... }  -- last 30

	What is caught:
	  1. Lua errors in any TidyBags file, including while it loads and in button
	     scripts: the game's error handler is chained (we record, then pass the
	     error on unchanged). Only messages mentioning TidyBags are saved.
	  2. Errors in TidyBags' event code (ns.On, in Data.lua, calls ns.Error).
	  3. Every "blocked" / "forbidden" action, whichever addon the game blames:
	     ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN (addon, function),
	     MACRO_ACTION_BLOCKED / MACRO_ACTION_FORBIDDEN (function).
	     Saved with: in combat or not, the item in the tooltip, the frame under the mouse.

	Nothing here touches item buttons or Blizzard frames. /tb errors shows the list.
]]

local ADDON, ns = ...

local MAX = 30
local pending = {}   -- caught before the saved variables are loaded
local warned = false

local function Readable(v)
	if v == nil then return nil end
	if canaccessvalue and not canaccessvalue(v) then return "(hidden)" end
	if issecretvalue and issecretvalue(v) then return "(hidden)" end
	return tostring(v)
end

-- what the player was pointing at: the tooltip's item and the frame under the mouse
local function Context()
	local item, mouse
	pcall(function()
		if GameTooltip and GameTooltip:IsShown() then
			local _, link = GameTooltip:GetItem()
			item = Readable(link)
		end
	end)
	pcall(function()
		local foci = GetMouseFoci and GetMouseFoci()
		local f = foci and foci[1]
		if f and f.GetDebugName then
			mouse = Readable(f:GetDebugName())
		end
	end)
	return item, mouse
end

local function Store(entry)
	if TidyBagsDB then
		TidyBagsDB.errors = TidyBagsDB.errors or {}
		local list = TidyBagsDB.errors
		-- the same thing again within a minute: count it instead of a new line
		local last = list[#list]
		if last and last.kind == entry.kind and last.where == entry.where and last.msg == entry.msg
				and entry.t - last.t < 60 then
			last.n = (last.n or 1) + 1
			last.t = entry.t
			return
		end
		tinsert(list, entry)
		while #list > MAX do
			tremove(list, 1)
		end
	else
		tinsert(pending, entry)
	end
end

local function Tell(text)
	print("|cff33ccffTidyBags|r: " .. text)
end

function ns.Error(where, err, kind)
	local item, mouse = Context()
	local combat = InCombatLockdown and InCombatLockdown() or false
	Store({ t = time(), kind = kind or "event", where = Readable(where) or "?",
		msg = (Readable(err) or "?"):sub(1, 400), combat = combat, item = item, mouse = mouse })
	if not warned then
		warned = true
		Tell("saved an error (" .. (Readable(where) or "?") .. "). /tb errors shows it.")
	end
end


--[[ 1. Lua errors from TidyBags files (chained onto the game's handler) ]]--

do
	local previous = geterrorhandler and geterrorhandler()
	if previous and seterrorhandler then
		seterrorhandler(function(msg, ...)
			pcall(function()
				local text = Readable(msg) or ""
				if text:find("TidyBags", 1, true) then
					local stack = debugstack and Readable(debugstack(3, 6, 0)) or nil
					local where = text:match("([%w_]+%.lua:%d+)") or "lua"
					ns.Error(where, text .. (stack and ("\n" .. stack) or ""), "lua")
				end
			end)
			return previous(msg, ...)
		end)
	end
end


--[[ 3. Blocked actions (the "Disable or Ignore" box), for any addon ]]--

local blockFrame = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "MACRO_ACTION_BLOCKED", "MACRO_ACTION_FORBIDDEN" }) do
	pcall(blockFrame.RegisterEvent, blockFrame, event)
end
blockFrame:SetScript("OnEvent", function(_, event, a, b)
	local addon, func
	if event:find("^MACRO") then
		addon, func = "(macro)", Readable(a)
	else
		addon, func = Readable(a), Readable(b)
	end
	local item, mouse = Context()
	local combat = InCombatLockdown and InCombatLockdown() or false
	Store({ t = time(), kind = "blocked", where = event, msg = (addon or "?") .. " -> " .. (func or "?"),
		addon = addon, func = func, combat = combat, item = item, mouse = mouse })
	Tell(format("the game blocked |cffffd100%s|r and blamed |cffffd100%s|r%s. Saved; /tb errors shows it.",
		func or "?", addon or "?", combat and " (in combat)" or ""))
	if GetCVar and GetCVar("taintLog") == "0" then
		Tell("for the full story type |cffffffff/console taintLog 1|r, do it again, then log out (writes Logs\\taint.log).")
	end
end)


--[[ Saved variables are ready: keep what was caught while loading ]]--

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")
	TidyBagsDB = TidyBagsDB or {}
	for _, entry in ipairs(pending) do
		Store(entry)
	end
	pending = {}
end)


--[[ /tb errors ]]--

function ns.ShowErrors(arg)
	if arg == "clear" then
		if TidyBagsDB then TidyBagsDB.errors = {} end
		Tell("error list cleared.")
		return
	end
	local list = TidyBagsDB and TidyBagsDB.errors or {}
	if #list == 0 then
		Tell("no errors or blocked actions saved.")
		return
	end
	Tell(#list .. " saved (oldest first). /tb errors clear empties the list.")
	for _, e in ipairs(list) do
		local times = (e.n and e.n > 1) and (" x" .. e.n) or ""
		print(format("|cff999999%s|r |cffffd100%s|r%s %s%s", date("%m-%d %H:%M", e.t), e.kind, times,
			e.where, e.combat and " |cffff7070(combat)|r" or ""))
		print("   " .. (e.msg or ""):gsub("\n.*", ""))
		if e.item or e.mouse then
			print("   |cff999999item:|r " .. (e.item or "-") .. "  |cff999999mouse:|r " .. (e.mouse or "-"))
		end
	end
end
