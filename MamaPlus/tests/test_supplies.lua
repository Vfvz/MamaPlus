-- Tests for Supplies.lua: classification (class/subclass, food vs drink by
-- the use spell with an unloaded spell not cached, generic consumables by
-- spell and name, Soul Shard and Healthstone IDs plus the name fallback,
-- reagents, secret or unknown items skipped and not cached), counting
-- over bags 0-5 (further with NUM_TOTAL_EQUIPPED_BAG_SLOTS, secret slots
-- skipped), the u field and its byte cap, parsing, the recount policy
-- (nothing before LOGIN; 1 s after BAG_UPDATE_DELAYED, once; dirty in
-- combat, once at regen),
-- Changed() only when the low-letter set changes (counts and thresholds),
-- the row entry (letters in order, class gating from k, strict thresholds,
-- 0 = off, tip), the trade top-up (freshness, roster, option, shards
-- never, Healthstones not to a warlock, ammo to hunters, bound and locked
-- stacks skipped and locked ones counted as gone, own thresholds kept,
-- biggest first, 3 and 6 caps, the partner's free-slot cap, identical for
-- manual true/false, Mama's FillTrade path: professions first, then the
-- trade window), commands, status line, probe and a missing bag API.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

---------------------------------------------------------------------------
-- Item data and bags (before LoadModule); Mama's own mats list.
---------------------------------------------------------------------------
state.items = {
  [4540] = { name = "Tough Jerky", class = 0, sub = 5, spell = "Food" },
  [159] = { name = "Refreshing Spring Water", class = 0, sub = 5, spell = "Drink" },
  [5349] = { name = "Conjured Muffin", class = 0, sub = 5, spell = "Food" },
  [5350] = { name = "Conjured Water", class = 0, sub = 5, spell = "Drink" },
  [1179] = { name = "Ice Cold Milk", class = 0, sub = 5 },                 -- use spell not loaded yet
  [1251] = { name = "Linen Bandage", class = 0, sub = 7 },
  [118] = { name = "Minor Healing Potion", class = 0, sub = 1 },
  [2512] = { name = "Rough Arrow", class = 6, sub = 2 },
  [2516] = { name = "Light Shot", class = 6, sub = 3 },
  [6265] = { name = "Soul Shard", class = 15, sub = 0 },
  [5512] = { name = "Minor Healthstone", class = 0, sub = 0 },
  [19013] = { name = "Major Healthstone", class = 0, sub = 0 },
  [99001] = { name = "Healthstone of Testing", class = 0, sub = 0 },      -- by name
  [17030] = { name = "Ankh", class = 5, sub = 0 },                         -- Reagent class
  [17056] = { name = "Light Feather", class = 15, sub = 1 },              -- Miscellaneous / Reagent
  [2589] = { name = "Linen Cloth", class = 7, sub = 5 },
  [2070] = { name = "Darnassian Bleu", class = 0, sub = 0, spell = "Food" },     -- generic by spell
  [4604] = { name = "Forest Mushroom Cap", class = 0, sub = 0, spell = "Refreshment" },
  [929] = { name = "Healing Potion", class = 0, sub = 0 },                -- generic by name
  [8529] = { name = "Noggenfogger Elixir", class = 0, sub = 0, spell = "Noggenfogger" },
  [3013] = { name = "Rough Weightstone", class = 0, sub = 0 },
}
local function Slot(id, n, bound, locked)
  return { itemID = id, stackCount = n, isBound = bound or false, isLocked = locked or false }
