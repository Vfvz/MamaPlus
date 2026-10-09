local addonName, ns = ...

-- Idle in combat. Every window watches only itself, only while in combat
-- (PLAYER_REGEN_DISABLED .. PLAYER_REGEN_ENABLED), with a 0.5 s sampler.
-- A sample is ACTIVE when ns.Moving() is plainly true, when
-- UnitCastingInfo / UnitChannelInfo("player") give a name (type check
-- only), while ranged auto-repeat runs (START/STOP_AUTOREPEAT_SPELL), and
-- every own UNIT_SPELLCAST_SUCCEEDED counts at that moment, except melee
-- Auto Attack (6603); a secret spell ID cannot be checked, so it counts.
-- IDLE = in combat, ns.Moving() plainly false and no activity for idleWarn
-- seconds. When movement is secret or unavailable (ns.Moving() == nil)
-- this window never reports idle. Messages (SendGroup; the limiter keeps
-- one pending "I", so a held message is replaced by the newest state):
--   x;I;1;<warn>  idle started; <warn> is this window's idleWarn, so the
--                 receivers' tooltip can say how long. Re-sent every 45 s
--                 while idle, so receivers (and anyone who joined or
--                 reloaded meanwhile) keep the mark; marks older than 90 s
--                 are dropped.
--   x;I;0         idle ended (active again, combat ended, died)
-- Transitions go out at least 5 s apart: a change inside the gap waits for
-- its end and only the state then, when it still differs, is sent. After a
-- load the window does not know what it last told the group, so LOGIN out
-- of combat sends one "0" and in combat the sampler starts and sends the
-- first state it settles on. Receivers show a red IDLE icon on the
-- member's row; Mama's lead also gets an alert once per episode. Nothing
-- here acts on any window: it only watches, sends and draws.

local Idle = {}
ns.Idle = Idle

local IsSecret = ns.IsSecret
local SAMPLE, REFRESH, STALE, GAP = 0.5, 45, 90, 5

-- Melee auto-attack alone is not activity: a melee alt standing still and
-- only auto-attacking is reported idle. Ranged auto-repeat (Auto Shot, wand
-- Shoot, Throw) is activity: hunters and wand users stand still on purpose.
local AUTO_ATTACK = { [6603] = true }

ns.AddDefaults({ idleAlarm = true, idleWarn = 5 })
ns.AddOption({ key = "idleAlarm", label = "Idle in combat", section = "Alerts to the lead", type = "toggle",
  tip = "Sound, raid-warning text and a row flash on the lead window when a member is in combat but standing "
    .. "still and doing nothing. The IDLE row icon shows either way." })
ns.AddOption({ key = "idleWarn", label = "Idle after this many seconds", section = "This window",
  type = "number", min = 2, max = 20, step = 1,
  tip = "How long this character may stand still in combat without casting before the group is told. Set it "
    .. "on each window: every window reports itself with its own value, and the IDLE tooltip shows it." })

local function Warn()
  local w = math.floor(ns.Setting("idleWarn", 5))
  if w < 2 then return 2 end
  if w > 20 then return 20 end
  return w
end
Idle.Warn = Warn

---------------------------------------------------------------------------
-- Local detection
---------------------------------------------------------------------------
-- idle:    current state: true, false, or nil before the first settled sample
-- sent:    what the group was last told (nil after a load); sentAt: when
-- transAt: when the last transition (not a refresh) went out
local me = { inCombat = false, idle = nil, sent = nil, sentAt = 0, transAt = 0, lastActive = 0, autoRepeat = false }
Idle.me = me

local function Dead()
  local ok, v = ns.Try(UnitIsDeadOrGhost, "player")
  return ok and ns.PlainTrue(v)
end

-- type() is safe on a secret, so a secret cast name still counts as casting.
local function Casting()
  local ok, name = ns.Try(UnitCastingInfo, "player")
  if ok and type(name) == "string" then return true end
  ok, name = ns.Try(UnitChannelInfo, "player")
  return ok and type(name) == "string"
