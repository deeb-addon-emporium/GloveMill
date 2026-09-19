-- GloveMill
-- Works for any item: type its name in the window, /gm item <name>, or shift-click a link.
-- Auction side: search for the target item, list every buyout under your cap, and buy the
-- cheapest one per click. Buying and disenchanting are both protected by the client, so
-- nothing here loops: every purchase and every cast is one real click.
-- Disenchant side: a secure button whose macro is "/cast Disenchant" + "/use <bag> <slot>" of
-- the next matching item in your bags.
--
--   /gm            show / hide the window
--   /gm cap 2g50s  set the max buyout (also editable in the window)
--   /gm item Name  change the item (default Embossed Leather Gloves)

local DEFAULT_ITEM = "Embossed Leather Gloves"
local DEFAULT_CAP  = 20000            -- 2g, in copper
local BUY_COOLDOWN = 0.8              -- seconds between buys; the AH throttles anyway

GloveMillDB = GloveMillDB or {}
local db

local function msg(t) print("|cffffd080GloveMill|r: " .. t) end

local function moneyText(c)
	if GetMoneyString then return GetMoneyString(c) end
	return tostring(c) .. "c"
end

-- "2g50s", "150s", "3g", "12345" (copper) -> copper
local function parseMoney(s)
	s = string.lower(strtrim and strtrim(s or "") or (s or ""))
	if s == "" then return nil end
	if tonumber(s) then return tonumber(s) end
	local total = 0
	local any = false
	for n, unit in string.gmatch(s, "(%d+)%s*([gsc])") do
		any = true
		n = tonumber(n)
		if unit == "g" then total = total + n * 10000
		elseif unit == "s" then total = total + n * 100
		else total = total + n end
	end
	return any and total or nil
end

local function targetName() return db.item or DEFAULT_ITEM end
local function cap() return db.cap or DEFAULT_CAP end

local function sameName(a, b)
	return type(a) == "string" and type(b) == "string" and string.lower(a) == string.lower(b)
end

-- ---------------------------------------------------------------------------
-- Auction house: two API shapes
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Expected disenchant result, from the classic tables (green items only)
-- ---------------------------------------------------------------------------
local DE_TABLE = {
	{ 5, 15,  "Strange Dust",  "Lesser Magic Essence",   nil },
	{ 16, 20, "Strange Dust",  "Greater Magic Essence",  "Small Glimmering Shard" },
	{ 21, 25, "Strange Dust",  "Lesser Astral Essence",  "Large Glimmering Shard" },
	{ 26, 30, "Soul Dust",     "Greater Astral Essence", "Small Glowing Shard" },
	{ 31, 35, "Soul Dust",     "Lesser Mystic Essence",  "Large Glowing Shard" },
	{ 36, 40, "Vision Dust",   "Greater Mystic Essence", "Small Radiant Shard" },
	{ 41, 45, "Vision Dust",   "Lesser Nether Essence",  "Large Radiant Shard" },
	{ 46, 50, "Dream Dust",    "Greater Nether Essence", "Small Brilliant Shard" },
	{ 51, 55, "Dream Dust",    "Lesser Eternal Essence", "Large Brilliant Shard" },
	{ 56, 65, "Illusion Dust", "Greater Eternal Essence","Large Brilliant Shard" },
}
local CLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local CLASS_ARMOR  = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local UNCOMMON     = (Enum and Enum.ItemQuality and Enum.ItemQuality.Uncommon) or 2

local EPIC         = (Enum and Enum.ItemQuality and Enum.ItemQuality.Epic) or 4
local ARMOR_MISC   = 0            -- shirts, tabards: not disenchantable

-- name, ilvl, quality, classID, subClassID for an item name / link / id
local function itemFacts(item)
	local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if not fn or not item then return end
	local ok, name, _, quality, ilvl, _, _, _, _, _, _, _, classID, subClassID = pcall(fn, item)
	if not ok or not name then return end
	return name, ilvl, quality, classID, subClassID
end

-- Can Disenchant take it? Green to epic, a weapon or armor, and not a shirt/tabard.
local function deable(quality, classID, subClassID)
	if type(quality) ~= "number" or quality < UNCOMMON or quality > EPIC then return false end
	if classID == CLASS_WEAPON then return true end
	if classID == CLASS_ARMOR then return subClassID ~= ARMOR_MISC end
	return false
end

-- ---------------------------------------------------------------------------
-- Presets: churn through every green weapon/armor in an ilvl bracket, cheapest first
-- ---------------------------------------------------------------------------
local PRESETS = {
	{ key = "item", label = "Single item by name" },
	{ key = "w5",  label = "Weapons ilvl 5-15  (Lesser Magic Essence)",  classID = CLASS_WEAPON, min = 5,  max = 15 },
	{ key = "w16", label = "Weapons ilvl 16-20 (Greater Magic Essence)", classID = CLASS_WEAPON, min = 16, max = 20 },
	{ key = "w21", label = "Weapons ilvl 21-25 (Lesser Astral Essence)", classID = CLASS_WEAPON, min = 21, max = 25 },
	{ key = "w26", label = "Weapons ilvl 26-30 (Greater Astral Essence)", classID = CLASS_WEAPON, min = 26, max = 30 },
	{ key = "a5",  label = "Armor ilvl 5-15  (Strange Dust)",             classID = CLASS_ARMOR,  min = 5,  max = 15 },
	{ key = "a16", label = "Armor ilvl 16-20 (Strange Dust)",             classID = CLASS_ARMOR,  min = 16, max = 20 },
	{ key = "a26", label = "Armor ilvl 26-30 (Soul Dust)",                classID = CLASS_ARMOR,  min = 26, max = 30 },
}
local function currentPreset()
	local k = db and db.preset or "item"
	for _, p in ipairs(PRESETS) do if p.key == k and p.classID then return p end end
	return nil
end
local function presetLabel()
	local k = db and db.preset or "item"
	for _, p in ipairs(PRESETS) do if p.key == k then return p.label end end
	return PRESETS[1].label
