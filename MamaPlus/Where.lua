local addonName, ns = ...

-- Where: this window's level, XP, rested XP, zone and movement facts ride
-- the heartbeat (fields l level, x XP % floored to 5, r rested % floored
-- to 10, z zone and s subzone cut to 20 bytes, k class; flags t on a taxi,
-- i resting), re-sent soon after a level-up, a new area, resting or taxi
-- changes. From the team's records every row gets: the level number, only
-- red below the level gate or orange levelGap+ levels below the lead (else
-- a tooltip line "level 12, 35% xp, rested 40%"); ZONE when not in the
-- lead's zone (tooltip "zone: subzone"); FLY on a flight; and, on the lead
-- window only, FAR when a grouped member is out of follow range, sampled
-- every 2 s with CheckInteractDistance(unit, 4) while both sides are out
-- of combat (no sample, so a frozen icon, while either fights). The gate
-- (/mama plus gate N|off) is per faction, saved, and told to the group as
-- "x;G;<N>" (0 = off); a received G only sets the same local value.

local Where = {}
ns.Where = Where

local IsSecret = ns.IsSecret
local FAR_TICK = 2
local EVENTS = { "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_UPDATE_RESTING",
  "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED" }

ns.AddDefaults({ levelGap = 3 })
ns.AddOption({ key = "levelGap", label = "Orange level when this many below the lead", section = "Team rows",
  type = "number", min = 1, max = 20, step = 1, onChange = function() ns.Rows.Refresh() end,
  tip = "The level shows on a row only when it is below the level gate (red) or at least this many levels below "
    .. "the lead (orange); otherwise it is in the tooltip." })

---------------------------------------------------------------------------
-- Own readings (plain or nothing)
---------------------------------------------------------------------------
-- First result of an API that may be missing or raise, nil otherwise.
local function Read(fn, ...)
  local ok, v = ns.Try(fn, ...)
  if ok then return v end
  return nil
end
local function Num(fn, ...) return ns.PlainNumber(Read(fn, ...)) end

-- Percent of the level's XP, floored to a step; nil when unknown or zero.
local function Percent(part, step)
  local max = Num(UnitXPMax, "player")
  if not part or not max or max <= 0 or part <= 0 then return nil end
  local pct = math.floor(part / max * 100 / step) * step
  return pct > 0 and pct or nil
end

ns.Status.AddField("l", function() return Num(UnitLevel, "player") end)
ns.Status.AddField("x", function() return Percent(Num(UnitXP, "player"), 5) end)
ns.Status.AddField("r", function() return Percent(Num(GetXPExhaustion), 10) end)
ns.Status.AddField("z", function() return ns.Clean(Read(GetZoneText), 20) end)
ns.Status.AddField("s", function() return ns.Clean(Read(GetSubZoneText), 20) end)
ns.Status.AddField("k", function() return ns.MyClass() end)
ns.Status.AddFlag("t", function() return ns.PlainTrue(Read(UnitOnTaxi, "player")) end)
ns.Status.AddFlag("i", function() return ns.PlainTrue(Read(IsResting)) end)

for _, event in ipairs(EVENTS) do
  ns.On(event, function()
    ns.Debug("where changed:", event)
    ns.Status.Changed()
  end)
end

---------------------------------------------------------------------------
-- Records: a received record keeps a field map, our own Local() a list of "k=v".
---------------------------------------------------------------------------
local function Field(rec, key)
  local v = rec.fields[key]
  if v ~= nil then return v end
  for _, f in ipairs(rec.fields) do
    local k, val = f:match("^(%w+)=(.*)$")
    if k == key then return val end
  end
  return nil
end

local function HasFlag(rec, letter)
  return type(rec.flags) == "string" and rec.flags:find(letter, 1, true) ~= nil
end

-- "level 12, 35% xp, rested 40%" (parts missing when unknown), or nil without a level.
local function LevelText(rec)
  local level, xp, rested = tonumber(Field(rec, "l")), Field(rec, "x"), Field(rec, "r")
  if not level then return nil end
  return "level " .. level .. (xp and (", " .. xp .. "% xp") or "") .. (rested and (", rested " .. rested .. "%") or "")
