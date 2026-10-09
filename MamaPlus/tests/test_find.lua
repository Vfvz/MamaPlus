-- Tests for Find.lua: parsing (link, id, name, unknown, secret), the own
-- count line with bank, one Q per item while its collector is open, the
-- collector (slot order, own slot skipped, stale cache entries not counted
-- as answers, "nobody else has", "no answer from" for grouped slot holders
-- only, "x?" answers), the Q answer whisper (GetItemCount, bag scan when it
-- is secret or missing, "?" without any API, bad ids ignored), the cache
-- cap with least recently answered dropped, the tooltip line (GameTooltip
-- and ItemRefTooltip only, type and secret checks, TooltipUtil fallback,
-- age wording, option off, never a message), comms off, status line, probe.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

---------------------------------------------------------------------------
-- Extra API fakes (before LoadModule): tooltip post calls, items and bags.
---------------------------------------------------------------------------
local postCalls = {}
TooltipDataProcessor = {
  AddTooltipPostCall = function(kind, fn) postCalls[#postCalls + 1] = { kind = kind, fn = fn } end,
}
state.items = {
  [2589] = { name = "Linen Cloth", class = 7, sub = 5, count = 20, bankCount = 5 },
  [6265] = { name = "Soul Shard", class = 15, sub = 0, count = 0 },
  [4540] = { name = "Tough Jerky", class = 0, sub = 5, count = 3 },
}
local function Slot(id, n) return { itemID = id, stackCount = n } end
state.bags = {
  [0] = { n = 16, Slot(2589, 20), Slot(2589, 7), Slot(4540, 3) },
  [1] = { n = 6, Slot(2589, 5), MakeSecret(), Slot(2589, MakeSecret("number")) },
}

LoadModule("Find.lua")
local Find = ns.Find
local PRI, VF, AB = "Pri Cuthbridge", "Vf Pr", "Ab Cd"
local LINK = "|cff1eff00|Hitem:2589::::::::12:::::::|h[Linen Cloth]|h|r"
local function lastPrinted() return printed[#printed] or "" end
local function since(n)
  local out = {}
  for i = n + 1, #printed do out[#out + 1] = printed[i] end
  return table.concat(out, "\n")
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

check(ns.commands.find and ns.ops.Q and ns.ops.A and ns.probes.find, "command, receivers or probe missing")
check(ns.db == nil and Find.tooltipHook == nil and #postCalls == 0, "nothing registered before login")

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------
local id, how = Find.ItemID(LINK)
check(id == 2589 and how == "link", "link: " .. tostring(id) .. " " .. tostring(how))
id, how = Find.ItemID(" 2589 ")
check(id == 2589 and how == "id", "id: " .. tostring(id) .. " " .. tostring(how))
id, how = Find.ItemID("Linen Cloth")
check(id == 2589 and how == "name", "name: " .. tostring(id) .. " " .. tostring(how))
check(Find.ItemID("0") == nil and Find.ItemID("1000000") == nil and Find.ItemID("") == nil and Find.ItemID(nil) == nil
  and Find.ItemID("No Such Thing") == nil and Find.ItemID(MakeSecret("string")) == nil, "unknown inputs")

---------------------------------------------------------------------------
-- Login; the mock's login drains the limiter with heartbeats (1 token per 2 s back)
---------------------------------------------------------------------------
Login({ "party1", "party2" })
check(ns.db.findTooltip == true, "default findTooltip")
check(Find.tooltipHook == true and #postCalls == 1 and postCalls[1].kind == 0, "post call registered at LOGIN")
Step(14)

local sent0 = #mamaSent
ns.RunCommand("find No Such Thing")
check(has(lastPrinted(), "usage:") and #mamaSent == sent0, "usage line: " .. lastPrinted())
ns.RunCommand("find")
check(has(lastPrinted(), "usage:") and #mamaSent == sent0, "usage line for no argument")

-- Own count and one Q per item while the collector is open.
local n = #printed
ns.RunCommand("find " .. LINK)
check(has(since(n), "find Linen Cloth (2589): you have x20 (+5 bank)"), "own count: " .. since(n))
check(#Sent("Q") == 1 and LastSent("Q").payload == "x;Q;2589" and LastSent("Q").kind == "group", "Q sent: " .. #Sent("Q"))
ns.RunCommand("find 2589")
check(#Sent("Q") == 1, "second ask within 3 s sends no Q")
check(has(lastPrinted(), "you have x20 (+5 bank)"), "own count printed again")

-- Answers delivered out of slot order are printed in slot order after 3 s; own slot never listed.
Deliver(VF, "x;A;2589;4;-")
Deliver(PRI, "x;A;2589;12;20")
n = #printed
Step(2.5)
check(#printed == n, "collector waits 3 s")
Step(0.5)
local out = since(n)
local p2, p3 = out:find("slot2 Pri Cuthbridge x12 (+20 bank)", 1, true), out:find("slot3 Vf Pr x4", 1, true)
check(p2 and p3 and p2 < p3, "slot order: " .. out)
check(not has(out, "nobody else") and not has(out, "no answer") and not has(out, "slot1"), "stray lines: " .. out)

-- Once the collector closed a new ask sends again; cached answers from the
-- first ask do not count; grouped slot holders that stay silent are named,
-- an ungrouped slot holder is not.
MamaForever.db.slots[4] = AB
ns.RunCommand("find 2589")
check(#Sent("Q") == 2, "Q again after 3 s: " .. #Sent("Q"))
n = #printed
Step(3)
out = since(n)
check(has(out, "no answer from slot2 Pri Cuthbridge") and has(out, "no answer from slot3 Vf Pr"), "no answer: " .. out)
check(not has(out, "slot4") and not has(out, "Ab Cd") and not has(out, "x12"), "ungrouped or stale: " .. out)
check(has(out, "nobody else has Linen Cloth (2589)"), "nobody else after silence: " .. out)
MamaForever.db.slots[4] = nil

-- Only zero answers: "nobody else", no "no answer".
ns.RunCommand("find Soul Shard")
check(has(lastPrinted(), "find Soul Shard (6265): you have x0"), "own zero count: " .. lastPrinted())
Deliver(PRI, "x;A;6265;0;-"); Deliver(VF, "x;A;6265;0;0")
n = #printed
Step(3)
out = since(n)
check(has(out, "nobody else has Soul Shard (6265)") and not has(out, "no answer") and not has(out, "slot2"), "zeros: " .. out)

-- An unknown ("?") answer is shown as such and counts as an answer.
ns.RunCommand("find 4540")
Deliver(PRI, "x;A;4540;?;-"); Deliver(VF, "x;A;4540;2;-")
n = #printed
Step(3)
out = since(n)
check(has(out, "slot2 Pri Cuthbridge x?") and has(out, "slot3 Vf Pr x2") and not has(out, "nobody"), "unknown answer: " .. out)

---------------------------------------------------------------------------
-- Answering a Q: one whisper to the asker from our own counts.
---------------------------------------------------------------------------
local a0 = #Sent("A")
Deliver(PRI, "x;Q;2589")
local a = LastSent("A")
check(#Sent("A") == a0 + 1 and a.kind == "whisper" and a.to == PRI and a.payload == "x;A;2589;20;5",
  "answer: " .. tostring(a and a.payload))
Deliver(VF, "x;Q;6265")
check(#Sent("A") == a0 + 2 and LastSent("A").payload == "x;A;6265;0;-" and LastSent("A").to == VF, "zero answer")
Deliver(PRI, "x;Q;abc"); Deliver(PRI, "x;Q;"); Deliver(PRI, "x;Q;0"); Deliver(PRI, "x;Q;1000000"); Deliver(PRI, "x;Q")
check(#Sent("A") == a0 + 2, "bad ids ignored: " .. #Sent("A"))
-- NaN and fractional ids pass a plain range test (every NaN compare is false);
-- they must neither be answered nor stored (cache[NaN] raises "table index is NaN").
local errs0 = #handlerErrors
Deliver(PRI, "x;Q;nan"); Deliver(PRI, "x;Q;1.5"); Deliver(PRI, "x;A;nan;1;-"); Deliver(PRI, "x;A;1.5;3;-")
check(#Sent("A") == a0 + 2 and #handlerErrors == errs0 and Find.cache[1.5] == nil,
  "nan or fractional ids ignored: " .. #Sent("A") .. " " .. (#handlerErrors - errs0))
Step(2)

-- Bag scan when GetItemCount is secret or missing (secret slots skipped); "?" without any API.
local realCount = C_Item.GetItemCount
C_Item.GetItemCount = function() return MakeSecret("number") end
local bags, bank = Find.Count(2589)
check(bags == 32 and bank == nil, "secret GetItemCount -> bag scan: " .. tostring(bags) .. " " .. tostring(bank))
C_Item.GetItemCount = nil
bags, bank = Find.Count(2589)
check(bags == 32 and bank == nil, "missing GetItemCount -> bag scan: " .. tostring(bags))
Deliver(PRI, "x;Q;2589")
check(LastSent("A").payload == "x;A;2589;32;-", "scanned answer: " .. LastSent("A").payload)
local realContainer = C_Container
C_Container = nil
check(Find.Count(2589) == nil, "no API -> unknown")
Deliver(PRI, "x;Q;2589")
check(LastSent("A").payload == "x;A;2589;?;-", "unknown answer: " .. LastSent("A").payload)
C_Container, C_Item.GetItemCount = realContainer, realCount

---------------------------------------------------------------------------
-- Tooltip line: cache only, never a message.
---------------------------------------------------------------------------
local function Tip(name)
  local t = { lines = {}, name = name }
  function t:GetName() return self.name end
  function t:AddLine(l) self.lines[#self.lines + 1] = l end
  return t
end
local sent1 = #mamaSent
local tip = Tip("GameTooltip")
postCalls[1].fn(tip, { id = 2589 })
check(tip.lines[1] and tip.lines[1]:match("^Team: slot2 x12 %(%+20 bank%), slot3 x4 %(%d+ s ago%)$"),
  "tooltip line: " .. tostring(tip.lines[1]))
check(has(Find.lastTooltip, "GameTooltip: data table, id number"), "last tooltip: " .. tostring(Find.lastTooltip))
tip = Tip("ItemRefTooltip")
postCalls[1].fn(tip, { id = 2589 })
check(#tip.lines == 1, "ItemRefTooltip gets the line")
Advance(120)
tip = Tip("GameTooltip")
postCalls[1].fn(tip, { id = 2589 })
check(tip.lines[1] and tip.lines[1]:find("(2 min ago)", 1, true), "age in minutes: " .. tostring(tip.lines[1]))
local function NoLine(tt, data, why)
  postCalls[1].fn(tt, data)
  check(#tt.lines == 0, "unexpected line (" .. why .. "): " .. tostring(tt.lines[1]))
end
NoLine(Tip("ShoppingTooltip1"), { id = 2589 }, "other tooltip")
NoLine(Tip("GameTooltip"), nil, "no data")
NoLine(Tip("GameTooltip"), "x", "data not a table")
NoLine(Tip("GameTooltip"), { id = MakeSecret("number") }, "secret id")
check(has(Find.lastTooltip, "(secret)"), "secret id recorded: " .. tostring(Find.lastTooltip))
NoLine(Tip("GameTooltip"), { id = "2589" }, "id not a number")
NoLine(Tip("GameTooltip"), { id = 99 }, "nothing cached")
NoLine(Tip("GameTooltip"), { id = 6265 }, "only zero answers")
NoLine({ lines = {}, AddLine = function() end }, { id = 2589 }, "no GetName")
NoLine(Tip(MakeSecret("string")), { id = 2589 }, "secret name")
TooltipUtil = { GetDisplayedItem = function() return "Linen Cloth", "link", 2589 end }
tip = Tip("GameTooltip")
postCalls[1].fn(tip, {})
check(#tip.lines == 1, "TooltipUtil fallback")
TooltipUtil = nil
ns.SetOption("findTooltip", false)
NoLine(Tip("GameTooltip"), { id = 2589 }, "option off")
ns.SetOption("findTooltip", true)
tip = Tip("GameTooltip")
postCalls[1].fn(tip, { id = 2589 })
check(#tip.lines == 1 and #mamaSent == sent1, "option back on; tooltips sent nothing: " .. (#mamaSent - sent1))

---------------------------------------------------------------------------
-- Cache cap: 100 items, least recently answered dropped first.
---------------------------------------------------------------------------
for i = 1, 101 do Deliver(PRI, "x;A;" .. (10000 + i) .. ";1;-") end
check(#Find.order == 100 and Find.cache[2589] == nil and Find.cache[10001] == nil and Find.cache[10002] and Find.cache[10101],
  "cache cap: " .. #Find.order)
Deliver(PRI, "x;A;10002;3;-")
Deliver(VF, "x;A;20000;1;-")
check(#Find.order == 100 and Find.cache[10002] and Find.cache[10002][PRI].bags == 3 and Find.cache[10003] == nil,
  "re-answered item kept, next oldest dropped")
check(#mamaSent == sent1, "answers sent nothing")

---------------------------------------------------------------------------
-- Comms off, status line, probe.
---------------------------------------------------------------------------
state.token = nil
local q = #Sent("Q")
n = #printed
ns.RunCommand("find 2589")
check(has(since(n), "cannot ask the team") and #Sent("Q") == q, "comms off: " .. since(n))
n = #printed
Step(3)
check(#printed == n, "no collector without a Q")
state.token = "tok"

n = #printed
ns.RunCommand("status")
check(has(since(n), "find: 100 cached items, tooltip line on"), "status line: " .. since(n))

local lines = ns.probes.find[1]()
local joined = table.concat(lines, "\n")
check(has(joined, "TooltipDataProcessor: table, AddTooltipPostCall: function")
  and has(joined, "Enum.TooltipDataType.Item: number, TooltipUtil.GetDisplayedItem: nil")
  and has(joined, "tooltip hook: true") and has(joined, "GetItemCount(6265): 0 (number)")
  and has(joined, "GetItemInfoInstant(Linen Cloth): 2589 (number)") and has(joined, "cache: 100 items"), "probe:\n" .. joined)
local out2 = {}
ns.probes.find[1](out2)
check(#out2 == #lines, "probe out table")
C_Item = nil
joined = table.concat(ns.probes.find[1](), "\n")
check(has(joined, "GetItemCount(6265): error or missing"), "probe without C_Item")

print("find OK")
