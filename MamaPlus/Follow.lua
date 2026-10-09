local addonName, ns = ...

-- Follow doctor. AUTOFOLLOW_BEGIN/END fire only on the follower, so every
-- window tracks its own follow state and tells the group, out of combat
-- only (SendGroup; the limiter keeps one pending "F", so a held message is
-- replaced by the newest state):
--   x;F;1;<target>            follow began (only after a sent 0 or 2)
--   x;F;0;<cause>[;<detail>]  follow ended, held 1 s so a quick re-follow
--                             sends nothing; cause died > taxi > zone (new
--                             area within 3 s) > cast (own cast bar or a
--                             non-auto-attack spell within 0.5 s, detail =
--                             the spell) > combat > stopped
--   x;F;2                     stuck: still following, but standing still
--                             for stuckSecs samples with the followed unit
--                             plainly out of trade range (once per episode,
--                             10 s cooldown, off for the session when
--                             movement is secret); "1" again once we move
-- In combat the state is only remembered; one flush at PLAYER_REGEN_ENABLED
-- sends it when it differs from the last sent. Heartbeat flag f while
-- following. Receivers keep {state, cause, detail, target, time} per sender
-- and draw F! (red, a grouped member that is not the lead and not
-- following), F? (orange, stuck) or a tooltip line while following; Mama's
-- lead gets an alert on F;2 only, once per 15 s per sender. Mama's own
-- out-of-range alert (its F letter) is untouched. The cue is a click-through
-- banner on this window, "Press <key> to follow <lead>", shown when our own
-- follow broke by stopping or a zone change, or we are stuck, and another
-- window leads; hidden on BEGIN, combat, death or after 30 s. Nothing here
-- acts on any window: it only watches, sends and draws.

local Follow = {}
ns.Follow = Follow

local IsSecret = ns.IsSecret
local HOLD, ZONE_WINDOW, CAST_WINDOW = 1, 3, 0.5
local SAMPLE, STUCK_COOLDOWN, ALERT_GAP, CUE_TIME = 1, 10, 15, 30
local AUTO_ATTACK = { [6603] = true }
local FOLLOW_KEY = "CLICK MamaFollow:LeftButton"

Follow.CAUSE_TEXT = { died = "died", taxi = "took a flight", zone = "changed zone", cast = "cast",
  combat = "entered combat", stopped = "stopped (moved by hand or stuck)" }

ns.AddDefaults({ stuckAlert = false, stuckSecs = 4, followCue = true, followFlash = false })
ns.AddOption({ key = "stuckAlert", label = "Stuck behind the lead", section = "Alerts to the lead", type = "toggle",
  tip = "Sound, raid-warning text and a row flash on the lead window when a following member stands still out of "
    .. "range. The F? row icon shows either way. Off by default: it doubles Mama's own \"Warn when follow breaks\" "
    .. "alert for the same episode unless one of the two is turned off." })
ns.AddOption({ key = "stuckSecs", label = "Stuck after this many seconds", section = "This window", type = "number",
  min = 2, max = 15, step = 1, tip = "Seconds this character may stand still while following, out of trade range." })
ns.AddOption({ key = "followCue", label = "Follow cue banner", section = "This window", type = "toggle",
  tip = "A banner on this window when its follow broke by stopping or a zone change, or it is stuck." })
ns.AddOption({ key = "followFlash", label = "Flash the taskbar icon with the cue", section = "This window", type = "toggle",
  tip = "FlashClientIcon() with the banner, so an unfocused window draws attention." })

local function Read(fn, ...)
  local ok, v = ns.Try(fn, ...)
  if ok then return v end
  return nil
end

local function StuckSecs() return math.max(2, math.min(15, math.floor(ns.Setting("stuckSecs", 4)))) end

---------------------------------------------------------------------------
-- Own state. sent: the state last told to the group (nil after a load);
-- time: the last own change (the age on our own row).
---------------------------------------------------------------------------
local me = { following = false, target = nil, cause = nil, detail = "", stuck = false, sent = nil, still = 0,
  lastStuck = -STUCK_COOLDOWN, holdUntil = 0, time = nil }
Follow.me = me
local lastZone, lastSpell, lastSpellName = -ZONE_WINDOW, -CAST_WINDOW, ""