end

-- "zone: subzone", or nil without a zone.
local function ZoneText(rec)
  local z, s = Field(rec, "z"), Field(rec, "s")
  if not z or z == "" then return nil end
  return z .. ((s and s ~= "") and (": " .. s) or "")
end

-- The lead's level and zone: own readings on the lead window, else its last heartbeat.
local function LeadFacts()
  local lead = ns.LeadName()
  local rec = lead and ns.Status.RecordFor(lead)
  if not rec then return nil, nil end
  return tonumber(Field(rec, "l")), Field(rec, "z")
end

---------------------------------------------------------------------------
-- Level gate: per faction, saved; "x;G;<N>" (0 = off) only sets the same value elsewhere.
---------------------------------------------------------------------------
local function Faction()
  return ns.PlainOfType(ns.MF and ns.MF.faction, "string", "Neutral")
end

function Where.Gate()
  local gates = ns.db and ns.db.gates
  return type(gates) == "table" and ns.PlainOfType(gates[Faction()], "number", nil) or nil
end

local function SetGate(n)
  if not ns.db then return end
  if type(ns.db.gates) ~= "table" then ns.db.gates = {} end
  ns.db.gates[Faction()] = n
  ns.Rows.Refresh()
end

local function ParseGate(s)
  local n = tonumber(s)
  if not n or n ~= math.floor(n) or n < 0 or n > 99 then return nil end
  return n
end

ns.ops.G = function(sender, body)
  local n = ParseGate((strsplit(";", body)))
  if not n then return end
  SetGate(n > 0 and n or nil)
  ns.Print(n > 0 and ("level gate " .. n) or "level gate off", "(from", ns.Who(sender) .. ")")
end

ns.AddCommand("gate", "gate [N|off] - level gate: a level below N shows red on every window", function(rest)
  rest = (rest or ""):lower()
  if rest ~= "" then
    local n = rest == "off" and 0 or ParseGate(rest)
    if not n then
      ns.Print("usage: gate <1-99|off>")
      return
    end
    SetGate(n > 0 and n or nil)
    ns.Send("G", n)
  end
  local gate = Where.Gate()
  ns.Print(gate and ("level gate " .. gate) or "no level gate", rest ~= "" and "(sent to the group)" or "")
end)

---------------------------------------------------------------------------
-- FAR: the lead window samples its grouped members every 2 s, out of combat.
---------------------------------------------------------------------------
local far = {}     -- name -> true while plainly out of follow range
Where.far = far
local ticker

function Where.SampleFar()
  if ns.PlainTrue(InCombatLockdown()) then return end
  local changed, seen = false, {}
  for name, unit in pairs(ns.MF and ns.MF.roster or {}) do
    seen[name] = true
    local ok, fighting = ns.Try(UnitAffectingCombat, unit)
    if ok and not ns.PlainTrue(fighting) then
      local known, near = ns.Try(CheckInteractDistance, unit, 4)
      local isFar = known and not IsSecret(near) and near == false
      if (far[name] or false) ~= isFar then
        far[name] = isFar or nil
        changed = true
      end
    end
  end
  for name in pairs(far) do
    if not seen[name] then far[name] = nil; changed = true end
  end
  if changed then ns.Rows.Refresh() end
end

function Where.Ticking() return ticker ~= nil end

function Where.UpdateTicker()
  local lead = ns.IsLead()
  local run = lead and not ns.PlainTrue(InCombatLockdown())
  if run and not ticker then
    ticker = ns.Ticker(FAR_TICK, Where.SampleFar)
    Where.SampleFar()
  elseif not run and ticker then
    ticker:Cancel()
    ticker = nil
  end
  if not lead and next(far) then
    wipe(far)
    ns.Rows.Refresh()
  end
end

ns.Listen("TEAM_CHANGED", Where.UpdateTicker)
ns.Listen("LOGIN", Where.UpdateTicker)
ns.On("PLAYER_REGEN_DISABLED", Where.UpdateTicker)
ns.On("PLAYER_REGEN_ENABLED", Where.UpdateTicker)

