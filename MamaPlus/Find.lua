local addonName, ns = ...

-- Find: "/mama plus find <item link|id|name>" asks every online team window
-- how many of an item it holds. The asker prints its own count, sends
-- x;Q;<itemID> to the team (SendTeam, at most once per item while an
-- answer collector is open, 3 s) and after 3 s prints the answers in slot
-- order ("slot2 Pri Cuthbridge x12 (+20 bank)"), "nobody else has it" when
-- no answer is positive, and "no answer from slotN Name" for grouped slot
-- holders that stayed silent. Every window answers a Q with one whisper
-- x;A;<itemID>;<bags|?>;<bank|-> from its own plain counts: GetItemCount
-- (bank = count with bank minus count without, when both are plain), a
-- container scan when GetItemCount is missing or secret. Answers go into a
-- session cache (100 items, oldest dropped) that the item tooltip line
-- "Team: slot2 x12 (2 min ago)" reads; the tooltip never sends anything.
-- Nothing here acts on another window: it counts, asks, answers and prints.

local Find = {}
ns.Find = Find

local IsSecret = ns.IsSecret
local COLLECT, CACHE_MAX, MAX_ID = 3, 100, 999999

ns.AddDefaults({ findTooltip = true })
ns.AddOption({ key = "findTooltip", label = "Team counts in item tooltips", section = "Find", type = "toggle",
  tip = "Adds 'Team: slot2 x12' from the last find answers to item tooltips. Never asks the team by itself." })

Find.cache = {}      -- itemID -> { [sender] = { bags, bank, time } }
Find.order = {}      -- itemIDs, least recently answered first (for the cap)
Find.tooltipHook = nil -- true once the tooltip post call is registered, false when the API is missing
Find.lastTooltip = nil -- what the post call saw last (probe P2)
local pending = {}   -- itemID -> { got = { [sender] = true } } while a collector is open

---------------------------------------------------------------------------
-- Parsing and own counts
---------------------------------------------------------------------------
-- itemID and how it was given ("link", "id", "name"), or nil.
function Find.ItemID(text)
  text = ns.PlainOfType(text, "string", ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local id = tonumber(text:match("|Hitem:(%d+)"))
  if id then return id, "link" end
  id = tonumber(text:match("^(%d+)$"))
  if id then
    if id >= 1 and id <= MAX_ID then return id, "id" end
    return nil
  end
  local ok, v = ns.Try(C_Item and C_Item.GetItemInfoInstant, text)
  id = ok and ns.PlainNumber(v) or nil
  if id and id >= 1 then return id, "name" end
  return nil
end

-- Stacks of itemID over bags 0-5 (and further when the client says so), plain slots only; nil without the API.
local function ScanBags(itemID)
  local bags = C_Container
  if not (bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo) then return nil end
  local last, total = ns.PlainNumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS), 0
  if not last or last < 5 then last = 5 end
  for bag = 0, last do
    local ok, slots = pcall(bags.GetContainerNumSlots, bag)
    slots = ok and ns.PlainNumber(slots) or 0
    for slot = 1, slots do
      local ok2, info = pcall(bags.GetContainerItemInfo, bag, slot)
      if ok2 and not IsSecret(info) and type(info) == "table" then
        local id, n = ns.PlainNumber(info.itemID), ns.PlainNumber(info.stackCount)
        if id == itemID and n then total = total + n end
      end
    end
  end
  return total
end

-- This window's plain counts: bags (nil when unknown), bank (nil when unknown or zero).
function Find.Count(itemID)
  local items, bags, bank = C_Item, nil, nil
  if items and items.GetItemCount then
    local ok, v = pcall(items.GetItemCount, itemID)
    bags = ok and ns.PlainNumber(v) or nil
    local ok2, all = pcall(items.GetItemCount, itemID, true)
    all = ok2 and ns.PlainNumber(all) or nil
    if bags and all and all - bags > 0 then bank = all - bags end
  end
  if not bags then bags = ScanBags(itemID) end
  return bags, bank
end

