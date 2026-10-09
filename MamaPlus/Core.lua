local addonName, ns = ...

-- MamaPlus: companion to Mama-forever (WoW: Forever, Interface 16001).
-- Core: namespace, secret-value helpers, private event frame, saved
-- variables and options registry, the "/mama plus" command tree, the
-- signed-message path through Mama (one Mama letter, "x", with our own
-- sub-kinds inside it, behind a keyed rate limiter), and shared helpers
-- (lead, hardcore, movement, blocked actions, probes).
-- Everything here acts only on this client: nothing in MamaPlus ever makes
-- another window perform an action because of a message.

ns.name = addonName
ns.LETTER = "x"           -- Mama message kind letter MamaPlus owns (payload "x;<sub>;...")
ns.handlers = {}
ns.defaults = { debug = false }

local MF = _G.MamaForever
ns.MF = MF

---------------------------------------------------------------------------
-- Secret-value helpers (site Rule 7). type() is safe on a secret; math,
-- compare, boolean test, index, table key, concat into a message and print
-- are not. Ask IsSecret first, always.
---------------------------------------------------------------------------
local function IsSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v) or false
end
ns.IsSecret = IsSecret

function ns.Plain(v, fallback)
  if IsSecret(v) or v == nil then return fallback end
  return v
end

function ns.PlainOfType(v, wanted, fallback)
  if type(v) ~= wanted or IsSecret(v) then return fallback end
  return v
end

function ns.PlainNumber(v) return ns.PlainOfType(v, "number", nil) end

-- True only for a plain truthy value.
function ns.PlainTrue(v)
  if IsSecret(v) then return false end
  return v and true or false
end

-- Calls an API that may be missing or may raise: ok, first result.
function ns.Try(fn, ...)
  if type(fn) ~= "function" then return false end
  local ok, v = pcall(fn, ...)
  if not ok then return false end
  return true, v
end

-- A string fit for a message or a print: "" when secret or not a string,
-- colour codes and links stripped, our delimiters replaced, cut to max
-- bytes without splitting a UTF-8 character.
function ns.Clean(s, max)
  if IsSecret(s) then return "" end
  if type(s) == "number" then s = tostring(s) end
  if type(s) ~= "string" then return "" end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", "")
  s = s:gsub("[;:|=]", " "):gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
  if max and #s > max then
    local j = max
    while j > 0 do
      local b = s:byte(j + 1)
      if not b or b < 128 or b >= 192 then break end
      j = j - 1
    end
    s = s:sub(1, j)
  end
  return s
end

function ns.EventIsValid(event)
  if C_EventUtils and C_EventUtils.IsEventValid then
    local ok, v = pcall(C_EventUtils.IsEventValid, event)
    if not ok then return false end
    return ns.PlainTrue(v)
  end
  return true
end

function ns.Version()
  local v = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")
  return ns.PlainOfType(v, "string", "?")
end