end
-- does an item (by id/link) fit what we are hunting right now?
local function wanted(item)
	local name, ilvl, quality, classID, subClassID = itemFacts(item)
	if not name then return nil end                       -- unknown yet
	local p = currentPreset()
	if p then
		return deable(quality, classID, subClassID) and classID == p.classID
			and type(ilvl) == "number" and ilvl >= p.min and ilvl <= p.max, name
	end
	return sameName(name, targetName()), name
end


-- returns a one-line expectation, and a kind ("weapon"/"armor"), or nil + reason
local function expectedDE(ilvl, quality, classID, subClassID)
	if quality ~= UNCOMMON then return nil, "only green items are tabled" end
	if not deable(quality, classID, subClassID) then return nil, "not disenchantable" end
	if type(ilvl) ~= "number" then return nil, "no item level" end
	local row
	for _, r in ipairs(DE_TABLE) do if ilvl >= r[1] and ilvl <= r[2] then row = r; break end end
	if not row then return nil, "ilvl " .. ilvl .. " is outside the table" end
	local weapon = classID == CLASS_WEAPON
	local dustPct, essPct = 75, 20
	if weapon then dustPct, essPct = 20, 75 end
	local shardPct = row[5] and 5 or 0
	if not row[5] then dustPct = weapon and 20 or 80; essPct = weapon and 80 or 20 end
	local parts = {
		string.format("%d%% %s", essPct, row[4]),
		string.format("%d%% %s", dustPct, row[3]),
	}
	if row[5] then parts[#parts + 1] = string.format("%d%% %s", shardPct, row[5]) end
	return table.concat(parts, ", "), weapon and "weapon" or "armor", essPct
end


local hasNewAH = type(C_AuctionHouse) == "table" and type(C_AuctionHouse.SendSearchQuery) == "function"
local hasOldAH = type(QueryAuctionItems) == "function"

local results = {}         -- { price=, count=, id=<auctionID or list index>, name= }
local lastBuy = 0
local ahOpen = false

local function itemIDForTarget()
	if db.itemID and db.itemIDName == targetName() then return db.itemID end
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, id = pcall(C_Item.GetItemInfoInstant, targetName())
		if ok and type(id) == "number" then return id end
	elseif GetItemInfoInstant then
		local ok, id = pcall(GetItemInfoInstant, targetName())
		if ok and type(id) == "number" then return id end
	end
	return nil
end

local function nameForID(id)
	if C_Item and C_Item.GetItemInfo then
		local ok, n = pcall(C_Item.GetItemInfo, id)
		if ok then return n end
	elseif GetItemInfo then
		local ok, n = pcall(GetItemInfo, id)
		if ok then return n end
	end
end

-- preset mode state
local queue, queued, fetching, browsePages, browseRetries = {}, 0, nil, 0, 0
local MAX_PREFETCH = 6                 -- item searches per scan; each one is a throttled call
local prefetchNext                     -- forward

local function scan()
	results = {}; queue = {}; queued = 0; fetching = nil; browsePages = 0; browseRetries = 0
	if not ahOpen then msg("open the auction house first"); return end
	local p = currentPreset()
	if p then
		if not hasNewAH then msg("presets need the new auction house API"); return end
		local q = {
			searchString = "",
			sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
			filters = { Enum.AuctionHouseFilter.UncommonQuality },
			itemClassFilters = { { classID = p.classID } },
		}
		local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, q)
		if not ok then msg("browse refused: " .. tostring(err)) else msg("scanning " .. p.label .. " under " .. moneyText(cap())) end
		return
	end
	if hasNewAH then
		local id = itemIDForTarget()
		if not id then
			-- ask the AH for it by name; the browse results carry the item ID
			msg("looking up '" .. targetName() .. "' on the auction house...")
			local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, { searchString = targetName(), sorts = {}, filters = {}, itemClassFilters = {} })
			if not ok then msg("browse refused: " .. tostring(err)) end
			return
		end
		local key = C_AuctionHouse.MakeItemKey(id)
		local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
		local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
		if not ok then msg("search refused: " .. tostring(err)) end
	elseif hasOldAH then
		local ok, err = pcall(QueryAuctionItems, targetName(), nil, nil, 0, false, 0, false, false)
		if not ok then msg("search refused: " .. tostring(err)) end
	else
		msg("no auction API found in this client")
	end
end