-- Own cast or channel name (type check only: a secret name counts, with an
-- empty detail), else the spell that succeeded within CAST_WINDOW.
local function CastName()
  local name = Read(UnitCastingInfo, "player")
  if type(name) ~= "string" then name = Read(UnitChannelInfo, "player") end
  if type(name) == "string" then return ns.Clean(name, 30) end
  if GetTime() - lastSpell < CAST_WINDOW then return lastSpellName end
  return nil
end

function Follow.Cause()
  if ns.PlainTrue(Read(UnitIsDeadOrGhost, "player")) then return "died", "" end
  if ns.PlainTrue(Read(UnitOnTaxi, "player")) then return "taxi", "" end
  if GetTime() - lastZone < ZONE_WINDOW then return "zone", "" end
  local spell = CastName()
  if spell then return "cast", spell end
  if ns.PlainTrue(InCombatLockdown()) then return "combat", "" end
  return "stopped", ""
end

-- Message parts for the state now: 2 stuck, 1 following, 0 not following.
local function Parts()
  if me.following then
    if me.stuck then return { 2 } end
    return me.target and { 1, me.target } or { 1 }
  end
  local parts = { 0, me.cause or "stopped" }
  if me.detail ~= "" then parts[3] = me.detail end
  return parts
end

-- Out of combat, when the state differs from the last sent and the end hold
-- is over; so a 1 only follows a sent 0 or 2.
local function Flush()
  if ns.PlainTrue(InCombatLockdown()) then return end
  local parts = Parts()
  if parts[1] == me.sent or (parts[1] == 0 and GetTime() < me.holdUntil) then return end
  if ns.Send("F", unpack(parts)) then me.sent = parts[1] end
end

---------------------------------------------------------------------------
-- Cue banner
---------------------------------------------------------------------------
local cue = CreateFrame("Frame", nil, UIParent)
Follow.cue = cue
cue:SetSize(400, 40)
cue:SetPoint("TOP", UIParent, "TOP", 0, -140)
cue:SetFrameStrata("HIGH")
cue:EnableMouse(false)
cue.bg = cue:CreateTexture(nil, "BACKGROUND")
cue.bg:SetAllPoints()
cue.bg:SetColorTexture(0, 0, 0, 0.6)
cue.text = cue:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cue.text:SetPoint("CENTER")
cue.text:SetTextColor(1, 0.25, 0.25)
cue:Hide()
local cueSerial = 0

function Follow.CueText()
  local key = ns.PlainOfType(Read(GetBindingKey, FOLLOW_KEY), "string", "your follow key")
  return "Press " .. key .. " to follow " .. ns.PlainOfType(ns.LeadName(), "string", "the lead")
end

-- Only when the option is on and another window leads; force (the command) skips both.
function Follow.ShowCue(secs, force)
  local lead = ns.LeadName()
  if not force and (not ns.OptionOn("followCue") or lead == nil or lead == ns.MyName()) then return false end
  cue.text:SetText(Follow.CueText())
  cue:SetWidth((ns.PlainNumber(cue.text:GetStringWidth()) or 360) + 40)
  cue:Show()
  cueSerial = cueSerial + 1
  local mine = cueSerial
  ns.After(secs, function() if cueSerial == mine then cue:Hide() end end)
  if ns.OptionOn("followFlash") then ns.Try(FlashClientIcon) end
  return true
end

function Follow.HideCue()
  cueSerial = cueSerial + 1
  cue:Hide()
end

---------------------------------------------------------------------------
-- Stuck sampler: 1 s while following and out of combat
---------------------------------------------------------------------------
local ticker
local function StopSampler()
  if ticker then ticker:Cancel() end
  ticker = nil
end
function Follow.Ticking() return ticker ~= nil end

local function StartSampler()
  StopSampler()
  me.still = 0
  if ns.moveSecret or not me.following or ns.PlainTrue(InCombatLockdown()) then return end
  ticker = ns.Ticker(SAMPLE, Follow.Sample)
end

-- The unit we follow: the event's target when grouped with it, else the lead's.
local function FollowedUnit() return ns.UnitOf(me.target) or ns.UnitOf(ns.LeadName()) end

