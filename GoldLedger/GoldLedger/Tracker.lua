--[[
	GoldLedger - Tracker.lua
	Works out where every gold change came from.

	How it works:
	  1. Hooks and events that know what's about to happen leave a "claim":
	     the exact amount if known (mail money, quest reward, repair cost, a bid,
	     a sold item's price, trade money ...), a category and a detail text.
	  2. PLAYER_MONEY gives the change. Half a second later (so late events like
	     QUEST_TURNED_IN can still add their claim) each change is matched:
	       a. a claim with the EXACT amount   (this keeps "Open All" mail correct)
	       b. a claim without amount, same direction (+/-), newest first
	       c. which window is open (merchant, mail, auction house, loot ...)
	       d. "Other"
	All hooks are hooksecurefunc on Blizzard functions: they run after the
	original and can't block or taint anything. UseContainerItem is never hooked.
]]

local ADDON, ns = ...

local CLAIM_SECONDS = 10
local CONTEXT_GRACE = 3   -- a window counts as open for a few seconds after it closes

local claims = {}
local pending = {}
local lastMoney           -- nil until we trust GetMoney()
local contexts = {}       -- contexts[name] = true while open, or the time it closed
local tradePartner, tradeClaim

local function Now()
	return GetTime()
end

-- hooksecurefunc, but errors are kept for /gl errors instead of vanishing
local function SafeHook(a, b, c)
	local fn = c or b
	local name = c and b or a
	local wrapped = function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			ns.Error(name, err)
		end
	end
	if c then
		hooksecurefunc(a, b, wrapped)
	else
		hooksecurefunc(a, wrapped)
	end
end


--[[ Claims ]]--

-- amount: exact signed copper, or nil. sign: +1 / -1 (needed when amount is nil)
-- entries: optional list of { amount, cat, detail } to record instead of one line
local function Claim(amount, sign, cat, detail, seconds, entries)
	tinsert(claims, {
		amount = amount, sign = sign or (amount and (amount > 0 and 1 or -1)),
		cat = cat, detail = detail, entries = entries,
		expires = Now() + (seconds or CLAIM_SECONDS),
	})
end
ns.Claim = Claim

local function TakeClaim(delta)
	local now = Now()
	for i = #claims, 1, -1 do
		if claims[i].expires < now then
			tremove(claims, i)
		end
	end
	-- exact amount, oldest first
	for i, claim in ipairs(claims) do
		if claim.amount == delta then
			return tremove(claims, i)
		end
	end
	-- one part of a split claim (mail: the gold and the postage can arrive as two changes)
	for _, claim in ipairs(claims) do
		if claim.entries then
			for j, e in ipairs(claim.entries) do
				if e[1] == delta then
					tremove(claim.entries, j)
					claim.amount = claim.amount and (claim.amount - delta) or nil
					if #claim.entries == 0 then
						claim.expires = 0
					end
					return { entries = { e } }
				end
			end
		end
	end
	-- no amount, same direction, newest first
	local sign = delta > 0 and 1 or -1
	for i = #claims, 1, -1 do
		local claim = claims[i]
		if not claim.amount and claim.sign == sign then
			return tremove(claims, i)
		end
	end
end


--[[ Open windows ]]--

local function Open(name)
	contexts[name] = true
end

local function Close(name)
	if contexts[name] == true then
		contexts[name] = Now()
	end
end

local function IsOpen(name)
	local state = contexts[name]
	return state == true or (state and Now() - state < CONTEXT_GRACE)
end

local function Zone()
	local name, instanceType = GetInstanceInfo()
	if instanceType and instanceType ~= "none" and name and name ~= "" then
		return name
	end
	return GetRealZoneText() or GetZoneText() or "?"
end

-- no claim matched: guess from what's open
local function FromContext(delta)
	local plus = delta > 0
	if IsOpen("trade") then
		return "trade", "Trade with " .. (tradePartner or "?")
	elseif IsOpen("mail") then
		if plus then
			return "mail", "Mail"
		end
		return "postage", "Postage"
	elseif IsOpen("auction") then
		return "auction", plus and "Auction house refund" or "Auction house"
	elseif IsOpen("merchant") then
		if not plus and InRepairMode and InRepairMode() then
			return "repair", "Repairs"
		end
		return "vendor", plus and "Sold items" or "Bought from vendor"
	elseif IsOpen("quest") and plus then
		return "quest", "Quest reward"
	elseif IsOpen("loot") and plus then
		return "loot", "Loot: " .. Zone()
	elseif IsOpen("taxi") and not plus then
		return "taxi", "Flight"
	elseif IsOpen("trainer") and not plus then
		return "train", "Training"
	elseif IsOpen("barber") and not plus then
		return "barber", "Barber"
	elseif IsOpen("transmog") and not plus then
		return "transmog", "Transmog"
	elseif IsOpen("guildbank") then
		-- deposits/withdraws leave exact claims; anything else here is a real cost (e.g. a tab)
		return "other", plus and "Guild bank" or "Guild bank purchase"
	elseif IsOpen("bank") then
		return "other", plus and "Bank" or "Bank purchase (bag slot or tab)"
	end
	return "other", plus and "Other income" or "Other expense"
end


--[[ Matching gold changes ]]--

local function Classify(delta)
	local claim = TakeClaim(delta)
	if claim then
		if claim.entries then
			for _, e in ipairs(claim.entries) do
				ns.Record(e[1], e[2], e[3])
			end
		else
			ns.Record(delta, claim.cat, claim.detail)
		end
		return
	end
	local cat, detail = FromContext(delta)
	ns.Record(delta, cat, detail)
end

local flusher = CreateFrame("Frame")
flusher:Hide()
flusher.wait = 0
flusher:SetScript("OnUpdate", function(self, elapsed)
	self.wait = self.wait - elapsed
	if self.wait > 0 then
		return
	end
	self:Hide()
	local list = pending
	pending = {}
	for _, delta in ipairs(list) do
		local ok, err = pcall(Classify, delta)
		if not ok then
			ns.Error("Classify", err)
		end
	end
end)

ns.On("PLAYER_MONEY", function()
	local money = GetMoney()
	if not lastMoney then
		-- no trusted starting point yet: just take this one, record nothing
		lastMoney = money
		return
	end
	local delta = money - lastMoney
	lastMoney = money
	if ns.Char() then
		ns.Char().money = money
	end
	if delta ~= 0 then
		tinsert(pending, delta)
		flusher.wait = 0.5
		flusher:Show()
	end
end)

-- Starting balance guard: GetMoney() can be 0 early at login, and a 0 starting
-- point would record the whole balance as income. Never start from 0 when this
-- character is known to have gold; wait for the next real value instead.
ns.On("PLAYER_ENTERING_WORLD", function()
	local money = GetMoney()
	local char = ns.Char()
	if money == 0 and char and (char.money or 0) > 0 then
		lastMoney = nil
		return
	end
	lastMoney = money
	if char then
		char.money = money
	end
end)


--[[ Windows open / closed ]]--

local pairsOpenClose = {
	merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
	mail = { "MAIL_SHOW", "MAIL_CLOSED" },
	auction = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
	trade = { "TRADE_SHOW", "TRADE_CLOSED" },
	loot = { "LOOT_OPENED", "LOOT_CLOSED" },
	taxi = { "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
	trainer = { "TRAINER_SHOW", "TRAINER_CLOSED" },
	barber = { "BARBER_SHOP_OPEN", "BARBER_SHOP_CLOSE" },
	transmog = { "TRANSMOGRIFY_OPEN", "TRANSMOGRIFY_CLOSE" },
	guildbank = { "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" },
	bank = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED" },
	quest = { "QUEST_COMPLETE", "QUEST_FINISHED" },
}
for name, events in pairs(pairsOpenClose) do
	ns.On(events[1], function() Open(name) end)
	ns.On(events[2], function() Close(name) end)
end

-- "You loot 3 Silver" / "Your share of the loot is ..." (text not read: it can be secret)
ns.On("CHAT_MSG_MONEY", function()
	Claim(nil, 1, "loot", "Loot: " .. Zone(), 3)
end)


--[[ Quests ]]--

ns.On("QUEST_TURNED_IN", function(_, questID, xp, money)
	if money and money > 0 then
		local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
		Claim(money, 1, "quest", "Quest: " .. (title or ("#" .. tostring(questID))))
	end
end)


--[[ Merchant: sales, purchases, repairs ]]--

-- the item you click to sell gets locked first; remember what it's worth
ns.On("ITEM_LOCK_CHANGED", function(_, bag, slot)
	if not IsOpen("merchant") or not bag or not slot then
		return
	end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if info and info.isLocked and info.hyperlink then
		local sellPrice = select(11, C_Item.GetItemInfo(info.hyperlink))
		if sellPrice and sellPrice > 0 then
			local count = info.stackCount or 1
			local detail = "Sold " .. info.hyperlink .. (count > 1 and (" x" .. count) or "")
			Claim(sellPrice * count, 1, "vendor", detail, 5)
		end
	end
end)

local repairCost = 0
local function RememberRepairCost()
	if CanMerchantRepair and CanMerchantRepair() then
		local cost = GetRepairAllCost()
		repairCost = cost or 0
	end
end
ns.On("MERCHANT_SHOW", RememberRepairCost)
ns.On("UPDATE_INVENTORY_DURABILITY", RememberRepairCost)

if RepairAllItems then
	SafeHook("RepairAllItems", function(useGuild)
		if not useGuild and repairCost > 0 then
			Claim(-repairCost, -1, "repair", "Repair all")
		else
			Claim(nil, -1, "repair", "Repair all", 3)
		end
	end)
end

if BuyMerchantItem then
	SafeHook("BuyMerchantItem", function(index, quantity)
		local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(index)
		local link = GetMerchantItemLink and GetMerchantItemLink(index)
		local name = link or (info and info.name) or "item"
		local qty = quantity or (info and info.stackCount) or 1
		Claim(nil, -1, "vendor", "Bought " .. name .. (qty > 1 and (" x" .. qty) or ""), 5)
	end)
end

if BuybackItem then
	SafeHook("BuybackItem", function(index)
		local link = GetBuybackItemLink and GetBuybackItemLink(index)
		Claim(nil, -1, "vendor", "Bought back " .. (link or "item"), 5)
	end)
end


--[[ Mail ]]--

local function MailClaim(index)
	local _, _, sender, subject, money, cod = GetInboxHeaderInfo(index)
	if not money or money <= 0 then
		return
	end
	local invoiceType, itemName, buyer, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)

	if invoiceType == "seller" then
		local what = (itemName or "item") .. ((count and count > 1) and (" x" .. count) or "")
		local who = buyer or "several buyers"
		local detail = "Sold " .. what .. " to " .. who
		if bid and bid > 0 then
			detail = detail .. " (price " .. ns.Money(bid) .. ", AH cut " .. ns.Money(consignment or 0) .. ")"
		end
		Claim(money, 1, "auction", detail, 30)
	elseif sender and ns.IsOwnChar(sender) then
		Claim(money, 1, "transfer", "Mail from " .. sender, 30)
	elseif subject and subject:find("[Oo]utbid") then
		Claim(money, 1, "auction", subject, 30)
	else
		Claim(money, 1, "mail", "Mail from " .. (sender or "?") .. (subject and subject ~= "" and (": " .. subject) or ""), 30)
	end
end

if TakeInboxMoney then
	SafeHook("TakeInboxMoney", MailClaim)
end
if AutoLootMailItem then
	SafeHook("AutoLootMailItem", MailClaim)
end

-- sending: gold now goes through a confirmation, so match on the exact amount later
if SendMailFrame_SendMail then
	SafeHook("SendMailFrame_SendMail", function()
		local to = SendMailNameEditBox and SendMailNameEditBox:GetText() or "?"
		local money = GetSendMailMoney and GetSendMailMoney() or 0
		local postage = GetSendMailPrice and GetSendMailPrice() or 0
		local entries = {}
		if money > 0 then
			local own = ns.IsOwnChar(to)
			tinsert(entries, { -money, own and "transfer" or "mail", "Mail to " .. to })
		end
		if postage > 0 then
			tinsert(entries, { -postage, "postage", "Postage to " .. to })
		end
		if #entries > 0 then
			Claim(-(money + postage), -1, "mail", "Mail to " .. to, 120, entries)
		end
	end)
end


--[[ Auction house ]]--

local function ItemFromLocation(location)
	if location and C_Item.DoesItemExist(location) then
		return C_Item.GetItemLink(location)
	end
end

if C_AuctionHouse then
	if C_AuctionHouse.PostItem then
		SafeHook(C_AuctionHouse, "PostItem", function(location, _, quantity)
			Claim(nil, -1, "auction", "Deposit: " .. (ItemFromLocation(location) or "item") .. ((quantity or 1) > 1 and (" x" .. quantity) or ""))
		end)
	end
	if C_AuctionHouse.PostCommodity then
		SafeHook(C_AuctionHouse, "PostCommodity", function(location, _, quantity)
			Claim(nil, -1, "auction", "Deposit: " .. (ItemFromLocation(location) or "item") .. ((quantity or 1) > 1 and (" x" .. quantity) or ""))
		end)
	end
	if C_AuctionHouse.PlaceBid then
		SafeHook(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
			local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
			local link = info and info.itemLink or "item"
			Claim(bidAmount and -bidAmount or nil, -1, "auction", "Bought " .. link)
		end)
	end
	if C_AuctionHouse.ConfirmCommoditiesPurchase then
		SafeHook(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
			local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or ("item " .. tostring(itemID))
			Claim(nil, -1, "auction", "Bought " .. name .. ((quantity or 1) > 1 and (" x" .. quantity) or ""))
		end)
	end
	if C_AuctionHouse.CancelAuction then
		SafeHook(C_AuctionHouse, "CancelAuction", function()
			Claim(nil, -1, "auction", "Cancel fee")
		end)
	end
end


--[[ Trade ]]--

ns.On("TRADE_SHOW", function()
	tradePartner = UnitName("NPC")
end)

ns.On("TRADE_ACCEPT_UPDATE", function(_, playerAccepted, targetAccepted)
	if playerAccepted == 1 and targetAccepted == 1 then
		local net = (GetTargetTradeMoney() or 0) - (GetPlayerTradeMoney() or 0)
		if net ~= 0 then
			local who = tradePartner or "?"
			Claim(net, nil, ns.IsOwnChar(who) and "transfer" or "trade", "Trade with " .. who, 30)
		end
	end
end)


--[[ Flights, training, guild bank, Warband bank ]]--

if TakeTaxiNode then
	SafeHook("TakeTaxiNode", function(index)
		local cost = TaxiNodeCost and TaxiNodeCost(index)
		local name = TaxiNodeName and TaxiNodeName(index) or "?"
		Claim(cost and cost > 0 and -cost or nil, -1, "taxi", "Flight to " .. name)
	end)
end

if BuyTrainerService then
	SafeHook("BuyTrainerService", function(index)
		local name = GetTrainerServiceInfo and GetTrainerServiceInfo(index)
		Claim(nil, -1, "train", "Learned " .. (name or "skill"))
	end)
end

if DepositGuildBankMoney then
	SafeHook("DepositGuildBankMoney", function(amount)
		Claim(amount and -amount or nil, -1, "transfer", "Guild bank deposit")
	end)
end
if WithdrawGuildBankMoney then
	SafeHook("WithdrawGuildBankMoney", function(amount)
		Claim(amount or nil, 1, "transfer", "Guild bank withdraw")
	end)
end

if C_Bank then
	if C_Bank.DepositMoney then
		SafeHook(C_Bank, "DepositMoney", function(_, amount)
			Claim(amount and -amount or nil, -1, "transfer", "Warband bank deposit")
		end)
	end
	if C_Bank.WithdrawMoney then
		SafeHook(C_Bank, "WithdrawMoney", function(_, amount)
			Claim(amount or nil, 1, "transfer", "Warband bank withdraw")
		end)
	end
end