end
state.bags = {
  [0] = { n = 16, Slot(4540, 20), Slot(159, 20), Slot(1251, 10), Slot(118, 5), Slot(6265, 3), Slot(5512, 1),
    Slot(17030, 20), Slot(2589, 20) },
  [1] = { n = 6, Slot(4540, 5), Slot(1179, 4), Slot(17056, 10), Slot(99001, 1), Slot(0, 5), Slot(2512, 0) },
  [4] = { n = 6, Slot(5349, 20, true) },                 -- bound conjured food still counts
  [5] = { n = 12, family = 1, Slot(2512, 200), Slot(2512, 150) },
  [6] = { n = 4, Slot(2516, 100) },
}
-- Mama's list: state.mats for the button (manual), state.matsAuto when set for the automatic fill.
MamaForever.MatsFor = function(_, _, manual)
  local src = (manual or not state.matsAuto) and state.mats or state.matsAuto
  local out = {}
  for _, m in ipairs(src or {}) do out[#out + 1] = m end
  return out
end

-- Mama's trade path (Trade.lua:150-217) as far as the top-up is concerned: FillTrade asks MatsFor only
-- for a partner on a slot whose professions (state.profs[name]) are known, else asks for them and fills
-- when PROFESSIONS answers; ClickTradeButton lands in tradeSlots and locks the stack like the client.
local tradeSlots, asked, lastKept = {}, {}, nil
local tradePartner, waitingFor, cursor
function GetTradePlayerItemInfo(i) return tradeSlots[i] end
function ClearCursor() cursor = nil end
function CursorHasItem() return cursor ~= nil end
function ClickTradeButton(i) tradeSlots[i] = cursor; cursor.isLocked = true; cursor = nil end
C_Container.PickupContainerItem = function(bag, slot) cursor = state.bags[bag] and state.bags[bag][slot] or nil end
function MamaForever:ProfessionsOf(name) return state.profs and state.profs[name] end
function MamaForever:AskProfessions(name) asked[#asked + 1] = name end
function MamaForever:FillTrade(manual)
  if not tradePartner then return end
  if tradePartner == self.myName or not self:SlotOf(tradePartner) then return end
  if not self:ProfessionsOf(tradePartner) then
    waitingFor = tradePartner
    self:AskProfessions(tradePartner)
    return
  end
  local mats = self:MatsFor(tradePartner, manual)
  lastKept = manual and 0 or #self:MatsFor(tradePartner, true) - #mats
  local tslot = 1
  for _, m in ipairs(mats) do
    while tslot <= 6 and GetTradePlayerItemInfo(tslot) do tslot = tslot + 1 end
    if tslot > 6 then break end
    ClearCursor()
    C_Container.PickupContainerItem(m.bag, m.slot)
    if CursorHasItem() then ClickTradeButton(tslot); ClearCursor() end
  end
end
MamaForever:On("TRADE_SHOW", function(self)
  tradePartner, waitingFor = self:FullName("NPC"), nil
  if self.db.autoTrade and not self:Disabled() then C_Timer.After(0.3, function() self:FillTrade(false) end) end
end)
MamaForever:On("TRADE_CLOSED", function()
  for i, stack in pairs(tradeSlots) do stack.isLocked = false; tradeSlots[i] = nil end
  tradePartner, waitingFor = nil, nil
end)
MamaForever:Listen("PROFESSIONS", function(self, name)
  if waitingFor and name == waitingFor and tradePartner == name then waitingFor = nil; self:FillTrade(true) end
end)

LoadModule("Supplies.lua")
local Supplies = ns.Supplies
local ME, PRI, VF = "Han Jaconelli", "Pri Cuthbridge", "Vf Pr"
local KINDS = Supplies.KINDS

local function text(c)
  local t = {}
  for _, k in ipairs(KINDS) do t[#t + 1] = k .. "=" .. tostring(c and c[k]) end
  return table.concat(t, " ")
end
local function same(c, exp)
  if not c then return false end
  for _, k in ipairs(KINDS) do if c[k] ~= exp[k] then return false end end
  return true
end
local function field(k)
  return ns.Status.Local().fields[k]
end
local function entry(name)
  for _, e in ipairs(ns.Rows.Entries(name)) do if e[1] == "supplies" then return e end end
  return nil
end
local function beat(sender, body) Deliver(sender, "x;H;0.1.0;-;100;-;" .. body) end
local function lastPrinted() return printed[#printed] or "" end

---------------------------------------------------------------------------
-- Login: a bag event in the loading screen (before LOGIN) counts nothing,
-- so no Changed() and no heartbeat leave early; the LOGIN count is the
-- first. Then defaults, options, first count, u field.
---------------------------------------------------------------------------
Fire("ADDON_LOADED", "Mama"); Fire("ADDON_LOADED", "MamaPlus")
Fire("BAG_UPDATE_DELAYED"); Step(2)
check(Supplies.counts == nil and Supplies.letters == "", "counted before LOGIN")
Fire("PLAYER_LOGIN"); Step(0.5)
state.group = { "party1", "party2" }; Fire("GROUP_ROSTER_UPDATE"); Step(1.5)
check(ns.db.suppliesTopup == true and ns.db.foodWarn == 5 and ns.db.drinkWarn == 5 and ns.db.bandageWarn == 5
  and ns.db.potionWarn == 0 and ns.db.ammoWarn == 200 and ns.db.shardWarn == 5 and ns.db.healthstoneWarn == 1, "defaults")
local specs = {}
for _, s in ipairs(ns.optionSpecs) do specs[s.key] = s end
check(specs.suppliesTopup and specs.suppliesTopup.type == "toggle" and specs.suppliesTopup.section == "Supplies", "topup option")
for _, k in ipairs({ "foodWarn", "drinkWarn", "bandageWarn", "potionWarn", "shardWarn", "healthstoneWarn" }) do
  local s = specs[k]
  check(s and s.type == "number" and s.min == 0 and s.max == 50 and s.step == 1 and s.section == "Supplies", k .. " option")
end
check(specs.ammoWarn and specs.ammoWarn.max == 1000 and specs.ammoWarn.step == 50 and specs.ammoWarn.min == 0, "ammoWarn option")
check(ns.commands.supplies, "command missing")
local LOGIN = { food = 49, drink = 20, bandage = 10, potion = 5, ammo = 350, shards = 3, hs = 2, reagent = 30 }
check(same(Supplies.counts, LOGIN), "login counts: " .. text(Supplies.counts))
check(field("u") == "49.20.10.5.350.3.2.30", "u field: " .. tostring(field("u")))
check(Supplies.letters == "S", "own letters at login: " .. Supplies.letters)

---------------------------------------------------------------------------
-- Classification
---------------------------------------------------------------------------
local C = Supplies.Classify
check(C(4540) == "food" and C(5349) == "food" and C(159) == "drink" and C(5350) == "drink", "food/drink")
check(C(1251) == "bandage" and C(118) == "potion" and C(2512) == "ammo" and C(2516) == "ammo", "bandage/potion/ammo")
check(C(6265) == "shards" and C(5512) == "hs" and C(19013) == "hs" and C(99001) == "hs", "shards/Healthstone")
check(C(17030) == "reagent" and C(17056) == "reagent", "reagents")
check(C(2589) == nil and C(3013) == nil and C(8529) == nil and C(424242) == nil, "non-supplies")
check(C(2070) == "food" and C(4604) == "food" and C(929) == "potion", "generic consumables by spell and name")
-- The use spell splits food from drink; while it is not loaded the item counts as food and is asked again.
check(C(1179) == "food", "unloaded spell")
state.items[1179].spell = "Drink"
check(C(1179) == "drink", "unloaded spell was cached")
state.items[159].spell = "Food"
check(C(159) == "drink", "final answer not cached")
state.items[159].spell = "Drink"
-- Secret or erroring data: nothing, and no cache entry.
state.items[99002] = { name = "Mystery Potion", class = 0, sub = 1 }
local realInstant = C_Item.GetItemInfoInstant
C_Item.GetItemInfoInstant = function(id)
  if id == 99002 then return id, "", 1, 1, 1, MakeSecret("number"), 1 end
  return realInstant(id)
end
check(C(99002) == nil, "secret class classified")
C_Item.GetItemInfoInstant = function() error("boom") end
check(C(99002) == nil and C(99003) == nil, "erroring API")
C_Item.GetItemInfoInstant = realInstant
check(C(99002) == "potion", "secret class was cached")

---------------------------------------------------------------------------
-- Counting: bags 0-5 always, further with NUM_TOTAL_EQUIPPED_BAG_SLOTS, secret slots skipped
---------------------------------------------------------------------------
local NOW = { food = 45, drink = 24, bandage = 10, potion = 5, ammo = 350, shards = 3, hs = 2, reagent = 30 }
check(same(Supplies.Count(), NOW), "counts: " .. text(Supplies.Count()))
NUM_TOTAL_EQUIPPED_BAG_SLOTS = 6
check(Supplies.Count().ammo == 450, "bag 6 not scanned with NUM_TOTAL_EQUIPPED_BAG_SLOTS 6")
NUM_TOTAL_EQUIPPED_BAG_SLOTS = MakeSecret("number")
check(Supplies.Count().ammo == 350, "secret NUM_TOTAL_EQUIPPED_BAG_SLOTS")
NUM_TOTAL_EQUIPPED_BAG_SLOTS = 3
check(Supplies.Count().ammo == 350, "bag 5 skipped with NUM_TOTAL_EQUIPPED_BAG_SLOTS 3")
NUM_TOTAL_EQUIPPED_BAG_SLOTS = nil
state.bags[0][9] = { itemID = MakeSecret("number"), stackCount = 5 }
state.bags[0][10] = { itemID = 4540, stackCount = MakeSecret("number") }
state.bags[0][11] = MakeSecret("table")
state.bags[0][12] = { itemID = 4540, stackCount = "7" }
check(Supplies.Count().food == 45, "secret or odd slots counted")
state.bags[0][9], state.bags[0][10], state.bags[0][11], state.bags[0][12] = nil, nil, nil, nil
local realNum = C_Container.GetContainerNumSlots
C_Container.GetContainerNumSlots = function(bag) if bag == 1 then return MakeSecret("number") end return realNum(bag) end
check(Supplies.Count().food == 40 and Supplies.Count().reagent == 20, "secret slot count")
C_Container.GetContainerNumSlots = realNum

---------------------------------------------------------------------------
-- Field encoding and parsing
---------------------------------------------------------------------------
local E = Supplies.Encode
check(E(NOW) == "45.24.10.5.350.3.2.30", "encode: " .. E(NOW))
check(E({ food = 1200, drink = 0, bandage = 0, potion = 0, ammo = 12000, shards = 0, hs = 0, reagent = 2500 })
  == "999.0.0.0.9999.0.0.999", "cap 1")
local big = E({ food = 120, drink = 120, bandage = 120, potion = 120, ammo = 2400, shards = 120, hs = 1, reagent = 120 })
check(big == "99.99.99.99.2400.99.1.99" and #big <= 24, "cap 2: " .. big)
big = E({ food = 120, drink = 120, bandage = 120, potion = 120, ammo = 12000, shards = 120, hs = 120, reagent = 120 })
check(big == "99.99.99.99.999.99.99.99" and #big <= 24, "cap 3: " .. big)
local p = Supplies.Parse("1.2.3.4.5.6.7.8.9")
check(p and p.food == 1 and p.potion == 4 and p.reagent == 8, "parse with an extra field")
for _, bad in ipairs({ "1.2.3", "a.2.3.4.5.6.7.8", "1.2.3.4.5.6.7.-1", "", "1..3.4.5.6.7.8" }) do
  check(Supplies.Parse(bad) == nil, "malformed u accepted: " .. bad)
end
check(Supplies.Parse(nil) == nil and Supplies.Parse(5) == nil, "non-string u")

---------------------------------------------------------------------------
-- Recount policy and Changed() only on a letter-set change
---------------------------------------------------------------------------
local scans, changes = 0, 0
C_Container.GetContainerNumSlots = function(bag) if bag == 0 then scans = scans + 1 end return realNum(bag) end
-- Count the Changed() calls Supplies makes (Status makes its own at regen):
-- any Supplies.lua frame on the stack, whatever the call depth.
local origChanged = ns.Status.Changed
ns.Status.Changed = function()
  local level = 2
  while true do
    local info = debug.getinfo(level, "S")
    if not info then break end
    if info.source:find("Supplies.lua", 1, true) then changes = changes + 1; break end
    level = level + 1
  end
  return origChanged()
end
-- A count change without a letter change: one recount 1 s after the events, no Changed.
state.bags[0][1].stackCount = 15
Fire("BAG_UPDATE_DELAYED"); Fire("BAG_UPDATE_DELAYED"); Fire("BAG_UPDATE_DELAYED")
check(Supplies.counts.food == 49 and scans == 0, "recounted at once")
Step(0.5)
check(Supplies.counts.food == 49, "recounted before 1 s")
Step(0.5)
check(scans == 1 and Supplies.counts.food == 40 and Supplies.counts.drink == 24, "one recount after 1 s: scans " .. scans
  .. " " .. text(Supplies.counts))
check(changes == 0 and Supplies.letters == "S", "Changed without a letter change")
-- In combat: dirty only; one recount at regen; the letter change then goes out.
state.combat = true; Fire("PLAYER_REGEN_DISABLED")
state.bags[0][2].stackCount = 3; state.bags[1][2] = nil     -- drink 3: D
Fire("BAG_UPDATE_DELAYED"); Fire("BAG_UPDATE_DELAYED")
Step(3)
check(scans == 1 and Supplies.counts.drink == 24 and changes == 0, "recounted in combat")
state.combat = false; Fire("PLAYER_REGEN_ENABLED")
check(scans == 2 and Supplies.counts.drink == 3 and changes == 1 and Supplies.letters == "DS",
  "no recount at regen: scans " .. scans .. " letters " .. Supplies.letters)
Fire("PLAYER_REGEN_ENABLED")
check(scans == 2, "recounted again at a second regen")
Step(4)
check(LastSent("H") and LastSent("H").payload:find(";u=40.3.10.5.350.3.2.30", 1, true), "heartbeat without the new counts: "
  .. tostring(LastSent("H") and LastSent("H").payload))
-- A recount queued out of combat whose timer fires in combat waits for regen too.
Fire("BAG_UPDATE_DELAYED")
state.combat = true; Fire("PLAYER_REGEN_DISABLED")
state.bags[0][2].stackCount = 20
Step(1)
check(scans == 2, "timer recounted in combat")
state.combat = false; Fire("PLAYER_REGEN_ENABLED")
check(scans == 3 and Supplies.counts.drink == 20 and Supplies.letters == "S" and changes == 2, "held recount at regen")
-- Thresholds: our own letter set changes with them (Changed), else only a redraw.
ns.SetOption("shardWarn", 0)
check(changes == 3 and Supplies.letters == "", "shardWarn 0 did not change our letters")
ns.SetOption("shardWarn", 3)
check(changes == 3 and Supplies.letters == "", "equal count is low")
ns.SetOption("shardWarn", 5)
check(changes == 4 and Supplies.letters == "S", "shardWarn back")
-- Missing bag API: no count, no error, old counts kept.
local realContainer = C_Container
C_Container = nil
Fire("BAG_UPDATE_DELAYED"); Step(1)
check(Supplies.Count() == nil and Supplies.counts.food == 40, "missing API")
Supplies.counts = nil
check(field("u") == nil, "u field without counts")
C_Container = realContainer
Supplies.Recount()
check(Supplies.counts.food == 40 and changes == 4, "recount after the API is back")

---------------------------------------------------------------------------
-- Row entries
---------------------------------------------------------------------------
local e = entry(ME)
check(e and e[2] == "S" and e[3] == 1 and e[4] == 0.55 and e[5] == 0.1 and e[6] == "shards 3" and e[7] == 13,
  "own entry: " .. tostring(e and e[2]) .. " / " .. tostring(e and e[6]))
state.class.player = "MAGE"
check(entry(ME) == nil, "S for a mage")
state.class.player = "HUNTER"
check(entry(ME) == nil, "A with 350 ammo")
ns.SetOption("ammoWarn", 400)
check(entry(ME) and entry(ME)[2] == "A" and Supplies.letters == "A", "A for a hunter below ammoWarn")
ns.SetOption("ammoWarn", 200)
state.class.player = "WARLOCK"
ns.SetOption("shardWarn", 0); ns.SetOption("shardWarn", 5)    -- back to the own letters of a warlock
check(entry(ME)[2] == "S", "own entry after class changes")
-- Received: letters in order F D B P A S H from their k and u with our thresholds.
beat(PRI, "k=PRIEST;u=3.0.4.0.0.0.0.0")
e = entry(PRI)
check(e and e[2] == "FDB" and e[6] == "food 3, drink 0, bandages 4", "priest entry: " .. tostring(e and e[2]) .. " / "
  .. tostring(e and e[6]))
ns.SetOption("potionWarn", 2)
beat(PRI, "k=PRIEST;u=3.0.4.2.0.0.0.0")
check(entry(PRI)[2] == "FDB", "equal count is low")
beat(PRI, "k=PRIEST;u=3.0.4.1.0.0.0.0")
check(entry(PRI)[2] == "FDBP", "potion threshold")
ns.SetOption("potionWarn", 0)
check(entry(PRI)[2] == "FDB", "potionWarn 0 still shows P")
beat(PRI, "k=PRIEST;u=9.9.9.9.0.0.0.0")
check(entry(PRI) == nil, "ammo/shards/hs letters for a priest")
beat(PRI, "k=HUNTER;u=9.9.9.9.150.0.0.0")
check(entry(PRI) and entry(PRI)[2] == "A" and entry(PRI)[6] == "ammo 150", "hunter ammo")
beat(PRI, "k=HUNTER;u=9.9.9.9.200.0.0.0")
check(entry(PRI) == nil, "ammo at the threshold")
beat(VF, "k=WARLOCK;u=9.9.9.9.0.2.0.0")
check(entry(VF) and entry(VF)[2] == "SH" and entry(VF)[6] == "shards 2, Healthstones 0", "warlock entry: "
  .. tostring(entry(VF) and entry(VF)[6]))
beat(VF, "u=0.0.0.0.0.0.0.0")
check(entry(VF) and entry(VF)[2] == "FDB", "unknown class letters: " .. tostring(entry(VF) and entry(VF)[2]))
beat(VF, "k=WARLOCK")
check(entry(VF) == nil, "entry without u")
beat(VF, "k=WARLOCK;u=1.2")
check(entry(VF) == nil, "entry with a malformed u")
beat(PRI, "k=PRIEST;u=3.0.4.0.0.0.0.0")
ns.SetOption("foodWarn", 0)
check(entry(PRI)[2] == "DB", "foodWarn 0")
ns.SetOption("foodWarn", 5)
check(entry("Nobody Here") == nil, "entry for a stranger")

---------------------------------------------------------------------------
-- Trade top-up through MamaForever:MatsFor
---------------------------------------------------------------------------
state.bags = {
  [0] = { n = 16, Slot(4540, 20), Slot(4540, 12), Slot(4540, 7), Slot(159, 20), Slot(159, 5, true),
    Slot(1251, 10, false, true), Slot(1251, 6), Slot(118, 5), Slot(6265, 10), Slot(5512, 1), Slot(5512, 1) },
  [5] = { n = 12, family = 1, Slot(2512, 200), Slot(2512, 150), Slot(2512, 50) },
}
Fire("BAG_UPDATE_DELAYED"); Step(1)
check(same(Supplies.counts, { food = 39, drink = 25, bandage = 16, potion = 5, ammo = 400, shards = 10, hs = 2, reagent = 0 }),
  "top-up bag counts: " .. text(Supplies.counts))
local MF = MamaForever
local function mats(partner, manual)
  local list = MF:MatsFor(partner, manual)
  local t = {}
  for _, m in ipairs(list) do t[#t + 1] = (m.label or "?") .. "@" .. tostring(m.bag) .. "/" .. tostring(m.slot) .. "x" .. tostring(m.count) end
  return list, table.concat(t, " ")
end
state.mats = {}
-- Priest lacking food, drink and bandages: biggest unbound unlocked stacks first, three at most.
beat(PRI, "k=PRIEST;u=2.0.1.0.0.0.1.0")
local list, s = mats(PRI, false)
check(s == "food@0/1x20 drink@0/4x20 food@0/2x12", "top-up list: " .. s)
check(list[1].bag == 0 and list[1].slot == 1 and list[1].count == 20 and list[1].label == "food", "stack shape")
-- Our own thresholds are kept: with foodWarn 30 only the 7-stack of food may go, and the locked
-- 10 bandages (in a trade already) leave 6 of 16: the 6-stack would take us to 0.
ns.SetOption("foodWarn", 30)
_, s = mats(PRI, false)
check(s == "drink@0/4x20 food@0/3x7", "own threshold kept: " .. s)
ns.SetOption("foodWarn", 5)
-- Stacks the first fill locked in the trade window are as good as gone: the button's second call
-- (or a PROFESSIONS fill after the automatic one) never gives below our thresholds.
state.bags[0][1].isLocked, state.bags[0][2].isLocked, state.bags[0][4].isLocked = true, true, true
_, s = mats(PRI, true)
check(s == "", "locked stacks still counted as ours: " .. s)
state.bags[0][2].isLocked, state.bags[0][4].isLocked = false, false
_, s = mats(PRI, true)
check(s == "drink@0/4x20 food@0/2x12", "budget after one locked stack: " .. s)
state.bags[0][1].isLocked = false
-- Same list for the button and the automatic fill; the 6-stack cap comes from the button's list.
state.mats = { { bag = 2, slot = 1, count = 9, label = "cloth" }, { bag = 2, slot = 2, count = 8, label = "cloth" },
  { bag = 2, slot = 3, count = 7, label = "cloth" }, { bag = 2, slot = 4, count = 6, label = "cloth" },
  { bag = 2, slot = 5, count = 5, label = "ore" } }
state.matsAuto = { state.mats[1], state.mats[5] }
local manual, sm = mats(PRI, true)
local auto, sa = mats(PRI, false)
check(#manual == 6 and sm == "food@0/1x20 cloth@2/1x9 cloth@2/2x8 cloth@2/3x7 cloth@2/4x6 ore@2/5x5", "manual list: " .. sm)
check(#auto == 3 and sa == "food@0/1x20 cloth@2/1x9 ore@2/5x5", "auto list: " .. sa)
check(#manual - #auto == #state.mats - #state.matsAuto, "kept count broken")
state.mats[6] = { bag = 2, slot = 6, count = 4, label = "herbs" }
_, s = mats(PRI, false)
check(s == "cloth@2/1x9 ore@2/5x5", "top-up with a full mats list: " .. s)
state.mats, state.matsAuto = { state.mats[1], state.mats[2] }, nil
_, s = mats(PRI, true)
check(s == "food@0/1x20 drink@0/4x20 food@0/2x12 cloth@2/1x9 cloth@2/2x8", "three top-ups before two mats: " .. s)
state.mats = {}
-- The partner's free general bag slots (Mama's G stats) cap the top-up too, Mama's own stacks counted
-- first; unknown or secret stats leave the cap alone.
state.stats = { [PRI] = { money = 0, free = 2, slots = 16, t = 0 } }
_, s = mats(PRI, false)
check(s == "food@0/1x20 drink@0/4x20", "free-slot cap: " .. s)
state.mats = { { bag = 2, slot = 1, count = 9, label = "cloth" } }
_, s = mats(PRI, false)
check(s == "food@0/1x20 cloth@2/1x9", "free-slot cap with a mat: " .. s)
state.stats[PRI].free = 0
_, s = mats(PRI, false)
check(s == "cloth@2/1x9", "no free slot topped up: " .. s)
state.stats[PRI].free = MakeSecret("number")
_, s = mats(PRI, false)
check(s == "food@0/1x20 drink@0/4x20 food@0/2x12 cloth@2/1x9", "secret free slots: " .. s)
state.stats, state.mats = nil, {}
-- The game's path: Mama's FillTrade reaches MatsFor only once the partner's professions are known.
-- Until their P answer the trade stays empty (Mama asks), then the top-up lands in the trade window;
-- the stacks are locked there, so "give mats" again adds nothing that takes us below our thresholds.
MF.db.autoTrade = true
state.full.NPC = PRI
Fire("TRADE_SHOW"); Step(0.5)
check(#tradeSlots == 0 and #asked == 1 and asked[1] == PRI and lastKept == nil, "filled before the professions are known")
state.profs = { [PRI] = { [197] = 75 } }
MF:Fire("PROFESSIONS", PRI)
check(#tradeSlots == 3 and tradeSlots[1].itemID == 4540 and tradeSlots[1].stackCount == 20 and tradeSlots[2].itemID == 159
  and tradeSlots[3].stackCount == 12 and lastKept == 0, "top-up in the trade after the professions: " .. #tradeSlots)
MF:FillTrade(true)
check(#tradeSlots == 3, "second fill gave below our thresholds: " .. #tradeSlots)
Fire("TRADE_CLOSED")
check(#tradeSlots == 0 and state.bags[0][1].isLocked == false, "trade closed")
-- Professions known from the start: the automatic fill 0.3 s after TRADE_SHOW, kept 0 (no Mama mats).
Fire("TRADE_SHOW"); Step(0.5)
check(#tradeSlots == 3 and lastKept == 0 and #asked == 1, "automatic fill with known professions: " .. #tradeSlots)
Fire("TRADE_CLOSED")
state.full.NPC, state.profs, MF.db.autoTrade = nil, nil, nil
-- Stale record (over 60 s), no record, not grouped, option off, secret or own name: Mama's list only.
Advance(61)
_, s = mats(PRI, false)
check(s == "", "stale record topped up: " .. s)
beat(PRI, "k=PRIEST;u=2.0.1.0.0.0.1.0")
Advance(60)
_, s = mats(PRI, false)
check(s ~= "", "60 s old record not fresh")
check(select(2, mats("Nobody Here", false)) == "", "stranger topped up")
ns.SetOption("suppliesTopup", false)
check(select(2, mats(PRI, false)) == "", "option off topped up")
ns.SetOption("suppliesTopup", true)
check(select(2, mats(MakeSecret("string"), false)) == "" and select(2, mats(ME, false)) == "", "secret or own partner")
state.group = { "party2" }; Fire("GROUP_ROSTER_UPDATE"); Flush()
check(select(2, mats(PRI, false)) == "", "ungrouped member topped up")
state.group = { "party1", "party2" }; Fire("GROUP_ROSTER_UPDATE"); Flush()
beat(PRI, "k=PRIEST;u=2.0.1.0.0.0.1.0")
check(select(2, mats(PRI, false)) ~= "", "grouped again")
-- Never shards; Healthstones only to non-warlocks, keeping our own; ammo only to hunters.
beat(VF, "k=WARLOCK;u=9.9.9.9.0.1.0.0")
check(select(2, mats(VF, false)) == "", "shards or Healthstones to a warlock")
beat(PRI, "k=PRIEST;u=9.9.9.9.0.0.0.0")
_, s = mats(PRI, false)
check(s == "Healthstones@0/10x1", "Healthstone to a priest: " .. s)
beat(PRI, "k=HUNTER;u=9.9.9.9.100.0.1.0")
_, s = mats(PRI, false)
check(s == "ammo@5/1x200", "ammo to a hunter: " .. s)
beat(PRI, "k=PRIEST;u=9.9.9.9.100.0.1.0")
check(select(2, mats(PRI, false)) == "", "ammo to a priest")
beat(PRI, "u=9.9.9.9.100.0.0.0")
check(select(2, mats(PRI, false)) == "Healthstones@0/10x1", "unknown class: ammo given or Healthstone kept")
-- A stack whose bound or locked state is secret stays with us.
state.bags[0][1].isBound = MakeSecret("boolean")
state.bags[0][2].isLocked = MakeSecret("boolean")
beat(PRI, "k=PRIEST;u=2.9.9.9.0.0.1.0")
_, s = mats(PRI, false)
check(s == "food@0/3x7", "secret bound/locked stack given: " .. s)
state.bags[0][1].isBound, state.bags[0][2].isLocked = false, false
-- A failing count never breaks Mama's list.
state.mats = { { bag = 2, slot = 1, count = 9, label = "cloth" } }
C_Container = nil
_, s = mats(PRI, false)
check(s == "cloth@2/1x9", "missing API broke MatsFor: " .. s)
C_Container = realContainer
state.mats = {}

---------------------------------------------------------------------------
-- Commands, status line, probe
---------------------------------------------------------------------------
beat(PRI, "k=PRIEST;u=2.0.1.0.0.0.1.0")
beat(VF, "k=WARLOCK")
local n = #printed
ns.RunCommand("supplies")
check(#printed == n + 3, "one line per slot: " .. (#printed - n))
check(printed[n + 1]:find("slot 1 Han Jaconelli: food 39, drink 25, bandages 16, potions 5, ammo 400, shards 10, Healthstones 2, reagents 0", 1, true)
  and not printed[n + 1]:find("low", 1, true), "own line: " .. printed[n + 1])
check(printed[n + 2]:find("slot 2 Pri Cuthbridge: food 2, drink 0, bandages 1, potions 0, ammo 0, shards 0, Healthstones 1, reagents 0 (low FDB)", 1, true),
  "priest line: " .. printed[n + 2])
check(printed[n + 3]:find("slot 3 Vf Pr: no supplies in its heartbeat", 1, true), "no-u line: " .. printed[n + 3])
ns.Status.records[VF] = nil
ns.RunCommand("supplies")
check(lastPrinted():find("slot 3 Vf Pr: no heartbeat yet", 1, true), "no-record line: " .. lastPrinted())
n = #printed
ns.RunCommand("supplies items")
check(printed[n + 1]:find("supplies in bags 0-5: food 39, drink 25", 1, true), "items header: " .. printed[n + 1])
check(printed[n + 2]:find("food: Tough Jerky x20, Tough Jerky x12, Tough Jerky x7", 1, true), "items food: " .. printed[n + 2])
check(printed[n + 3]:find("drink: Refreshing Spring Water x20, Refreshing Spring Water x5", 1, true), "items drink: " .. printed[n + 3])
check(printed[n + 6]:find("ammo: Rough Arrow x200, Rough Arrow x150, Rough Arrow x50", 1, true), "items ammo: " .. printed[n + 6])
check(printed[n + 8]:find("Healthstones: Minor Healthstone x1, Minor Healthstone x1", 1, true), "items hs: " .. printed[n + 8])
check(#printed == n + 8, "items lines: " .. (#printed - n))
state.items[4540].name = nil
ns.RunCommand("supplies items")
check(printed[n + 10]:find("food: item 4540 x20", 1, true), "uncached name: " .. printed[n + 10])
state.items[4540].name = "Tough Jerky"
ns.RunCommand("status")
check(lastPrinted():find("supplies: counts food 39, drink 25", 1, true) and lastPrinted():find("low none; dirty false; top-up on", 1, true),
  "status line: " .. lastPrinted())
local lines = ns.probes.supplies[1]()
local joined = table.concat(lines, "\n")
check(#lines >= 14 and joined:find("NUM_TOTAL_EQUIPPED_BAG_SLOTS: nil (nil)", 1, true) and joined:find("last bag scanned: 5", 1, true),
  "probe bag lines:\n" .. joined)
check(joined:find("GetContainerNumSlots(5): 12 (number)", 1, true) and joined:find("GetContainerNumFreeSlots(5): 9 (number), family 1 (number)", 1, true),
  "probe bag 5:\n" .. joined)
check(joined:find("Enum.ItemClass: table, Enum.ItemConsumableSubclass: table", 1, true), "probe enums")
check(joined:find("GetItemInfoInstant(4540) class/sub: 0 (number) / 5 (number) -> food", 1, true)
  and joined:find("GetItemInfoInstant(6265) class/sub: 15 (number) / 0 (number) -> shards", 1, true), "probe item classes:\n" .. joined)
check(joined:find("GetItemSpell(4540): Food (string)", 1, true) and joined:find("GetItemSpell(159): Drink (string)", 1, true), "probe spells")
check(joined:find("counted 0/1 item 4540 x20 -> food", 1, true) and joined:find("state: counts", 1, true), "probe sample")
local out = {}
ns.probes.supplies[1](out)
check(#out == #lines, "probe out table")
C_Container, C_Item, Enum = nil, nil, nil
lines = ns.probes.supplies[1]()
check(table.concat(lines, "\n"):find("GetItemInfoInstant(4540) class/sub: error or missing", 1, true), "probe without APIs")
n = #printed
ns.RunCommand("supplies items")
check(lastPrinted():find("bag or item API missing", 1, true), "items without API: " .. lastPrinted())
C_Container, C_Item = realContainer, nil
Enum = { ItemClass = { Consumable = 0, Projectile = 6, Reagent = 5, Miscellaneous = 15 },
  ItemConsumableSubclass = { Generic = 0, Potion = 1, Fooddrink = 5, Bandage = 7 } }

print("SUPPLIES TESTS PASSED")