---------------------------------------------------------------------------
-- Output: through Mama's Print/Debug (so it lands in /mama bug too), with
-- every argument sanitised first. Debug lines are for state changes only,
-- never one per message.
---------------------------------------------------------------------------
local function Join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if IsSecret(v) then
      parts[#parts + 1] = "<secret " .. type(v) .. ">"
    else
      parts[#parts + 1] = tostring(v)
    end
  end
  return table.concat(parts, " ")
end

function ns.Print(...)
  local text = Join(...)
  if MF and MF.Print then
    MF:Print("|cFF99E5FF+|r %s", text)
  else
    print("MamaPlus: " .. text)
  end
end

function ns.Debug(...)
  if not (ns.db and ns.db.debug) then return end
  local text = Join(...)
  if MF and MF.Debug then
    MF:Debug("plus: %s", text)
  else
    print("MamaPlus debug: " .. text)
  end
end

local function Report(err)
  local handler = type(geterrorhandler) == "function" and geterrorhandler()
  if handler then handler(err) else ns.Print("|cffff4040error:|r", err) end
end
ns.Report = Report

---------------------------------------------------------------------------
-- Events: one private frame, a handler table, validity-guarded
-- registration, each handler in its own xpcall. Unit events get their own
-- frame so RegisterUnitEvent filters them.
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.eventFrame = frame

local function Dispatch(list, ...)
  local n, args = select("#", ...), { ... }
  for i = 1, #list do
    local handler = list[i]
    xpcall(function() return handler(unpack(args, 1, n)) end, Report)
  end
end

function ns.On(event, fn)
  local list = ns.handlers[event]
  if not list then
    if not ns.EventIsValid(event) then
      ns.Debug("event not valid on this client:", event)
      return false
    end
    -- without a validity check, RegisterEvent itself raises on an unknown name
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns.Debug("cannot register event:", event, err)
      return false
    end
    list = {}
    ns.handlers[event] = list
  end
  list[#list + 1] = fn
  return true
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = ns.handlers[event]
  if list then Dispatch(list, ...) end
end)

function ns.OnUnit(event, unit, fn)
  if not ns.EventIsValid(event) then
    ns.Debug("unit event not valid on this client:", event)
    return false
  end
  local f = CreateFrame("Frame")
  local ok, err
  if f.RegisterUnitEvent then
    ok, err = pcall(f.RegisterUnitEvent, f, event, unit)
  else
    ok, err = pcall(f.RegisterEvent, f, event)
  end
  if not ok then
    ns.Debug("cannot register unit event:", event, err)
    return false
  end
  f:SetScript("OnEvent", function(_, _, ...) Dispatch({ fn }, ...) end)
  return true
end

---------------------------------------------------------------------------
-- Internal callbacks. Mama's names (LOGIN, TEAM_CHANGED, MEMBER_SEEN,
-- STATS, PROFESSIONS, OPTION_CHANGED) are bridged from MF:Listen the first
-- time someone listens; our own names (HEARTBEAT, RECORD, ...) are local.
---------------------------------------------------------------------------
local listeners, bridged = {}, {}
local MAMA_EVENTS = { LOGIN = true, TEAM_CHANGED = true, MEMBER_SEEN = true, STATS = true,
  PROFESSIONS = true, OPTION_CHANGED = true }

function ns.Fire(name, ...)
  local list = listeners[name]
  if list then Dispatch(list, ...) end
end

function ns.Listen(name, fn)
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], fn)
  if MAMA_EVENTS[name] and not bridged[name] and MF and MF.Listen then
    bridged[name] = true
    MF:Listen(name, function(_, ...)
      if name == "LOGIN" then ns.loggedIn = true end
      ns.Fire(name, ...)
    end)
  end
end

---------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------
function ns.After(delay, fn)
  if C_Timer and C_Timer.After then C_Timer.After(delay, fn) else fn() end
end

-- Repeating timer with :Cancel(); C_Timer.NewTicker, else an After chain.
function ns.Ticker(interval, fn)
  if C_Timer and C_Timer.NewTicker then
    return C_Timer.NewTicker(interval, fn)
  end
  local t = { cancelled = false }
  function t:Cancel() self.cancelled = true end
  local function Tick()
    if t.cancelled then return end
    fn(t)
    if not t.cancelled then ns.After(interval, Tick) end
  end
  ns.After(interval, Tick)
  return t
end

local regenQueue = {}
function ns.RunOutOfCombat(key, fn)
  if not InCombatLockdown() then
    fn()
    return true
  end
  regenQueue[key] = fn
  return false
end

ns.On("PLAYER_REGEN_ENABLED", function()
  local queued = regenQueue
  regenQueue = {}
  for _, fn in pairs(queued) do fn() end
end)

---------------------------------------------------------------------------
-- Saved variables and options registry
---------------------------------------------------------------------------
function ns.AddDefaults(tbl)
  for k, v in pairs(tbl) do
    if ns.defaults[k] == nil then ns.defaults[k] = v end
  end
end

