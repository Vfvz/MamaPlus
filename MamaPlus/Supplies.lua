local addonName, ns = ...

-- Supplies: every window counts its own bags (0 to 5 at least, so a quiver
-- or soul bag in the fifth slot is seen) into food, drink, bandages,
-- potions, ammo, Soul Shards, Healthstones and reagents, and tells the team
-- in the heartbeat field u "food.drink.bandage.potion.ammo.shards.hs.reagent"
-- (capped to fit Status' 24-byte field limit). The LOGIN count is the
-- first (loading-screen bag events count nothing); then counting runs 1 s
-- after BAG_UPDATE_DELAYED out of combat; in combat the bags are only marked
-- dirty and counted once at PLAYER_REGEN_ENABLED. The heartbeat goes out
-- early only when the set of low kinds changes; counts ride the beat.
-- Every window compares every member's counts with its OWN thresholds
-- (strictly below, 0 = off) and shows the low kinds as one orange entry of
-- letters F D B P A S H (A for hunters, S and H for warlocks, by the
-- member's class field k; reagents never make an icon), low counts in the
-- tooltip. Trade top-up: Mama's MatsFor is wrapped (original kept) so a
-- trade with a grouped member whose heartbeat is at most 60 s old and shows
-- a lack starts with up to three of our own whole, unbound, unlocked stacks
-- of what they lack (ammo for hunters, Healthstones for non-warlocks, never
-- shards), biggest first, never taking us below our own thresholds (stacks
-- locked in the trade already count as gone, so the button's second fill
-- keeps them too), six stacks in all at most and no more than the partner's
-- free bag slots when Mama's stats know them, the same list for Mama's
-- automatic fill and its button so its "kept" count stays right. Nothing
-- here acts on another window: it counts, sends, draws and adds stacks to
-- a trade we opened.

local Supplies = {}
ns.Supplies = Supplies

local MF = ns.MF
local IsSecret = ns.IsSecret
local SOUL_SHARD = 6265
local RECOUNT_DELAY, FRESH = 1, 60      -- recount debounce; a top-up needs a record this young
local MAX_TOPUP, TRADE_SLOTS = 3, 6
local FIELD_MAX = 24                    -- Status.AddField cuts a value to this many bytes
local HEALTHSTONE = {}
for _, id in ipairs({ 5512, 19004, 19005, 5511, 19006, 19007, 5509, 19008, 19009, 5510, 19010, 19011, 9421, 19012,
  19013 }) do HEALTHSTONE[id] = true end

local KINDS = { "food", "drink", "bandage", "potion", "ammo", "shards", "hs", "reagent" }
Supplies.KINDS = KINDS
local NAMES = { food = "food", drink = "drink", bandage = "bandages", potion = "potions", ammo = "ammo",
  shards = "shards", hs = "Healthstones", reagent = "reagents" }
-- Low letters in row order; class: only members of that class get the letter.
local LOW = {
  { kind = "food", letter = "F", opt = "foodWarn" },
  { kind = "drink", letter = "D", opt = "drinkWarn" },
  { kind = "bandage", letter = "B", opt = "bandageWarn" },
  { kind = "potion", letter = "P", opt = "potionWarn" },
  { kind = "ammo", letter = "A", opt = "ammoWarn", class = "HUNTER" },
  { kind = "shards", letter = "S", opt = "shardWarn", class = "WARLOCK" },
  { kind = "hs", letter = "H", opt = "healthstoneWarn", class = "WARLOCK" },
}
local OPT = {}
for _, l in ipairs(LOW) do OPT[l.kind] = l.opt end
local DEFAULTS = { suppliesTopup = true, foodWarn = 5, drinkWarn = 5, bandageWarn = 5, potionWarn = 0, ammoWarn = 200,
  shardWarn = 5, healthstoneWarn = 1 }
ns.AddDefaults(DEFAULTS)

Supplies.counts = nil     -- this window's counts (kind -> number), nil until counted or without the bag API
Supplies.letters = ""     -- this window's low letters as last computed

---------------------------------------------------------------------------
-- Thresholds (this window's, applied to every member)
---------------------------------------------------------------------------
local function Threshold(kind)
  return ns.Setting(OPT[kind], DEFAULTS[OPT[kind]])
end

local function Low(c, kind)
  local n, warn = c[kind], Threshold(kind)
  return n ~= nil and warn > 0 and n < warn
end

-- Letters and "food 3, drink 0" of the kinds a member of class cls (nil = unknown) is low on.
function Supplies.LowOf(c, cls)
  local letters, parts = "", {}
  for _, l in ipairs(LOW) do
    if (not l.class or l.class == cls) and Low(c, l.kind) then
      letters = letters .. l.letter
      parts[#parts + 1] = NAMES[l.kind] .. " " .. c[l.kind]
    end
  end
  return letters, table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Classification: class/subclass from GetItemInfoInstant, fixed IDs for
-- shards and Healthstones, the use spell or name for the rest. A final
-- answer is kept for the session; unknown, secret or not-yet-loaded data
-- is asked again next time.
---------------------------------------------------------------------------
local function EnumNumber(tbl, key, fallback)
  if type(tbl) ~= "table" or IsSecret(tbl) then return fallback end
  return ns.PlainOfType(tbl[key], "number", fallback)
end

local function ClassIds()
  local ic, cs = Enum and Enum.ItemClass, Enum and Enum.ItemConsumableSubclass
  return { consumable = EnumNumber(ic, "Consumable", 0), projectile = EnumNumber(ic, "Projectile", 6),
    reagent = EnumNumber(ic, "Reagent", 5), misc = EnumNumber(ic, "Miscellaneous", 15),
    food = EnumNumber(cs, "Fooddrink", 5), potion = EnumNumber(cs, "Potion", 1), bandage = EnumNumber(cs, "Bandage", 7) }
end

-- The bag and item functions counting needs, or nil when any is missing.
local function Api()
  local bags, items = C_Container, C_Item
  if bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo and items and items.GetItemInfoInstant then
    return bags, items
  end
  return nil
end

-- First result of an item function as a plain string, or nil.
local function ItemString(fn, itemID)
  local ok, v = ns.Try(fn, itemID)
  return ok and ns.PlainOfType(v, "string", nil) or nil
end

-- A consumable with no telling subclass: by its use spell, then its name.
-- Second result false while the item data is not loaded yet (not cached).
local function ByText(items, itemID)
  local spell, name = ItemString(items.GetItemSpell, itemID), ItemString(items.GetItemInfo, itemID)
  if spell then
    if spell:find("Drink", 1, true) then return "drink", true end
    if spell == "Food" or spell == "Refreshment" then return "food", true end
    if spell == "First Aid" then return "bandage", true end
  end
  if not name then return nil, false end
  if name:find("Healthstone", 1, true) then return "hs", true end
  if name:find("Potion", 1, true) then return "potion", true end
  return nil, true
end

local kindCache = {}      -- itemID -> kind, or false for "none of ours"

function Supplies.Classify(itemID, ids, items)
  if itemID == SOUL_SHARD then return "shards" end
  if HEALTHSTONE[itemID] then return "hs" end
  local cached = kindCache[itemID]
  if cached ~= nil then return cached or nil end
  items = items or C_Item
  if not (items and items.GetItemInfoInstant) then return nil end
  ids = ids or ClassIds()
  local ok, class, sub = pcall(function() return select(6, items.GetItemInfoInstant(itemID)) end)
  class, sub = ok and ns.PlainNumber(class) or nil, ok and ns.PlainNumber(sub) or nil
  if not class or not sub then return nil end
  local kind, final = nil, true
  if class == ids.projectile then
    kind = "ammo"
  elseif class == ids.reagent or (class == ids.misc and sub == 1) then
    kind = "reagent"
  elseif class == ids.consumable then
    if sub == ids.potion then
      kind = "potion"
    elseif sub == ids.bandage then
      kind = "bandage"
    elseif sub == ids.food then
      local spell = ItemString(items.GetItemSpell, itemID)
      kind, final = (spell and spell:find("Drink", 1, true)) and "drink" or "food", spell ~= nil
    else
      kind, final = ByText(items, itemID)
    end
  end
  if final then kindCache[itemID] = kind or false end
  return kind
end

---------------------------------------------------------------------------
-- Counting this window's bags
---------------------------------------------------------------------------
-- Last bag to scan: the client's equipped bag slots, and 5 at least.
local function LastBag()
  return math.max(ns.PlainNumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS) or 4, 5)
end

-- fn(bag, slot, itemID, count, info) for every slot with a plain item ID and stack count.
local function EachItem(bags, fn)
  for bag = 0, LastBag() do
    local ok, slots = pcall(bags.GetContainerNumSlots, bag)
    slots = ok and ns.PlainNumber(slots) or 0
    for slot = 1, slots do
      local ok2, info = pcall(bags.GetContainerItemInfo, bag, slot)
      if ok2 and not IsSecret(info) and type(info) == "table" then
        local itemID, count = ns.PlainNumber(info.itemID), ns.PlainNumber(info.stackCount)
        if itemID and count and count > 0 then fn(bag, slot, itemID, count, info) end
      end
    end
  end
end

-- Counts by kind, or nil without the bag API. fn(bag, slot, itemID, count, info, kind) sees every counted stack.
function Supplies.Count(fn)
  local bags, items = Api()
  if not bags then return nil end
  local ids, c = ClassIds(), {}
  for _, kind in ipairs(KINDS) do c[kind] = 0 end
  EachItem(bags, function(bag, slot, itemID, count, info)
    local kind = Supplies.Classify(itemID, ids, items)
    if kind then
      c[kind] = c[kind] + count
      if fn then fn(bag, slot, itemID, count, info, kind) end
    end
  end)
  return c
end

-- The u field, capped until it fits: 999 (ammo 9999), then 99 for all but ammo, then ammo 999.
local CAPS = { { 999, 9999 }, { 99, 9999 }, { 99, 999 } }
function Supplies.Encode(c)
  local s
  for _, cap in ipairs(CAPS) do
    local parts = {}
    for i, kind in ipairs(KINDS) do parts[i] = tostring(math.min(c[kind], kind == "ammo" and cap[2] or cap[1])) end
    s = table.concat(parts, ".")
    if #s <= FIELD_MAX then break end
  end
  return s
end

-- Counts from a u field, or nil when malformed (fields a later version appends are ignored).
function Supplies.Parse(u)
  if type(u) ~= "string" then return nil end
  local list, c = { strsplit(".", u) }, {}
  for i, kind in ipairs(KINDS) do
    local n = tonumber(list[i])
    if not n or n < 0 or n ~= math.floor(n) then return nil end
    c[kind] = n
  end
  return c
end

-- Counts and class of a member: this window's own, or from the member's heartbeat.
local function CountsOf(name)
  if name == ns.MyName() then return Supplies.counts, ns.MyClass() end
  return Supplies.Parse(ns.Status.Field(name, "u")), ns.Status.Field(name, "k")
end

ns.Status.AddField("u", function()
  return Supplies.counts and Supplies.Encode(Supplies.counts) or nil
end)

---------------------------------------------------------------------------
-- Recount policy
---------------------------------------------------------------------------
local dirty, queued = false, false

local function Same(a, b)
  if not a or not b then return a == b end
  for _, k in ipairs(KINDS) do if a[k] ~= b[k] then return false end end
  return true
end

-- Our letters from the current counts: tell the team when they differ, else redraw when asked.
local function Settle(redraw)
  local letters = Supplies.counts and Supplies.LowOf(Supplies.counts, ns.MyClass()) or ""
  if letters ~= Supplies.letters then
    Supplies.letters = letters
    ns.Debug("supplies low:", letters == "" and "none" or letters)
    ns.Status.Changed()
  elseif redraw then
    ns.Rows.Refresh()
  end
end

function Supplies.Recount()
  local c = Supplies.Count()
  if not c then return end
  local changed = not Same(c, Supplies.counts)
  Supplies.counts = c
  Settle(changed)
end

local function InCombat() return ns.PlainTrue(InCombatLockdown()) end

function Supplies.QueueRecount()
  if not ns.loggedIn then return end     -- a loading-screen bag event: the LOGIN count is the first
  if InCombat() then dirty = true return end
  if queued then return end
  queued = true
  ns.After(RECOUNT_DELAY, function()
    queued = false
    if InCombat() then dirty = true else Supplies.Recount() end
  end)
end

ns.On("BAG_UPDATE_DELAYED", Supplies.QueueRecount)
ns.On("PLAYER_REGEN_ENABLED", function()
  if dirty then dirty = false; Supplies.Recount() end
end)

---------------------------------------------------------------------------
-- Options (a threshold change re-settles our letters and redraws every row)
---------------------------------------------------------------------------
local function Rethink() Settle(true) end

ns.AddOption({ key = "suppliesTopup", label = "Trades start with what the partner lacks", section = "Supplies",
  type = "toggle", tip = "A trade with a grouped member whose heartbeat shows a low kind starts with up to three of "
    .. "your own stacks of it (food, drink, bandages, potions, ammo, Healthstones) before Mama's mats. You still click Trade." })
for _, o in ipairs({ { "foodWarn", "Low food below" }, { "drinkWarn", "Low drink below" },
  { "bandageWarn", "Low bandages below" }, { "potionWarn", "Low potions below" }, { "ammoWarn", "Low ammo below (hunters)" },
  { "shardWarn", "Low Soul Shards below (warlocks)" }, { "healthstoneWarn", "Low Healthstones below (warlocks)" } }) do
  local ammo = o[1] == "ammoWarn"
  ns.AddOption({ key = o[1], label = o[2], section = "Supplies", type = "number", min = 0, max = ammo and 1000 or 50,
    step = ammo and 50 or 1, onChange = Rethink, tip = "Strictly below this count the letter shows on the member's row "
      .. "and a trade tops it up. 0 turns it off. Your thresholds apply to every row on this window." })
end

---------------------------------------------------------------------------
-- Row entry: one orange entry of low letters, counts in the tooltip
---------------------------------------------------------------------------
ns.Rows.AddProvider(function(name, out)
  local c, cls = CountsOf(name)
  if not c then return end
  local letters, tip = Supplies.LowOf(c, cls)
  if letters == "" then return end
  out[#out + 1] = { "supplies", letters, 1, 0.55, 0.1, tip, 13 }
end)

---------------------------------------------------------------------------
-- Trade top-up through Mama's MatsFor
---------------------------------------------------------------------------
local TOPUP = { "food", "drink", "bandage", "potion", "ammo", "hs" }

-- Kinds a partner of class cls (nil = unknown) lacks and could use, by our thresholds; nil when none.
local function Lacking(c, cls)
  if not c then return nil end
  local lack = {}
  for _, kind in ipairs(TOPUP) do
    local fits = (kind ~= "ammo" or cls == "HUNTER") and (kind ~= "hs" or cls ~= "WARLOCK")
    if fits and Low(c, kind) then lack[kind] = true end
  end
  return next(lack) and lack or nil
end

-- Up to max whole, unbound, unlocked stacks of the kinds a grouped partner with a fresh record lacks,
-- biggest first, keeping our own thresholds: {bag, slot, count, label} like Mama's own list.
function Supplies.TopUp(partner, max)
  if max <= 0 or not ns.OptionOn("suppliesTopup") then return {} end
  if type(partner) ~= "string" or IsSecret(partner) or not ns.UnitOf(partner) then return {} end
  local rec = ns.Status.records[partner]
  if not rec or GetTime() - rec.time > FRESH then return {} end
  local lack = Lacking(Supplies.Parse(rec.fields.u), rec.fields.k)
  if not lack then return {} end
  local stacks, locked = {}, {}
  local own = Supplies.Count(function(bag, slot, _, count, info, kind)
    if not lack[kind] or IsSecret(info.isLocked) then return end
    if info.isLocked then
      locked[kind] = (locked[kind] or 0) + count     -- in the trade (or on the cursor) already: as good as gone
    elseif not IsSecret(info.isBound) and not info.isBound then
      stacks[#stacks + 1] = { bag = bag, slot = slot, count = count, label = NAMES[kind], kind = kind }
    end
  end)
  if not own then return {} end
  for kind, n in pairs(locked) do own[kind] = own[kind] - n end
  table.sort(stacks, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.bag < b.bag or (a.bag == b.bag and a.slot < b.slot)
  end)
  local out = {}
  for _, s in ipairs(stacks) do
    if #out >= max then break end
    if own[s.kind] - s.count >= Threshold(s.kind) then
      own[s.kind] = own[s.kind] - s.count
      out[#out + 1] = { bag = s.bag, slot = s.slot, count = s.count, label = s.label }
    end
  end
  return out
end

local original
local function Wrap()
  if original or not (MF and type(MF.MatsFor) == "function") then return end
  original = MF.MatsFor
  MF.MatsFor = function(self, partner, manual)
    local list = original(self, partner, manual)
    if type(list) ~= "table" then return list end
    local ok, extra = pcall(function()
      -- the cap comes from the button's (manual) list for both calls, so Trade.lua's "kept" stays right
      local full = manual and list or original(self, partner, true)
      local nFull = type(full) == "table" and #full or 0
      local cap = math.min(MAX_TOPUP, TRADE_SLOTS - nFull)
      -- and from the partner's free general bag slots when Mama's stats (G) know them
      local stats = type(self.StatsOf) == "function" and self:StatsOf(partner) or nil
      if type(stats) == "table" and not IsSecret(stats) then
        local free = ns.PlainNumber(stats.free)
        if free then cap = math.min(cap, free - nFull) end
      end
      return Supplies.TopUp(partner, cap)
    end)
    if not ok then
      ns.Debug("supplies top-up failed:", extra)
      return list
    end
    if #extra == 0 then return list end
    for _, m in ipairs(list) do extra[#extra + 1] = m end
    ns.Debug("supplies top-up for", partner, #extra - #list, "stacks")
    return extra
  end
end
Wrap()

-- First count without a Changed(): the first beat (8 s) carries it.
ns.Listen("LOGIN", function()
  Supplies.counts = Supplies.Count()
  Supplies.letters = Supplies.counts and Supplies.LowOf(Supplies.counts, ns.MyClass()) or ""
  if not Supplies.counts then ns.Debug("supplies: bag or item API missing; this window counts nothing") end
  Wrap()
end)

---------------------------------------------------------------------------
-- Commands, status line, probe
---------------------------------------------------------------------------
local function CountsText(c)
  local parts = {}
  for _, kind in ipairs(KINDS) do parts[#parts + 1] = NAMES[kind] .. " " .. c[kind] end
  return table.concat(parts, ", ")
end

local function ItemName(itemID)
  return ItemString(C_Item and C_Item.GetItemInfo, itemID) or ("item " .. itemID)
end

-- What this window counts, per kind with item names.
local function PrintItems()
  local byKind = {}
  local c = Supplies.Count(function(_, _, itemID, count, _, kind)
    byKind[kind] = byKind[kind] or {}
    byKind[kind][#byKind[kind] + 1] = ItemName(itemID) .. " x" .. count
  end)
  if not c then
    ns.Print("supplies: bag or item API missing; this window counts nothing")
    return
  end
  ns.Print(string.format("supplies in bags 0-%d: %s", LastBag(), CountsText(c)))
  for _, kind in ipairs(KINDS) do
    if byKind[kind] then ns.Print("  " .. NAMES[kind] .. ": " .. table.concat(byKind[kind], ", ")) end
  end
end

ns.AddCommand("supplies", "supplies [items] - every slot's food, drink, bandages, potions, ammo, shards, Healthstones "
  .. "and reagents; items: what this window counts", function(rest)
  if (rest or ""):lower() == "items" then return PrintItems() end
  local slots = {}
  for slot in pairs(ns.Slots()) do slots[#slots + 1] = slot end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    local name = ns.Slots()[slot]
    local c, cls = CountsOf(name)
    local text = ns.Status.RecordFor(name) and "no supplies in its heartbeat (no MamaPlus, an older one, or no bag API)"
      or "no heartbeat yet"
    if c then
      local letters = Supplies.LowOf(c, cls)
      text = CountsText(c) .. (letters ~= "" and (" (low " .. letters .. ")") or "")
    end
    ns.Print(string.format("slot %d %s: %s", slot, name, text))
  end
end)

local function State()
  return string.format("counts %s; low %s; dirty %s; top-up %s%s",
    Supplies.counts and CountsText(Supplies.counts) or "none (no bag API)",
    Supplies.letters == "" and "none" or Supplies.letters, tostring(dirty),
    ns.OptionOn("suppliesTopup") and "on" or "off", original and "" or " (MatsFor not wrapped)")
end
ns.Listen("STATUS_COMMAND", function() ns.Print("supplies: " .. State()) end)

local function Describe(ok, v)
  if not ok then return "error or missing" end
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  return tostring(v) .. " (" .. type(v) .. ")"
end

-- Lines for /mama plus probe supplies (design probes S1-S4, S7): returned, and appended to out when given.
ns.AddProbe("supplies", function(out)
  local lines = {}
  local function Add(label, ...) lines[#lines + 1] = label .. ": " .. Describe(...) end
  for _, g in ipairs({ "NUM_BAG_SLOTS", "NUM_REAGENTBAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS" }) do Add(g, true, _G[g]) end
  lines[#lines + 1] = "last bag scanned: " .. LastBag()
  local bags, items = C_Container, C_Item
  Add("GetContainerNumSlots(5)", ns.Try(bags and bags.GetContainerNumSlots, 5))
  local ok, free, family = false, nil, nil
  if type(bags and bags.GetContainerNumFreeSlots) == "function" then ok, free, family = pcall(bags.GetContainerNumFreeSlots, 5) end
  lines[#lines + 1] = "GetContainerNumFreeSlots(5): " .. Describe(ok, free) .. ", family " .. Describe(ok, family)
  lines[#lines + 1] = "Enum.ItemClass: " .. type(Enum and Enum.ItemClass) .. ", Enum.ItemConsumableSubclass: "
    .. type(Enum and Enum.ItemConsumableSubclass)
  for _, id in ipairs({ 4540, 159, 1251, 2512, 6265, 5512 }) do
    local ok2, class, sub = pcall(function() return select(6, items.GetItemInfoInstant(id)) end)
    lines[#lines + 1] = string.format("GetItemInfoInstant(%d) class/sub: %s / %s -> %s", id, Describe(ok2, class),
      Describe(ok2, sub), tostring(Supplies.Classify(id)))
  end
  Add("GetItemSpell(4540)", ns.Try(items and items.GetItemSpell, 4540))
  Add("GetItemSpell(159)", ns.Try(items and items.GetItemSpell, 159))
  local n = 0
  Supplies.Count(function(bag, slot, itemID, count, _, kind)
    n = n + 1
    if n <= 6 then lines[#lines + 1] = string.format("counted %d/%d item %d x%d -> %s", bag, slot, itemID, count, kind) end
  end)
  lines[#lines + 1] = "state: " .. State()
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