end

local function Transmit(on)
  me.sent, me.sentAt = on, GetTime()
  if on then return ns.Send("I", 1, Warn()) end
  return ns.Send("I", 0)
end

-- Sends the current state when it differs from what the group was told, at
-- most one transition per GAP seconds: a change inside the gap waits.
local flushQueued = false
local function Flush()
  if me.idle == nil or me.idle == me.sent then return end
  local wait = GAP - (GetTime() - me.transAt)
  if me.sent ~= nil and wait > 0 then
    if not flushQueued then
      flushQueued = true
      ns.After(wait, function()
        flushQueued = false
        Flush()
      end)
    end
    return
  end
  me.transAt = GetTime()
  Transmit(me.idle)
end

local function SetIdle(on, why)
  on = on and true or false
  if me.idle == on then return end
  me.idle = on
  ns.Debug("idle:", on and "idle" or "active", "(" .. tostring(why) .. ")")
  Flush()
end

-- Activity seen by an event (a sample reads the rest).
local function Active(why, autoRepeat)
  me.lastActive = GetTime()
  if autoRepeat ~= nil then me.autoRepeat = autoRepeat end
  SetIdle(false, why)
end

function Idle.Sample()
  if not me.inCombat then return end
  local now = GetTime()
  local moving = ns.Moving()
  if moving == nil or moving or me.autoRepeat or Dead() or Casting() then
    me.lastActive = now
    SetIdle(false, moving == nil and "movement unknown" or "active")
  elseif now - me.lastActive >= Warn() then
    if not me.idle then
      SetIdle(true, "no activity")
    elseif me.sent and now - me.sentAt >= REFRESH then
      Transmit(true) -- still idle: refresh the receivers' mark before it goes stale
    end
  end
end

local ticker
local function StopTicker()
  if ticker then ticker:Cancel() end
  ticker = nil
end
function Idle.Ticking() return ticker ~= nil end

function Idle.CombatStart()
  me.inCombat = true
  me.lastActive = GetTime()
  StopTicker()
  ticker = ns.Ticker(SAMPLE, Idle.Sample)
end

function Idle.CombatEnd()
  me.inCombat = false
  me.autoRepeat = false
  StopTicker()
  SetIdle(false, "combat ended")
end

local function OnSpellSucceeded(unit, _, spellID)
  if IsSecret(unit) or unit ~= "player" then return end
  -- A secret spell ID cannot be checked against the auto-attack list: it counts.
  if not IsSecret(spellID) and spellID ~= nil and AUTO_ATTACK[spellID] then return end
  Active("spell")
end
Idle.OnSpellSucceeded = OnSpellSucceeded
Idle.spellEvent = ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", OnSpellSucceeded)

ns.On("START_AUTOREPEAT_SPELL", function() Active("auto-repeat", true) end)
ns.On("STOP_AUTOREPEAT_SPELL", function() me.autoRepeat = false; me.lastActive = GetTime() end)
ns.On("PLAYER_REGEN_DISABLED", Idle.CombatStart)
ns.On("PLAYER_REGEN_ENABLED", Idle.CombatEnd)
ns.On("PLAYER_DEAD", function() Active("dead") end)

-- A /reload in combat fires no PLAYER_REGEN_DISABLED: start the sampler.
-- Out of combat this window cannot be idle: tell the group once.
ns.Listen("LOGIN", function()
  if ns.PlainTrue(InCombatLockdown()) then
    if not me.inCombat then Idle.CombatStart() end
  else
    SetIdle(false, "login")
  end
end)

---------------------------------------------------------------------------
-- Receiving: records keyed by the sender's full name
---------------------------------------------------------------------------
Idle.records = {}   -- name -> { since, time, warn }; warn nil when the sender left it out