---------------------------------------------------------------------------
-- Row entries
---------------------------------------------------------------------------
ns.Rows.AddProvider(function(name, out)
  local rec = ns.Status.RecordFor(name)
  if not rec then return end
  local leadLevel, leadZone = LeadFacts()
  local levelText, level = LevelText(rec), tonumber(Field(rec, "l"))
  if levelText then
    local gate = Where.Gate()
    if gate and level < gate then
      out[#out + 1] = { "level", tostring(level), 1, 0.3, 0.3, levelText .. ", below the gate of " .. gate, 8 }
    elseif leadLevel and leadLevel - level >= ns.Setting("levelGap", 3) then
      out[#out + 1] = { "level", tostring(level), 1, 0.6, 0.2, levelText .. ", the lead is " .. leadLevel, 8 }
    else
      out[#out + 1] = { "level", "", 1, 1, 1, levelText, 8 }
    end
  end
  local zoneText = ZoneText(rec)
  if zoneText then
    if leadZone and Field(rec, "z") ~= leadZone then
      out[#out + 1] = { "zone", "ZONE", 1, 0.6, 0.2, zoneText .. " (the lead is in " .. leadZone .. ")", 7 }
    else
      out[#out + 1] = { "zone", "", 1, 1, 1, zoneText, 7 }
    end
  end
  if far[name] and ns.IsLead() then
    out[#out + 1] = { "far", "FAR", 1, 0.3, 0.3, "out of follow range (28 yards)", 6 }
  end
  if HasFlag(rec, "t") then out[#out + 1] = { "fly", "FLY", 0.6, 0.8, 1, "on a flight", 14 } end
end)

---------------------------------------------------------------------------
-- Command, status line, probe
---------------------------------------------------------------------------
ns.AddCommand("where", "one line per slot: level, xp, rested, zone, flight, resting", function()
  local slots = {}
  for slot in pairs(ns.Slots()) do slots[#slots + 1] = slot end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    local name = ns.Slots()[slot]
    local rec = ns.Status.RecordFor(name)
    ns.Print(string.format("slot %d %s: %s", slot, name, rec and (LevelText(rec) or "level ?") .. ", " .. (ZoneText(rec) or "zone ?")
      .. (HasFlag(rec, "t") and ", flying" or "") .. (HasFlag(rec, "i") and ", resting" or "") or "no heartbeat yet"))
  end
end)

local function State()
  local n = 0
  for _ in pairs(far) do n = n + 1 end
  return string.format("gate %s, lead level %s, far %d, far sampler %s", tostring(Where.Gate()), tostring((LeadFacts())), n,
    ticker and "on" or "off")
end
ns.Listen("STATUS_COMMAND", function() ns.Print("where: " .. State()) end)

local function Describe(ok, v)
  if not ok then return "error or missing" end
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  return tostring(v) .. " (" .. type(v) .. ")"
end

-- Lines for /mama plus probe where (design probes W1-W5): returned, and
-- appended to the table given as the argument when there is one.
ns.AddProbe("where", function(out)
  local lines = {}
  local function Add(label, ...) lines[#lines + 1] = label .. ": " .. Describe(...) end
  Add("UnitLevel(player)", ns.Try(UnitLevel, "player"))
  Add("UnitXP(player)", ns.Try(UnitXP, "player"))
  Add("UnitXPMax(player)", ns.Try(UnitXPMax, "player"))
  Add("GetXPExhaustion()", ns.Try(GetXPExhaustion))
  Add("IsResting()", ns.Try(IsResting))
  Add("GetZoneText()", ns.Try(GetZoneText))
  Add("GetSubZoneText()", ns.Try(GetSubZoneText))
  Add("UnitOnTaxi(player)", ns.Try(UnitOnTaxi, "player"))
  Add("CheckInteractDistance(party1, 4)", ns.Try(CheckInteractDistance, "party1", 4))
  Add("UnitAffectingCombat(party1)", ns.Try(UnitAffectingCombat, "party1"))
  for _, event in ipairs(EVENTS) do lines[#lines + 1] = event .. " valid: " .. tostring(ns.EventIsValid(event)) end
  lines[#lines + 1] = "state: " .. State()
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