function Follow.Sample()
  if not me.following or ns.PlainTrue(InCombatLockdown()) then return end
  local moving = ns.Moving()
  if moving == nil then
    me.still = 0
    if ns.moveSecret then StopSampler() end -- off for the session
    return
  end
  if moving then
    me.still = 0
    if me.stuck then
      me.stuck, me.time = false, GetTime()
      Flush() -- moving again: 1
    end
    return
  end
  me.still = me.still + 1
  if me.stuck or me.still < StuckSecs() then return end
  local unit = FollowedUnit()
  local near = unit and Read(CheckInteractDistance, unit, 2)
  if IsSecret(near) or near ~= false or GetTime() - me.lastStuck < STUCK_COOLDOWN then return end
  me.stuck, me.lastStuck, me.time = true, GetTime(), GetTime()
  ns.Debug("stuck: still for", me.still, "s, out of range of", unit)
  Flush()
  Follow.ShowCue(CUE_TIME)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- The event may give "First Last-Realm" while roster and slot names are the
-- plain "First Last": strip the realm only when the stripped form is a known
-- team name (names are opaque otherwise).
local function TeamName(targetName)
  local t = ns.PlainOfType(targetName, "string", nil)
  if not t then return nil end
  local plain = t:gsub("%-[^%-]*$", "")
  if plain ~= t and (ns.UnitOf(plain) or ns.SlotOf(plain)) then return plain end
  return t
end

local function OnBegin(targetName)
  me.following, me.target, me.stuck, me.time = true, TeamName(targetName), false, GetTime()
  ns.Debug("follow begin:", me.target or "?")
  Follow.HideCue()
  StartSampler()
  Flush()
  ns.Rows.Refresh()
end

local function OnEnd()
  me.following, me.stuck, me.time = false, false, GetTime()
  me.cause, me.detail = Follow.Cause()
  me.holdUntil = GetTime() + HOLD
  ns.Debug("follow end:", me.cause, me.detail)
  StopSampler()
  ns.After(HOLD, Flush)
  if (me.cause == "stopped" or me.cause == "zone") and not ns.PlainTrue(InCombatLockdown()) then Follow.ShowCue(CUE_TIME) end
  ns.Rows.Refresh()
end
Follow.beginEvent = ns.On("AUTOFOLLOW_BEGIN", OnBegin)
Follow.endEvent = ns.On("AUTOFOLLOW_END", OnEnd)

ns.On("ZONE_CHANGED_NEW_AREA", function() lastZone = GetTime() end)
ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if IsSecret(isLogin) or IsSecret(isReload) then return end
  if not isLogin and not isReload then lastZone = GetTime() end
end)
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(unit, _, spellID)
  if IsSecret(unit) or unit ~= "player" then return end
  if not IsSecret(spellID) and spellID ~= nil and AUTO_ATTACK[spellID] then return end
  lastSpell = GetTime()
  lastSpellName = ns.Clean(Read(C_Spell and C_Spell.GetSpellName, spellID), 30)
end)
ns.On("PLAYER_REGEN_DISABLED", function()
  StopSampler()
  Follow.HideCue()
end)
ns.On("PLAYER_REGEN_ENABLED", function()
  Flush()
  StartSampler()
end)
ns.On("PLAYER_DEAD", Follow.HideCue)
ns.Status.AddFlag("f", function() return me.following end)

---------------------------------------------------------------------------
-- Receiving: records keyed by the sender's full name
---------------------------------------------------------------------------
Follow.records = {}   -- name -> { state, cause, detail, target, time }
local lastAlert = {}

ns.ops.F = function(sender, body)
  local state, a, b = strsplit(";", body)
  state = tonumber(state)
  if state ~= 0 and state ~= 1 and state ~= 2 then return end
  local rec = { state = state, cause = "stopped", detail = "", target = "", time = GetTime() }
  if state == 1 then
    rec.target = a or ""
  elseif state == 0 then
    rec.cause, rec.detail = (a and a ~= "") and a or "stopped", b or ""
  end
  Follow.records[sender] = rec
  if state == 2 and GetTime() - (lastAlert[sender] or -ALERT_GAP) >= ALERT_GAP
    and ns.LeadAlert("stuckAlert", (ns.Who(sender):gsub("^slot", "Slot")) .. " is stuck behind you", sender) then
    lastAlert[sender] = GetTime()
  end
  ns.Rows.Refresh()
end

-- Our own row reads the local state (after the first follow event).
function Follow.RecordFor(name)
  if name ~= ns.MyName() then return Follow.records[name] end
  if not me.time then return nil end
  return { state = me.following and (me.stuck and 2 or 1) or 0, cause = me.cause or "stopped", detail = me.detail,
    target = me.target or "", time = me.time, me = true }
end

