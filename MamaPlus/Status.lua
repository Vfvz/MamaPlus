local addonName, ns = ...

-- Heartbeat: each client tells the team its own plain facts every BEAT
-- seconds and, debounced, when something changes:
--   x;H;<version>;<flags>;<minDurability>;<dialogs>[;k=v]...
-- flags:   c in combat, d dead or ghost, a AFK, plus letters feature files
--          add with Status.AddFlag (t taxi, i resting, f following), or "-"
-- minDur:  lowest equipped durability in percent, quantized to 5, or "?"
-- dialogs: T trade, S summon, L loot roll, R ready check, or "-"
-- k=v:     fields feature files add with Status.AddField (level, zone...)
-- Records are keyed by the sender's full name. A grouped member whose
-- heartbeat is overdue is "silent" (the ! icon). Dialogs are only shown,
-- never answered.

local Status = {}
ns.Status = Status

local MF = ns.MF
local IsSecret = ns.IsSecret
local BEAT, STALE, FIRST_BEAT = 30, 75, 8
local DEBOUNCE, MIN_GAP = 1, 3
local MAX_PAYLOAD = 200
Status.BEAT, Status.STALE, Status.FIRST_BEAT = BEAT, STALE, FIRST_BEAT

ns.AddDefaults({ durWarn = 25 })
ns.AddOption({ key = "durWarn", label = "Durability icon below this percent", section = "Team rows",
  type = "number", min = 0, max = 100, step = 5, onChange = function() ns.Rows.Refresh() end })