-- item-search results for one queued item key -> listings
local function collectKey(entry)
	local n = C_AuctionHouse.GetNumItemSearchResults(entry.key) or 0
	local added = 0
	for i = 1, n do
		local ok, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, entry.key, i)
		if ok and type(r) == "table" and r.buyoutAmount and r.buyoutAmount > 0
			and r.itemKey and r.itemKey.itemID == entry.itemID and r.containsOwnerItem ~= true
			and r.buyoutAmount <= cap() then
			results[#results + 1] = { price = r.buyoutAmount, count = r.quantity or 1, id = r.auctionID, name = entry.name, itemID = entry.itemID }
			added = added + 1
		end
	end
	return added
end

prefetchNext = function()
	if not currentPreset() or fetching or not ahOpen then return end
	if queued >= MAX_PREFETCH or queued >= #queue then return end
	local entry = queue[queued + 1]
	fetching = entry
	local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	local ok = pcall(C_AuctionHouse.SendSearchQuery, entry.key, sorts, false)
	if not ok then fetching = nil end   -- throttled: AUCTION_HOUSE_THROTTLED_SYSTEM_READY retries
end

local function onPresetBrowse()
	local p = currentPreset()
	if not p then return end
	local list = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
	local seen, needRetry = {}, false
	queue = {}
	for _, r in ipairs(list) do
		local key = r.itemKey
		if key and key.itemID and not seen[key.itemID] then
			seen[key.itemID] = true
			local fits, name = wanted(key.itemID)
			if fits == nil then
				needRetry = true
				if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, key.itemID) end
			elseif fits and r.minPrice and r.minPrice <= cap() and r.containsOwnerItem ~= true then
				queue[#queue + 1] = { key = key, itemID = key.itemID, name = name, minPrice = r.minPrice }
			end
		end
	end
	-- more pages? (results are cumulative)
	if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() and browsePages < 3 then
		browsePages = browsePages + 1
		pcall(C_AuctionHouse.RequestMoreBrowseResults)
		return
	end
	table.sort(queue, function(a, b) return a.minPrice < b.minPrice end)
	if needRetry and browseRetries < 3 then
		browseRetries = browseRetries + 1
		C_Timer.After(1, onPresetBrowse)      -- item data arrived by then; rebuild the queue
	end
	msg(string.format("%d item type(s) fit, cheapest %s - pulling listings", #queue, queue[1] and moneyText(queue[1].minPrice) or "-"))
	queued = 0; fetching = nil; results = {}
	prefetchNext()
	if win and win:IsShown() then win.refresh() end
end

local function onBrowse()
	if currentPreset() then onPresetBrowse(); return end
	if db.itemID and db.itemIDName == targetName() then return end
	local list = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
	for _, r in ipairs(list) do
		local key = r.itemKey
		if key and key.itemID then
			local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, key)
			local name = ok and type(info) == "table" and info.itemName or nameForID(key.itemID)
			if sameName(name, targetName()) then
				db.itemID, db.itemIDName = key.itemID, targetName()
				msg("found it, item ID " .. key.itemID .. " - scanning")
				scan()
				return
			end
		end
	end
	msg("no listing called '" .. targetName() .. "' right now - check the spelling, or /gm item with a shift-clicked link")
end

local function collectNew()
	if currentPreset() then
		if fetching then
			collectKey(fetching)
			queued = queued + 1
			fetching = nil
			C_Timer.After(0.3, prefetchNext)
		end
		return
	end
	results = {}
	local id = itemIDForTarget()
	if not id then return end
	local key = C_AuctionHouse.MakeItemKey(id)
	local n = C_AuctionHouse.GetNumItemSearchResults(key) or 0
	for i = 1, n do
		local ok, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, i)
		if ok and type(r) == "table" and r.buyoutAmount and r.buyoutAmount > 0
			and r.itemKey and r.itemKey.itemID == id and r.containsOwnerItem ~= true then
			results[#results + 1] = { price = r.buyoutAmount, count = r.quantity or 1, id = r.auctionID, name = nameForID(id) or targetName(), itemID = id }
		end
	end
end

local function collectOld()
	results = {}
	local n = GetNumAuctionItems("list") or 0
	for i = 1, n do
		local name, _, count, _, _, _, _, _, _, buyout, _, _, _, owner = GetAuctionItemInfo("list", i)
		if sameName(name, targetName()) and type(buyout) == "number" and buyout > 0
			and owner ~= UnitName("player") then
			results[#results + 1] = { price = buyout, count = count or 1, id = i, name = name }
		end
	end
end

local function sortResults()
	table.sort(results, function(a, b) return a.price < b.price end)
end

-- the cheapest listing under the cap, or nil + why
local function pickNext()
	sortResults()
	local r = results[1]
	if not r then return nil, "nothing listed - scan first" end
	if r.price > cap() then return nil, "cheapest is " .. moneyText(r.price) .. ", over your cap of " .. moneyText(cap()) end
	return r
end

-- Runs from a button click only. One listing per call. Re-checks the name and the cap
-- right before the buy so a stale list can never buy the wrong thing.
local function buyNext()
	if not ahOpen then msg("auction house is closed"); return end
	if GetTime() - lastBuy < BUY_COOLDOWN then return end
	local r, why = pickNext()
	if not r then msg(why); return end
	local fits = wanted(r.itemID or r.name)
	if not fits then msg("refusing: listing '" .. tostring(r.name) .. "' does not fit " .. presetLabel()); return end
	if r.price > cap() then msg("refusing: over cap"); return end
	if GetMoney() < r.price then msg("not enough gold"); return end

	local ok, err
	if hasNewAH then
		ok, err = pcall(C_AuctionHouse.PlaceBid, r.id, r.price)
	else
		local name = GetAuctionItemInfo("list", r.id)
		if not sameName(name, targetName()) then msg("list moved under us - scan again"); return end
		ok, err = pcall(PlaceAuctionBid, "list", r.id, r.price)
	end
	if not ok then msg("buy refused: " .. tostring(err)); return end
	lastBuy = GetTime()
	table.remove(results, 1)
	db.bought = (db.bought or 0) + 1
	db.spent = (db.spent or 0) + r.price
	msg(string.format("bought 1 for %s  (session: %d for %s)", moneyText(r.price), db.bought, moneyText(db.spent)))
	if currentPreset() and #results < 3 then
		if queued < #queue then MAX_PREFETCH = queued + 3; prefetchNext()
		elseif queued >= #queue and #results == 0 then msg("queue empty - Scan again for fresh listings") end
	end
end

-- ---------------------------------------------------------------------------
-- Bags: find the next target item to disenchant
-- ---------------------------------------------------------------------------
local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetItemInfoAt = (C_Container and C_Container.GetContainerItemInfo) or nil
local GetItemLinkAt = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
local MAX_BAG = (NUM_BAG_SLOTS or 4)

local function bagCount()
	local n, bag, slot = 0, nil, nil
	local id = itemIDForTarget()
	for b = 0, MAX_BAG do
		for s = 1, (GetNumSlots(b) or 0) do
			local hit = false
			if GetItemInfoAt then
				local info = GetItemInfoAt(b, s)
				if info and not info.isLocked then
					if currentPreset() then hit = wanted(info.itemID) == true
					elseif id and info.itemID == id then hit = true end
				end
			end
			if not hit and not currentPreset() and GetItemLinkAt then
				local link = GetItemLinkAt(b, s)
				if link and string.find(link, "%[" .. targetName() .. "%]") then hit = true end
			end
			if hit then
				n = n + (1)
				if not bag then bag, slot = b, s end
			end
		end
	end
	return n, bag, slot
end

-- ---------------------------------------------------------------------------
-- Mats tally: every disenchant result you loot (dust / essence / shard / crystal)
-- ---------------------------------------------------------------------------
local MAT_WORDS = { "dust", "essence", "shard", "crystal" }

local function isMat(name)
	local n = string.lower(name or "")
	for _, w in ipairs(MAT_WORDS) do
		if string.find(n, w, 1, true) then return true end
	end
	return false
end

local function addMat(name, count)
	db.mats = db.mats or {}
	db.mats[name] = (db.mats[name] or 0) + count
	db.matsAll = db.matsAll or {}
	db.matsAll[name] = (db.matsAll[name] or 0) + count
end

-- "You receive loot: [Strange Dust]x3." / "You receive loot: [Lesser Magic Essence]."
local function onLoot(text)
	if type(text) ~= "string" then return end
	-- only OUR loot: "You receive loot" / "You receive item", never "Bob receives loot"
	if not string.find(text, "^You receive") and not string.find(text, "^You create") then return end
	local name, count = string.match(text, "%[(.-)%]x(%d+)")
	if not name then name = string.match(text, "%[(.-)%]"); count = 1 end
	if not name or not isMat(name) then return end
	if db.countMats == false then return end
	addMat(name, tonumber(count) or 1)
	if GloveMillFX and GloveMillFX.onMat then GloveMillFX.onMat(name, tonumber(count) or 1) end
	if win and win:IsShown() then win.refresh() end
end

-- ---------------------------------------------------------------------------
-- Listings: whatever you post at the AH counts as income the moment you post it.
-- Assumed profit = listed * (1 - AH cut) - gold spent on gloves.
-- Remembers the unit price per mat so unlisted mats get a "worth" too.
-- ---------------------------------------------------------------------------
local AH_CUT = 0.05

local function addListing(name, qty, unitPrice)
	if not name or not qty or not unitPrice or unitPrice <= 0 then return end
	local total = unitPrice * qty
	db.listed = (db.listed or 0) + total
	db.listedAll = (db.listedAll or 0) + total
	db.listedCount = (db.listedCount or 0) + qty
	db.unitPrice = db.unitPrice or {}
	db.unitPrice[name] = unitPrice
	db.listedMats = db.listedMats or {}
	db.listedMats[name] = (db.listedMats[name] or 0) + qty
	msg(string.format("listed %d x %s for %s", qty, name, moneyText(total)))
	if win and win:IsShown() then win.refresh() end
end

-- mats looted this session but not yet listed, valued at the last price you listed each at
local function unlistedWorth()
	local worth, unknown = 0, 0
	for name, n in pairs(db.mats or {}) do
		local left = n - ((db.listedMats or {})[name] or 0)
		if left > 0 then
			local u = (db.unitPrice or {})[name]
			if u then worth = worth + left * u else unknown = unknown + left end
		end
	end
	return worth, unknown
end

local function profitText()
	local listed = db.listed or 0
	local worth, unknown = unlistedWorth()
	local income = (listed + worth) * (1 - AH_CUT)
	local spent = db.spent or 0
	local p = income - spent
	local sign = p >= 0 and "|cff80ff80+" or "|cffff8080-"
	return string.format("Listed: %s   unlisted worth: %s%s\nAssumed profit (after %d%% cut): %s%s|r",
		moneyText(listed), moneyText(worth), unknown > 0 and (" (+" .. unknown .. " unpriced)") or "",
		AH_CUT * 100, sign, moneyText(math.abs(p)))
end

-- hooks: new AH posts
if C_AuctionHouse and hooksecurefunc then
	local function itemName(loc)
		if C_Item and C_Item.GetItemName and loc then
			local ok, n = pcall(C_Item.GetItemName, loc); if ok then return n end
		end
	end
	if C_AuctionHouse.PostCommodity then
		hooksecurefunc(C_AuctionHouse, "PostCommodity", function(loc, _dur, qty, unitPrice)
			addListing(itemName(loc), qty, unitPrice)
		end)
	end
	if C_AuctionHouse.PostItem then
		hooksecurefunc(C_AuctionHouse, "PostItem", function(loc, _dur, qty, _bid, buyout)
			if buyout and buyout > 0 then addListing(itemName(loc), qty or 1, buyout / (qty or 1)) end
		end)
	end
end
-- hooks: old AH posts
if type(StartAuction) == "function" and hooksecurefunc then
	hooksecurefunc("StartAuction", function(_minBid, buyout, _dur, stackSize, numStacks)
		local name = GetAuctionSellItemInfo and GetAuctionSellItemInfo()
		local qty = (stackSize or 1) * (numStacks or 1)
		if name and buyout and buyout > 0 then addListing(name, qty, buyout / (stackSize or 1)) end
	end)
end

local function matsText(tbl)
	local lines = {}
	for name, n in pairs(tbl or {}) do lines[#lines + 1] = { name = name, n = n } end
	table.sort(lines, function(a, b) return a.n > b.n end)
	local out = {}
	for _, l in ipairs(lines) do out[#out + 1] = string.format("%s x%d", l.name, l.n) end
	return #out > 0 and table.concat(out, ", ") or "nothing yet"
end

-- tooltip line on every green item
local function addTooltipLine(tt, link)
	if db and db.tooltip == false then return end
	local name, ilvl, quality, classID, subClassID = itemFacts(link)
	if not name then return end
	if not deable(quality, classID, subClassID) then return end
	local text, kind, essPct = expectedDE(ilvl, quality, classID, subClassID)
	if not text then return end
	tt:AddLine(string.format("|cffffd080DE|r ilvl %d %s: %s", ilvl, kind, text), 0.8, 0.8, 0.8, true)
end
-- one line per tooltip build, whichever hook fires first
local lastTT, lastKey = nil, nil
local function once(tt, key)
	if lastTT == tt and lastKey == key then return false end
	lastTT, lastKey = tt, key
	return true
end
if GameTooltip.HookScript then
	GameTooltip:HookScript("OnHide", function() lastTT, lastKey = nil, nil end)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
		if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
		local _, link = tt.GetItem and tt:GetItem()
		local item = link or (type(data) == "table" and data.id)     -- AH rows: item key, no link
		if item and once(tt, item) then addTooltipLine(tt, item) end
	end)
elseif GameTooltip.HookScript then
	GameTooltip:HookScript("OnTooltipSetItem", function(tt)
		local _, link = tt:GetItem()
		if link and once(tt, link) then addTooltipLine(tt, link) end
	end)
end
-- new AH browse / item lists set the tooltip from an item key
if hooksecurefunc and GameTooltip.SetItemKey then
	hooksecurefunc(GameTooltip, "SetItemKey", function(tt, itemID)
		if itemID and once(tt, itemID) then addTooltipLine(tt, itemID); tt:Show() end
	end)
end
-- old AH list
if hooksecurefunc and GameTooltip.SetAuctionItem and GetAuctionItemLink then
	hooksecurefunc(GameTooltip, "SetAuctionItem", function(tt, kind, index)
		local link = GetAuctionItemLink(kind, index)
		if link and once(tt, link) then addTooltipLine(tt, link); tt:Show() end
	end)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local win = CreateFrame("Frame", "GloveMillFrame", UIParent, "BasicFrameTemplateWithInset")
win:SetSize(320, 393)
win:SetPoint("CENTER", 300, 0)
win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:SetFrameStrata("DIALOG")
win:Hide()
if win.TitleText then win.TitleText:SetText("GloveMill") end
tinsert(UISpecialFrames, "GloveMillFrame")

-- preset dropdown
local presetDrop = CreateFrame("Frame", "GloveMillPresetDrop", win, "UIDropDownMenuTemplate")
presetDrop:SetPoint("TOPLEFT", -2, -26)
UIDropDownMenu_SetWidth(presetDrop, 270)
UIDropDownMenu_Initialize(presetDrop, function(self, level)
	for _, p in ipairs(PRESETS) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = p.label
		info.checked = (db and db.preset or "item") == p.key
		info.func = function()
			db.preset = p.key
			results = {}; queue = {}
			UIDropDownMenu_SetText(presetDrop, p.label)
			msg("preset: " .. p.label .. (p.classID and "  -  set the cap, then Scan" or ""))
			win.refresh()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end)

local itemLbl = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
itemLbl:SetPoint("TOPLEFT", 14, -60); itemLbl:SetText("Item:")
local itemBoxMain = CreateFrame("EditBox", "GloveMillItemBoxMain", win, "InputBoxTemplate")
itemBoxMain:SetSize(230, 20); itemBoxMain:SetPoint("LEFT", itemLbl, "RIGHT", 10, 0); itemBoxMain:SetAutoFocus(false)
itemBoxMain:SetScript("OnEnterPressed", function(self)
	SlashCmdList.GLOVEMILL("item " .. self:GetText()); self:ClearFocus()
end)
itemBoxMain:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
-- shift-click an item link into the box
if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if itemBoxMain:HasFocus() then itemBoxMain:SetText(link); SlashCmdList.GLOVEMILL("item " .. link); itemBoxMain:ClearFocus() end
	end)
end

local deLine = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
deLine:SetPoint("TOPLEFT", 14, -82); deLine:SetWidth(290); deLine:SetJustifyH("LEFT")

local capLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
capLabel:SetPoint("TOPLEFT", 14, -104)
capLabel:SetText("Max buyout:")

local capBox = CreateFrame("EditBox", "GloveMillCapBox", win, "InputBoxTemplate")
capBox:SetSize(90, 20)
capBox:SetPoint("LEFT", capLabel, "RIGHT", 10, 0)
capBox:SetAutoFocus(false)
capBox:SetScript("OnEnterPressed", function(self)
	local c = parseMoney(self:GetText())
	if c then db.cap = c; msg("cap is now " .. moneyText(c)) else msg("could not read that, try 2g50s") end
	self:ClearFocus()
	win.refresh()
end)
capBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", 14, -130)
status:SetWidth(290); status:SetJustifyH("LEFT"); status:SetHeight(50)

local scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
scanBtn:SetSize(90, 24); scanBtn:SetPoint("TOPLEFT", 14, -184); scanBtn:SetText("Scan AH")
scanBtn:SetScript("OnClick", scan)

local buyBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
buyBtn:SetSize(120, 24); buyBtn:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0); buyBtn:SetText("Buy cheapest")
buyBtn:SetScript("OnClick", function() buyNext(); win.refresh() end)

-- Secure button: the only way an addon may cast. Macro text is rebuilt before each click
-- (PreClick, out of combat) to point at the next glove in the bags.
local deBtn = CreateFrame("Button", "GloveMillDEButton", win, "SecureActionButtonTemplate,UIPanelButtonTemplate")
deBtn:SetSize(218, 28); deBtn:SetPoint("TOPLEFT", 14, -218); deBtn:SetText("Disenchant next")
deBtn:RegisterForClicks("AnyUp", "AnyDown")
deBtn:SetAttribute("type", "macro")
deBtn:SetScript("PreClick", function(self)
	if InCombatLockdown() then return end
	local n, bag, slot = bagCount()
	if not bag then
		self:SetAttribute("macrotext", "")
		msg("no " .. targetName() .. " in your bags")
		return
	end
	self:SetAttribute("macrotext", string.format("/cast Disenchant\n/use %d %d", bag, slot))
end)
deBtn:SetScript("PostClick", function() C_Timer.After(0.5, function() win.refresh() end) end)

local matsLine = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
matsLine:SetPoint("TOPLEFT", 14, -254); matsLine:SetWidth(290); matsLine:SetJustifyH("LEFT"); matsLine:SetHeight(48)

local profitLine = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
profitLine:SetPoint("TOPLEFT", 14, -304); profitLine:SetWidth(290); profitLine:SetJustifyH("LEFT"); profitLine:SetHeight(30)

local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", 14, 12); hint:SetWidth(290); hint:SetJustifyH("LEFT")
hint:SetText("One click = one buy or one cast. Type any item name above, or shift-click a link into it.")

function win.refresh()
	UIDropDownMenu_SetText(presetDrop, presetLabel())
	local p = currentPreset()
	itemLbl:SetShown(not p); itemBoxMain:SetShown(not p)
	if not itemBoxMain:HasFocus() then itemBoxMain:SetText(targetName()) end
	if p then
		local text = expectedDE(p.min, UNCOMMON, p.classID, p.classID == CLASS_WEAPON and 1 or 1)
		deLine:SetText(string.format("%s\nexpect %s", p.label, text or "?"))
	else
		local id = itemIDForTarget()
		local name, ilvl, quality, classID = itemFacts(id or targetName())
		if not name then
			deLine:SetText("|cff808080ilvl ? - not seen yet, scan or mouse over one|r")
		else
			local text, kind, essPct = expectedDE(ilvl, quality, classID)
			if text then
				deLine:SetText(string.format("ilvl %d %s  -  expect %s", ilvl, kind, text))
			else
				deLine:SetText(string.format("ilvl %d  -  %s", ilvl or 0, kind or "?"))
			end
		end
	end
	deLine:SetHeight(p and 26 or 14)
	if not capBox:HasFocus() then capBox:SetText(moneyText(cap())) end
	sortResults()
	local under = 0
	for _, r in ipairs(results) do if r.price <= cap() then under = under + 1 end end
	local cheapest = results[1] and moneyText(results[1].price) or "-"
	local inBags = bagCount()
	local qtext = p and string.format("   item types: %d (%d pulled)", #queue, queued) or ""
	status:SetText(string.format("AH: %s   listings: %d   under cap: %d   cheapest: %s%s\nIn bags: %d   bought this session: %d for %s",
		ahOpen and "open" or "closed", #results, under, cheapest, qtext, inBags, db.bought or 0, moneyText(db.spent or 0)))
	matsLine:SetText("Mats this session: " .. matsText(db.mats) .. "\nAll time: " .. matsText(db.matsAll))
	profitLine:SetText(profitText())
	buyBtn:SetEnabled(ahOpen and under > 0)
	deBtn:SetEnabled(inBags > 0 and not InCombatLockdown())
end
win:SetScript("OnShow", win.refresh)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "BAG_UPDATE_DELAYED",
	"ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_ITEM_LIST_UPDATE", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "CHAT_MSG_LOOT", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" }) do
	pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "CHAT_MSG_LOOT" then
		onLoot(arg1)
		return
	elseif event == "PLAYER_LOGIN" then
		db = GloveMillDB
		db.bought, db.spent, db.mats, db.listed, db.listedCount, db.listedMats = 0, 0, {}, 0, 0, {}
		msg("loaded - /gm for the window. " .. (hasNewAH and "new" or hasOldAH and "old" or "NO") .. " auction API")
	elseif event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		if db.autoOpen ~= false then win:Show() end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ahOpen = false; results = {}
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and hasNewAH then
		onBrowse()
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and hasNewAH then
		collectNew()
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" and hasNewAH then
		if currentPreset() and not fetching then prefetchNext() end
	elseif event == "AUCTION_ITEM_LIST_UPDATE" and hasOldAH and not hasNewAH then
		collectOld()
	end
	if win:IsShown() then win.refresh() end
end)

SLASH_GLOVEMILL1 = "/gm"
SlashCmdList.GLOVEMILL = function(input)
	input = strtrim and strtrim(input or "") or (input or "")
	local cmd, rest = string.match(input, "^(%S+)%s*(.*)$")
	if cmd == "cap" then
		local c = parseMoney(rest)
		if c then db.cap = c; msg("cap is now " .. moneyText(c)) else msg("say it like: /gm cap 2g50s") end
	elseif cmd == "preset" then
		local found
		for _, p in ipairs(PRESETS) do if p.key == rest then found = p end end
		if found then db.preset = found.key; results = {}; queue = {}; msg("preset: " .. found.label)
		else msg("presets: " .. (function() local t = {} for _, p in ipairs(PRESETS) do t[#t+1] = p.key end return table.concat(t, " ") end)()) end
	elseif cmd == "mats" then
		msg("this session: " .. matsText(db.mats))
		msg("all time: " .. matsText(db.matsAll))
	elseif cmd == "profit" then
		msg(string.gsub(profitText(), "\n", "  |  "))
	elseif cmd == "resetmats" then
		db.mats, db.matsAll = {}, {}
		msg("mats tally cleared")
	elseif cmd == "item" and rest ~= "" then
		local id = tonumber(string.match(rest, "item:(%d+)"))
		local name = string.match(rest, "%[(.-)%]") or rest
		db.item = name; results = {}
		if id then db.itemID, db.itemIDName = id, name else db.itemID, db.itemIDName = nil, nil end
		msg("item is now " .. name .. (id and (" (id " .. id .. ")") or ""))
	else
		if win:IsShown() then win:Hide() else win:Show() end
	end
	if win:IsShown() then win.refresh() end
end


-- ---------------------------------------------------------------------------
-- Minimap button + settings
--   left click   show / hide the GloveMill window
--   right click  settings
--   drag         move around the minimap (saved)
-- ---------------------------------------------------------------------------
local cfg = CreateFrame("Frame", "GloveMillConfig", UIParent, "BasicFrameTemplateWithInset")
cfg:SetSize(300, 230)
cfg:SetPoint("CENTER", -100, 0)
cfg:SetMovable(true); cfg:EnableMouse(true); cfg:RegisterForDrag("LeftButton")
cfg:SetScript("OnDragStart", cfg.StartMoving)
cfg:SetScript("OnDragStop", cfg.StopMovingOrSizing)
cfg:SetFrameStrata("DIALOG")
cfg:Hide()
if cfg.TitleText then cfg.TitleText:SetText("GloveMill settings") end
tinsert(UISpecialFrames, "GloveMillConfig")

local l1 = cfg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
l1:SetPoint("TOPLEFT", 14, -34); l1:SetText("Item:")
local itemBox = CreateFrame("EditBox", "GloveMillItemBox", cfg, "InputBoxTemplate")
itemBox:SetSize(200, 20); itemBox:SetPoint("LEFT", l1, "RIGHT", 10, 0); itemBox:SetAutoFocus(false)
itemBox:SetScript("OnEnterPressed", function(self)
	SlashCmdList.GLOVEMILL("item " .. self:GetText()); self:ClearFocus()
end)
itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local l2 = cfg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
l2:SetPoint("TOPLEFT", 14, -62); l2:SetText("Max buyout:")
local capBox2 = CreateFrame("EditBox", "GloveMillCapBox2", cfg, "InputBoxTemplate")
capBox2:SetSize(90, 20); capBox2:SetPoint("LEFT", l2, "RIGHT", 10, 0); capBox2:SetAutoFocus(false)
capBox2:SetScript("OnEnterPressed", function(self)
	SlashCmdList.GLOVEMILL("cap " .. self:GetText()); self:ClearFocus()
end)
capBox2:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local rows = {
	{ label = "Open the window when the AH opens", get = function() return db.autoOpen ~= false end,  set = function(v) db.autoOpen = v end },
	{ label = "Count disenchant mats I loot",       get = function() return db.countMats ~= false end, set = function(v) db.countMats = v end },
	{ label = "Expected DE line on item tooltips",  get = function() return db.tooltip ~= false end,  set = function(v) db.tooltip = v end },
	{ label = "Show the minimap button",            get = function() return db.minimap ~= false end,   set = function(v) db.minimap = v; if GloveMillMinimapButton then GloveMillMinimapButton:SetShown(v) end end },
}
local boxes = {}
local y = -90
for i, row in ipairs(rows) do
	local cb = CreateFrame("CheckButton", "GloveMillConfigCheck" .. i, cfg, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 12, y); cb:SetSize(26, 26)
	local t = cb.Text or _G[cb:GetName() .. "Text"]
	if t then t:SetText(row.label) end
	cb:SetScript("OnClick", function(self) row.set(self:GetChecked() and true or false) end)
	cb.row = row
	boxes[#boxes + 1] = cb
	y = y - 28
end
cfg:SetScript("OnShow", function()
	itemBox:SetText(targetName())
	capBox2:SetText(moneyText(cap()))
	for _, cb in ipairs(boxes) do cb:SetChecked(cb.row.get()) end
end)

local function buildMinimapButton()
	local btn = CreateFrame("Button", "GloveMillMinimapButton", Minimap)
	btn:SetSize(32, 32)
	btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel(8)
	btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	btn:RegisterForDrag("LeftButton")
	btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local overlay = btn:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53); overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); overlay:SetPoint("TOPLEFT")
	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20); bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background"); bg:SetPoint("TOPLEFT", 7, -5)
	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18); icon:SetTexture("Interface\\Icons\\INV_Gauntlets_04"); icon:SetPoint("TOPLEFT", 8, -6)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local function place()
		local angle = math.rad(db.minimapAngle or 200)
		local r = (Minimap:GetWidth() / 2) + 5
		btn:ClearAllPoints()
		btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
	end
	local function dragUpdate()
		local mx, my = Minimap:GetCenter()
		local cx, cy = GetCursorPosition()
		local sc = Minimap:GetEffectiveScale()
		db.minimapAngle = math.deg(math.atan2(cy / sc - my, cx / sc - mx))
		place()
	end
	btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", dragUpdate) end)
	btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	btn:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			cfg:SetShown(not cfg:IsShown())
		else
			win:SetShown(not win:IsShown())
			if win:IsShown() then win.refresh() end
		end
	end)
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("GloveMill")
		GameTooltip:AddLine(targetName() .. "  cap " .. moneyText(cap()), 1, 1, 1)
		GameTooltip:AddLine("Left click: window", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Right click: settings", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Drag: move", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	place()
	btn:SetShown(db.minimap ~= false)
end

local uiFrame = CreateFrame("Frame")
uiFrame:RegisterEvent("PLAYER_LOGIN")
uiFrame:SetScript("OnEvent", function()
	local ok, err = pcall(buildMinimapButton)
	if not ok then msg("minimap button failed: " .. tostring(err)) end
end)

local baseSlash = SlashCmdList.GLOVEMILL
SlashCmdList.GLOVEMILL = function(input)
	local w = string.lower(strtrim and strtrim(input or "") or (input or ""))
	if w == "config" or w == "options" then cfg:SetShown(not cfg:IsShown()); return end
	baseSlash(input)
end


-- ---------------------------------------------------------------------------
-- Fun: slot machine over the DE button while Disenchant casts, confetti on essence
-- ---------------------------------------------------------------------------
GloveMillFX = {}

local ICONS = {
	dust    = "Interface\\Icons\\INV_Enchant_DustStrange",
	essence = "Interface\\Icons\\INV_Enchant_EssenceMagicSmall",
	shard   = "Interface\\Icons\\INV_Enchant_ShardBrilliantSmall",
	crystal = "Interface\\Icons\\INV_Enchant_ShardGlowingLarge",
}
local REEL_POOL = { "dust", "dust", "dust", "essence", "shard" }   -- weighted like real drops

local function iconFor(name)
	local n = string.lower(name or "")
	for k in pairs(ICONS) do if string.find(n, k, 1, true) then return ICONS[k] end end
	return ICONS.dust
end

-- overlay sits exactly on the DE button, ignores the mouse so clicks still hit the button
local slot = CreateFrame("Frame", nil, deBtn)
slot:SetAllPoints(deBtn)
slot:SetFrameLevel(deBtn:GetFrameLevel() + 5)
slot:EnableMouse(false)
slot:Hide()
local slotBg = slot:CreateTexture(nil, "BACKGROUND")
slotBg:SetAllPoints(); slotBg:SetColorTexture(0, 0, 0, 0.75)
local reels = {}
for i = 1, 3 do
	local t = slot:CreateTexture(nil, "ARTWORK")
	t:SetSize(22, 22)
	t:SetPoint("CENTER", slot, "CENTER", (i - 2) * 30, 0)
	t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	t:SetTexture(ICONS.dust)
	reels[i] = t
end

local REEL_LEAD  = 0.6    -- keep spinning this long after the result is known
local REEL_GAP   = 0.55   -- seconds between each reel landing
local RESULT_HOLD = 3.0   -- seconds the landed result stays on the button

local spinning, spinT, stopAt = false, 0, nil
local reelStopped = { false, false, false }

local function setReel(i, key) reels[i]:SetTexture(ICONS[key] or key) end

slot:SetScript("OnUpdate", function(_, dt)
	if not spinning then return end
	spinT = spinT + dt
	for i = 1, 3 do
		local rate = 15
		if stopAt then
			local left = (stopAt.t + (i - 1) * REEL_GAP) - spinT
			if left < 0.5 then rate = 6 end
		end
		if not reelStopped[i] and math.floor(spinT * rate + i) % 2 == 0 then
			setReel(i, REEL_POOL[math.random(#REEL_POOL)])
		end
	end
	if stopAt then
		-- stop reels one at a time, left to right, on the real result
		for i = 1, 3 do
			if not reelStopped[i] and spinT >= stopAt.t + (i - 1) * REEL_GAP then
				reelStopped[i] = true
				reels[i]:SetTexture(stopAt.icon)
			end
		end
		if reelStopped[3] then
			spinning = false
			C_Timer.After(RESULT_HOLD, function() if not spinning then slot:Hide() end end)
		end
	end
end)

local function startSpin()
	spinning, spinT, stopAt = true, 0, nil
	reelStopped = { false, false, false }
	slot:Show()
end

local function stopSpin(icon)
	if not spinning then return end
	stopAt = { t = spinT + REEL_LEAD, icon = icon }
end

-- ---- confetti ----
local confettiFrame = CreateFrame("Frame", nil, UIParent)
confettiFrame:SetFrameStrata("TOOLTIP")
confettiFrame:SetAllPoints(UIParent)
confettiFrame:EnableMouse(false)
local bits = {}
local COLORS = { {1,0.2,0.2}, {0.2,1,0.2}, {0.3,0.5,1}, {1,1,0.2}, {1,0.4,1}, {0.3,1,1}, {1,0.6,0.1} }

local function burst(count, spread)
	local x, y = deBtn:GetCenter()
	if not x then return end
	local scale = UIParent:GetEffectiveScale()
	for _ = 1, count do
		local t
		for _, b in ipairs(bits) do if not b.alive then t = b; break end end
		if not t then
			t = { tex = confettiFrame:CreateTexture(nil, "OVERLAY") }
			t.tex:SetSize(5, 8)
			bits[#bits + 1] = t
		end
		local c = COLORS[math.random(#COLORS)]
		t.tex:SetColorTexture(c[1], c[2], c[3], 1)
		t.alive, t.life = true, 1.2 + math.random() * 0.8
		t.x, t.y = x + (math.random() - 0.5) * 20, y
		local ang = math.rad(50 + math.random() * 80)
		local sp = spread * (0.6 + math.random() * 0.8)
		t.vx, t.vy = math.cos(ang) * sp * (math.random() < 0.5 and -1 or 1), math.sin(ang) * sp
		t.rot, t.vr = math.random() * 6.28, (math.random() - 0.5) * 12
		t.tex:Show()
	end
end

confettiFrame:SetScript("OnUpdate", function(_, dt)
	local any = false
	for _, b in ipairs(bits) do
		if b.alive then
			any = true
			b.life = b.life - dt
			b.vy = b.vy - 900 * dt
			b.vx = b.vx * 0.985
			b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
			b.rot = b.rot + b.vr * dt
			b.tex:ClearAllPoints()
			b.tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", b.x, b.y)
			b.tex:SetRotation(b.rot)
			b.tex:SetAlpha(math.min(1, b.life))
			if b.life <= 0 then b.alive = false; b.tex:Hide() end
		end
	end
end)

-- ---- wiring ----
local pendingCast = false

function GloveMillFX.onMat(name, count)
	stopSpin(iconFor(name))
	if string.find(string.lower(name), "essence", 1, true) then
		if count >= 2 then
			burst(160, 520)                      -- the big one
			C_Timer.After(0.35, function() burst(120, 420) end)
		else
			burst(60, 380)
		end
	end
end

local fx = CreateFrame("Frame")
fx:RegisterEvent("UNIT_SPELLCAST_START")
fx:RegisterEvent("UNIT_SPELLCAST_STOP")
fx:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
fx:RegisterEvent("UNIT_SPELLCAST_FAILED")
fx:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if unit ~= "player" then return end
	local name
	if C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(spellID) elseif GetSpellInfo then name = GetSpellInfo(spellID) end
	if name ~= "Disenchant" then return end
	if event == "UNIT_SPELLCAST_START" then
		pendingCast = true
		startSpin()
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
		pendingCast = false
		spinning = false
		slot:Hide()
	elseif event == "UNIT_SPELLCAST_STOP" then
		-- keep spinning until the loot line lands; give up after 3 s
		C_Timer.After(4, function() if spinning and not stopAt then spinning = false; slot:Hide() end end)
	end
end)

-- /gm test  -> preview: spin, then land on essence with confetti
local prevSlash = SlashCmdList.GLOVEMILL
SlashCmdList.GLOVEMILL = function(input)
	local w = string.lower(strtrim and strtrim(input or "") or (input or ""))
	if w == "test" then
		win:Show(); win.refresh()
		startSpin()
		C_Timer.After(1.5, function() GloveMillFX.onMat("Lesser Magic Essence", 2) end)
		return
	end
	prevSlash(input)
end