ns.Listen("TEAM_CHANGED", function()
  for name in pairs(Follow.records) do
    if not ns.UnitOf(name) then Follow.records[name] = nil end
  end
end)

local function Grouped(name)
  if name == ns.MyName() then return ns.PlainTrue(IsInGroup()) end
  return ns.UnitOf(name) ~= nil
end

local function Age(rec) return math.floor(GetTime() - rec.time + 0.5) end

-- "following X" / "not following: cast Drink" / "stuck"
local function Words(rec)
  if rec.state == 2 then return "stuck" end
  if rec.state == 1 then return "following " .. (rec.target ~= "" and rec.target or "?") end
  return "not following: " .. (Follow.CAUSE_TEXT[rec.cause] or rec.cause) .. (rec.detail ~= "" and (" " .. rec.detail) or "")
end

ns.Rows.AddProvider(function(name, out)
  local rec = Follow.RecordFor(name)
  if not rec then return end
  if rec.state == 2 then
    out[#out + 1] = { "follow", "F?", 1, 0.6, 0.2, Words(rec) .. " " .. Age(rec) .. " s ago", 5 }
  elseif rec.state == 1 then
    out[#out + 1] = { "follow", "", 1, 1, 1, Words(rec), 5 }
  elseif Grouped(name) and name ~= ns.LeadName() then
    out[#out + 1] = { "follow", "F!", 1, 0.3, 0.3, Words(rec) .. ", " .. Age(rec) .. " s ago", 5 }
  end
end)

---------------------------------------------------------------------------
-- Command, status line, probe
---------------------------------------------------------------------------
local function State()
  local own = Follow.RecordFor(ns.MyName())
  return string.format("%s, told %s, stuck sampler %s%s", own and Words(own) or "no follow event yet",
    tostring(me.sent), ticker and "on" or "off", ns.moveSecret and " (off: movement is secret)" or "")
end
ns.Listen("STATUS_COMMAND", function() ns.Print("follow: " .. State()) end)

ns.AddCommand("follow", "follow [cue] - own follow state and every member's last report; cue shows the banner 5 s",
  function(rest)
    if (rest or ""):lower() == "cue" then
      Follow.ShowCue(5, true)
      ns.Print("cue: " .. Follow.CueText())
      return
    end
    ns.Print("you: " .. State())
    local slots = {}
    for slot in pairs(ns.Slots()) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
      local name = ns.Slots()[slot]
      if name ~= ns.MyName() then
        local rec = Follow.records[name]
        ns.Print(string.format("slot %d %s: %s", slot, name,
          rec and (Words(rec) .. string.format(" (%d s ago)", Age(rec))) or "no follow message yet"))
      end
    end
  end)

local function Describe(ok, v)
  if not ok then return "error or missing" end
  if IsSecret(v) then return "<secret " .. type(v) .. ">" end
  return tostring(v) .. " (" .. type(v) .. ")"
end

-- Lines for /mama plus probe follow (design probes F1-F4): returned, and
-- appended to the table given as the argument when there is one.
ns.AddProbe("follow", function(out)
  local lines = {}
  local function Add(label, ...) lines[#lines + 1] = label .. ": " .. Describe(...) end
  Add("GetBindingKey(" .. FOLLOW_KEY .. ")", ns.Try(GetBindingKey, FOLLOW_KEY))
  lines[#lines + 1] = "FlashClientIcon: " .. type(FlashClientIcon)
  Add("IsPlayerMoving()", ns.Try(IsPlayerMoving))
  Add("GetUnitSpeed(player)", ns.Try(GetUnitSpeed, "player"))
  local unit = ns.UnitOf(ns.LeadName())
  if unit then
    Add("CheckInteractDistance(" .. unit .. ", 2)", ns.Try(CheckInteractDistance, unit, 2))
  else
    lines[#lines + 1] = "CheckInteractDistance(lead, 2): not grouped under a lead"
  end
  lines[#lines + 1] = "AUTOFOLLOW_BEGIN valid: " .. tostring(ns.EventIsValid("AUTOFOLLOW_BEGIN"))
  lines[#lines + 1] = "AUTOFOLLOW_END valid: " .. tostring(ns.EventIsValid("AUTOFOLLOW_END"))
  lines[#lines + 1] = "state: " .. State()
  if type(out) == "table" then for _, l in ipairs(lines) do out[#out + 1] = l end end
  return lines
end)