local function Label(itemID)
  local ok, name = ns.Try(C_Item and C_Item.GetItemInfo, itemID)
  name = ok and ns.PlainOfType(name, "string", nil) or nil
  return name and (name .. " (" .. itemID .. ")") or ("item " .. itemID)
end

---------------------------------------------------------------------------
-- Cache, slot order, formatting
---------------------------------------------------------------------------
function Find.Store(itemID, sender, bags, bank)
  local answers = Find.cache[itemID]
  if not answers then
    answers = {}
    Find.cache[itemID] = answers
  end
  for i, id in ipairs(Find.order) do
    if id == itemID then table.remove(Find.order, i) break end
  end
  Find.order[#Find.order + 1] = itemID
  while #Find.order > CACHE_MAX do Find.cache[table.remove(Find.order, 1)] = nil end
  answers[sender] = { bags = bags, bank = bank, time = GetTime() }
end

-- { slot, name } pairs in slot order.
local function SlotList()
  local list = {}
  for slot, name in pairs(ns.Slots()) do
    if type(slot) == "number" and type(name) == "string" then list[#list + 1] = { slot = slot, name = name } end
  end
  table.sort(list, function(a, b) return a.slot < b.slot end)
  return list
end

local function Positive(a) return (a.bags and a.bags > 0) or (a.bank and a.bank > 0) or false end

local function Amount(bags, bank)
  return (bags and ("x" .. bags) or "x?") .. ((bank and bank > 0) and (" (+" .. bank .. " bank)") or "")
end

local function Ago(secs)
  secs = math.floor(secs + 0.5)
  if secs < 60 then return secs .. " s ago" end
  return math.floor(secs / 60) .. " min ago"
end

-- "Team: slot2 x12, slot4 x3 (2 min ago)" from cached positive answers, or nil.
function Find.Summary(itemID)
  local answers = Find.cache[itemID]
  if not answers then return nil end
  local parts, newest = {}, nil
  for _, s in ipairs(SlotList()) do
    local a = answers[s.name]
    if a and Positive(a) then
      parts[#parts + 1] = "slot" .. s.slot .. " " .. Amount(a.bags, a.bank)
      if not newest or a.time > newest then newest = a.time end
    end
  end
  if #parts == 0 then return nil end
  return "Team: " .. table.concat(parts, ", ") .. " (" .. Ago(GetTime() - newest) .. ")"
end

---------------------------------------------------------------------------
-- Asking and collecting
---------------------------------------------------------------------------
local function Collect(itemID)
  local p = pending[itemID]
  pending[itemID] = nil
  if not p then return end
  local answers, any, me = Find.cache[itemID] or {}, false, ns.MyName()
  for _, s in ipairs(SlotList()) do
    if s.name ~= me then
      local a = p.got[s.name] and answers[s.name]
      if a then
        if Positive(a) or not a.bags then
          any = true
          ns.Print(string.format("slot%d %s %s", s.slot, s.name, Amount(a.bags, a.bank)))
        end
      elseif ns.UnitOf(s.name) then
        ns.Print(string.format("no answer from slot%d %s", s.slot, s.name))
      end
    end
  end
  if not any then ns.Print("nobody else has " .. Label(itemID)) end
end

function Find.Ask(itemID, how)
  local bags, bank = Find.Count(itemID)
  ns.Debug("find " .. itemID .. " (" .. tostring(how) .. ")")
  ns.Print(string.format("find %s: you have %s", Label(itemID), Amount(bags, bank)))
  if pending[itemID] then return false end -- asked less than COLLECT s ago: that collector prints
  if not ns.SendTeam("Q", itemID) then
    ns.Print("cannot ask the team: messages are off (no slot, no token or Mama disabled)")
    return false
  end
  pending[itemID] = { got = {} }
  ns.After(COLLECT, function() Collect(itemID) end)
  return true
end

ns.AddCommand("find", "find <item link|id|name> - how many of an item each team window holds", function(rest)
  local id, how = Find.ItemID(rest)
  if not id then
    ns.Print("usage: /mama plus find <item link, item ID or exact item name>")
    return
  end
  Find.Ask(id, how)
end)

-- Receivers. Mama verified the sender; the body is plain. Q is answered by
-- reading our own bags only; A fills the cache and the open collector.
ns.ops.Q = function(sender, body)
  local id = tonumber((strsplit(";", body)))
  if not id or id ~= math.floor(id) or id < 1 or id > MAX_ID then return end
  local bags, bank = Find.Count(id)
  ns.Whisper(sender, "A", id, bags or "?", bank or "-")
end

ns.ops.A = function(sender, body)
  local id, bags, bank = strsplit(";", body)
  id = tonumber(id)
  if not id or id ~= math.floor(id) or id < 1 or id > MAX_ID then return end
  Find.Store(id, sender, tonumber(bags), tonumber(bank))
  local p = pending[id]
  if p then p.got[sender] = true end
end

---------------------------------------------------------------------------
-- Tooltip line (cache only, never a message)
---------------------------------------------------------------------------
local function OnTooltip(tooltip, data)
  if type(tooltip) ~= "table" or type(tooltip.GetName) ~= "function" then return end
  local ok, name = pcall(tooltip.GetName, tooltip)
  if not ok or IsSecret(name) or (name ~= "GameTooltip" and name ~= "ItemRefTooltip") then return end
  if type(data) ~= "table" then return end
  local id = data.id
  Find.lastTooltip = string.format("%s: data %s, id %s%s", name, type(data), type(id), IsSecret(id) and " (secret)" or "")
  id = ns.PlainNumber(id)
  if not id and TooltipUtil and TooltipUtil.GetDisplayedItem then
    local ok2, _, _, shown = pcall(TooltipUtil.GetDisplayedItem, tooltip)
    id = ok2 and ns.PlainNumber(shown) or nil
  end
  if not id or not ns.OptionOn("findTooltip") then return end
  local line = Find.Summary(id)
  if line and tooltip.AddLine then tooltip:AddLine(line, 0.6, 0.9, 1) end
end

ns.Listen("LOGIN", function()
  local tdp = TooltipDataProcessor
  local kind = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
  if type(tdp) ~= "table" or type(tdp.AddTooltipPostCall) ~= "function" or type(kind) ~= "number" then
    Find.tooltipHook = false
    return
  end
  Find.tooltipHook = pcall(tdp.AddTooltipPostCall, kind, function(tooltip, data)
    xpcall(function() OnTooltip(tooltip, data) end, ns.Report)
  end)
end)

---------------------------------------------------------------------------
-- Status line and probe
---------------------------------------------------------------------------
ns.Listen("STATUS_COMMAND", function()
  ns.Print(string.format("find: %d cached item%s, tooltip line %s", #Find.order, #Find.order == 1 and "" or "s",
    Find.tooltipHook and (ns.OptionOn("findTooltip") and "on" or "off") or "unavailable"))
end)

local function Describe(ok, v)
  if not ok then return "error or missing" end
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  return tostring(v) .. " (" .. type(v) .. ")"
end

-- Lines for /mama plus probe find (design probes P1-P5): returned, and
-- appended to the table given as the argument when there is one.
ns.AddProbe("find", function(out)
  local items = C_Item
  local lines = {
    "TooltipDataProcessor: " .. type(TooltipDataProcessor) .. ", AddTooltipPostCall: "
      .. type(TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall),
    "Enum.TooltipDataType.Item: " .. type(Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item)
      .. ", TooltipUtil.GetDisplayedItem: " .. type(TooltipUtil and TooltipUtil.GetDisplayedItem),
    "tooltip hook: " .. tostring(Find.tooltipHook) .. ", last tooltip: " .. tostring(Find.lastTooltip),
    "GetItemCount(6265): " .. Describe(ns.Try(items and items.GetItemCount, 6265)),
    "GetItemCount(6265, true): " .. Describe(ns.Try(items and items.GetItemCount, 6265, true)),
    "GetItemInfoInstant(Linen Cloth): " .. Describe(ns.Try(items and items.GetItemInfoInstant, "Linen Cloth")),
    "GetItemInfoInstant(item:2589): " .. Describe(ns.Try(items and items.GetItemInfoInstant, "item:2589")),
    "cache: " .. #Find.order .. " items",
  }
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
