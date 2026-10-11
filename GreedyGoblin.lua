------------------------------------------------------------------------
-- Greedy Goblin 2.0 - standalone crafting profit list (WotLK 3.3.5)
-- * learns your recipes from the profession windows
-- * scans the whole auction house itself
-- * Auctionator support: on at first install when detected (/gg auctionator on|off)
-- * top search bar: filter the list by recipe name or material names
-- * Refresh Prices button (/gg refresh): re-pull the list with fresh prices
--   from Auctionator or the own AH database, without rescanning
-- * alt crafting: a material can also be crafted by any other character of the
--   realm whose recipes were learned (/gg alts on|off, on by default)
-- * one window, one tooltip (cost / sell price / profit), no other hooks
------------------------------------------------------------------------
local GG = {}
GreedyGoblin = GG

local floor, format, min = math.floor, string.format, math.min
local db

local PER_PAGE  = NUM_AUCTION_ITEMS_PER_PAGE or 50
local CHUNK     = 500     -- auctions processed per frame after a get-all scan
local DB_VERSION = 2

-- every WotLK enchanting vellum, so the vellum price can come straight from
-- Auctionator when there are no own AH scans that have spotted them
local VELLUM_NAMES = {
	"Weapon Vellum", "Weapon Vellum II", "Weapon Vellum III",
	"Armor Vellum", "Armor Vellum II", "Armor Vellum III",
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd700Greedy Goblin|r: " .. msg)
end

local function ItemID(link)
	if type(link) ~= "string" then return nil end
	return tonumber(link:match("item:(%d+)"))
end

local function Money(c)
	if not c then return "|cff888888?|r" end
	local neg = c < 0
	if neg then c = -c end
	c = floor(c + 0.5)
	local g, s, cc = floor(c / 10000), floor((c % 10000) / 100), c % 100
	local t = {}
	if g > 0 then t[#t + 1] = format("|cffffd700%dg|r", g) end
	if g > 0 or s > 0 then t[#t + 1] = format("|cffc7c7cf%ds|r", s) end
	if g < 100 then t[#t + 1] = format("|cffeda55f%dc|r", cc) end
	local out = table.concat(t, " ")
	if neg then out = "|cffff4040-|r" .. out end
	return out
end

local function Age(sec)
	if sec < 3600 then return floor(sec / 60) .. "m" end
	if sec < 86400 then return floor(sec / 3600) .. "h" end
	return floor(sec / 86400) .. "d"
end

local function Qty(n)
	if n == floor(n) then return tostring(n) end
	return format("%.1f", n)
end

local function CharKey() return GetRealmName() .. "-" .. UnitName("player") end

local function AHData() return db.ah[GetRealmName()] end

local function AHPrice(id)
	local d = AHData()
	return d and d.p[id]
end

-- Alt crafting (on by default, /gg alts on|off): recipes learned on your other
-- characters of this realm count as ways to craft a material yourself.
local function AltsEnabled() return db.useAlts ~= false end

------------------------------------------------------------------------
-- Auctionator (optional): its price database, probed through either the
-- current API (Auctionator.API.v1) or the legacy Atr_ functions, so any
-- Auctionator flavour works.
------------------------------------------------------------------------
local function AuctionatorPrice(id, name)
	if not id and not name then return nil end

	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if api and api.GetAuctionPriceByItemID then
		local ok, p = pcall(api.GetAuctionPriceByItemID, "GreedyGoblin", id)
		if ok and type(p) == "number" and p > 0 then return p end
	end

	local legacy = Atr_GetAuctionBuyout or Atr_GetAuctionPrice
	if type(legacy) == "function" then
		local ok, p = pcall(legacy, name or id)
		if (not ok or p == nil) and id then
			ok, p = pcall(legacy, id)
		end
		if ok and type(p) == "number" and p > 0 then return p end
	end

	return nil
end

------------------------------------------------------------------------
-- Auctionator mode: decided once at first install (Auctionator detected
-- or not), stored in db.auctMode and switchable with /gg auctionator
-- on|off. While on, Auctionator is the sole source of market prices and
-- the own AH scan machinery is switched off.
------------------------------------------------------------------------
local function AuctionatorPresent()
	return Atr_GetAuctionBuyout ~= nil or Atr_GetAuctionPrice ~= nil
		or (Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil)
end

local function AuctionatorMode()
	return db.auctMode ~= false and AuctionatorPresent()
end

local function ClearAHData()
	local had = (next(db.ah) or next(db.scrolls) or next(db.vellums)) ~= nil
	db.ah, db.scrolls, db.vellums = {}, {}, {}
	return had
end

------------------------------------------------------------------------
-- Recipes: learned when a profession window is opened
------------------------------------------------------------------------
local function IsHeader(t) return t == "header" or t == "subheader" end

local function LearnTradeSkill()
	if IsTradeSkillLinked and IsTradeSkillLinked() then return end
	local prof = GetTradeSkillLine()
	if not prof or prof == "UNKNOWN" then return end
	local n = GetNumTradeSkills()
	if not n or n == 0 then return false end

	-- expand collapsed headers so every recipe is listed, restore afterwards
	local collapsed = {}
	for i = n, 1, -1 do
		local name, typ, _, isExpanded = GetTradeSkillInfo(i)
		if IsHeader(typ) and not isExpanded then
			collapsed[name] = true
			ExpandTradeSkillSubClass(i)
		end
	end
	n = GetNumTradeSkills()

	local list = {}
	for i = 1, n do
		local name, typ = GetTradeSkillInfo(i)
		if name and not IsHeader(typ) then
			local ilink = GetTradeSkillItemLink(i)
			local product = ItemID(ilink) -- nil for enchants

			local minMade, maxMade = 1, 1
			if GetTradeSkillNumMade then minMade, maxMade = GetTradeSkillNumMade(i) end
			minMade = minMade or 1
			local made = (minMade + (maxMade or minMade)) / 2
			if made < 1 then made = 1 end

			local reagents, ok = {}, true
			for j = 1, GetTradeSkillNumReagents(i) do
				local rname, _, rcount = GetTradeSkillReagentInfo(i, j)
				local rid = ItemID(GetTradeSkillReagentItemLink(i, j))
				if rid and rcount then
					reagents[#reagents + 1] = { id = rid, n = rcount, name = rname }
				else
					ok = false
				end
			end
			if ok and #reagents > 0 then
				list[#list + 1] = { name = name, prof = prof, product = product, made = made, reagents = reagents }
			end
		end
	end

	for i = n, 1, -1 do
		local name, typ, _, isExpanded = GetTradeSkillInfo(i)
		if IsHeader(typ) and collapsed[name] and isExpanded then CollapseTradeSkillSubClass(i) end
	end

	local key = CharKey()
	db.recipes[key] = db.recipes[key] or {}
	local old = db.recipes[key][prof]
	db.recipes[key][prof] = list
	if not old or #old ~= #list then
		Print(format("Learned %d %s recipes.", #list, prof))
	end
	return true
end

------------------------------------------------------------------------
-- Costing: every material takes the cheapest of AH, vendor, or crafting it
-- yourself (recursively) with a recipe you know.
------------------------------------------------------------------------
local MAX_DEPTH = 4
local memo, byProduct = {}, {}
local ownerOf = {}      -- [recipe] = alt's name, only for recipes of OTHER characters
local vellumPrice       -- price of the priciest vellum (cheapest source for each), nil if none known
local vellumNode        -- the costing node behind vellumPrice when it is craftable (nil = plain AH price)

-- Character keys whose recipes may be used: this character first (so it wins
-- ties), then, if enabled, every other character stored for this realm.
local function CrafterKeys()
	local me = CharKey()
	local keys = { me }
	if AltsEnabled() then
		local prefix = GetRealmName() .. "-"
		local alts = {}
		for key in pairs(db.recipes) do
			if key ~= me and key:sub(1, #prefix) == prefix then alts[#alts + 1] = key end
		end
		table.sort(alts)
		for _, k in ipairs(alts) do keys[#keys + 1] = k end
	end
	return keys
end

local function BuildIndex()
	byProduct, memo, ownerOf, vellumPrice, vellumNode = {}, {}, {}, nil, nil
	local me = CharKey()
	local prefix = GetRealmName() .. "-"
	for _, key in ipairs(CrafterKeys()) do
		local who = key:sub(#prefix + 1)
		for _, list in pairs(db.recipes[key] or {}) do
			for _, r in ipairs(list) do
				if r.product then
					if key ~= me then ownerOf[r] = who end
					byProduct[r.product] = byProduct[r.product] or {}
					table.insert(byProduct[r.product], r)
				end
			end
		end
	end
end

-- Cheapest way to get ONE unit of an item: vendor, AH, or craft it.
local function Node(id, name, visiting, depth)
	if memo[id] then return memo[id] end
	local node = { id = id, name = name or GetItemInfo(id) or ("item " .. id) }

	local v = db.vendor[id]
	if v then node.cost, node.src = v, "vendor" end

	local ah = AHPrice(id)
	if ah and (not node.cost or ah < node.cost) then node.cost, node.src = ah, "AH" end

	local ap = AuctionatorPrice(id, name)
	if ap and (not node.cost or ap < node.cost) then node.cost, node.src = ap, "auctionator" end

	local recs = byProduct[id]
	if recs and depth <= MAX_DEPTH and not visiting[id] then
		visiting[id] = true
		for _, r in ipairs(recs) do
			local sum, ok, kids = 0, true, {}
			for _, rg in ipairs(r.reagents) do
				local kn = Node(rg.id, rg.name, visiting, depth + 1)
				kids[#kids + 1] = { n = rg.n, node = kn }
				if kn.cost then sum = sum + kn.cost * rg.n else ok = false end
			end
			if ok then
				local unit = sum / r.made
				if not node.cost or unit < node.cost then
					node.cost, node.src, node.rec, node.kids = unit, "craft", r, kids
				end
			end
		end
		visiting[id] = nil
	end

	memo[id] = node
	return node
end

local function IsVellumName(n)
	return n and n:find("Vellum", 1, true) and not n:find("Ruined", 1, true)
end

-- Vellum cost for enchanting recipes: the priciest vellum, where each vellum
-- costs the cheaper of buying it or crafting it (e.g. on an Inscription alt).
local function ComputeVellum()
	local best, bestNode
	local function consider(price, node)
		if price and (not best or price > best) then best, bestNode = price, node end
	end

	-- vellums that a known character can craft: Node() picks AH vs craft
	local crafted = {}
	for id, recs in pairs(byProduct) do
		local name = recs[1].name
		if IsVellumName(name) then
			crafted[id], crafted[name] = true, true
			local node = Node(id, name, {}, 1)
			consider(node.cost, node)
		end
	end

	-- every other vellum: plain market price
	if AuctionatorMode() then
		for _, nm in ipairs(VELLUM_NAMES) do
			if not crafted[nm] then consider(AuctionatorPrice(nil, nm)) end
		end
	else
		for id in pairs(db.vellums) do
			if not crafted[id] then consider(AHPrice(id) or AuctionatorPrice(id)) end
		end
	end

	vellumPrice, vellumNode = best, bestNode
end

local function Evaluate(r)
	local res = { r = r, name = r.name, prof = r.prof, made = r.made, missing = {}, kids = {} }

	local visiting = {}
	if r.product then visiting[r.product] = true end
	local cost = 0
	for _, rg in ipairs(r.reagents) do
		local node = Node(rg.id, rg.name, visiting, 1)
		res.kids[#res.kids + 1] = { n = rg.n, node = node }
		if node.cost then cost = cost + node.cost * rg.n else res.missing[#res.missing + 1] = node.name end
	end
	if not r.product then
		res.enchant, res.vellum, res.vellumNode = true, vellumPrice, vellumNode
		cost = cost + (vellumPrice or 0)
	end
	if #res.missing == 0 then res.cost = cost end

	if not r.product then
		-- enchant: the product is the scroll (enchant put on a vellum), found by name
		local p
		for _, nm in ipairs({ "Scroll of " .. r.name, r.name }) do
			local id = db.scrolls[nm]
			p = id and AHPrice(id)
			if p then break end
		end
		if not p then
			for _, nm in ipairs({ "Scroll of " .. r.name, r.name }) do
				p = AuctionatorPrice(nil, nm)
				if p then
					res.auc = true
					break
				end
			end
		end
		if p then
			res.gross, res.scroll = p, true
			res.sell = p * (1 - db.cut / 100)
		end
	elseif r.product then
		local p = AHPrice(r.product)
		if not p then
			p = AuctionatorPrice(r.product)
			if p then res.auc = true end
		end
		if p then
			res.gross = p * r.made
			res.sell = res.gross * (1 - db.cut / 100)
		else
			local vs = select(11, GetItemInfo(r.product))
			if vs and vs > 0 then
				res.gross, res.sell, res.vendorSell = vs * r.made, vs * r.made, true
			end
		end
	end

	if res.cost and res.sell then
		res.profit = res.sell - res.cost
		if res.sell > 0 then res.margin = res.profit / res.sell * 100 end
	end
	return res
end

GG.sortKey, GG.sortDesc = "profit", true

local function SortResults()
	local key, desc = GG.sortKey, GG.sortDesc
	table.sort(GG.results, function(a, b)
		local x, y = a[key], b[key]
		if x == y then return a.name < b.name end
		if x == nil then return false end   -- unpriced always last
		if y == nil then return true end
		if desc then return x > y end
		return x < y
	end)
end

------------------------------------------------------------------------
-- Optional search bar: filters the list by recipe name and by the names
-- of any material the recipe uses (as shown in the row tooltip).
------------------------------------------------------------------------
local function KidsMatch(kids, text)
	for _, k in ipairs(kids or {}) do
		local node = k.node
		if node then
			if node.name and node.name:lower():find(text, 1, true) then return true end
			if node.kids and KidsMatch(node.kids, text) then return true end
		end
	end
	return false
end

local function ApplyFilter()
	local text = GG.search
	if not text or text == "" then
		GG.view = GG.results or {}
		return
	end
	local view = {}
	for _, res in ipairs(GG.results or {}) do
		if (res.name and res.name:lower():find(text, 1, true))
			or (res.enchant and string.find("vellum", text, 1, true))
			or KidsMatch(res.kids, text) then
			view[#view + 1] = res
		end
	end
	GG.view = view
end

function GG:RefreshList()
	SortResults()
	ApplyFilter()
	self:UpdateList()
	self:UpdateStatus()
end

function GG:SetSearch(text)
	self.search = text and text:lower() or ""
	self:SetSearchPrompt()
	-- start from the top when the filter changes
	local bar = _G["GreedyGoblinScrollScrollBar"]
	if bar then bar:SetValue(0) end
	self:RefreshList()
end

function GG:SetSearchPrompt()
	local f = self.frame
	if f and f.searchPrompt then
		if (self.search or "") == "" then f.searchPrompt:Show() else f.searchPrompt:Hide() end
	end
end

function GG:Compute()
	BuildIndex()
	ComputeVellum()
	local res = {}
	for _, list in pairs(db.recipes[CharKey()] or {}) do
		for _, r in ipairs(list) do res[#res + 1] = Evaluate(r) end
	end
	self.results = res
	self:RefreshList()
end

-- Explicit refresh (Refresh Prices button / /gg refresh): drop every cached
-- cost and re-pull every price from the active source (Auctionator's live
-- database, or the own AH scan data), then rebuild the whole list from the top.
function GG:RefreshPrices()
	local bar = _G["GreedyGoblinScrollScrollBar"]
	if bar then bar:SetValue(0) end -- start the fresh list from the top
	self:Compute()
	Print(AuctionatorMode() and "List rebuilt with the latest Auctionator prices."
						or "List rebuilt from your own AH scan data.")
end

------------------------------------------------------------------------
-- Auction house scan
------------------------------------------------------------------------
local scan  -- nil when idle

local function StopScan(msg)
	scan = nil
	if msg then Print(msg) end
	GG:UpdateButtons()
	GG:UpdateStatus()
end

local function FinishScan()
	local n = 0
	for _ in pairs(scan.p) do n = n + 1 end
	db.ah[GetRealmName()] = { t = time(), n = n, p = scan.p }
	for name, id in pairs(scan.scrolls) do db.scrolls[name] = id end
	for id in pairs(scan.vellums) do db.vellums[id] = true end
	scan = nil
	Print(format("Scan complete: prices for %d different items.", n))
	GG:UpdateButtons()
	GG:Compute()
end

-- lowest buyout per unit, keyed by item id
local function AddAuction(i)
	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
	if buyout and buyout > 0 and count and count > 0 then
		local id = ItemID(GetAuctionItemLink("list", i))
		if id then
			if name and (name:find("^Scroll of Enchant") or name:find("^Enchant ")) then
				scan.scrolls[name] = id -- enchant scrolls, looked up by name for enchanting recipes
			elseif name and name:find("Vellum") and not name:find("Ruined") then
				scan.vellums[id] = true
			end
			local unit = floor(buyout / count)
			local cur = scan.p[id]
			if not cur or unit < cur then scan.p[id] = unit end
		end
	end
end

------------------------------------------------------------------------
-- Look up prices that are still unknown (targeted AH searches)
------------------------------------------------------------------------
local checked = {} -- [key] = GetTime() of the last lookup this session (skip repeats for 10 min)

local function CollectUnknown()
	local list, seen, now = {}, {}, GetTime()
	local function add(key, t)
		if seen[key] then return end
		seen[key] = true
		if checked[key] and now - checked[key] < 600 then return end
		t.key = key
		list[#list + 1] = t
	end

	-- materials (at any crafting depth) that have no AH, vendor or craft cost
	for id, node in pairs(memo) do
		if not node.cost and node.name and not node.name:find("^item %d") then
			add(id, { id = id, name = node.name })
		end
	end

	local anyEnchant
	for _, res in ipairs(GG.results or {}) do
		local r = res.r
		if r.product then
			if not AHPrice(r.product) and not AuctionatorPrice(r.product) then
				add(r.product, { id = r.product, name = GetItemInfo(r.product) or r.name })
			end
		else
			anyEnchant = true
			if not res.scroll then add("scroll:" .. r.name, { name = r.name, scroll = true }) end
		end
	end
	if anyEnchant and not vellumPrice then add("vellum", { name = "Vellum", vellum = true }) end
	return list
end

local function Matches(t, id, name)
	if t.id then return id == t.id end
	if t.scroll then return name == t.name or name == "Scroll of " .. t.name end
	if t.vellum then return name:find("Vellum", 1, true) and not name:find("Ruined", 1, true) end
end

local function CommitUnknownItem()
	local t = scan.cur
	checked[t.key] = GetTime()
	local realm = GetRealmName()
	for id, price in pairs(scan.prices) do
		local d = db.ah[realm]
		if not d then d = { t = time(), n = 0, p = {} }; db.ah[realm] = d end
		if not d.p[id] then d.n = d.n + 1; scan.found = scan.found + 1 end
		if not d.p[id] or price < d.p[id] then d.p[id] = price end
		if t.scroll then db.scrolls[scan.names[id]] = id end
		if t.vellum then db.vellums[id] = true end
	end
	scan.state = "next"
end

local function ProcessUnknownPage()
	local t = scan.cur
	local batch, total = GetNumAuctionItems("list")
	for i = 1, batch do
		local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
		if name and buyout and buyout > 0 and count and count > 0 then
			local id = ItemID(GetAuctionItemLink("list", i))
			if id and Matches(t, id, name) then
				local unit = floor(buyout / count)
				if not scan.prices[id] or unit < scan.prices[id] then scan.prices[id] = unit end
				scan.names[id] = name
			end
		end
	end
	if batch >= PER_PAGE and (scan.page + 1) < 3 and (scan.page + 1) * PER_PAGE < total then
		scan.page, scan.state = scan.page + 1, "ready"
	else
		CommitUnknownItem()
	end
end

local function UnknownTick(now)
	local st = scan.state
	if st == "next" then
		scan.i = scan.i + 1
		if scan.i > #scan.queue then
			local found, total = scan.found, #scan.queue
			scan = nil
			Print(format("Looked up %d item(s), found prices for %d.", total, found))
			GG:UpdateButtons()
			GG:Compute()
			return
		end
		scan.cur, scan.page, scan.prices, scan.names, scan.state = scan.queue[scan.i], 0, {}, {}, "ready"
		GG:UpdateStatus()
	elseif st == "ready" then
		if not CanSendAuctionQuery() then return end
		scan.state, scan.sentAt = "waiting", now
		QueryAuctionItems(scan.cur.name, nil, nil, 0, nil, nil, scan.page, nil, -1)
	elseif st == "waiting" then
		if now - scan.sentAt > 12 then CommitUnknownItem() end -- no answer: move on
	end
end

function GG:StartUnknownScan()
	if AuctionatorMode() then
		Print("Not needed: Auctionator already provides the prices. /gg auctionator off to re-enable.")
		return
	end
	if not self.ahOpen then Print("Open the auction house first.") return end
	if scan then Print("A scan is already running.") return end
	self:Compute()
	local list = CollectUnknown()
	if #list == 0 then Print("No unknown prices to look up (or they were all just checked).") return end
	scan = { mode = "unknown", queue = list, i = 0, found = 0, state = "next" }
	Print(format("Looking up %d unknown price(s)...", #list))
	self:UpdateButtons()
	self:UpdateStatus()
end

StaticPopupDialogs["GREEDYGOBLIN_CLEAR"] = {
	text = "Clear the whole Greedy Goblin database?\n\nAll AH prices, vendor prices, learned recipes and scroll/vellum data will be deleted.",
	button1 = YES,
	button2 = NO,
	OnAccept = function() GG:ClearDatabase() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	preferredIndex = 3,
}

function GG:ClearDatabase()
	if scan then StopScan() end
	db.vendor, db.ah = {}, {}
	db.recipes, db.scrolls, db.vellums = {}, {}, {}
	for k in pairs(checked) do checked[k] = nil end
	self:Compute()
	self:UpdateButtons()
	Print("Database cleared. Open your profession windows again to re-learn recipes.")
end

function GG:StartScan()
	if AuctionatorMode() then
		Print("Scanning is off: prices come from Auctionator now. /gg auctionator off to re-enable.")
		return
	end
	if not self.ahOpen then Print("Open the auction house first.") return end
	if scan then Print("A scan is already running.") return end
	local _, canAll = CanSendAuctionQuery()
	if not canAll then Print("The full scan is on cooldown, try again later.") return end
	scan = { mode = "all", p = {}, scrolls = {}, vellums = {}, state = "ready", sentAt = GetTime() }
	Print("Scanning the whole auction house...")
	self:UpdateButtons()
	self:UpdateStatus()
end

local function ScanTick(now)
	if scan.mode == "unknown" then return UnknownTick(now) end
	if scan.state == "ready" then
		local canQuery, canAll = CanSendAuctionQuery()
		if not (canQuery and canAll) then return end
		scan.state, scan.sentAt = "waiting", now
		QueryAuctionItems("", nil, nil, 0, nil, nil, 0, nil, -1, true)

	elseif scan.state == "waiting" then
		if now - scan.sentAt > 40 then
			StopScan("The auction house did not answer, scan aborted.")
		end

	elseif scan.state == "processing" then
		local last = min(scan.pos + CHUNK - 1, scan.count)
		for i = scan.pos, last do AddAuction(i) end
		scan.pos = last + 1
		if scan.pos > scan.count then
			FinishScan()
		else
			GG:UpdateStatus()
		end
	end
end

local function OnAuctionListUpdate()
	if not scan or scan.state ~= "waiting" then return end
	if scan.mode == "unknown" then return ProcessUnknownPage() end
	local batch = GetNumAuctionItems("list")
	if not batch or batch == 0 then return end -- wait for the real result (timeout covers failure)
	scan.state, scan.pos, scan.count = "processing", 1, batch
end

------------------------------------------------------------------------
-- Vendor prices (so vendor-sold mats like thread and flux are costed)
------------------------------------------------------------------------
local function RecordVendor()
	local npc = UnitName("npc")

	-- ids of every material used by the recipes you know
	local mats = {}
	for _, list in pairs(db.recipes[CharKey()] or {}) do
		for _, r in ipairs(list) do
			for _, rg in ipairs(r.reagents) do mats[rg.id] = true end
		end
	end

	local learned = {}
	for i = 1, GetMerchantNumItems() do
		local mname, _, price, qty, _, _, ext = GetMerchantItemInfo(i)
		local id = ItemID(GetMerchantItemLink(i))
		if id and price and price > 0 and not ext then
			local unit = price / ((qty and qty > 0) and qty or 1)
			if mats[id] and db.vendor[id] ~= unit then
				learned[#learned + 1] = { name = mname or ("item " .. id), unit = unit }
			end
			db.vendor[id] = unit
		end
	end

	if #learned > 0 then
		local parts = {}
		for i = 1, math.min(#learned, 8) do
			parts[#parts + 1] = learned[i].name .. " " .. Money(learned[i].unit)
		end
		Print(format("%s: learned %d material price%s: %s%s", npc or "Vendor", #learned,
			#learned > 1 and "s" or "", table.concat(parts, ", "), #learned > 8 and ", ..." or ""))
		if GG.frame and GG.frame:IsShown() then GG:Compute() end
	end
end

------------------------------------------------------------------------
-- Optional ElvUI skin (does nothing unless ElvUI is loaded)
------------------------------------------------------------------------
local function GetElvUI()
	if not ElvUI then return end
	local ok, E = pcall(function() return unpack(ElvUI) end)
	if not ok or type(E) ~= "table" or not E.GetModule then return end
	local ok2, S = pcall(E.GetModule, E, "Skins")
	if ok2 and type(S) == "table" then return E, S end
end

function GG:SkinButton(b)
	local E, S = GetElvUI()
	if E and S.HandleButton then pcall(S.HandleButton, S, b) end
end

function GG:SkinWindow(f)
	local E, S = GetElvUI()
	if not E then return end
	pcall(function()
		if f.SetTemplate then f:SetTemplate("Transparent") end
		if S.HandleCloseButton then S:HandleCloseButton(f.close) end
		if S.HandleButton then S:HandleButton(f.scanBtn) end
		if S.HandleButton and f.unknownBtn then S:HandleButton(f.unknownBtn) end
		if S.HandleButton and f.refreshBtn then S:HandleButton(f.refreshBtn) end
		if S.HandleButton and f.clearBtn then S:HandleButton(f.clearBtn) end
		local bar = _G["GreedyGoblinScrollScrollBar"]
		if bar and S.HandleScrollBar then S:HandleScrollBar(bar) end
		if f.searchBox and S.HandleEditBox then S:HandleEditBox(f.searchBox) end
		local tex = E.media and E.media.blankTex
		if tex then
			for _, row in ipairs(f.rows) do
				row:SetHighlightTexture(tex)
				local h = row:GetHighlightTexture()
				if h then h:SetVertexColor(1, 1, 1, 0.12) end
			end
		end
	end)
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
local ROWS, ROW_H = 20, 24

local COLS = {
	{ key = "name",   label = "Recipe",     x = 6,   w = 250, j = "LEFT"  },
	{ key = "prof",   label = "Profession", x = 262, w = 108, j = "LEFT"  },
	{ key = "cost",   label = "Materials",  x = 376, w = 110, j = "RIGHT" },
	{ key = "sell",   label = "Sells for",  x = 490, w = 110, j = "RIGHT" },
	{ key = "profit", label = "Profit",     x = 604, w = 110, j = "RIGHT" },
	{ key = "margin", label = "Margin",     x = 718, w = 68,  j = "RIGHT" },
}

local COL_W = {}
for _, c in ipairs(COLS) do COL_W[c.key] = c.w - 6 end

local SRC_COLOR = { vendor = "|cff55ff55", AH = "|cffffd100", craft = "|cff55ccff", auctionator = "|cff40d0b0" }

local function SrcLabel(node)
	if node.src == "vendor" then
		return "vendor"
	elseif node.src == "craft" then
		local who = ownerOf[node.rec]
		return "craft: " .. node.rec.prof .. (who and (", " .. who) or "")
	elseif node.src == "auctionator" then
		return "auctionator"
	end
	return "AH"
end

local function AddKids(tt, kids, qty, indent)
	for _, k in ipairs(kids) do
		local n, node = k.n * qty, k.node
		local label = indent .. Qty(n) .. " x " .. node.name
		if node.cost then
			tt:AddDoubleLine(label .. " " .. (SRC_COLOR[node.src] or "") .. "(" .. SrcLabel(node) .. ")|r",
				Money(node.cost * n), 1, 1, 1, 1, 1, 1)
			if node.src == "craft" then
				AddKids(tt, node.kids, n / node.rec.made, indent .. "   ")
			end
		else
			tt:AddDoubleLine(label, "|cffff4040no price|r", 1, 1, 1, 1, 1, 1)
		end
	end
end

local function ShowRowTooltip(row, res)
	local tt = GameTooltip
	tt:SetOwner(row, "ANCHOR_RIGHT")
	tt:AddLine(res.name .. (res.made > 1 and (" x" .. Qty(res.made)) or ""), 1, 0.82, 0)
	tt:AddLine(" ")
	AddKids(tt, res.kids, 1, "")
	if res.enchant then
		local vn = res.vellumNode
		if vn then
			tt:AddDoubleLine("Vellum: " .. vn.name .. " " .. (SRC_COLOR[vn.src] or "") .. "(" .. SrcLabel(vn) .. ")|r",
				Money(res.vellum), 1, 1, 1, 1, 1, 1)
			if vn.src == "craft" then AddKids(tt, vn.kids, 1 / vn.rec.made, "   ") end
		else
			tt:AddDoubleLine("Vellum (priciest on AH)", Money(res.vellum), 1, 1, 1, 1, 1, 1)
		end
	end
	tt:AddLine(" ")
	tt:AddDoubleLine("Materials cost", Money(res.cost), 1, 1, 1, 1, 1, 1)
	if res.gross then
		local label
		if res.vendorSell then label = "Sell price (vendor)"
		elseif res.scroll then label = res.auc and "Sell price (scroll, auctionator)" or "Sell price (scroll, AH)"
		elseif res.auc then label = "Sell price (auctionator)"
		else label = "Sell price (AH)" end
		tt:AddDoubleLine(label, Money(res.gross), 1, 1, 1, 1, 1, 1)
		if not res.vendorSell then
			tt:AddDoubleLine("AH cut (" .. db.cut .. "%)", Money(-(res.gross - res.sell)), 1, 1, 1, 1, 1, 1)
		end
	else
		tt:AddDoubleLine("Sell price", "|cff888888?|r", 1, 1, 1, 1, 1, 1)
	end
	tt:AddDoubleLine("Profit", Money(res.profit), 1, 0.82, 0, 1, 1, 1)
	if res.margin then
		tt:AddDoubleLine("Profit margin", format("%d%%", floor(res.margin + 0.5)), 1, 1, 1, 1, 1, 1)
	end
	tt:Show()
end

local function MakeText(parent, c)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", parent, "LEFT", c.x, 0)
	fs:SetWidth(c.w)
	fs:SetJustifyH(c.j)
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	return fs
end

-- Shorten text with "..." so it fits one line (measured on a hidden font string).
local function Fit(f, name, suffix, maxW)
	local m = f.measure
	m:SetText(name .. suffix)
	if m:GetStringWidth() <= maxW then return name .. suffix end
	local n = #name
	while n > 1 do
		n = n - 1
		local b = name:byte(n + 1)
		if not (b and b >= 128 and b < 192) then -- don't cut inside a multi-byte character
			local t = name:sub(1, n) .. "..." .. suffix
			m:SetText(t)
			if m:GetStringWidth() <= maxW then return t end
		end
	end
	return name:sub(1, 1) .. "..." .. suffix
end

function GG:CreateWindow()
	if self.frame then return end
	local f = CreateFrame("Frame", "GreedyGoblinFrame", UIParent)
	f:SetWidth(880)
	f:SetHeight(672)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()
	table.insert(UISpecialFrames, "GreedyGoblinFrame")

	f.measure = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.measure:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	f.measure:SetAlpha(0)

	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", f, "TOP", 0, -16)
	title:SetText("Greedy Goblin")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
	f.close = close

	local searchLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 30, -52)
	searchLabel:SetText("Search:")

	local searchBox = CreateFrame("EditBox", "GreedyGoblinSearch", f, "InputBoxTemplate")
	searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 86, -46)
	searchBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -60, 0)
	searchBox:SetHeight(24)
	searchBox:SetAutoFocus(false)
	searchBox:SetMaxLetters(48)
	searchBox:SetScript("OnTextChanged", function(self)
		GG:SetSearch(self:GetText() or "")
	end)
	searchBox:SetScript("OnEscapePressed", function(self)
		if self:GetText() ~= "" then
			self:SetText("")
		else
			self:ClearFocus()
		end
	end)
	searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	f.searchBox = searchBox

	local searchPrompt = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	searchPrompt:SetPoint("LEFT", searchBox, "LEFT", 13, 0)
	searchPrompt:SetText("Search recipes or materials...")
	f.searchPrompt = searchPrompt
	GG:SetSearchPrompt()

	for _, c in ipairs(COLS) do
		local b = CreateFrame("Button", nil, f)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", 30 + c.x, -76)
		b:SetWidth(c.w)
		b:SetHeight(20)
		b:SetNormalFontObject(GameFontNormal)
		b:SetText(c.label)
		b:GetFontString():SetJustifyH(c.j)
		b:GetFontString():SetAllPoints(b)
		b:SetScript("OnClick", function()
			if GG.sortKey == c.key then
				GG.sortDesc = not GG.sortDesc
			else
				GG.sortKey, GG.sortDesc = c.key, (c.key ~= "name" and c.key ~= "prof")
			end
			GG:RefreshList()
		end)
	end

	local sf = CreateFrame("ScrollFrame", "GreedyGoblinScroll", f, "FauxScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", f, "TOPLEFT", 30, -102)
	sf:SetWidth(790)
	sf:SetHeight(ROWS * ROW_H)
	sf:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() GG:UpdateList() end)
	end)
	f.scroll = sf
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(_, delta)
		local bar = _G["GreedyGoblinScrollScrollBar"]
		if bar then bar:SetValue(bar:GetValue() - delta * ROW_H * 2) end
	end)

	f.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetWidth(790)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", f, "TOPLEFT", 30, -102 - (i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.cols = {}
		for _, c in ipairs(COLS) do row.cols[c.key] = MakeText(row, c) end
		row:SetScript("OnEnter", function(self) if self.res then ShowRowTooltip(self, self.res) end end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.rows[i] = row
	end

	f.empty = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	f.empty:SetPoint("CENTER", f, "CENTER", 0, 20)
	f.empty:SetWidth(640)
	f.empty:SetText("No recipes yet.\nOpen each of your profession windows once so Greedy Goblin can learn them.")

	f.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 32, 66)
	f.status:SetWidth(800)
	f.status:SetJustifyH("LEFT")

	-- The Refresh button owns the bottom-right corner; the scan buttons chain
	-- off its left side. Scan/unknown are hidden in Auctionator mode, but the
	-- Refresh button stays, pinned to the corner in every mode.
	local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refreshBtn:SetWidth(110)
	refreshBtn:SetHeight(26)
	refreshBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 26)
	refreshBtn:SetText("Refresh Prices")
	refreshBtn:SetScript("OnClick", function() GG:RefreshPrices() end)
	refreshBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Refresh Prices", 1, 0.82, 0)
		GameTooltip:AddLine("Re-pull every price from the active source", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("(Auctionator or the own AH db) and rebuild the list.", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	refreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.refreshBtn = refreshBtn

	local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	scanBtn:SetWidth(130)
	scanBtn:SetHeight(26)
	scanBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -10, 0)
	scanBtn:SetText("Scan AH")
	scanBtn:SetScript("OnClick", function() GG:StartScan() end)
	f.scanBtn = scanBtn

	local unkBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	unkBtn:SetWidth(150)
	unkBtn:SetHeight(26)
	unkBtn:SetPoint("RIGHT", scanBtn, "LEFT", -10, 0)
	unkBtn:SetText("Find Unknown Prices")
	unkBtn:SetScript("OnClick", function() GG:StartUnknownScan() end)
	f.unknownBtn = unkBtn

	local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clearBtn:SetWidth(130)
	clearBtn:SetHeight(26)
	clearBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 34, 26)
	clearBtn:SetText("Clear Database")
	clearBtn:SetScript("OnClick", function() StaticPopup_Show("GREEDYGOBLIN_CLEAR") end)
	f.clearBtn = clearBtn

	self.frame = f
	self:SkinWindow(f)
	self:UpdateButtons()
end

function GG:UpdateList()
	local f = self.frame
	if not f then return end
	local view = self.view or {}
	FauxScrollFrame_Update(f.scroll, #view, ROWS, ROW_H)
	local off = FauxScrollFrame_GetOffset(f.scroll)
	if off > 0 then off = min(off, math.max(0, #view - ROWS)) end

	for i = 1, ROWS do
		local row, res = f.rows[i], view[off + i]
		row.res = res
		if res then
			local c = row.cols
			local suffix = res.made > 1 and (" |cff888888x" .. Qty(res.made) .. "|r") or ""
			c.name:SetText(Fit(f, res.name, suffix, COL_W.name))
			c.prof:SetText(Fit(f, res.prof, "", COL_W.prof))
			c.cost:SetText(Money(res.cost))
			c.sell:SetText(Money(res.sell) .. (res.vendorSell and " |cff888888v|r" or ""))
			c.profit:SetText(Money(res.profit))
			if res.margin then
				c.margin:SetText((res.margin >= 0 and "|cff55ff55" or "|cffff4040") .. floor(res.margin + 0.5) .. "%|r")
			else
				c.margin:SetText("|cff888888?|r")
			end
			row:Show()
		else
			row:Hide()
		end
	end

	if #view == 0 then
		if (self.search or "") ~= "" and #(self.results or {}) > 0 then
			f.empty:SetText("No recipes match your search.")
		else
			f.empty:SetText("No recipes yet.\nOpen each of your profession windows once so Greedy Goblin can learn them.")
		end
		f.empty:Show()
	else
		f.empty:Hide()
	end
end

function GG:UpdateStatus()
	local f = self.frame
	if not f then return end
	local txt
	local count
	if (self.search or "") ~= "" and self.view then
		count = format("%d of %d recipes shown", #self.view, #(self.results or {}))
	else
		count = format("%d recipes", #(self.results or {}))
	end
	if scan then
		if scan.mode == "unknown" then
			txt = format("|cffffd700Looking up prices:|r %d/%d  %s", scan.i, #scan.queue, scan.cur and scan.cur.name or "")
		elseif scan.state == "processing" then
			txt = format("|cffffd700Scanning:|r reading auctions %d/%d", min(scan.pos, scan.count), scan.count)
		else
			txt = "|cffffd700Scanning:|r waiting for the auction house..."
		end
	elseif AuctionatorMode() then
		txt = format("Prices: |cffffd700Auctionator|r  |  AH cut %d%%  |  %s", db.cut, count)
	else
		local d = AHData()
		local ah = d and format("%d items scanned %s ago", d.n, Age(time() - d.t)) or "|cffff4040no AH scan yet|r"
		txt = format("AH: %s  |  AH cut %d%%  |  %s", ah, db.cut, count)
		if self.ahOpen then
			local _, canAll = CanSendAuctionQuery()
			if not canAll then txt = txt .. "  |  |cffff8040full scan on cooldown|r" end
		end
	end
	f.status:SetText(txt)
end

function GG:UpdateButtons()
	local f = self.frame
	if not f then return end
	-- One foot layout for both modes: the Refresh button now always lives in
	-- the bottom-right corner, so the window keeps its full height everywhere
	-- and only the own-scan buttons hide in Auctionator mode.
	local auct = AuctionatorMode()
	local function showBtn(b, show)
		if not b then return end
		if show then b:Show() else b:Hide() end
	end
	showBtn(f.scanBtn, not auct)
	showBtn(f.unknownBtn, not auct)
	showBtn(f.clearBtn, not auct)
	if f.status then
		f.status:ClearAllPoints()
		f.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 32, 66)
	end
	f:SetHeight(672)
	local canAll, canQuery = false, false
	if not auct and self.ahOpen and not scan then
		local q, a = CanSendAuctionQuery()
		canQuery, canAll = q and true or false, a and true or false
	end
	local function set(b, on)
		if b then
			if on then b:Enable() else b:Disable() end
		end
	end
	set(f.scanBtn, canAll)
	set(f.unknownBtn, canQuery)
end

function GG:Toggle()
	self:CreateWindow()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self:Compute()
		self.frame:Show()
	end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
SLASH_GREEDYGOBLIN1 = "/gg"
SLASH_GREEDYGOBLIN2 = "/greedygoblin"
SlashCmdList["GREEDYGOBLIN"] = function(msg)
	if not db then return end
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd, rest = cmd:lower(), rest:lower()

	if cmd == "" then
		GG:Toggle()
	elseif cmd == "scan" then
		GG:StartScan()
	elseif cmd == "clear" then
		StaticPopup_Show("GREEDYGOBLIN_CLEAR")
	elseif cmd == "unknown" then
		GG:StartUnknownScan()
	elseif cmd == "refresh" then
		GG:RefreshPrices()
	elseif cmd == "auctionator" then
		if rest == "on" or rest == "off" then
			db.auctMode = (rest == "on")
			if rest == "on" then
				if AuctionatorPresent() then
					local had = ClearAHData()
					Print("Auctionator mode on: prices come from Auctionator" .. (had and ", own AH data cleared." or "."))
				else
					Print("Auctionator mode on, but Auctionator is not loaded.")
				end
			else
				Print("Auctionator mode off: prices come from /gg scan and /gg unknown again.")
			end
			GG:Compute()
			GG:UpdateButtons()
			if GG.frame and GG.frame:IsShown() then GG:UpdateStatus() end
		else
			Print("Auctionator mode is " .. (AuctionatorMode() and "on" or "off") .. ". Usage: /gg auctionator on|off")
		end
	elseif cmd == "cut" then
		local n = tonumber(rest)
		if not n or n < 0 or n > 50 then Print("Usage: /gg cut <percent>   (5 faction AH, 15 neutral AH)") return end
		db.cut = n
		GG:Compute()
		Print("AH cut set to " .. n .. "%.")
	elseif cmd == "alts" then
		if rest == "on" or rest == "off" then
			db.useAlts = (rest == "on")
			GG:Compute()
			Print("Alt crafting " .. (db.useAlts and "on: recipes of your other characters count as a way to craft materials." or "off: only this character's recipes are used."))
		else
			local prefix = GetRealmName() .. "-"
			local lines = {}
			for key, profs in pairs(db.recipes) do
				if key:sub(1, #prefix) == prefix then
					local parts = {}
					for prof, list in pairs(profs) do parts[#parts + 1] = format("%s (%d)", prof, #list) end
					table.sort(parts)
					lines[#lines + 1] = format("  %s: %s", key:sub(#prefix + 1), table.concat(parts, ", "))
				end
			end
			table.sort(lines)
			Print("Alt crafting is " .. (AltsEnabled() and "on" or "off") .. ". Usage: /gg alts on|off. Known recipes on this realm:")
			for _, l in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage(l) end
			if #lines == 0 then DEFAULT_CHAT_FRAME:AddMessage("  none yet - open each profession window on every character once.") end
		end
	elseif cmd == "reset" then
		db.recipes[CharKey()] = nil
		GG:Compute()
		Print("Forgot the recipes stored for this character.")
	else
		Print("/gg  |  /gg scan  |  /gg unknown  |  /gg refresh  |  /gg auctionator on|off  |  /gg alts on|off  |  /gg cut <percent>  |  /gg reset  |  /gg clear")
	end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local learnAt, learnTries
local frame = CreateFrame("Frame")

local btnTimer = 0
frame:SetScript("OnUpdate", function(_, elapsed)
	local now = GetTime()
	btnTimer = btnTimer - elapsed
	if btnTimer <= 0 then
		btnTimer = 0.5
		if db and GG.ahOpen then
			GG:UpdateButtons()
			if not scan and GG.frame and GG.frame:IsShown() then GG:UpdateStatus() end
		end
	end
	if learnAt and now >= learnAt then
		learnAt = nil
		if LearnTradeSkill() == false then
			learnTries = learnTries + 1
			if learnTries <= 3 then learnAt = now + 0.7 end
		else
			if GG.frame and GG.frame:IsShown() then GG:Compute() end
		end
	end
	if scan then ScanTick(now) end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "GreedyGoblin" then return end
		if type(GreedyGoblinDB) ~= "table" or GreedyGoblinDB.v ~= DB_VERSION then
			GreedyGoblinDB = { v = DB_VERSION }
		end
		db = GreedyGoblinDB
		db.cut     = db.cut or 5
		db.vendor  = db.vendor or {}   -- [itemID] = copper per unit
		db.scrolls = db.scrolls or {}  -- [scroll name] = itemID, learned from AH scans
		db.vellums = db.vellums or {}  -- [itemID] = true, every vellum seen on the AH
		db.vendorNPC = nil -- no longer tracked: vendor prices only, no names
		db.ah      = db.ah or {}       -- [realm] = { t = time, n = items, p = { [itemID] = lowest unit buyout } }
		db.recipes = db.recipes or {}  -- [realm-char] = { [profession] = { recipe, ... } }
		Print("loaded. /gg to open, /gg scan at the auction house.")
		if db.auctMode == nil then
			-- first install: pick the price source once and tell the player
			if AuctionatorPresent() then
				db.auctMode = true
				local had = ClearAHData()
				Print("Auctionator found: prices come from Auctionator"
					.. (had and ", own AH data cleared." or ".")
					.. " /gg auctionator off to scan yourself instead.")
			else
				db.auctMode = false
				Print("No Auctionator found: prices come from your own AH scans (/gg scan and /gg unknown)."
					.. " Switch with /gg auctionator on once it is installed.")
			end
		elseif AuctionatorPresent() then
			if AuctionatorMode() then
				local had = ClearAHData()
				if had then
					Print("Auctionator mode: own AH data cleared. /gg auctionator off to disable.")
				end
			else
				Print("Auctionator present but disabled: /gg auctionator on to use its prices.")
			end
		end

	elseif not db then
		return

	elseif event == "TRADE_SKILL_SHOW" then
		learnAt, learnTries = GetTime() + 0.6, 0

	elseif event == "MERCHANT_SHOW" then
		RecordVendor()

	elseif event == "AUCTION_HOUSE_SHOW" then
		GG.ahOpen = true
		GG:UpdateButtons()

	elseif event == "AUCTION_HOUSE_CLOSED" then
		GG.ahOpen = false
		if scan then StopScan("Auction house closed, scan aborted.") end
		GG:UpdateButtons()

	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		OnAuctionListUpdate()
	end
end)
