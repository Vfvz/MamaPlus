-- Tests for Idle.lua: options, login "0", ticker only in combat, idle after
-- the threshold, 45 s refresh, moving / casting / channelling / spell /
-- auto-repeat as activity, melee auto-attack and other units ignored,
-- secret spell ID counts, combat end and death end idle, threshold option,
-- secret or missing movement (never idle), /reload in combat, the 5 s gap
-- between transitions, keyed replacement during chat lockdown, receiver
-- records, IDLE row entry and tooltip, lead-only alert once per episode
-- (group leader and Mama's explicit lead), option off, stale drop, prune
-- on roster change, command, probe.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

-- Casts: state.casts[unit] / state.channels[unit] = { name = "Frostbolt" }
state.casts, state.channels = {}, {}
function UnitCastingInfo(u) local c = state.casts[u]; if c then return c.name, c.name, 1, 0, 1000, false, "cast-1", false, 1 end end
function UnitChannelInfo(u) local c = state.channels[u]; if c then return c.name, c.name, 1, 0, 1000, false, false, 1 end end
local SECRET_NUM = MakeSecret("number")

LoadModule("Idle.lua")
local Idle = ns.Idle
check(Idle.me.idle == nil and Idle.me.sent == nil, "load state not unknown")
-- Keep the heartbeat out of the limiter's bucket so idle timings are exact.
ns.Status.Send = function() return false end

local function idle() return Sent("I") end
local function last() local l = LastSent("I"); return l and l.payload end
local function count() return #idle() end
local function startCombat() state.combat = true; Fire("PLAYER_REGEN_DISABLED") end
local function endCombat() state.combat = false; Fire("PLAYER_REGEN_ENABLED") end

---------------------------------------------------------------------------
-- Login in a group sends one "0"; options registered
---------------------------------------------------------------------------
state.group = { "party1", "party2" }
Login()
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(count() == 1 and last() == "x;I;0", "login did not send 0: " .. tostring(last()))
check(idle()[1].kind == "group", "not sent to the group")
check(Idle.me.idle == false and Idle.me.sent == false, "login state")
check(ns.db.idleAlarm == true and ns.db.idleWarn == 5, "defaults")
local specs = {}
for _, s in ipairs(ns.optionSpecs) do specs[s.key] = s end
check(specs.idleAlarm and specs.idleAlarm.type == "toggle" and specs.idleAlarm.section == "Alerts to the lead", "idleAlarm option")
local w = specs.idleWarn
check(w and w.type == "number" and w.min == 2 and w.max == 20 and w.step == 1 and w.section == "This window", "idleWarn option")
check(Idle.spellEvent == true, "spell event not registered")
check(ns.commands.idle, "idle command missing")

---------------------------------------------------------------------------
-- Ticker only in combat; idle only after the threshold
---------------------------------------------------------------------------
check(LiveTickers() == 0 and not Idle.Ticking(), "ticker before combat")
Step(10)
check(count() == 1, "message out of combat")
startCombat()
check(LiveTickers() == 1 and Idle.Ticking() and tickers[1].d == 0.5, "ticker not started at 0.5 s")
Step(4.5)
check(count() == 1 and not Idle.me.idle, "idle before threshold")
Step(0.5)
check(Idle.me.idle and last() == "x;I;1;5", "idle start message: " .. tostring(last()))
local c = count()
Step(5)
check(count() == c, "idle start sent twice")

-- Still idle: "1" again every 45 s (receivers drop a mark after 90 s).
Step(39.5)
check(count() == c, "refresh too early")
Step(0.5)
check(count() == c + 1 and last() == "x;I;1;5", "no refresh at 45 s")
Step(90)
check(count() == c + 3 and Idle.me.idle, "refresh not every 45 s: " .. (count() - c))

---------------------------------------------------------------------------
-- Moving ends idle (the last send was a refresh, not a transition: no gap)
---------------------------------------------------------------------------
state.moving = true
Step(0.5)
check(not Idle.me.idle and last() == "x;I;0", "moving did not end idle")
Step(10)
check(not Idle.me.idle, "idle while moving")
state.moving = false
Step(4.5)
check(not Idle.me.idle, "idle too soon after moving")
Step(0.5)
check(Idle.me.idle and last() == "x;I;1;5", "not idle after moving stopped")

---------------------------------------------------------------------------
-- Casting and channelling are activity
---------------------------------------------------------------------------
Step(5)
state.casts.player = { name = "Frostbolt" }
Step(0.5)
check(not Idle.me.idle and last() == "x;I;0", "cast did not end idle")
Step(10)
check(not Idle.me.idle, "idle while casting")
state.casts.player = nil
Step(4.5)
check(not Idle.me.idle, "idle too soon after cast")
Step(0.5)
check(Idle.me.idle, "not idle after cast")
Step(5)
state.channels.player = { name = "Arcane Missiles" }
Step(0.5)
check(not Idle.me.idle, "channel did not end idle")
Step(10)
check(not Idle.me.idle, "idle while channelling")
state.channels.player = nil
Step(5)
check(Idle.me.idle, "not idle after channel")
-- A secret cast name is still a string: casting.
Step(5)
state.casts.player = { name = MakeSecret("string") }
Step(0.5)
check(not Idle.me.idle, "secret cast name not counted")
state.casts.player = nil
Step(5)
check(Idle.me.idle, "not idle after secret cast")

---------------------------------------------------------------------------
-- Own spell events (instant casts show no cast bar)
---------------------------------------------------------------------------
Step(5)
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1", 133)
check(not Idle.me.idle and last() == "x;I;0", "spell did not end idle")
Step(4.5)
check(not Idle.me.idle, "idle within window after spell")
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-2", 133)
Step(4.5)
check(not Idle.me.idle, "second spell not counted")
Step(0.5)
check(Idle.me.idle, "not idle after spell window")
-- Melee auto-attack does not count, nor another unit's cast.
Step(5)
c = count()
for _ = 1, 3 do
  Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-9", 6603)
  Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-3-9", 133)
  Idle.OnSpellSucceeded("target", "Cast-3-9", 133)
  Step(2)
end
check(Idle.me.idle and count() == c, "melee auto-attack or other unit counted as activity")
-- A secret spell ID cannot be checked, so it counts; a secret unit is ignored.
Idle.OnSpellSucceeded("player", "Cast-3-9", SECRET_NUM)
check(not Idle.me.idle, "secret spell ID not counted")
Step(5)
check(Idle.me.idle, "not idle again")
Idle.OnSpellSucceeded(SECRET_NUM, "Cast-3-9", 133)
check(Idle.me.idle, "secret unit counted")
-- Ranged auto-repeat running keeps the player active even with no shot events.
Step(5)
Fire("START_AUTOREPEAT_SPELL")
check(not Idle.me.idle, "auto-repeat start not counted")
Step(12)
check(not Idle.me.idle, "idle while Auto Shot / Shoot is running")
Fire("STOP_AUTOREPEAT_SPELL")
Step(4.5)
check(not Idle.me.idle, "idle too soon after auto-repeat")
Step(0.5)
check(Idle.me.idle, "still active after auto-repeat stopped")

---------------------------------------------------------------------------
-- Combat end ends idle and stops the ticker; death ends idle
---------------------------------------------------------------------------
Step(5)
endCombat()
check(not Idle.me.idle and last() == "x;I;0", "combat end did not end idle")
check(LiveTickers() == 0 and not Idle.Ticking(), "ticker still running after combat")
c = count()
Step(20)
check(count() == c, "messages after combat")
startCombat(); Step(2); endCombat()
check(count() == c and LiveTickers() == 0, "message without an idle episode, or ticker leaked")

startCombat()
check(LiveTickers() == 1, "one ticker per combat")
Step(5)
check(Idle.me.idle, "not idle before death")
state.dead.player = true
Fire("PLAYER_DEAD")
check(not Idle.me.idle, "death did not end idle")
Step(5)
check(last() == "x;I;0", "death end not sent")
Step(10)
check(not Idle.me.idle, "idle while dead")
state.dead.player = nil
Step(4.5)
check(not Idle.me.idle, "idle too soon after death")
Step(0.5)
check(Idle.me.idle, "not idle after revive")
endCombat(); Step(5)

---------------------------------------------------------------------------
-- Threshold option (clamped, in the message)
---------------------------------------------------------------------------
ns.SetOption("idleWarn", 8)
startCombat()
Step(7.5)
check(not Idle.me.idle, "idle before 8 s")
Step(0.5)
check(Idle.me.idle and last() == "x;I;1;8", "threshold not in message: " .. tostring(last()))
endCombat(); Step(5)
ns.SetOption("idleWarn", 99)
check(Idle.Warn() == 20, "threshold not clamped")
ns.SetOption("idleWarn", 5)

---------------------------------------------------------------------------
-- Movement secret or unavailable: never idle (ns.Moving() == nil)
---------------------------------------------------------------------------
c = count()
state.speedSecret = true
local p = #printed
startCombat(); Step(30)
check(not Idle.me.idle and count() == c, "idle with secret movement")
check(ns.moveSecret and #printed == p + 1 and printed[#printed]:find("movement is secret"), "secret movement not reported once")
state.casts.player = { name = "Fireball" }
Step(1)
state.casts.player = nil
Step(30)
check(not Idle.me.idle and count() == c, "idle after a cast with secret movement")
endCombat(); Step(5)
state.speedSecret = false
local realMoving, realSpeed = IsPlayerMoving, GetUnitSpeed
IsPlayerMoving, GetUnitSpeed = nil, nil
startCombat(); Step(30)
check(not Idle.me.idle and count() == c, "idle with no movement API")
-- Movement readable again mid-combat: counting starts from the last unknown sample.
IsPlayerMoving, GetUnitSpeed = realMoving, realSpeed
Step(4.5)
check(not Idle.me.idle, "idle counted while movement was unknown")
Step(0.5)
check(Idle.me.idle and count() == c + 1, "not idle once movement returned")
-- Movement vanishes while idle: idle ends.
IsPlayerMoving, GetUnitSpeed = nil, nil
Step(5.5)
check(not Idle.me.idle and last() == "x;I;0", "idle kept with no movement signal")
IsPlayerMoving, GetUnitSpeed = realMoving, realSpeed
endCombat(); Step(5)

---------------------------------------------------------------------------
-- /reload in combat: LOGIN starts the sampler and the first settled state
-- goes out; out of combat LOGIN sends "0" once.
---------------------------------------------------------------------------
local function reload()
  for _, tk in ipairs(tickers) do tk.cancelled = true end
  for k in pairs(Idle.me) do Idle.me[k] = nil end
  Idle.me.inCombat, Idle.me.sentAt, Idle.me.transAt, Idle.me.lastActive, Idle.me.autoRepeat = false, 0, 0, 0, false
end
startCombat(); Step(5)
check(Idle.me.idle, "idle before reload 1")
reload()
state.combat = true
c = count()
MamaForever:Fire("LOGIN")
check(LiveTickers() == 1 and Idle.me.inCombat and count() == c, "login in combat: no ticker or an early send")
Step(2)
check(count() == c and Idle.me.idle == nil, "sent before the state settled")
state.moving = true
Step(0.5)
check(count() == c + 1 and last() == "x;I;0", "no 0 after reload + moving")
state.moving = false
endCombat()
check(count() == c + 1, "second 0 at combat end")
-- Still idle after the reload: "1" again (receivers refresh, no new alert).
Step(5)
startCombat(); Step(5)
reload()
state.combat = true
MamaForever:Fire("LOGIN")
c = count()
Step(5)
check(Idle.me.idle and count() == c + 1 and last() == "x;I;1;5", "no 1 after reload while idle")
endCombat(); Step(5)
-- Combat ended during the loading screen: LOGIN sends one 0, a second LOGIN nothing.
startCombat(); Step(5)
reload()
state.combat = false
c = count()
MamaForever:Fire("LOGIN")
check(count() == c + 1 and last() == "x;I;0" and LiveTickers() == 0, "no 0 at login out of combat")
MamaForever:Fire("LOGIN")
check(count() == c + 1, "0 repeated at login")

---------------------------------------------------------------------------
-- Transitions at least 5 s apart: a change inside the gap waits and only
-- the state at the end of the gap goes out, when it still differs.
---------------------------------------------------------------------------
Step(5)
ns.SetOption("idleWarn", 2)
startCombat(); Step(2)
check(Idle.me.idle and last() == "x;I;1;2", "idle at 2 s")
c = count()
state.moving = true
Step(1)
check(not Idle.me.idle and count() == c, "0 sent inside the gap")
Step(3.5)
check(count() == c, "0 sent before the gap ended")
Step(0.5)
check(count() == c + 1 and last() == "x;I;0", "0 not sent at the end of the gap")
-- A blip (active 1.5 s, idle again) inside the gap sends nothing at all.
state.moving = false
Step(5.5)
check(Idle.me.idle and last() == "x;I;1;2", "idle again")
c = count()
state.moving = true
Step(1)
state.moving = false
Step(2.5)
check(Idle.me.idle and count() == c, "blip sent")
Step(2)
check(count() == c, "blip sent at the end of the gap")
Step(10)
check(count() == c, "blip sent later")
-- After the gap a change goes out at once.
state.moving = true
Step(0.5)
check(count() == c + 1 and last() == "x;I;0", "change after the gap held")
state.moving = false
endCombat(); Step(5)
ns.SetOption("idleWarn", 5)

---------------------------------------------------------------------------
-- Chat lockdown: the held idle start is replaced by the end
---------------------------------------------------------------------------
c = count()
state.lockdown = true
startCombat(); Step(5)
check(Idle.me.idle and count() == c and ns.PendingCount() == 1, "sent during lockdown")
Step(5)
endCombat()
check(count() == c, "sent during lockdown (end)")
state.lockdown = false
Step(1.5)
check(count() == c + 1 and last() == "x;I;0" and ns.PendingCount() == 0, "held start not replaced: " .. tostring(last()))
Step(5)
check(count() == c + 1, "held start resent")

---------------------------------------------------------------------------
-- Receiver: record, IDLE entry, alert on the lead once per episode
---------------------------------------------------------------------------
local ALT, ALT2 = "Pri Cuthbridge", "Vf Pr"
local function entry(name)
  for _, e in ipairs(ns.Rows.Entries(name)) do if e[1] == "idle" then return e end end
end
local function recv(sender, body) Deliver(sender, "x;I;" .. body) end

check(not entry(ALT), "entry before message")
check(ns.IsLead(), "not the lead in this setup")
local warns, snd = #warnings, #sounds
recv(ALT, "1;5")
local e = entry(ALT)
check(e and e[2] == "IDLE" and e[3] == 1 and e[4] < 0.5 and e[5] < 0.5 and e[7] == 4, "idle entry")
check(e[6] == "in combat and standing still for 5+ s", "entry tip: " .. tostring(e[6]))
check(not entry(ALT2), "entry on the wrong row")
check(#warnings == warns + 1 and warnings[#warnings] == "Slot 2 Pri Cuthbridge is idle in combat",
  "alert text: " .. tostring(warnings[#warnings]))
check(#sounds == snd + 1 and sounds[#sounds] == 8959, "alert sound")
check(ns.Rows.IsFlashing(ALT), "row not flashing")
MamaForever:RefreshStatus()
check(MamaForeverStatusRow2.plus.text:find("IDLE", 1, true), "IDLE not drawn on row 2")
check(not MamaForeverStatusRow1.plus.text:find("IDLE", 1, true), "IDLE drawn on our own row")
-- Same episode again: no second alert; end clears; a new episode alerts again.
Advance(1)
recv(ALT, "1;5")
check(#warnings == warns + 1, "alerted twice in one episode")
recv(ALT, "0")
check(not entry(ALT) and Idle.records[ALT] == nil, "end message did not clear")
recv(ALT, "1;5")
check(#warnings == warns + 2, "new episode did not alert")
recv(ALT, "0")
-- Own messages never come back from Mama's dispatcher.
warns = #warnings
recv("Han Jaconelli", "1;5")
check(#warnings == warns and not entry("Han Jaconelli"), "own message accepted")
-- Malformed messages are ignored; extra fields and bad thresholds tolerated.
recv(ALT, "x"); recv(ALT, ""); recv(ALT, "2;5")
check(not entry(ALT) and #warnings == warns, "malformed message accepted")
recv(ALT, "1;7;new;stuff")
check(entry(ALT)[6] == "in combat and standing still for 7+ s", "extra field broke parsing")
recv(ALT, "1;9")
check(entry(ALT)[6] == "in combat and standing still for 9+ s", "threshold not refreshed")
for _, bad in ipairs({ "", ";", ";abc", ";0", ";2.5", ";100", ";-3" }) do
  recv(ALT, "1" .. bad)
  check(entry(ALT)[6] == "in combat and standing still", "bad threshold '" .. bad .. "'")
end
recv(ALT, "0")
warns = #warnings

---------------------------------------------------------------------------
-- Not the lead / explicit lead / option off: icon only
---------------------------------------------------------------------------
state.leader = "party1"
check(not ns.IsLead(), "still lead")
recv(ALT, "1;5")
check(#warnings == warns and entry(ALT), "non-lead alerted or lost entry")
-- Becoming lead mid-episode does not alert for that episode.
state.leader = "player"
recv(ALT, "1;5")
check(#warnings == warns, "alerted mid-episode")
recv(ALT, "0")
-- Mama's explicit lead on this window alerts even when the game leader is another.
state.leader = "party1"
MamaForever.db.lead = "Han Jaconelli"
check(ns.IsLead(), "explicit lead not seen")
recv(ALT2, "1;5")
check(#warnings == warns + 1 and warnings[#warnings] == "Slot 3 Vf Pr is idle in combat", "explicit lead not alerted")
recv(ALT2, "0")
MamaForever.db.lead = ALT
recv(ALT2, "1;5")
check(#warnings == warns + 1, "alerted while another window is the explicit lead")
recv(ALT2, "0")
MamaForever.db.lead = false
state.leader = "player"
-- Command toggles the alert; the icon stays.
ns.RunCommand("idle off")
check(ns.db.idleAlarm == false and printed[#printed]:find("idle alert off", 1, true), "idle off")
snd = #sounds
recv(ALT, "1;5")
check(#warnings == warns + 1 and #sounds == snd and entry(ALT), "option off: alerted or no entry")
recv(ALT, "0")
ns.RunCommand("idle on")
check(ns.db.idleAlarm == true, "idle on")
ns.RunCommand("idle")
check(printed[#printed]:find("idle alert on", 1, true) and printed[#printed]:find("after 5 s", 1, true), "idle line")

---------------------------------------------------------------------------
-- Stale marks drop after 90 s; refreshes keep them without a second alert
---------------------------------------------------------------------------
warns = #warnings
recv(ALT, "1;5")
check(#warnings == warns + 1, "alert before stale test")
Step(89)
check(entry(ALT), "dropped too early")
Step(2)
check(not entry(ALT) and Idle.records[ALT] == nil, "stale mark kept")
recv(ALT, "1;5")
check(#warnings == warns + 2, "new episode after stale drop")
for _ = 1, 4 do
  Step(45)
  recv(ALT, "1;5")
  check(entry(ALT), "refreshed mark dropped")
end
check(#warnings == warns + 2, "refresh alerted again")
-- A receiver that lost its records (reload) learns the state from the next refresh.
wipe(Idle.records)
Step(45)
recv(ALT, "1;5")
check(entry(ALT) and #warnings == warns + 3, "refresh not shown after receiver reload")
recv(ALT, "0")
Flush()

---------------------------------------------------------------------------
-- Roster changes prune members who left; status line; probe
---------------------------------------------------------------------------
recv(ALT, "1;5"); recv(ALT2, "1;5")
check(entry(ALT) and entry(ALT2), "both idle")
state.group = { "party1" }
Fire("GROUP_ROSTER_UPDATE")
check(Idle.records[ALT] and Idle.records[ALT2] == nil, "left member kept or current member pruned")
state.group = {}
Fire("GROUP_ROSTER_UPDATE")
check(next(Idle.records) == nil, "records kept after leaving the group")
Flush()

p = #printed
ns.RunCommand("status")
local found = false
for i = p + 1, #printed do if printed[i]:find("idle: out of combat", 1, true) then found = true end end
check(found, "no idle status line")
-- The probe fills the runner's add(name, value) callable (Probe.lua renders
-- secret and nil values); a missing or raising API reads "error or missing".
local function probe()
  local out = setmetatable({}, { __call = function(t, name, value)
    t[#t + 1] = tostring(name) .. ": " .. (issecretvalue(value) and ("<secret " .. type(value) .. ">") or tostring(value))
  end })
  ns.probes.idle[1](out)
  return out
end
local function has(lines, s) for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end return false end
local lines = probe()
check(#lines >= 9 and has(lines, "IsPlayerMoving(): false") and has(lines, "GetUnitSpeed(player): 0")
  and has(lines, "UNIT_SPELLCAST_SUCCEEDED registered: true") and lines[#lines]:find("^state: out of combat"),
  "probe lines: " .. table.concat(lines, " | "))
IsPlayerMoving = nil
check(has(probe(), "IsPlayerMoving(): error or missing"), "probe with a missing API")
IsPlayerMoving = realMoving
-- A secret value is handed to the runner untouched, so it can render it.
state.speedSecret = true
lines = probe()
check(has(lines, "IsPlayerMoving(): <secret boolean>") and has(lines, "GetUnitSpeed(player): <secret number>"),
  "secret probe value: " .. table.concat(lines, " | "))
state.speedSecret = false

print("IDLE TESTS PASSED")