function Idle.RecordFor(name)
  local rec = name and Idle.records[name]
  if rec and GetTime() - rec.time > STALE then
    Idle.records[name] = nil
    return nil
  end
  return rec
end

ns.ops.I = function(sender, body)
  local flag, warn = strsplit(";", body)
  if flag == "0" then
    if Idle.records[sender] then Idle.records[sender] = nil; ns.Rows.Refresh() end
    return
  end
  if flag ~= "1" then return end
  warn = tonumber(warn)
  if warn and (warn ~= math.floor(warn) or warn < 1 or warn > 99) then warn = nil end
  local now = GetTime()
  local rec = Idle.RecordFor(sender)
  local fresh = rec == nil
  if fresh then
    rec = { since = now }
    Idle.records[sender] = rec
  end
  rec.time, rec.warn = now, warn
  if fresh then
    ns.LeadAlert("idleAlarm", ns.Who(sender, true) .. " is idle in combat", sender)
  end
  ns.Rows.Refresh()
  ns.After(STALE + 0.1, ns.Rows.Refresh) -- the icon leaves without a message
end

-- Members no longer grouped with us cannot tell us when they are active again.
ns.Listen("TEAM_CHANGED", function()
  for name in pairs(Idle.records) do
    if not ns.UnitOf(name) then Idle.records[name] = nil end
  end
end)

-- The tooltip uses the sender's threshold: detection ran on that window.
ns.Rows.AddProvider(function(name, out)
  local rec = Idle.RecordFor(name)
  if not rec then return end
  local tip = rec.warn and string.format("in combat and standing still for %d+ s", rec.warn)
    or "in combat and standing still"
  out[#out + 1] = { "idle", "IDLE", 1, 0.2, 0.2, tip, 4 }
end)

---------------------------------------------------------------------------
-- Command, status line, probe
---------------------------------------------------------------------------
ns.AddCommand("idle", "idle [on|off] - idle-in-combat alert on the lead (the IDLE icon always shows)", function(rest)
  rest = (rest or ""):lower()
  if rest == "on" or rest == "off" then ns.SetOption("idleAlarm", rest == "on") end
  ns.Print(string.format("idle alert %s; this window reports idle after %d s in combat",
    ns.OptionOn("idleAlarm") and "on" or "off", Warn()))
end)

local function State()
  local n = 0
  for _ in pairs(Idle.records) do n = n + 1 end
  return string.format("%s, %s, told %s, idle records %d", me.inCombat and "in combat (sampling)" or "out of combat",
    me.idle and "idle" or (me.idle == false and "active" or "unsettled"), tostring(me.sent), n)
end
ns.Listen("STATUS_COMMAND", function() ns.Print("idle: " .. State()) end)

-- ns.Try's two returns as one probe value: the runner renders a secret or
-- nil value itself, so a secret is handed on untouched.
local function Result(ok, v)
  if not ok then return "error or missing" end
  return v
end

-- /mama plus probe idle (design probe 7) through the runner's add(name, value).
ns.AddProbe("idle", function(add)
  add("IsPlayerMoving()", Result(ns.Try(IsPlayerMoving)))
  add("GetUnitSpeed(player)", Result(ns.Try(GetUnitSpeed, "player")))
  add("C_Secrets.ShouldUnitStatsBeSecret(player)", Result(ns.Try(C_Secrets and C_Secrets.ShouldUnitStatsBeSecret, "player")))
  add("UnitCastingInfo(player)", Result(ns.Try(UnitCastingInfo, "player")))
  add("UnitChannelInfo(player)", Result(ns.Try(UnitChannelInfo, "player")))
  add("InCombatLockdown()", Result(ns.Try(InCombatLockdown)))
  add("ns.Moving()", tostring(ns.Moving()) .. ", movement secret seen: " .. tostring(ns.moveSecret))
  add("UNIT_SPELLCAST_SUCCEEDED registered", Idle.spellEvent)
  add("state", State())
end)