-- spec = { key, label, section, type = "toggle"|"number", min, max, step, tip,
--          onChange = function(value), enabledWhen = function() -> bool, note }
ns.optionSpecs = {}
function ns.AddOption(spec)
  ns.optionSpecs[#ns.optionSpecs + 1] = spec
end

function ns.SetOption(key, value)
  if not ns.db then return end
  ns.db[key] = value
  for _, spec in ipairs(ns.optionSpecs) do
    if spec.key == key and spec.onChange then spec.onChange(value) end
  end
  if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
end

-- Plain number setting with a fallback (never compares a secret).
function ns.Setting(key, fallback)
  local v = ns.db and ns.db[key]
  return ns.PlainOfType(v, "number", fallback)
end

function ns.OptionOn(key)
  local v = ns.db and ns.db[key]
  if IsSecret(v) then return false end
  return v ~= false and v ~= nil
end

ns.On("ADDON_LOADED", function(loaded)
  if loaded ~= addonName then return end
  MamaPlusDB = MamaPlusDB or {}
  for k, v in pairs(ns.defaults) do
    if MamaPlusDB[k] == nil then MamaPlusDB[k] = v end
  end
  ns.db = MamaPlusDB
  frame:UnregisterEvent("ADDON_LOADED")
  ns.handlers["ADDON_LOADED"] = nil
  ns.Fire("DB_READY")
end)

---------------------------------------------------------------------------
-- Commands: "/mama plus <sub> ..." (and /mamaplus as a fallback alias).
---------------------------------------------------------------------------
ns.commands, ns.commandOrder = {}, {}
function ns.AddCommand(sub, help, fn)
  sub = sub:lower()
  if not ns.commands[sub] then ns.commandOrder[#ns.commandOrder + 1] = sub end
  ns.commands[sub] = { help = help, fn = fn }
end

local function Help()
  ns.Print("MamaPlus " .. ns.Version() .. " commands (|cFF99E5FF/mama plus <command>|r):")
  for _, sub in ipairs(ns.commandOrder) do
    ns.Print(string.format("  |cFF99E5FF%s|r - %s", sub, ns.commands[sub].help))
  end
end

function ns.RunCommand(msg)
  msg = type(msg) == "string" and not IsSecret(msg) and msg or ""
  local sub, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
  sub = (sub or ""):lower()
  local c = ns.commands[sub]
  if c then
    xpcall(function() c.fn(rest) end, Report)
  elseif sub == "" or sub == "help" then
    Help()
  else
    ns.Print("unknown command: " .. sub)
    Help()
  end
end

SLASH_MAMAPLUS1 = "/mamaplus"
SlashCmdList["MAMAPLUS"] = ns.RunCommand

if MF and MF.AddCommand then
  if MF.commands and MF.commands.plus then
    ns.Print("|cffff4040/mama plus is already taken by another addon: use /mamaplus|r")
  else
    MF:AddCommand("plus", function(_, rest) ns.RunCommand(rest) end,
      "plus [command] - MamaPlus: row icons, alerts, supplies, find, keys (/mama plus for the list)")
  end
end

---------------------------------------------------------------------------
-- Team helpers (all through Mama's tables, read at call time)
---------------------------------------------------------------------------
function ns.Slots()
  return MF and MF.db and MF.db.slots or {}
end

function ns.MySlot()
  local s = MF and MF.db and MF.db.slot
  return ns.PlainOfType(s, "number", 0)
end

function ns.MyName()
  return MF and MF.myName or nil
end

function ns.SlotOf(name)
  if not (MF and MF.SlotOf and name) then return nil end
  return MF:SlotOf(name)
end

function ns.IsTeamMember(name)
  return ns.SlotOf(name) ~= nil
end

function ns.Disabled()
  return MF and MF.Disabled and MF:Disabled() or false
end

-- The lead's full name (Mama's explicit lead, else the group leader), or nil when alone.
function ns.LeadName()
  if not (MF and MF.GetLead) then return nil end
  local lead = MF:GetLead()
  if lead then return lead end
  if ns.PlainTrue(IsInGroup()) then return MF.myName end
  return nil
end

-- True when this window is Mama's lead of a group (Dialogs.lua iAmLead).
function ns.IsLead()
  if not (MF and MF.GetLead) or not ns.PlainTrue(IsInGroup()) or ns.Disabled() then return false end
  local lead = MF:GetLead()
  return lead == nil or lead == MF.myName
end

-- Unit token of a team member we are grouped with, or nil.
function ns.UnitOf(name)
  return name and MF and MF.roster and MF.roster[name] or nil
end

-- "slot 2 First Last" ("Slot 2 First Last" with capital = true) or just the name.
function ns.Who(name, capital)
  local slot = ns.SlotOf(name)
  return (slot and ((capital and "Slot " or "slot ") .. slot .. " ") or "") .. tostring(name)
end

function ns.MyClass()
  local ok, _, classFile = pcall(UnitClass, "player")
  if not ok then return nil end
  return ns.PlainOfType(classFile, "string", nil)
end

-- true/false when the client answers plainly, nil when unknown (automation treats nil as Hardcore).
function ns.IsHardcore()
  if C_GameRules and C_GameRules.IsHardcoreActive then
    local ok, v = pcall(C_GameRules.IsHardcoreActive)
    if ok and type(v) == "boolean" and not IsSecret(v) then return v end
  end
  if C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule and Enum.GameRule.HardcoreRuleset then
    local ok, v = pcall(C_GameRules.IsGameRuleActive, Enum.GameRule.HardcoreRuleset)
    if ok and type(v) == "boolean" and not IsSecret(v) then return v end
  end
  return nil
end

-- Own movement: true/false when the client says so plainly, nil when it is
-- secret or unavailable. The first secret answer is reported once.
ns.moveSecret = false
function ns.Moving()
  if IsPlayerMoving then
    local ok, v = pcall(IsPlayerMoving)
    if ok and type(v) == "boolean" and not IsSecret(v) then return v end
  end
  if GetUnitSpeed then
    local ok, v = pcall(GetUnitSpeed, "player")
    if ok and type(v) == "number" and not IsSecret(v) then return v > 0 end
    if ok and IsSecret(v) and not ns.moveSecret then
      ns.moveSecret = true
      ns.Print("movement is secret on this client: idle and stuck detection are off here")
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Blocked actions: ADDON_ACTION_FORBIDDEN / BLOCKED naming this addon.
---------------------------------------------------------------------------
ns.blocked = { count = 0, last = nil }
local blockedWatchers = {}
function ns.OnBlocked(fn) blockedWatchers[#blockedWatchers + 1] = fn end

local function Blocked(addon, func)
  if IsSecret(addon) or IsSecret(func) then return end
  if addon ~= addonName then return end
  ns.blocked.count = ns.blocked.count + 1
  ns.blocked.last = tostring(func)
  ns.Debug("blocked action:", func)
  for _, fn in ipairs(blockedWatchers) do xpcall(function() fn(func) end, Report) end
end
ns.On("ADDON_ACTION_FORBIDDEN", Blocked)
ns.On("ADDON_ACTION_BLOCKED", Blocked)

---------------------------------------------------------------------------
-- Probes: sections of "name: value" lines (Probe.lua prints them). A probe
-- fn gets one argument, add: call add(name, value) per line (value rendered
-- secret-safely); add also works as a table (add[#add + 1] = line).
---------------------------------------------------------------------------
ns.probes, ns.probeOrder = {}, {}
function ns.AddProbe(section, fn)
  if not ns.probes[section] then ns.probeOrder[#ns.probeOrder + 1] = section end
  ns.probes[section] = ns.probes[section] or {}
  table.insert(ns.probes[section], fn)
end

---------------------------------------------------------------------------
-- Messages. Payload "x;<sub>;<part>;<part>..." signed and sent by Mama.
-- A keyed limiter sits in front of Mama's queue: one pending message per
-- key (the newest replaces an unsent one), a token bucket (BURST now,
-- +1 every REFILL seconds), drained by priority, held during chat lockdown.
-- The key is the sub for state messages (H, I, F, G: the newest state is
-- the one to send; plus the name for whispers) and the sub plus the first
-- part for event messages (R;<op>, Q;<item>, A;<item> per asker), so a
-- pending lead cancel R;c is never swallowed by a later R;r or R;x.
---------------------------------------------------------------------------
local BURST, REFILL = 6, 2
local PRIO = { R = 1, I = 2, F = 3, G = 4, H = 5, Q = 6, A = 7 }
local EVENT_SUBS = { R = true, Q = true, A = true }   -- keyed by their first part
ns.ops = {}                       -- sub -> function(sender, body)
ns.comms = { sent = 0, replaced = 0, held = 0, secret = 0, dropped = 0 }
ns.commsOff = false
local pending, pendingOrder = {}, {}
local bucket, lastRefill = BURST, nil
local drainScheduled = false

function ns.Payload(sub, ...)
  local parts = { ns.LETTER, sub }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if IsSecret(v) then
      ns.comms.secret = ns.comms.secret + 1
      v = ""
    elseif v == nil then
      v = ""
    elseif type(v) == "number" then
      v = tostring(v)
    elseif type(v) ~= "string" then
      v = tostring(v)
    end
    parts[#parts + 1] = (v:gsub(";", ","))
  end
  return table.concat(parts, ";")
end

local function CanSend(group)
  if ns.commsOff or not MF then return false end
  if ns.MySlot() <= 0 then return false end
  if not (MF.Token and MF:Token()) then return false end
  if ns.Disabled() then return false end
  if group and not ns.PlainTrue(IsInGroup()) then return false end
  return true
end
ns.CanSend = CanSend

local function InLockdown()
  if not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then return false end
  local ok, v = pcall(C_ChatInfo.InChatMessagingLockdown)
  return ok and ns.PlainTrue(v)
end
ns.InLockdown = InLockdown

local function Refill()
  local now = GetTime()
  if not lastRefill then lastRefill = now return end
  local n = math.floor((now - lastRefill) / REFILL)
  if n > 0 then
    bucket = math.min(BURST, bucket + n)
    lastRefill = lastRefill + n * REFILL
  end
end

local Drain

local function ScheduleDrain(delay)
  if drainScheduled then return end
  drainScheduled = true
  ns.After(delay, function()
    drainScheduled = false
    Drain()
  end)
end

local function NextKey()
  local best, bestPrio, bestIdx
  for i, key in ipairs(pendingOrder) do
    local p = pending[key]
    if p then
      local prio = PRIO[p.sub] or 9
      if not best or prio < bestPrio then best, bestPrio, bestIdx = key, prio, i end
    end
  end
  return best, bestIdx
end

Drain = function()
  Refill()
  while bucket > 0 do
    local key, idx = NextKey()
    if not key then break end
    if InLockdown() then
      ns.comms.held = ns.comms.held + 1
      ScheduleDrain(1)
      return
    end
    local p = pending[key]
    pending[key] = nil
    table.remove(pendingOrder, idx)
    bucket = bucket - 1
    ns.comms.sent = ns.comms.sent + 1
    xpcall(p.send, Report)
  end
  if next(pending) then ScheduleDrain(REFILL) end
end

local function Queue(key, sub, send)
  if pending[key] then
    ns.comms.replaced = ns.comms.replaced + 1
  else
    pendingOrder[#pendingOrder + 1] = key
  end
  pending[key] = { sub = sub, send = send }
  Drain()
end

-- Limiter key: the sub (plus the whisper target), plus the first part for an
-- event-style sub when that part is plain: a secret may be concatenated into
-- a payload (Payload blanks it) but never used as a table key.
local function KeyFor(sub, name, ...)
  local key = name and (sub .. ":" .. name) or sub
  if EVENT_SUBS[sub] then
    local first = (...)
    if not IsSecret(first) and first ~= nil then key = key .. ":" .. tostring(first) end
  end
  return key
end

-- To the group we are in (Mama's SendGroup).
function ns.Send(sub, ...)
  if not CanSend(true) then return false end
  local payload = ns.Payload(sub, ...)
  Queue(KeyFor(sub, nil, ...), sub, function() MF:SendGroup(payload) end)
  return true
end

-- To one team member (Mama's SendWhisper, works across layers).
function ns.Whisper(name, sub, ...)
  if not CanSend(false) or type(name) ~= "string" or IsSecret(name) then return false end
  if name == MF.myName then return false end
  local payload = ns.Payload(sub, ...)
  Queue(KeyFor(sub, name, ...), sub, function() MF:SendWhisper(name, payload, "plus " .. sub) end)
  return true
end

-- To every online team member, grouped or not (Mama's SendTeam).
function ns.SendTeam(sub, ...)
  if not CanSend(false) then return false end
  local payload = ns.Payload(sub, ...)
  Queue(KeyFor(sub, nil, ...), sub, function() MF:SendTeam(payload, true) end)
  return true
end

function ns.PendingCount()
  local n = 0
  for _ in pairs(pending) do n = n + 1 end
  return n
end

-- Receiving: Mama has verified the signature and the sender; we only dispatch.
if MF and MF.messageHandlers then
  if MF.messageHandlers[ns.LETTER] then
    ns.commsOff = true
    ns.Print("|cffff4040Mama already uses message letter " .. ns.LETTER .. ": MamaPlus messages are off|r")
  else
    MF.messageHandlers[ns.LETTER] = function(_, sender, rest)
      if IsSecret(sender) or IsSecret(rest) or type(rest) ~= "string" or type(sender) ~= "string" then return end
      if sender == MF.myName or ns.Disabled() then return end
      local sub, body = rest:match("^(%w+);?(.*)$")
      local op = sub and ns.ops[sub]
      if not op then return end
      xpcall(function() op(sender, body) end, Report)
    end
  end
end

---------------------------------------------------------------------------
-- Login. Mama fires LOGIN from its PLAYER_LOGIN handler once its team data
-- is ready; our LOGIN listeners run from that. Should Mama's chain stop
-- before reaching us (an error in another listener), the same init runs
-- one frame after PLAYER_LOGIN.
---------------------------------------------------------------------------
ns.loggedIn = false
ns.On("PLAYER_LOGIN", function()
  ns.After(0, function()
    if ns.loggedIn then return end
    if not MF then
      ns.Print("|cffff4040Mama-forever is not loaded: MamaPlus does nothing|r")
      return
    end
    ns.loggedIn = true
    ns.Print("Mama's login chain did not reach MamaPlus: starting on our own")
    ns.Fire("LOGIN")
  end)
end)

ns.Listen("LOGIN", function()
  ns.Print("MamaPlus " .. ns.Version() .. " loaded (|cFF99E5FF/mama plus|r)")
end)

---------------------------------------------------------------------------
-- Built-in commands
---------------------------------------------------------------------------
ns.AddCommand("status", "show MamaPlus state: comms, slot, lead, limiter counters", function()
  local lead = ns.LeadName()
  ns.Print(string.format("comms %s, slot %d, token %s, lead %s%s",
    ns.commsOff and "OFF" or (CanSend(false) and "on" or "off (no slot/token or disabled)"), ns.MySlot(),
    (MF and MF.Token and MF:Token()) and "yes" or "no", tostring(lead),
    ns.IsLead() and " (this window)" or ""))
  ns.Print(string.format("messages: sent %d, replaced %d, held %d, secret parts dropped %d, pending %d; blocked actions %d%s",
    ns.comms.sent, ns.comms.replaced, ns.comms.held, ns.comms.secret, ns.PendingCount(), ns.blocked.count,
    ns.blocked.last and (" (last " .. ns.blocked.last .. ")") or ""))
  ns.Fire("STATUS_COMMAND")
end)

ns.AddCommand("debug", "turn MamaPlus debug lines on or off", function()
  ns.SetOption("debug", not ns.OptionOn("debug"))
  ns.Print("debug", ns.OptionOn("debug") and "on" or "off")
end)

ns.AddOption({ key = "debug", label = "Debug lines in chat", section = "This window", type = "toggle" })
