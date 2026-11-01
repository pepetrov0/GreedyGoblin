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
-- * vellum support: every enchant is matched to the vellum it needs (Armor or
--   Weapon, tier I/II/III) and costed at the cheapest of AH / craft / vendor
--   (/gg vellum shows the current vellum prices)
-- * one window, one tooltip (cost / sell price / profit), no other hooks
------------------------------------------------------------------------
local GG = {}
GreedyGoblin = GG

local floor, format, min, max = math.floor, string.format, math.min, math.max
local pairs, ipairs, select = pairs, ipairs, select
local wipe = wipe or table.wipe
local db
local EMPTY = {} -- shared read-only empty table (never write to it)

local PER_PAGE  = NUM_AUCTION_ITEMS_PER_PAGE or 50
local CHUNK     = 500     -- auctions processed per frame after a get-all scan
local DB_VERSION = 3

-- Stored recipe format (compact, ~4x smaller than v2):
--   { id1, n1, id2, n2, ...,  name = spell name, prof = profession,
--     product = item id (nil for enchants), made = avg yield (nil = 1),
--     lvl = enchant level restriction (enchants only) }
-- Reagent names live once per item in db.names[id].

-- every WotLK enchanting vellum, so the vellum price can come straight from
-- Auctionator when there are no own AH scans that have spotted them
-- Vellums, by item id. Each vellum only absorbs enchants up to a level
-- restriction: tier I = enchants with no restriction, II = 35 or lower,
-- III = 60 or lower. A higher tier can also hold the enchants of a lower one.
local VELLUM_ID = {
	Armor  = { 38682, 37602, 43145 },   -- Armor Vellum, II, III
	Weapon = { 39349, 39350, 43146 },   -- Weapon Vellum, II, III
}
local VELLUM_LIMIT = { 0, 35, 60 }
-- only used for display / AH search text until the client has the item cached
local VELLUM_FALLBACK = {
	Armor  = { "Armor Vellum", "Armor Vellum II", "Armor Vellum III" },
	Weapon = { "Weapon Vellum", "Weapon Vellum II", "Weapon Vellum III" },
}

local function VellumName(kind, tier)
	return GetItemInfo(VELLUM_ID[kind][tier]) or VELLUM_FALLBACK[kind][tier]
end

-- smallest tier whose limit covers the enchant's level restriction
local function TierForLevel(lvl)
	for t = 1, 3 do
		if lvl <= VELLUM_LIMIT[t] then return t end
	end
	return 3
end

