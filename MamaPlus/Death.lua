local addonName, ns = ...

-- Death: this window's own death state and what the team may know about
-- it. State a (alive) / d (dead) / g (ghost) from PLAYER_DEAD, PLAYER_ALIVE
-- and PLAYER_UNGHOST, re-read every second from UnitIsDead/UnitIsGhost
-- ("player") while not alive; flags c corpse in range, s spirit healer in
-- range, o resurrection offered (kept 60 s). The heartbeat carries
--   R = <a|d|g><c?><s?><o?>.<releaseEnd|->
-- (empty while alive; releaseEnd is the server time an armed auto-release
-- fires at, so receivers count down). A plain prompt frame on death offers
-- [Release] and [Retrieve] (RepopMe / RetrieveCorpse, this window only).
-- Opt-in automation acts on this client's own death from its own events:
-- auto-release after a countdown (never on Hardcore or an unknown ruleset,
-- never with a self-res option, held 20 s while a teammate casts a
-- resurrection, dropped by an offer, a click, Escape, the option going off
-- or the lead's "x;R;c", and every gate is asked again when it fires), and
-- auto-retrieve while a ghost next to its corpse with the lead alive
-- (3 tries 5 s apart, each announced). Neither needs a hand click first:
-- the first timer attempt on a build is its own probe (design open
-- question 4, decided for a plain toggle). Every RepopMe/RetrieveCorpse
-- call gets an outcome: "ok" on the first state change (or a plain re-read
-- OUTCOME_WAIT s later), "blocked" when ADDON_ACTION_FORBIDDEN/BLOCKED
-- names that call, it raises, or nothing moved in OUTCOME_WAIT s; stored
-- per build in MamaPlusDB.deathProbe under the path that called (repopClick,
-- repopAuto, repopCmd, retrieve*). A blocked timer path turns its option
-- off and greys the toggle until "/mama plus death reset"; a blocked click
-- path hides its button. Healers tell the group "x;R;r;<spell>;<target>"
-- when a resurrection cast (by spell ID, any rank) is sent and "x;R;x" when
-- their last cast in flight fails. Nothing here acts on another window.

local Death = {}
ns.Death = Death

local IsSecret = ns.IsSecret
local FLAG_HOLD, OFFER_TTL, RES_HOLD, OUTCOME_WAIT = 15, 60, 20, 5
local RETRIEVE_TRIES, RETRIEVE_GAP = 3, 5
local CAST_TTL = 15   -- an own resurrection cast whose end was never seen is forgotten after this
local EVENTS = { "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "CORPSE_IN_RANGE", "CORPSE_OUT_OF_RANGE",
  "AREA_SPIRIT_HEALER_IN_RANGE", "AREA_SPIRIT_HEALER_OUT_OF_RANGE", "RESURRECT_REQUEST", "SELF_RES_SPELL_CHANGED",
  "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET", "UNIT_SPELLCAST_INTERRUPTED",
  "UNIT_SPELLCAST_SUCCEEDED" }
-- Resurrection spells by ID, every rank (the client's spell names are localized): id -> label.
local RES_SPELLS = {}
for label, ids in pairs({
  ["Resurrection"] = { 2006, 2010, 10880, 10881, 20770 },
  ["Redemption"] = { 7328, 10322, 10324, 20772, 20773 },
  ["Ancestral Spirit"] = { 2008, 20609, 20610, 20776, 20777 },
  ["Rebirth"] = { 20484, 20739, 20742, 20747, 20748 },
}) do
  for _, id in ipairs(ids) do RES_SPELLS[id] = label end
end
Death.RES_SPELLS = RES_SPELLS
local STATE_NAMES = { a = "alive", d = "dead", g = "ghost" }
Death.CAN_RES = { PRIEST = 10, PALADIN = 12, SHAMAN = 12, DRUID = 20 }

local function NotHardcore() return ns.IsHardcore() == false end
local function Note(label)
  return "Off on Hardcore (or when the ruleset is unknown), and after " .. label
    .. "() from a timer was blocked on this build (/mama plus death reset clears that record)"
end
ns.AddDefaults({ deathDesk = true, deathAlert = true, autoRelease = false, autoReleaseSecs = 30, autoRetrieve = false })
ns.AddOption({ key = "deathAlert", label = "Deaths", section = "Alerts to the lead", type = "toggle",
  tip = "Sound, raid-warning text and a row flash when a teammate dies; one alert for a burst of deaths." })
ns.AddOption({ key = "deathDesk", label = "Death desk under the status window", section = "Death", type = "toggle",
  tip = "On the lead window: who is dead or a ghost, who can resurrect, a cancel button for auto-releases.",
  onChange = function() ns.Fire("DEATH_CHANGED") end })
ns.AddOption({ key = "autoRelease", label = "Auto-release after a countdown", section = "Death", type = "toggle",
  enabledWhen = function() return NotHardcore() and Death.Outcome("repopAuto") ~= "blocked" end, note = Note("RepopMe"),
  onChange = function(v) if not v then Death.CancelRelease("cancelled: option off") end end,
  tip = "This window releases its own spirit when the countdown ends, unless a self-res option exists, a teammate "
    .. "is casting a resurrection, one is offered, you click or press Escape, or the lead cancels." })
ns.AddOption({ key = "autoReleaseSecs", label = "Auto-release after this many seconds", section = "Death",
  type = "number", min = 5, max = 120, step = 5 })
ns.AddOption({ key = "autoRetrieve", label = "Auto-retrieve the corpse", section = "Death", type = "toggle",
  enabledWhen = function() return NotHardcore() and Death.Outcome("retrieveAuto") ~= "blocked" end, note = Note("RetrieveCorpse"),
  tip = "This window retrieves its own corpse when it is in range, the recovery delay is over and the lead is alive." })

---------------------------------------------------------------------------
-- Own state
---------------------------------------------------------------------------
-- releaseAt (GetTime) / releaseEnd (server time) while an auto-release is
-- armed; tries/lastTry for auto-retrieve; closed: the prompt was closed.
local me = { state = "a", corpse = false, spirit = false, offer = nil, offerUntil = 0, releaseAt = nil,
  releaseEnd = nil, diedAt = nil, tries = 0, lastTry = -100, closed = false }
Death.me = me
Death.resCasts = {}   -- sender -> { spell, target, time }: a teammate's resurrection cast in flight
local releaseSerial, hiding, flagHold = 0, false, false
-- The RepopMe/RetrieveCorpse call whose outcome is still open: { key, label, before, serial }.
local pending = nil
local ResolveOutcome

local function ServerNow()
  local ok, v = ns.Try(GetServerTime)
  if not ok then return nil end
  return ns.PlainNumber(v)
end
Death.ServerNow = ServerNow

-- The own state as the client tells it plainly, or nil when it will not say.
local function ReadState()
  local okG, ghost = ns.Try(UnitIsGhost, "player")
  local okD, dead = ns.Try(UnitIsDead, "player")
  if not okG or not okD or IsSecret(ghost) or IsSecret(dead) then return nil end
  if ghost then return "g" end
  if dead then return "d" end
  return "a"
end
Death.ReadState = ReadState

-- "none" only when the client plainly lists no self-res option; else "blocked" and why.
function Death.SelfRes()
  local api = C_DeathInfo and C_DeathInfo.GetSelfResurrectOptions
  if type(api) ~= "function" then return "blocked", "no API" end
  local ok, t = pcall(api)
  if not ok then return "blocked", "error" end
  if IsSecret(t) then return "blocked", "secret" end
  if type(t) ~= "table" then return "blocked", "nil" end
  if #t == 0 then return "none", "none" end
  return "blocked", "available"
end

function Death.RecoveryDelay()
  local ok, v = ns.Try(GetCorpseRecoveryDelay)
  if not ok then return nil end
  return ns.PlainNumber(v)
end

-- Outcome DB: ns.db.deathProbe[build][key] = "ok" | "blocked"
local function Build()
  local ok, _, build = pcall(GetBuildInfo)
  if not ok then return "?" end
  return ns.PlainOfType(build, "string", "?")
end

function Death.Outcome(key)
  local t = ns.db and ns.db.deathProbe
  t = t and t[Build()]
  return t and t[key] or nil
end

function Death.Record(key, result)
  if not ns.db then return end
  ns.db.deathProbe = ns.db.deathProbe or {}
  local b = Build()
  ns.db.deathProbe[b] = ns.db.deathProbe[b] or {}
  ns.db.deathProbe[b][key] = result
  ns.Debug("death outcome", key, result)
end

local PROBE_KEYS = { "repopClick", "repopAuto", "retrieveClick", "retrieveAuto", "repopCmd", "retrieveCmd" }
local function ProbeText()
  local parts = {}
  for _, k in ipairs(PROBE_KEYS) do
    parts[#parts + 1] = k .. "=" .. (Death.Outcome(k) or "-")
  end
  return table.concat(parts, " ")
end

-- Forgets this build's outcomes: a blocked timer record greys its toggle until then.
function Death.Reset()
  local was = ProbeText()
  if ns.db and ns.db.deathProbe then ns.db.deathProbe[Build()] = nil end
  ns.Print("death outcomes for build " .. Build() .. " cleared (were " .. was .. ")")
  if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
  Death.UpdatePrompt()
end

-- Everything that follows a change of our own facts.
function Death.Changed()
  ns.Status.Changed()
  ns.Fire("DEATH_CHANGED")
  Death.UpdatePrompt()
end

local ticker
local function UpdateTicker()
  if me.state ~= "a" then
    ticker = ticker or ns.Ticker(1, function() Death.Tick() end)
  elseif ticker then
    ticker:Cancel()
    ticker = nil
  end
end

function Death.SetState(s)
  if s == me.state then return end
  local old = me.state
  me.state = s
  if s == "d" then me.diedAt = GetTime() end
  if s == "a" then
    me.corpse, me.spirit, me.offer, me.diedAt, me.closed = false, false, nil, nil, false
  end
  if s ~= "d" then Death.CancelRelease(nil) end
  -- The call in flight did its job: the state moved from where it was made.
  if pending and s ~= pending.before then ResolveOutcome("ok") end
  ns.Debug("death state", old, "->", s)
  UpdateTicker()
  Death.Changed()
end

-- Corpse/spirit flags: shown at once, told to the team after a 15 s hold
-- (a ghost pacing at the edge of its corpse range flaps them).
local function SetFlag(key, on)
  if me[key] == on then return end
  me[key] = on
  ns.Fire("DEATH_CHANGED")
  Death.UpdatePrompt()
  if flagHold then return end
  flagHold = true
  ns.After(FLAG_HOLD, function()
    flagHold = false
    ns.Status.Changed()
  end)
end

ns.Status.AddField("R", function()
  local flags = (me.corpse and "c" or "") .. (me.spirit and "s" or "") .. (me.offer and "o" or "")
  if me.state == "a" and flags == "" then return nil end
  return me.state .. flags .. "." .. (me.releaseEnd and tostring(me.releaseEnd) or "-")
end)

-- A member's death facts: { state a|d|g, corpse, spirit, offer, endTime, me }, nil when nothing is known.
function Death.StateOf(name)
  if name == ns.MyName() then
    return { state = me.state, corpse = me.corpse, spirit = me.spirit, offer = me.offer ~= nil,
      endTime = me.releaseEnd, me = true }
  end
  local rec = ns.Status.records[name]
  if not rec then return nil end
  local r = rec.fields.R
  if not r or r == "" then
    return { state = (rec.flags and rec.flags:find("d", 1, true)) and "d" or "a" }
  end
  local st, flags, endt = r:match("^([adg])([cso]*)%.?(.*)$")
  if not st then return { state = "a" } end
  return { state = st, corpse = flags:find("c", 1, true) ~= nil, spirit = flags:find("s", 1, true) ~= nil,
    offer = flags:find("o", 1, true) ~= nil, endTime = tonumber(endt) }
end

function Death.LeadAlive()
  local lead = ns.LeadName()
  if lead == nil or lead == ns.MyName() then return true end
  local r = ns.Status.Field(lead, "R")
  return r == nil or r == "" or r:sub(1, 1) == "a"
end

---------------------------------------------------------------------------
-- Prompt: a plain frame, Escape closes it (and cancels an armed release)
---------------------------------------------------------------------------
local prompt = CreateFrame("Frame", "MamaPlusDeathPrompt", UIParent, "BackdropTemplate")
Death.prompt = prompt
prompt:SetSize(260, 96)
prompt:SetPoint("TOP", UIParent, "TOP", 0, -220)
prompt:SetFrameStrata("DIALOG")
if prompt.SetBackdrop then
  prompt:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  prompt:SetBackdropColor(0, 0, 0, 0.8)
  prompt:SetBackdropBorderColor(0.8, 0.1, 0.1, 1)
end
prompt.title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
prompt.title:SetPoint("TOP", 0, -8)
prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
prompt.text:SetPoint("TOP", prompt.title, "BOTTOM", 0, -4)
prompt.text:SetWidth(248)
local function Button(text, x, fn)
  local b = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
  b:SetSize(90, 22)
  b:SetPoint("BOTTOM", x, 6)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end
prompt.release = Button("Release", -50, function() Death.Repop("repopClick") end)
prompt.retrieve = Button("Retrieve", 50, function() Death.Retrieve("retrieveClick") end)
prompt:SetScript("OnHide", function(self)
  -- Our own HidePrompt, being alive, or a hide through a parent (Alt+Z, a
  -- cinematic: the frame itself stays shown) is not a close; Escape is.
  if hiding or me.state == "a" or self:IsShown() then return end
  me.closed = true
  Death.CancelRelease("cancelled: prompt closed")
end)
local function HidePrompt()
  hiding = true
  prompt:Hide()
  hiding = false
end
HidePrompt()
if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "MamaPlusDeathPrompt") end

function Death.UpdatePrompt()
  if me.state == "a" or me.closed then
    HidePrompt()
    return
  end
  local lines = {}
  local canRelease = me.state == "d" and type(RepopMe) == "function" and Death.Outcome("repopClick") ~= "blocked"
  local canRetrieve = me.state == "g" and type(RetrieveCorpse) == "function" and Death.Outcome("retrieveClick") ~= "blocked"
  if me.state == "d" then
    prompt.title:SetText("You died")
    if me.releaseAt then
      if Death.HeldUntil() then
        lines[#lines + 1] = "auto-release held: a resurrection is being cast"
      else
        lines[#lines + 1] = string.format("auto-release in %d s", math.max(0, math.ceil(me.releaseAt - GetTime())))
      end
    end
    local sr, why = Death.SelfRes()
    if sr ~= "none" then
      lines[#lines + 1] = why == "available" and "Soulstone available: auto-release off"
        or ("self-res unknown (" .. why .. "): auto-release off")
    end
  else
    prompt.title:SetText("ghost: corpse " .. (me.corpse and "near" or "far") .. (me.spirit and ", spirit healer near" or ""))
    if me.corpse and Death.CanAutoRetrieve() then
      if not Death.LeadAlive() then
        lines[#lines + 1] = "auto-retrieve: waiting for the lead"
      elseif me.tries < RETRIEVE_TRIES then
        lines[#lines + 1] = "auto-retrieve on"
      end
    end
  end
  local delay = Death.RecoveryDelay()
  if delay and delay > 0 then lines[#lines + 1] = string.format("wait %d s", delay) end
  if me.offer then lines[#lines + 1] = "res offered by " .. me.offer end
  if (me.state == "d" and not canRelease) or (me.state == "g" and not canRetrieve) then
    lines[#lines + 1] = "use the game's own popup"
  end
  prompt.text:SetText(table.concat(lines, "\n"))
  prompt.release:SetShown(canRelease)
  prompt.retrieve:SetShown(canRetrieve)
  prompt:SetHeight(44 + 12 * #lines + 30)
  prompt:Show()
end

---------------------------------------------------------------------------
-- Release / retrieve with the outcome check
---------------------------------------------------------------------------
local outcomeSerial = 0

local function Blocked(key, label)
  if key == "repopAuto" or key == "retrieveAuto" then
    local option = key == "repopAuto" and "autoRelease" or "autoRetrieve"
    ns.SetOption(option, false)
    ns.Print(string.format("%s turned off: %s() from a timer was blocked or did nothing on this build "
      .. "(/mama plus death reset clears that record)", option == "autoRelease" and "auto-release" or "auto-retrieve", label))
  else
    ns.Print(label .. "() from " .. (key:find("Cmd", 1, true) and "the command" or "a click")
      .. " was blocked or did nothing on this build: use the game's own popup")
  end
end

-- Settles the call in flight: records it, acts on "blocked", refreshes the prompt.
ResolveOutcome = function(result)
  local p = pending
  pending = nil
  Death.Record(p.key, result)
  if result == "blocked" then Blocked(p.key, p.label) end
  Death.UpdatePrompt()
end

-- A blocked action naming the call in flight ("RepopMe()") settles it at
-- once; any other blocked action is not ours to judge by.
ns.OnBlocked(function(func)
  if pending and tostring(func):find(pending.label, 1, true) then ResolveOutcome("blocked") end
end)

-- Runs RepopMe/RetrieveCorpse. The outcome is "ok" at the first state change
-- (SetState) and "blocked" when the call is named by a blocked-action event,
-- raises, or has moved nothing OUTCOME_WAIT s later (after a plain re-read,
-- in case the client knows before its event arrives, as after a loading
-- screen). lenient: nothing moved is not recorded (auto-retrieve tries again).
local function Call(key, fn, label, lenient)
  if type(fn) ~= "function" then
    ns.Print(label .. "() is missing on this client: use the game's own popup")
    return false
  end
  outcomeSerial = outcomeSerial + 1
  local mine = outcomeSerial
  pending = { key = key, label = label, before = me.state, serial = mine }
  local ok, err = pcall(fn)
  if not ok then
    ns.Debug(label, "raised:", err)
    if pending and pending.serial == mine then ResolveOutcome("blocked") end
    return false
  end
  ns.After(OUTCOME_WAIT, function()
    if not pending or pending.serial ~= mine then return end
    local s = ReadState()
    if s and s ~= me.state then Death.SetState(s) end
    if not pending or pending.serial ~= mine then return end
    if lenient then
      ns.Debug(label, "did nothing (" .. key .. "), trying again")
      pending = nil
      return
    end
    ResolveOutcome("blocked")
  end)
  return true
end

-- Why an auto-release may not run now, or nil when every gate is open.
local function AutoGate()
  if not ns.OptionOn("autoRelease") then return "option off" end
  if ns.IsHardcore() ~= false then return "Hardcore or unknown ruleset" end
  if ns.Disabled() then return "Mama disabled" end
  if Death.Outcome("repopAuto") == "blocked" then return "blocked on this build" end
  local sr, why = Death.SelfRes()
  if sr ~= "none" then return "self-res " .. why end
  return nil
end

function Death.Repop(key)
  Death.CancelRelease(nil)
  if me.state ~= "d" then
    ns.Print("not dead: nothing to release")
    return false
  end
  if key == "repopAuto" then
    -- Every gate again: the countdown may have outlived the option, Mama or the ruleset reading.
    local why = AutoGate()
    if why then
      ns.Print("auto-release skipped: " .. why)
      return false
    end
  end
  return Call(key, RepopMe, "RepopMe")
end

function Death.Retrieve(key, lenient)
  Death.CancelRelease(nil)
  if me.state ~= "g" then
    ns.Print("not a ghost: nothing to retrieve")
    return false
  end
  local delay = Death.RecoveryDelay()
  if delay and delay > 0 then
    ns.Print(string.format("corpse recovery in %d s", delay))
    return false
  end
  return Call(key, RetrieveCorpse, "RetrieveCorpse", lenient)
end

-- Once per session: the option is on but a blocked record keeps it idle.
local told = {}
local function TellBlocked(option, key, label, what)
  if told[option] or not ns.OptionOn(option) or Death.Outcome(key) ~= "blocked" then return end
  told[option] = true
  ns.Print(what .. " is off: " .. label .. "() from a timer was blocked on this build (/mama plus death reset clears that record)")
end

---------------------------------------------------------------------------
-- Auto-release
---------------------------------------------------------------------------
-- End of the hold a teammate's resurrection cast puts on the release, or nil.
function Death.HeldUntil()
  local now, latest = GetTime(), nil
  for sender, c in pairs(Death.resCasts) do
    local holdEnd = c.time + RES_HOLD
    if holdEnd <= now then
      Death.resCasts[sender] = nil
    elseif not latest or holdEnd > latest then
      latest = holdEnd
    end
  end
  return latest
end

local function Expire(mine)
  if releaseSerial ~= mine or not me.releaseAt then return end
  local held = Death.HeldUntil()
  if held then
    ns.After(held - GetTime() + 0.1, function() Expire(mine) end)
    Death.UpdatePrompt()
    return
  end
  me.releaseAt, me.releaseEnd = nil, nil
  releaseSerial = releaseSerial + 1
  Death.Repop("repopAuto")
end

function Death.ArmRelease()
  if me.releaseAt then return false end
  local why = AutoGate()
  if why then return false, why end
  local secs = math.min(120, math.max(5, ns.Setting("autoReleaseSecs", 30)))
  releaseSerial = releaseSerial + 1
  local mine = releaseSerial
  me.releaseAt = GetTime() + secs
  local server = ServerNow()
  me.releaseEnd = server and math.floor(server + secs) or nil
  ns.After(secs, function() Expire(mine) end)
  ns.Print(string.format("auto-release in %d s: a click, Escape or the lead's cancel stops it", secs))
  Death.Changed()
  return true
end

function Death.CancelRelease(why)
  if not me.releaseAt then return false end
  me.releaseAt, me.releaseEnd = nil, nil
  releaseSerial = releaseSerial + 1
  if why then ns.Print("auto-release " .. why) end
  Death.Changed()
  return true
end

-- The lead's cancel: "x;R;c" to the group (only ever suppresses) plus our own.
function Death.CancelAll()
  ns.Send("R", "c")
  Death.CancelRelease("cancelled")
  ns.Print("auto-release cancel sent to the group")
end

---------------------------------------------------------------------------
-- Auto-retrieve (from the 1 s ticker while a ghost)
---------------------------------------------------------------------------
function Death.CanAutoRetrieve()
  return ns.OptionOn("autoRetrieve") and ns.IsHardcore() == false and not ns.Disabled()
    and Death.Outcome("retrieveAuto") ~= "blocked"
end

function Death.TryRetrieve()
  if me.state ~= "g" or not me.corpse then return false end
  TellBlocked("autoRetrieve", "retrieveAuto", "RetrieveCorpse", "auto-retrieve")
  if not Death.CanAutoRetrieve() or pending then return false end
  if me.tries >= RETRIEVE_TRIES or GetTime() - me.lastTry < RETRIEVE_GAP then return false end
  if Death.RecoveryDelay() ~= 0 or not Death.LeadAlive() then return false end
  me.tries, me.lastTry = me.tries + 1, GetTime()
  ns.Print(string.format("auto-retrieve: try %d of %d", me.tries, RETRIEVE_TRIES))
  return Death.Retrieve("retrieveAuto", me.tries < RETRIEVE_TRIES)
end

function Death.Tick()
  local s = ReadState()
  if s and s ~= me.state then Death.SetState(s) end
  if me.state == "a" then return end
  if me.offer and GetTime() >= me.offerUntil then
    me.offer = nil
    Death.Changed()
  end
  Death.TryRetrieve()
  Death.UpdatePrompt()
end

---------------------------------------------------------------------------
-- Healer report: our own resurrection casts, by plain cast GUID
---------------------------------------------------------------------------
local ownCasts = {}   -- plain castGUID -> GetTime() of our resurrection casts in flight
Death.ownCasts = ownCasts

-- Drops casts whose end was never seen; true while any is still in flight.
local function CastsInFlight()
  local now, any = GetTime(), false
  for g, t in pairs(ownCasts) do
    if now - t > CAST_TTL then ownCasts[g] = nil else any = true end
  end
  return any
end

Death.sentEvent = ns.OnUnit("UNIT_SPELLCAST_SENT", "player", function(_, target, castGUID, spellID)
  local id = ns.PlainNumber(spellID)
  local label = id and RES_SPELLS[id]
  if not label then return end
  -- The client's (localized) name for the payload when it is plain, else our label.
  local ok, name = ns.Try(C_Spell and C_Spell.GetSpellName, id)
  name = ok and ns.PlainOfType(name, "string", nil) or nil
  if not name or name == "" then name = label end
  local g = ns.PlainOfType(castGUID, "string", nil)
  if g then ownCasts[g] = GetTime() end
  local t = ns.Clean(target, 30)
  ns.Send("R", "r", name, t ~= "" and t or "?")
end)

-- A failed (also quietly, as a repeat press), or interrupted cast lifts the
-- hold once none of ours is left in flight.
local function CastLost(_, castGUID)
  local g = ns.PlainOfType(castGUID, "string", nil)
  if not g or not ownCasts[g] then return end
  ownCasts[g] = nil
  if not CastsInFlight() then ns.Send("R", "x") end
end
ns.OnUnit("UNIT_SPELLCAST_FAILED", "player", CastLost)
ns.OnUnit("UNIT_SPELLCAST_FAILED_QUIET", "player", CastLost)
ns.OnUnit("UNIT_SPELLCAST_INTERRUPTED", "player", CastLost)
-- A finished cast is done: the target gets RESURRECT_REQUEST; the others keep their hold.
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, castGUID)
  local g = ns.PlainOfType(castGUID, "string", nil)
  if g then ownCasts[g] = nil end
end)

---------------------------------------------------------------------------
-- Receiving: r (cast sent) holds our release, x lifts it, c from the lead cancels it
---------------------------------------------------------------------------
ns.ops.R = function(sender, body)
  local op, spell, target = strsplit(";", body)
  if op == "r" then
    Death.resCasts[sender] = { spell = spell or "?", target = target or "?", time = GetTime() }
    ns.Debug("res cast by", sender, spell, "on", target)
    Death.UpdatePrompt()
  elseif op == "x" then
    Death.resCasts[sender] = nil
    if me.releaseAt and GetTime() >= me.releaseAt then Expire(releaseSerial) end
    Death.UpdatePrompt()
  elseif op == "c" then
    if sender == ns.LeadName() then Death.CancelRelease("cancelled by the lead") end
  end
  ns.Fire("DEATH_CHANGED")
end

---------------------------------------------------------------------------
-- Own events
---------------------------------------------------------------------------
ns.On("PLAYER_DEAD", function()
  me.tries, me.lastTry, me.closed = 0, -100, false
  Death.SetState("d")
  local armed, why = Death.ArmRelease()
  if not armed and why then
    ns.Debug("auto-release not armed:", why)
    TellBlocked("autoRelease", "repopAuto", "RepopMe", "auto-release")
  end
  Death.UpdatePrompt()
end)
ns.On("PLAYER_ALIVE", function() Death.SetState(ReadState() or "a") end)
ns.On("PLAYER_UNGHOST", function() Death.SetState("a") end)
ns.On("CORPSE_IN_RANGE", function() SetFlag("corpse", true) end)
ns.On("CORPSE_OUT_OF_RANGE", function() SetFlag("corpse", false) end)
ns.On("AREA_SPIRIT_HEALER_IN_RANGE", function() SetFlag("spirit", true) end)
ns.On("AREA_SPIRIT_HEALER_OUT_OF_RANGE", function() SetFlag("spirit", false) end)
ns.On("RESURRECT_REQUEST", function(offerer)
  local who = ns.Clean(offerer, 30)
  me.offer, me.offerUntil = who ~= "" and who or "?", GetTime() + OFFER_TTL
  Death.CancelRelease("cancelled: resurrection offered by " .. me.offer)
  Death.Changed()
end)
ns.On("SELF_RES_SPELL_CHANGED", function()
  if me.releaseAt and Death.SelfRes() ~= "none" then Death.CancelRelease("cancelled: a self-res option appeared") end
  Death.UpdatePrompt()
end)
ns.Listen("LOGIN", function()
  local s = ReadState()
  if s then Death.SetState(s) end
end)

---------------------------------------------------------------------------
-- Command, status line, probe
---------------------------------------------------------------------------
local function State()
  local sr, why = Death.SelfRes()
  return string.format("%s%s%s%s, auto-release %s, auto-retrieve %s, self-res %s (%s), %s", STATE_NAMES[me.state],
    me.corpse and ", corpse near" or "", me.spirit and ", spirit healer near" or "",
    me.offer and (", res offered by " .. me.offer) or "",
    me.releaseAt and string.format("in %d s", math.ceil(me.releaseAt - GetTime())) or (ns.OptionOn("autoRelease") and "on" or "off"),
    ns.OptionOn("autoRetrieve") and "on" or "off", sr, why, ProbeText())
end

ns.AddCommand("death", "death [cancel|release|retrieve|reset] - who is dead and who can res; cancel auto-releases (lead); "
  .. "release or retrieve on this window; reset forgets this build's blocked outcomes", function(rest)
  rest = (rest or ""):lower()
  if rest == "cancel" then
    if not ns.IsLead() then
      ns.Print("only the lead cancels auto-releases (/mama lead)")
      return
    end
    Death.CancelAll()
  elseif rest == "release" then
    Death.Repop("repopCmd")      -- its own record: a typed call never speaks for the button
  elseif rest == "retrieve" then
    Death.Retrieve("retrieveCmd")
  elseif rest == "reset" then
    Death.Reset()
  else
    local lines = ns.DeathDesk and ns.DeathDesk.Lines() or { "death: " .. State() }
    for _, l in ipairs(lines) do ns.Print(l) end
  end
end)
ns.Listen("STATUS_COMMAND", function() ns.Print("death: " .. State()) end)

local function Describe(ok, v)
  if not ok then return "error or missing" end
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  if type(v) == "table" then return "table with " .. #v .. " entries" end
  return tostring(v) .. " (" .. type(v) .. ")"
end

-- Lines for /mama plus probe death (design probes D0-D8).
ns.AddProbe("death", function(out)
  local lines = {}
  local function Add(label, ...) lines[#lines + 1] = label .. ": " .. Describe(...) end
  for _, name in ipairs({ "RepopMe", "RetrieveCorpse", "AcceptResurrect", "GetCorpseRecoveryDelay" }) do
    lines[#lines + 1] = name .. ": " .. type(_G[name])
  end
  lines[#lines + 1] = "C_DeathInfo.GetSelfResurrectOptions: " .. type(C_DeathInfo and C_DeathInfo.GetSelfResurrectOptions)
  Add("C_DeathInfo.GetSelfResurrectOptions()", ns.Try(C_DeathInfo and C_DeathInfo.GetSelfResurrectOptions))
  Add("UnitIsDeadOrGhost(player)", ns.Try(UnitIsDeadOrGhost, "player"))
  Add("UnitIsDeadOrGhost(party1)", ns.Try(UnitIsDeadOrGhost, "party1"))
  Add("UnitIsDead(player)", ns.Try(UnitIsDead, "player"))
  Add("UnitIsGhost(player)", ns.Try(UnitIsGhost, "player"))
  Add("GetCorpseRecoveryDelay()", ns.Try(GetCorpseRecoveryDelay))
  lines[#lines + 1] = "IsHardcore(): " .. tostring(ns.IsHardcore())
  for _, event in ipairs(EVENTS) do lines[#lines + 1] = event .. " valid: " .. tostring(ns.EventIsValid(event)) end
  lines[#lines + 1] = "deathProbe[" .. Build() .. "]: " .. ProbeText()
  lines[#lines + 1] = "state: " .. State()
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