local flagProviders, fieldProviders = {}, {}
function Status.AddFlag(letter, fn) flagProviders[#flagProviders + 1] = { letter = letter, fn = fn } end
-- max: byte limit of the value (default 24).
function Status.AddField(key, fn, max)
  fieldProviders[#fieldProviders + 1] = { key = key, fn = fn, max = max or 24 }
end

Status.records = {}   -- name -> { version, flags, dur, dialogs, fields = {}, time }

---------------------------------------------------------------------------
-- Local readings
---------------------------------------------------------------------------
local Bool = ns.PlainTrue

local function MinDurability()
  if not GetInventoryItemDurability then return nil end
  local lowest
  for slot = 1, 19 do
    local ok, cur, max = pcall(GetInventoryItemDurability, slot)
    if ok and type(cur) == "number" and type(max) == "number" and not IsSecret(cur) and not IsSecret(max)
      and max > 0 then
      local pct = math.floor(cur / max * 100)
      if not lowest or pct < lowest then lowest = pct end
    end
  end
  if not lowest then return 100 end
  return math.floor(lowest / 5) * 5
end
Status.MinDurability = MinDurability

local dialogs = {}
local DIALOG_TTL = { T = 300, S = 120, L = 180, R = 60 }
local DIALOG_ORDER = { "T", "S", "L", "R" }
Status.DIALOG_NAMES = { T = "trade", S = "summon", L = "loot roll", R = "ready check" }
local lootRolls = {}

local function DialogString()
  local now, out = GetTime(), {}
  for _, k in ipairs(DIALOG_ORDER) do
    if dialogs[k] and dialogs[k] > now then out[#out + 1] = k else dialogs[k] = nil end
  end
  return #out > 0 and table.concat(out) or "-"
end

local function Flags()
  local f = ""
  if Bool(InCombatLockdown()) then f = f .. "c" end
  if UnitIsDeadOrGhost and Bool(UnitIsDeadOrGhost("player")) then f = f .. "d" end
  if UnitIsAFK and Bool(UnitIsAFK("player")) then f = f .. "a" end
  for _, p in ipairs(flagProviders) do
    local ok, on = pcall(p.fn)
    if ok and Bool(on) then f = f .. p.letter end
  end
  return f == "" and "-" or f
end

-- Own record, shaped like a received one (fields = { key = value }), plus
-- list = the ordered "k=v" strings that go into the message.
function Status.Local()
  local fields, list = {}, {}
  for _, p in ipairs(fieldProviders) do
    local ok, v = pcall(p.fn)
    if ok then
      v = ns.Clean(v, p.max)
      if v ~= "" then
        fields[p.key] = v
        list[#list + 1] = p.key .. "=" .. v
      end
    end
  end
  local dur = MinDurability()
  return { version = ns.Version(), flags = Flags(), dur = dur, dialogs = DialogString(), fields = fields, list = list,
    time = GetTime(), me = true }
end

-- Message parts after "x;H". Trailing fields are dropped while the payload is too long.
function Status.Parts(s)
  local parts = { s.version, s.flags, s.dur and tostring(s.dur) or "?", s.dialogs }
  for _, f in ipairs(s.list) do parts[#parts + 1] = f end
  while #parts > 4 and #ns.Payload("H", unpack(parts)) > MAX_PAYLOAD do table.remove(parts) end
  return parts
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local lastSent, lastSentAt, sendQueued, gapQueued = nil, nil, false, false

local function Transmit(parts)
  lastSent = table.concat(parts, ";")
  lastSentAt = GetTime()
  return ns.Send("H", unpack(parts))
end

-- force: on the beat; otherwise only when the message changed, at most one per MIN_GAP.
function Status.Send(force)
  if not ns.CanSend(true) then return false end
  local parts = Status.Parts(Status.Local())
  local msg = table.concat(parts, ";")
  if not force and msg == lastSent then return false end
  if not force and lastSentAt and GetTime() - lastSentAt < MIN_GAP then
    if not gapQueued then
      gapQueued = true
      ns.After(MIN_GAP - (GetTime() - lastSentAt), function()
        gapQueued = false
        Status.Send(false)
      end)
    end
    return false
  end
  return Transmit(parts)
end

-- Debounced "something changed on this client".
function Status.Changed()
  ns.Rows.Refresh()
  if sendQueued then return end
  sendQueued = true
  ns.After(DEBOUNCE, function()
    sendQueued = false
    Status.Send(false)
  end)
end

-- One heartbeat to a single member (whisper: works before we are grouped).
function Status.SendTo(name)
  if not ns.CanSend(false) then return false end
  local parts = Status.Parts(Status.Local())
  return ns.Whisper(name, "H", unpack(parts))
end

local started = false
function Status.Start()
  if started then return end
  started = true
  local function Beat()
    ns.After(BEAT, Beat) -- schedule first: an error below never stops the heartbeat
    xpcall(function() Status.Send(true) end, ns.Report)
    ns.Rows.Refresh()
  end
  ns.After(FIRST_BEAT, Beat)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
-- One live timer per sender: a redraw once its record would go silent, so
-- the ! icon appears without a message. The timer re-arms from the newest
-- record while heartbeats keep coming and ends when the record is stale.
local staleArmed = {}
local function ArmStale(sender)
  local rec = Status.records[sender]
  if staleArmed[sender] or not rec or GetTime() - rec.time > STALE then return end
  staleArmed[sender] = true
  ns.After(rec.time + STALE + 0.5 - GetTime(), function()
    staleArmed[sender] = nil
    ns.Rows.Refresh()
    ArmStale(sender)
  end)
end

ns.ops.H = function(sender, body)
  local list = { strsplit(";", body) }
  local version, flags, dur, dlg = list[1], list[2], list[3], list[4]
  if not dlg then return end
  local old = Status.records[sender]
  local rec = { version = version, flags = flags, dur = tonumber(dur), dialogs = dlg, fields = {}, time = GetTime(),
    sender = sender }
  for i = 5, #list do
    local k, v = list[i]:match("^(%w+)=(.*)$")
    if k then rec.fields[k] = v end
  end
  Status.records[sender] = rec
  ns.Fire("HEARTBEAT", sender, rec, old)
  ns.Rows.Refresh()
  ArmStale(sender)
end

function Status.RecordFor(name)
  if name == ns.MyName() then return Status.Local() end
  return Status.records[name]
end

function Status.Field(name, key)
  local rec = Status.RecordFor(name)
  return rec and rec.fields[key] or nil
end

function Status.HasFlag(name, letter)
  local rec = Status.RecordFor(name)
  if not rec or not rec.flags then return false end
  return rec.flags:find(letter, 1, true) ~= nil
end

-- Overdue heartbeat of a grouped member (and we are not the ones held by chat lockdown).
function Status.IsStale(name)
  if name == ns.MyName() then return false end
  local rec = Status.records[name]
  if not rec or not ns.UnitOf(name) then return false end
  return GetTime() - rec.time > STALE and not ns.InLockdown()
end

-- Drop records of names that are neither grouped with us nor in a team slot.
function Status.Prune()
  local keep = {}
  for _, name in pairs(ns.Slots()) do keep[name] = true end
  for name in pairs(MF and MF.roster or {}) do keep[name] = true end
  for name in pairs(Status.records) do
    if not keep[name] then Status.records[name] = nil end
  end
end

---------------------------------------------------------------------------
-- Row icons
---------------------------------------------------------------------------
local function Pct(v) return math.floor(v + 0.5) end

ns.Rows.AddProvider(function(name, out)
  local rec = Status.RecordFor(name)
  if not rec then return end
  if Status.IsStale(name) then
    out[#out + 1] = { "live", "!", 1, 0.3, 0.3,
      string.format("no message for %d s: client frozen, offline or MamaPlus off", Pct(GetTime() - rec.time)), 1 }
  end
  local flags = rec.flags or "-"
  if flags:find("d", 1, true) then
    -- the desk (DeathDesk.lua), when loaded, adds the richer "dead 0:42, auto-release 12 s" tooltip line
    out[#out + 1] = { "dead", "X", 1, 0.2, 0.2, (not ns.DeathDesk) and "dead" or nil, 2 }
  end
  if rec.dialogs and rec.dialogs ~= "-" then
    local names = {}
    for i = 1, #rec.dialogs do names[#names + 1] = Status.DIALOG_NAMES[rec.dialogs:sub(i, i)] or "?" end
    out[#out + 1] = { "dialog", rec.dialogs, 0.4, 0.8, 1, "waiting: " .. table.concat(names, ", "), 10 }
  end
  if flags:find("a", 1, true) then out[#out + 1] = { "afk", "AFK", 1, 0.8, 0.2, "AFK", 11 } end
  local durWarn = ns.Setting("durWarn", 25)
  if rec.dur and rec.dur < durWarn then
    out[#out + 1] = { "dur", rec.dur .. "%", 1, 0.3, 0.3, "lowest item at " .. rec.dur .. "% durability", 12 }
  end
  if not rec.me and rec.version and rec.version ~= ns.Version() then
    out[#out + 1] = { "version", "v" .. rec.version, 1, 0.6, 0.2,
      "runs MamaPlus " .. rec.version .. ", you run " .. ns.Version(), 15 }
  end
end)

---------------------------------------------------------------------------
-- Local events
---------------------------------------------------------------------------
local function Open(k) dialogs[k] = GetTime() + DIALOG_TTL[k]; Status.Changed() end
local function Close(k) if dialogs[k] then dialogs[k] = nil; Status.Changed() end end

ns.On("TRADE_SHOW", function() Open("T") end)
ns.On("TRADE_CLOSED", function() Close("T") end)
ns.On("CONFIRM_SUMMON", function() Open("S") end)
ns.On("CANCEL_SUMMON", function() Close("S") end)
ns.On("READY_CHECK", function() Open("R") end)
ns.On("READY_CHECK_FINISHED", function() Close("R") end)
ns.On("READY_CHECK_CONFIRM", function(unit)
  if not IsSecret(unit) and unit == "player" then Close("R") end
end)
ns.On("START_LOOT_ROLL", function(rollID)
  if IsSecret(rollID) or rollID == nil then rollID = "?" end
  lootRolls[rollID] = true
  Open("L")
end)
ns.On("CANCEL_LOOT_ROLL", function(rollID)
  if IsSecret(rollID) or rollID == nil then wipe(lootRolls) else lootRolls[rollID] = nil end
  if next(lootRolls) == nil then Close("L") end
end)

-- A new 5 % step sends at once out of combat. In combat only a crossing of
-- durWarn does (that changes the icon); the rest rides the REGEN_ENABLED send.
local lastDur
ns.On("UPDATE_INVENTORY_DURABILITY", function()
  local d = MinDurability()
  if d == lastDur then return end
  local warn = ns.Setting("durWarn", 25)
  local crossed = ((d or 100) < warn) ~= ((lastDur or 100) < warn)
  lastDur = d
  if crossed or not Bool(InCombatLockdown()) then Status.Changed() else ns.Rows.Refresh() end
end)
ns.On("PLAYER_DEAD", function() Status.Changed() end)
ns.On("PLAYER_ALIVE", function() Status.Changed() end)
ns.On("PLAYER_UNGHOST", function() Status.Changed() end)
ns.OnUnit("PLAYER_FLAGS_CHANGED", "player", function() Status.Changed() end)
ns.On("PLAYER_REGEN_DISABLED", function() Status.Changed() end)
ns.On("PLAYER_REGEN_ENABLED", function() Status.Changed() end)

-- Roster: a real change of who is grouped (Mama fires TEAM_CHANGED far more
-- often). A newcomer has no record of us yet, so the next send goes out even
-- when nothing changed (lastSent = nil); the debounce and MIN_GAP still apply.
local lastRoster, rosterNames = "", {}
local function RosterKey()
  local names = {}
  for name in pairs(MF and MF.roster or {}) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ";"), names
end
-- Remembers the names; true when one of them was not grouped before.
local function RosterGrew(names)
  local grew, set = false, {}
  for _, name in ipairs(names) do
    set[name] = true
    if not rosterNames[name] then grew = true end
  end
  rosterNames = set
  return grew
end
ns.Listen("TEAM_CHANGED", function()
  local key, names = RosterKey()
  if key == lastRoster then return end
  lastRoster = key
  if RosterGrew(names) then lastSent = nil end
  Status.Prune()
  Status.Changed()
end)

-- A member we just heard from (new to Mama, or announcing a login or reload):
-- grouped ones get a send even when unchanged, others one whisper.
ns.Listen("MEMBER_SEEN", function(name)
  if type(name) ~= "string" or IsSecret(name) then return end
  if ns.UnitOf(name) then
    lastSent = nil
    Status.Changed()
  else
    ns.After(1, function() Status.SendTo(name) end)
  end
end)

ns.Listen("LOGIN", function()
  lastDur = MinDurability()
  local key, names = RosterKey()
  lastRoster = key
  RosterGrew(names)
  Status.Start()
end)

ns.AddCommand("team", "one line per team member: version, flags, durability, dialogs, fields", function()
  for slot, name in pairs(ns.Slots()) do
    local rec = Status.RecordFor(name)
    if rec then
      local fields = {}
      for k, v in pairs(rec.fields) do fields[#fields + 1] = k .. "=" .. v end
      table.sort(fields)
      ns.Print(string.format("slot %d %s: v%s flags %s dur %s dialogs %s %s%s", slot, name, tostring(rec.version),
        tostring(rec.flags), tostring(rec.dur), tostring(rec.dialogs), table.concat(fields, " "),
        rec.me and "" or string.format(" (%d s ago%s)", Pct(GetTime() - rec.time), Status.IsStale(name) and ", SILENT" or "")))
    else
      ns.Print(string.format("slot %d %s: no heartbeat yet", slot, name))
    end
  end
end)