-- Fallback for recipes learned before levels were stored (reopen the Enchanting
-- window to learn the exact level): guess from the enchant's materials.
-- BC: Arcane Dust, Greater/Lesser Planar Essence, Small/Large Prismatic Shard, Void Crystal
-- Wrath: Dream Shard, Infinite Dust, Greater/Lesser Cosmic Essence, Abyss Crystal
local MAT_TIER = {
	[22445] = 2, [22446] = 2, [22447] = 2, [22448] = 2, [22449] = 2, [22450] = 2,
	[34052] = 3, [34054] = 3, [34055] = 3, [34056] = 3, [34057] = 3,
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local TAG = "|cff33ff99Greedy Goblin|r"
local ADDON_VERSION = GetAddOnMetadata("GreedyGoblin", "Version") or "?"

local function Log(msg) DEFAULT_CHAT_FRAME:AddMessage(TAG .. " " .. msg) end
local function LogLoad(hint) Log("v" .. ADDON_VERSION .. " loaded." .. (hint and (" " .. hint) or "")) end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(TAG .. " " .. msg)
end

local function ItemID(link)
	if type(link) ~= "string" then return nil end
	return tonumber(link:match("item:(%d+)"))
end

-- one format() call, no temp table
local function Money(c)
	if not c then return "|cff888888?|r" end
	local neg = ""
	if c < 0 then neg, c = "|cffff4040-|r", -c end
	c = floor(c + 0.5)
	local g, s, cc = floor(c / 10000), floor((c % 10000) / 100), c % 100
	if g >= 100 then return format("%s|cffffd700%dg|r |cffc7c7cf%ds|r", neg, g, s) end
	if g > 0 then return format("%s|cffffd700%dg|r |cffc7c7cf%ds|r |cffeda55f%dc|r", neg, g, s, cc) end
	if s > 0 then return format("%s|cffc7c7cf%ds|r |cffeda55f%dc|r", neg, s, cc) end
	return format("%s|cffeda55f%dc|r", neg, cc)
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
	if not id and name then
		-- the current API only takes ids: resolve it from the (cached) item name
		local link = select(2, GetItemInfo(name))
		id = ItemID(link)
	end

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
	local had = (next(db.ah) or next(db.scrolls)) ~= nil
	db.ah, db.scrolls = {}, {}
	return had
end

local enchName
local function EnchantingName()
	if not enchName then enchName = (GetSpellInfo and GetSpellInfo(7411)) or "Enchanting" end
	return enchName
end

local scrollName = {} -- [enchant name] = "Scroll of <name>", so it is not re-concatenated
local function ScrollOf(name)
	local s = scrollName[name]
	if not s then s = "Scroll of " .. name; scrollName[name] = s end
	return s
end

-- Item ids (reagents, products, vellums) and enchant scroll names used by the
-- recipes of every character on `realm` (nil = all realms). Only these items
-- are worth storing prices for.
local function RelevantItems(realm)
	local ids, scrolls = {}, {}
	local prefix = realm and (realm .. "-")
	local ench = EnchantingName()
	for key, profs in pairs(db.recipes) do
		if not prefix or key:sub(1, #prefix) == prefix then
			for _, list in pairs(profs) do
				for _, r in ipairs(list) do
					if r.product then
						ids[r.product] = true
					elseif r.prof == ench then
						scrolls[ScrollOf(r.name)], scrolls[r.name] = true, true
					end
					for i = 1, #r, 2 do ids[r[i]] = true end
				end
			end
		end
	end
	for _, list in pairs(VELLUM_ID) do
		for _, id in ipairs(list) do ids[id] = true end
	end
	return ids, scrolls
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

	local names = db.names
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

			local r, ok = {}, true
			for j = 1, GetTradeSkillNumReagents(i) do
				local rname, _, rcount = GetTradeSkillReagentInfo(i, j)
				local rid = ItemID(GetTradeSkillReagentItemLink(i, j))
				if rid and rcount then
					r[#r + 1] = rid
					r[#r + 1] = rcount
					if rname and names[rid] ~= rname then names[rid] = rname end
				else
					ok = false
				end
			end
			if ok and #r > 0 then
				r.name, r.prof, r.product = name, prof, product
				if made ~= 1 then r.made = made end
				-- enchants: the level restriction in the description ("Requires a level
				-- 60 or higher item", none = no restriction) decides the vellum tier
				if not product and GetTradeSkillDescription then
					local desc = GetTradeSkillDescription(i)
					if desc and desc ~= "" then r.lvl = tonumber(desc:match("[Ll]evel (%d+)")) or 0 end
				end
				list[#list + 1] = r
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
	-- fewer recipes than last time means a search/filter is active: keep the old list
	if old and #list < #old then return true end
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
local memo = {}
-- [item id] = the recipe making it, or a list of recipes when several differ.
-- The same recipe known by several characters is kept once (the first key in
-- CrafterKeys order, so this character wins).
local byProduct = {}
local ownerOf = {}      -- [recipe] = alt's name, only for recipes of OTHER characters
local vellumCache = {}  -- [vellum id] = node or false (no price known), valid until the next BuildIndex
local ahP = EMPTY       -- this realm's AH price table, captured by BuildIndex

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
	byProduct, memo, ownerOf, vellumCache = {}, {}, {}, {}
	local d = AHData()
	ahP = d and d.p or EMPTY
	local me = CharKey()
	local prefix = GetRealmName() .. "-"
	for _, key in ipairs(CrafterKeys()) do
		local who = key:sub(#prefix + 1)
		for _, list in pairs(db.recipes[key] or EMPTY) do
			for _, r in ipairs(list) do
				local p = r.product
				if p then
					local cur, add = byProduct[p], true
					if not cur then
						byProduct[p] = r
					elseif cur.name then -- a single recipe so far
						if cur.name == r.name then add = false else byProduct[p] = { cur, r } end
					else
						for i = 1, #cur do
							if cur[i].name == r.name then add = false break end
						end
						if add then cur[#cur + 1] = r end
					end
					if add and key ~= me then ownerOf[r] = who end
				end
			end
		end
	end
end

local Node

-- Unit cost of crafting with recipe r, or nil when a reagent has no price.
-- Every reagent is evaluated even after one is unpriced, so all of them land
-- in memo (Find Unknown Prices looks there).
local function CraftUnit(r, visiting, depth)
	local sum = 0
	for i = 1, #r, 2 do
		local kn = Node(r[i], nil, visiting, depth)
		if sum and kn.cost then sum = sum + kn.cost * r[i + 1] else sum = nil end
	end
	return sum and sum / (r.made or 1)
end

-- Cheapest way to get ONE unit of an item: vendor, AH, or craft it.
-- node = { name, cost, src, rec, kids }; kids[i] is the node of rec's i-th
-- reagent (count rec[2 * i]), only set when crafting is the cheapest source.
function Node(id, name, visiting, depth)
	local node = memo[id]
	if node then return node end
	name = name or db.names[id] or GetItemInfo(id) or ("item " .. id)

	local cost, src = db.vendor[id], nil
	if cost then src = "vendor" end

	local ah = ahP[id]
	if ah and (not cost or ah < cost) then cost, src = ah, "AH" end

	local ap = AuctionatorPrice(id, name)
	if ap and (not cost or ap < cost) then cost, src = ap, "auctionator" end

	local rec, kids
	local recs = byProduct[id]
	if recs and depth <= MAX_DEPTH and not visiting[id] then
		visiting[id] = true
		if recs.name then
			local unit = CraftUnit(recs, visiting, depth + 1)
			if unit and (not cost or unit < cost) then cost, src, rec = unit, "craft", recs end
		else
			for ri = 1, #recs do
				local unit = CraftUnit(recs[ri], visiting, depth + 1)
				if unit and (not cost or unit < cost) then cost, src, rec = unit, "craft", recs[ri] end
			end
		end
		visiting[id] = nil
		if rec then
			-- only the winning recipe keeps its children (all already memoized)
			kids = {}
			for i = 1, #rec, 2 do kids[#kids + 1] = memo[rec[i]] end
		end
	end

	node = { name = name, cost = cost, src = src, rec = rec, kids = kids }
	memo[id] = node
	return node
end

------------------------------------------------------------------------
-- Vellums: which one an enchant needs, and what it costs
------------------------------------------------------------------------

-- Cheapest way to get one vellum (by item id): vendor, AH, Auctionator or
-- crafting it (e.g. on an Inscription alt). Returns its node or nil.
local function VellumOption(kind, tier)
	local id = VELLUM_ID[kind][tier]
	local c = vellumCache[id]
	if c ~= nil then return c or nil end
	local node = Node(id, VellumName(kind, tier), {}, 1)
	vellumCache[id] = node.cost and node or false
	return node.cost and node or nil
end

-- Cheapest vellum that can hold an enchant of `tier` (a higher tier works too).
local function BestVellum(kind, tier)
	local best
	for t = tier, 3 do
		local node = VellumOption(kind, t)
		if node and (not best or node.cost < best.cost) then best = node end
	end
	return best
end

-- Weapon or Armor vellum, which tier, and whether the enchant can go on a
-- vellum at all (ring enchants are enchanter-only and cannot).
-- Returns kind, tier, guessed.
local function EnchantVellumReq(r)
	local name = r.name or ""
	if name:find("Ring", 1, true) then return nil end
	local kind = (name:find("Weapon", 1, true) or name:find("Staff", 1, true)) and "Weapon" or "Armor"
	if r.lvl then return kind, TierForLevel(r.lvl), false end
	local tier = 1
	for i = 1, #r, 2 do
		local t = MAT_TIER[r[i]]
		if t and t > tier then tier = t end
	end
	return kind, tier, true
end

-- enchant product = the scroll (enchant put on a vellum), looked up by name
local function ScrollPrice(name)
	local sn = ScrollOf(name)
	local id = db.scrolls[sn]
	local p = id and ahP[id]
	if not p then
		id = db.scrolls[name]
		p = id and ahP[id]
	end
	if p then return p, false end
	p = AuctionatorPrice(nil, sn) or AuctionatorPrice(nil, name)
	if p then return p, true end
end

local evalVisiting = {} -- reused; Node leaves it as it found it

-- res = { r, kids, v, cost, sell, sellSrc, profit, margin } (8 fields = one
-- small hash). v: nil = not an enchant, false = ring enchant (no vellum),
-- else { kind, tier, need, guess, node }.
local function Evaluate(r)
	local kids, cost, missing = {}, 0, false
	local product = r.product
	if product then evalVisiting[product] = true end
	for i = 1, #r, 2 do
		local node = Node(r[i], nil, evalVisiting, 1)
		kids[#kids + 1] = node
		if node.cost then cost = cost + node.cost * r[i + 1] else missing = true end
	end
	if product then evalVisiting[product] = nil end

	local v, gross, sellSrc
	if not product and r.prof == EnchantingName() then
		local kind, tier, guessed = EnchantVellumReq(r)
		if kind then
			local vn = BestVellum(kind, tier)
			v = { kind = kind, tier = tier, need = VellumName(kind, tier), guess = guessed, node = vn }
			if vn then cost = cost + vn.cost else missing = true end
			local p, auc = ScrollPrice(r.name)
			if p then gross, sellSrc = p, auc and "scroll, auctionator" or "scroll, AH" end
		else
			v = false -- ring enchants: enchanter only, no vellum, no scroll
		end
	elseif product then
		local made = r.made or 1
		local p, s = ahP[product], "AH"
		if not p then p, s = AuctionatorPrice(product), "auctionator" end
		if p then
			gross, sellSrc = p * made, s
		else
			local vs = select(11, GetItemInfo(product))
			if vs and vs > 0 then gross, sellSrc = vs * made, "vendor" end
		end
	end

	if missing then cost = nil end
	local sell, profit, margin
	if gross then sell = (sellSrc == "vendor") and gross or gross * (1 - db.cut / 100) end
	if cost and sell then
		profit = sell - cost
		if sell > 0 then margin = profit / sell * 100 end
	end
	return { r = r, kids = kids, v = v, cost = cost, sell = sell, sellSrc = sellSrc, profit = profit, margin = margin }
end

-- price before the AH cut (shown in the tooltip)
local function Gross(res)
	if not res.sell or res.sellSrc == "vendor" then return res.sell end
	return res.sell / (1 - db.cut / 100)
end

GG.sortKey, GG.sortDesc = "profit", true

local sortKey, sortDesc, sortOnRecipe
local function SortCmp(a, b)
	local x, y
	if sortOnRecipe then x, y = a.r[sortKey], b.r[sortKey] else x, y = a[sortKey], b[sortKey] end
	if x == y then return a.r.name < b.r.name end
	if x == nil then return false end   -- unpriced always last
	if y == nil then return true end
	if sortDesc then return x > y end
	return x < y
end

local function SortResults()
	sortKey, sortDesc = GG.sortKey, GG.sortDesc
	sortOnRecipe = (sortKey == "name" or sortKey == "prof")
	table.sort(GG.results, SortCmp)
end

------------------------------------------------------------------------
-- Optional search bar: filters the list by recipe name and by the names
-- of any material the recipe uses (as shown in the row tooltip).
------------------------------------------------------------------------
-- lower-cased names, kept while the window is open so typing makes no garbage
local LOWER_MT = { __index = function(t, s)
	local l = s:lower()
	t[s] = l
	return l
end }
local lowerCache = setmetatable({}, LOWER_MT)
local matchMemo = {} -- [node] = matches the current search text (nodes are shared by many recipes)
local viewBuf = {}

local function NodeMatches(node, text)
	local m = matchMemo[node]
	if m ~= nil then return m end
	matchMemo[node] = false -- guards against cycles
	m = lowerCache[node.name]:find(text, 1, true) ~= nil
	local kids = node.kids
	if not m and kids then
		for i = 1, #kids do
			if NodeMatches(kids[i], text) then m = true break end
		end
	end
	matchMemo[node] = m
	return m
end

local function ApplyFilter()
	local results = GG.results or EMPTY
	local text = GG.search
	if not text or text == "" then
		GG.view = results
		return
	end
	wipe(matchMemo)
	wipe(viewBuf)
	local vellumWord = ("vellum"):find(text, 1, true) ~= nil
	for _, res in ipairs(results) do
		local v, hit = res.v, lowerCache[res.r.name]:find(text, 1, true)
		if not hit and v then
			hit = vellumWord or lowerCache[v.need]:find(text, 1, true)
				or (v.node and NodeMatches(v.node, text))
		end
		if not hit then
			local kids = res.kids
			for i = 1, #kids do
				if NodeMatches(kids[i], text) then hit = true break end
			end
		end
		if hit then viewBuf[#viewBuf + 1] = res end
	end
	GG.view = viewBuf
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
	-- the order did not change: filter only, no re-sort
	ApplyFilter()
	self:UpdateList()
	self:UpdateStatus()
end

function GG:SetSearchPrompt()
	local f = self.frame
	if f and f.searchPrompt then
		if (self.search or "") == "" then f.searchPrompt:Show() else f.searchPrompt:Hide() end
	end
end

function GG:Compute()
	BuildIndex()
	local res = self.results
	if res then wipe(res) else res = {} end
	for _, list in pairs(db.recipes[CharKey()] or EMPTY) do
		for _, r in ipairs(list) do res[#res + 1] = Evaluate(r) end
	end
	self.results = res
	self:RefreshList()
end

-- Recompute only while the window is open (it computes when opened anyway).
function GG:Refresh()
	if self.frame and self.frame:IsShown() then self:Compute() end
end

-- Window closed: drop every derived table so it can be garbage collected.
-- Only the saved variables stay resident.
function GG:Release()
	byProduct, memo, ownerOf, vellumCache, ahP = {}, {}, {}, {}, EMPTY
	self.results, self.view = nil, nil
	-- fresh tables rather than wipe(): wipe keeps the allocated capacity
	viewBuf, matchMemo, lowerCache = {}, {}, setmetatable({}, LOWER_MT)
	scrollName = {}
	if self.ReleaseUI then self:ReleaseUI() end
end

-- Explicit refresh (Refresh Prices button / /gg refresh): drop every cached
-- cost and re-pull every price from the active source (Auctionator's live
-- database, or the own AH scan data), then rebuild the whole list from the top.
function GG:RefreshPrices()
	local bar = _G["GreedyGoblinScrollScrollBar"]
	if bar then bar:SetValue(0) end -- start the fresh list from the top
	self:Refresh()
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
	scan = nil
	Print(format("Scan complete: prices for %d items your recipes use.", n))
	GG:UpdateButtons()
	GG:Refresh()
end

-- lowest buyout per unit, keyed by item id; only items some recipe on this
-- realm uses (reagent, product, vellum, enchant scroll) are kept
local function AddAuction(i)
	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
	if buyout and buyout > 0 and count and count > 0 then
		local id = ItemID(GetAuctionItemLink("list", i))
		if not id then return end
		local isScroll = name and scan.scrollSet[name]
		if isScroll or scan.want[id] then
			if isScroll then
				scan.scrolls[name] = id -- enchant scrolls, looked up by name for enchanting recipes
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

	for _, res in ipairs(GG.results or EMPTY) do
		local r, v = res.r, res.v
		if r.product then
			if not AHPrice(r.product) and not AuctionatorPrice(r.product) then
				add(r.product, { id = r.product, name = GetItemInfo(r.product) or db.names[r.product] or r.name })
			end
		elseif v then
			-- enchant without a scroll price (for enchants the scroll is the only sell price)
			if not res.sell then add("scroll:" .. r.name, { name = r.name, scroll = true }) end
			-- the vellum this enchant needs (or a higher tier) has no price yet
			if not v.node then
				for t = v.tier, 3 do
					if not VellumOption(v.kind, t) then
						add("vellum:" .. VELLUM_ID[v.kind][t], { id = VELLUM_ID[v.kind][t], name = VellumName(v.kind, t) })
					end
				end
			end
		end
	end
	return list
end

local function Matches(t, id, name)
	if t.id then return id == t.id end
	if t.scroll then return name == t.name or name == "Scroll of " .. t.name end
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
			GG:Refresh()
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
	if not (self.frame and self.frame:IsShown()) then self:Release() end
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
	db.recipes, db.scrolls, db.names = {}, {}, {}
	wipe(checked)
	self:Refresh()
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
	if not next(db.recipes) then
		Print("No recipes known yet: open your profession windows first, the scan only keeps prices your recipes use.")
		return
	end
	local want, scrollSet = RelevantItems(GetRealmName())
	scan = { mode = "all", p = {}, scrolls = {}, want = want, scrollSet = scrollSet, state = "ready", sentAt = GetTime() }
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

	-- only items used by a recipe of any character on this realm are stored
	local mats = RelevantItems(GetRealmName())

	local learned = {}
	for i = 1, GetMerchantNumItems() do
		local mname, _, price, qty, _, _, ext = GetMerchantItemInfo(i)
		local id = ItemID(GetMerchantItemLink(i))
		if id and mats[id] and price and price > 0 and not ext then
			local unit = price / ((qty and qty > 0) and qty or 1)
			if db.vendor[id] ~= unit then
				learned[#learned + 1] = { name = mname or ("item " .. id), unit = unit }
				db.vendor[id] = unit
			end
		end
	end

	if #learned > 0 then
		local parts = {}
		for i = 1, math.min(#learned, 8) do
			parts[#parts + 1] = learned[i].name .. " " .. Money(learned[i].unit)
		end
		Print(format("%s: learned %d material price%s: %s%s", npc or "Vendor", #learned,
			#learned > 1 and "s" or "", table.concat(parts, ", "), #learned > 8 and ", ..." or ""))
		GG:Refresh()
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

-- kids[i] is the node of rec's i-th reagent; rec[2 * i] is its count
local function AddKids(tt, rec, kids, qty, indent, depth)
	for i = 1, #kids do
		local node = kids[i]
		local n = rec[2 * i] * qty
		local label = indent .. Qty(n) .. " x " .. node.name
		if node.cost then
			tt:AddDoubleLine(label .. " " .. (SRC_COLOR[node.src] or "") .. "(" .. SrcLabel(node) .. ")|r",
				Money(node.cost * n), 1, 1, 1, 1, 1, 1)
			if node.src == "craft" and depth < 8 then
				AddKids(tt, node.rec, node.kids, n / (node.rec.made or 1), indent .. "   ", depth + 1)
			end
		else
			tt:AddDoubleLine(label, "|cffff4040no price|r", 1, 1, 1, 1, 1, 1)
		end
	end
end

local function ShowRowTooltip(row, res)
	local tt = GameTooltip
	local r, v = res.r, res.v
	local made = r.made or 1
	tt:SetOwner(row, "ANCHOR_RIGHT")
	tt:AddLine(r.name .. (made > 1 and (" x" .. Qty(made)) or ""), 1, 0.82, 0)
	tt:AddLine(" ")
	AddKids(tt, r, res.kids, 1, "", 1)
	if v == false then
		tt:AddLine("Ring enchant: enchanter only, cannot be put on a vellum", 0.6, 0.6, 0.6)
	elseif v then
		local vn = v.node
		if vn then
			tt:AddDoubleLine("Vellum: " .. vn.name .. " " .. (SRC_COLOR[vn.src] or "") .. "(" .. SrcLabel(vn) .. ")|r",
				Money(vn.cost), 1, 1, 1, 1, 1, 1)
			if vn.src == "craft" then AddKids(tt, vn.rec, vn.kids, 1 / (vn.rec.made or 1), "   ", 2) end
			if r.lvl then
				tt:AddLine("   enchant level restriction " .. r.lvl, 0.6, 0.6, 0.6)
			elseif v.guess then
				tt:AddLine("   tier guessed from materials, reopen Enchanting to read the level", 0.6, 0.6, 0.6)
			end
			if vn.name ~= v.need then
				tt:AddLine("   needs " .. v.need .. ", the higher tier is cheaper", 0.6, 0.6, 0.6)
			end
		else
			tt:AddDoubleLine("Vellum: " .. v.need, "|cffff4040no price|r", 1, 1, 1, 1, 1, 1)
			if r.lvl then tt:AddLine("   enchant level restriction " .. r.lvl, 0.6, 0.6, 0.6) end
		end
	end
	tt:AddLine(" ")
	tt:AddDoubleLine("Materials cost", Money(res.cost), 1, 1, 1, 1, 1, 1)
	if res.sell then
		local gross = Gross(res)
		tt:AddDoubleLine("Sell price (" .. res.sellSrc .. ")", Money(gross), 1, 1, 1, 1, 1, 1)
		if res.sellSrc ~= "vendor" then
			tt:AddDoubleLine("AH cut (" .. db.cut .. "%)", Money(-(gross - res.sell)), 1, 1, 1, 1, 1, 1)
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

-- Fit() is costly (one SetText + measure per dropped character), so every
-- shortened text is cached while the window is open.
local fitCache = {}   -- [maxW] = { [suffix] = { [text] = fitted } }
local suffixCache = {} -- [made] = " xN" suffix
local function FitCached(f, name, suffix, maxW)
	local byW = fitCache[maxW]
	if not byW then byW = {}; fitCache[maxW] = byW end
	local bySuffix = byW[suffix]
	if not bySuffix then bySuffix = {}; byW[suffix] = bySuffix end
	local t = bySuffix[name]
	if not t then
		t = Fit(f, name, suffix, maxW)
		bySuffix[name] = t
	end
	return t
end

local function MadeSuffix(made)
	if not made or made <= 1 then return "" end
	local s = suffixCache[made]
	if not s then
		s = " |cff888888x" .. Qty(made) .. "|r"
		suffixCache[made] = s
	end
	return s
end

function GG:ReleaseUI()
	fitCache, suffixCache = {}, {}
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
	f:SetScript("OnHide", function() GG:Release() end)
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
	f.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 32, 66) -- one foot layout for both modes
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
	local view = self.view or EMPTY
	FauxScrollFrame_Update(f.scroll, #view, ROWS, ROW_H)
	local off = FauxScrollFrame_GetOffset(f.scroll)
	if off > 0 then off = min(off, max(0, #view - ROWS)) end

	for i = 1, ROWS do
		local row, res = f.rows[i], view[off + i]
		row.res = res
		if res then
			local c, r = row.cols, res.r
			c.name:SetText(FitCached(f, r.name, MadeSuffix(r.made), COL_W.name))
			c.prof:SetText(FitCached(f, r.prof, "", COL_W.prof))
			c.cost:SetText(Money(res.cost))
			if res.sellSrc == "vendor" then
				c.sell:SetText(Money(res.sell) .. " |cff888888v|r")
			else
				c.sell:SetText(Money(res.sell))
			end
			c.profit:SetText(Money(res.profit))
			if res.margin then
				c.margin:SetText(format("%s%d%%|r", res.margin >= 0 and "|cff55ff55" or "|cffff4040", floor(res.margin + 0.5)))
			else
				c.margin:SetText("|cff888888?|r")
			end
			row:Show()
		else
			row:Hide()
		end
	end

	if #view == 0 then
		if (self.search or "") ~= "" and #(self.results or EMPTY) > 0 then
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
		count = format("%d of %d recipes shown", #self.view, #(self.results or EMPTY))
	else
		count = format("%d recipes", #(self.results or EMPTY))
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

local function ShowIf(b, show)
	if show then b:Show() else b:Hide() end
end

local function EnableIf(b, on)
	if on then b:Enable() else b:Disable() end
end

-- Runs every 0.5 s while the AH is open: no layout changes, no closures.
-- The Refresh button always lives in the bottom-right corner; only the
-- own-scan buttons hide in Auctionator mode.
function GG:UpdateButtons()
	local f = self.frame
	if not f then return end
	local auct = AuctionatorMode()
	ShowIf(f.scanBtn, not auct)
	ShowIf(f.unknownBtn, not auct)
	ShowIf(f.clearBtn, not auct)
	local canAll, canQuery = false, false
	if not auct and self.ahOpen and not scan then
		local q, a = CanSendAuctionQuery()
		canQuery, canAll = q and true or false, a and true or false
	end
	EnableIf(f.scanBtn, canAll)
	EnableIf(f.unknownBtn, canQuery)
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
			GG:Refresh()
			GG:UpdateButtons()
			if GG.frame and GG.frame:IsShown() then GG:UpdateStatus() end
		else
			Print("Auctionator mode is " .. (AuctionatorMode() and "on" or "off") .. ". Usage: /gg auctionator on|off")
		end
	elseif cmd == "vellum" then
		local shown = GG.frame and GG.frame:IsShown()
		if shown then GG:Compute() else BuildIndex() end
		Print("Vellum prices (I: no level restriction, II: restriction 35 or lower, III: 60 or lower; a higher tier also works for lower enchants):")
		for _, kind in ipairs({ "Armor", "Weapon" }) do
			for t = 1, 3 do
				local vn = VellumName(kind, t)
				local node = VellumOption(kind, t)
				if node then
					DEFAULT_CHAT_FRAME:AddMessage(format("  %s: %s %s(%s)|r", vn, Money(node.cost), SRC_COLOR[node.src] or "", SrcLabel(node)))
				else
					DEFAULT_CHAT_FRAME:AddMessage(format("  %s: |cff888888no price known|r", vn))
				end
			end
		end
		if not shown then GG:Release() end
	elseif cmd == "cut" then
		local n = tonumber(rest)
		if not n or n < 0 or n > 50 then Print("Usage: /gg cut <percent>   (5 faction AH, 15 neutral AH)") return end
		db.cut = n
		GG:Refresh()
		Print("AH cut set to " .. n .. "%.")
	elseif cmd == "alts" then
		if rest == "on" or rest == "off" then
			db.useAlts = (rest == "on")
			GG:Refresh()
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
		GG:Refresh()
		Print("Forgot the recipes stored for this character.")
	else
		Print("/gg  |  /gg scan  |  /gg unknown  |  /gg refresh  |  /gg vellum  |  /gg auctionator on|off  |  /gg alts on|off  |  /gg cut <percent>  |  /gg reset  |  /gg clear")
	end
end

------------------------------------------------------------------------
-- Saved variables v2 -> v3: compact recipes, and drop stored prices of items
-- no known recipe uses (they were never read).
------------------------------------------------------------------------
local function MigrateV2()
	local names = db.names
	for _, profs in pairs(db.recipes) do
		for _, list in pairs(profs) do
			for i, old in ipairs(list) do
				if old.reagents then
					local r = {}
					for _, rg in ipairs(old.reagents) do
						r[#r + 1] = rg.id
						r[#r + 1] = rg.n
						if rg.name then names[rg.id] = rg.name end
					end
					r.name, r.prof, r.product = old.name, old.prof, old.product
					if old.made and old.made ~= 1 then r.made = old.made end
					if not old.product then r.lvl = old.lvl end
					list[i] = r
				end
			end
		end
	end

	local ids, scrolls = RelevantItems() -- every realm
	for id in pairs(db.vendor) do
		if not ids[id] then db.vendor[id] = nil end
	end
	local scrollIds = {}
	for name, id in pairs(db.scrolls) do
		if scrolls[name] then scrollIds[id] = true else db.scrolls[name] = nil end
	end
	for _, d in pairs(db.ah) do
		local n = 0
		for id in pairs(d.p) do
			if ids[id] or scrollIds[id] then n = n + 1 else d.p[id] = nil end
		end
		d.n = n
	end
	scrollName = {}
	db.v = DB_VERSION
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local learnAt, learnTries
local frame = CreateFrame("Frame")

-- The OnUpdate only runs while the frame is shown, and the frame is only
-- shown while there is work: the AH is open, a scan runs, or a recipe learn
-- is pending. Otherwise the addon costs nothing per frame.
local btnTimer = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	local now = GetTime()
	btnTimer = btnTimer - elapsed
	if btnTimer <= 0 then
		btnTimer = 0.5
		if db and GG.ahOpen and GG.frame and GG.frame:IsShown() then
			GG:UpdateButtons()
			if not scan then GG:UpdateStatus() end
		end
	end
	if learnAt and now >= learnAt then
		learnAt = nil
		if LearnTradeSkill() == false then
			learnTries = learnTries + 1
			if learnTries <= 3 then learnAt = now + 0.7 end
		else
			GG:Refresh()
		end
	end
	if scan then ScanTick(now) end
	if not (scan or learnAt or GG.ahOpen) then self:Hide() end
end)
frame:Hide()

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "GreedyGoblin" then return end
		local sv = GreedyGoblinDB
		if type(sv) ~= "table" or (sv.v ~= DB_VERSION and sv.v ~= 2) then
			GreedyGoblinDB = { v = DB_VERSION }
		end
		db = GreedyGoblinDB
		db.cut     = db.cut or 5
		db.vendor  = db.vendor or {}   -- [itemID] = copper per unit
		db.scrolls = db.scrolls or {}  -- [scroll name] = itemID, learned from AH scans
		db.names   = db.names or {}    -- [itemID] = item name of every reagent
		db.vellums = nil   -- no longer used (vellums are tracked by item id)
		db.vendorNPC = nil -- no longer tracked: vendor prices only, no names
		db.ah      = db.ah or {}       -- [realm] = { t = time, n = items, p = { [itemID] = lowest unit buyout } }
		db.recipes = db.recipes or {}  -- [realm-char] = { [profession] = { recipe, ... } } (format at the top)
		if db.v == 2 then MigrateV2() end
		LogLoad("/gg to open, /gg scan at the auction house.")
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
		frame:Show()

	elseif event == "MERCHANT_SHOW" then
		RecordVendor()

	elseif event == "AUCTION_HOUSE_SHOW" then
		GG.ahOpen = true
		frame:Show()
		GG:UpdateButtons()

	elseif event == "AUCTION_HOUSE_CLOSED" then
		GG.ahOpen = false
		if scan then StopScan("Auction house closed, scan aborted.") end
		GG:UpdateButtons()

	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		OnAuctionListUpdate()
	end
end)
