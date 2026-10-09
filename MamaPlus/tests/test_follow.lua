-- Tests for Follow.lua: options and registration, no wrapper on Mama's F
-- handler, F;1 on BEGIN only after a sent 0/2, the heartbeat f flag, the
-- 1 s end hold cancelled by a re-follow, cause order (died > taxi > zone >
-- cast > combat > stopped) with secret and missing readings, nothing sent
-- in combat and one flush at regen, the stuck sampler (threshold, plain
-- false range only, once per episode, cooldown, 1 again when moving,
-- lifecycle, secret movement), the cue rules, the receiver records and
-- row entries, the lead alert on F;2 only (15 s per sender), prune, the
-- follow command, the status line and the probe.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

---------------------------------------------------------------------------
-- Extra mock APIs (before LoadModule)
---------------------------------------------------------------------------
state.casts, state.channels, state.spells = {}, {}, { [133] = "Fireball", [6603] = "Attack", [2061] = "Flash Heal" }
function UnitCastingInfo(u) local c = state.casts[u]; if c then return c.name, c.name, nil, 0, 1000 end end
function UnitChannelInfo(u) local c = state.channels[u]; if c then return c.name, c.name, nil, 0, 1000 end end
local MF = MamaForever
local mamaF = function() end
MF.messageHandlers.F = mamaF

LoadModule("Follow.lua")
local Follow = ns.Follow
local ME, PRI, VF = "Han Jaconelli", "Pri Cuthbridge", "Vf Pr"

local function fSent() local out = {}; for _, s in ipairs(Sent("F")) do out[#out + 1] = s.payload end; return out end
local function lastF() local l = fSent(); return l[#l] end
local function countF() return #fSent() end
local function entry(name) for _, e in ipairs(ns.Rows.Entries(name)) do if e[1] == "follow" then return e end end end
local function begin(target) Fire("AUTOFOLLOW_BEGIN", target or PRI) end
local function stop() Fire("AUTOFOLLOW_END") end
local function startCombat() state.combat = true; Fire("PLAYER_REGEN_DISABLED") end
local function endCombat() state.combat = false; Fire("PLAYER_REGEN_ENABLED") end
local function cueShown() return Follow.cue:IsShown() end
local function lastPrinted() return printed[#printed] or "" end

Login({ "party1", "party2" })
Step(14) -- the login heartbeats empty the limiter's bucket; let it refill

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
check(ns.db.stuckAlert == false and ns.db.stuckSecs == 4 and ns.db.followCue == true and ns.db.followFlash == false, "defaults")
local specs = {}
for _, s in ipairs(ns.optionSpecs) do specs[s.key] = s end
check(specs.stuckAlert.type == "toggle" and specs.stuckAlert.section == "Alerts to the lead", "stuckAlert option")
local s = specs.stuckSecs
check(s.type == "number" and s.min == 2 and s.max == 15 and s.step == 1 and s.section == "This window", "stuckSecs option")
check(specs.followCue.section == "This window" and specs.followFlash.section == "This window", "cue options")
check(ns.commands.follow and ns.ops.F and ns.probes.follow, "command, receiver or probe missing")
check(Follow.beginEvent == true and Follow.endEvent == true, "AUTOFOLLOW events not registered")
check(MF.messageHandlers.F == mamaF, "Mama's F handler was wrapped")
check(not cueShown() and not Follow.Ticking() and countF() == 0, "state before any event")
check(ns.Status.Local().flags == "-" and entry(ME) == nil, "flag or own entry before any event")

---------------------------------------------------------------------------
-- BEGIN: F;1 once, flag f, sampler, own row line
---------------------------------------------------------------------------
begin()
check(countF() == 1 and lastF() == "x;F;1;Pri Cuthbridge" and LastSent("F").kind == "group", "begin message: " .. tostring(lastF()))
check(ns.Status.Local().flags == "f", "f flag: " .. ns.Status.Local().flags)
check(Follow.Ticking() and LiveTickers() == 1 and tickers[#tickers].d == 1, "sampler not running")
local e = entry(ME)
check(e and e[2] == "" and e[6] == "following Pri Cuthbridge" and e[7] == 5, "own following entry: " .. tostring(e and e[6]))
begin()
check(countF() == 1, "duplicate 1 on a second BEGIN")
-- A secret or missing target name gives a bare 1.
stop(); Step(2)
check(countF() == 2 and lastF() == "x;F;0;stopped", "end message: " .. tostring(lastF()))
Fire("AUTOFOLLOW_BEGIN", MakeSecret("string"))
check(lastF() == "x;F;1" and Follow.me.target == nil, "secret target: " .. tostring(lastF()))
stop(); Step(2)
begin()
Step(4)

---------------------------------------------------------------------------
-- END hold: a re-follow within 1 s cancels the 0
---------------------------------------------------------------------------
local c = countF()
stop()
check(countF() == c and ns.Status.Local().flags == "-" and not Follow.Ticking(), "0 sent before the hold")
Step(0.5)
begin()
Step(2)
check(countF() == c, "0 sent after a re-follow, or a duplicate 1: " .. tostring(lastF()))
stop()
Step(0.5)
check(countF() == c, "0 sent at 0.5 s")
Step(0.5)
check(countF() == c + 1 and lastF() == "x;F;0;stopped", "0 not sent after the hold: " .. tostring(lastF()))
e = entry(ME)
check(e == nil, "F! on our own row while we lead")
Step(4)

---------------------------------------------------------------------------
-- Cause order
---------------------------------------------------------------------------
local function cause(setup, cleanup)
  begin(); Step(2)
  if setup then setup() end
  stop(); Step(2)
  if cleanup then cleanup() end
  Step(2)
  return lastF()
end
local function all()
  state.dead.player, state.taxi = true, true
  Fire("ZONE_CHANGED_NEW_AREA")
  state.casts.player = { name = "Fireball" }
  state.combat = true
end
local function none()
  state.dead.player, state.taxi, state.casts.player = nil, false, nil
  if state.combat then state.combat = false; Fire("PLAYER_REGEN_ENABLED") end
end
check(cause(all, none) == "x;F;0;died", "died first: " .. tostring(lastF()))
check(cause(function() all(); state.dead.player = nil end, none) == "x;F;0;taxi", "taxi second: " .. tostring(lastF()))
check(cause(function() all(); state.dead.player, state.taxi = nil, false end, none) == "x;F;0;zone", "zone third: " .. tostring(lastF()))
check(cause(function() state.casts.player = { name = "Fireball" }; state.combat = true end, none) == "x;F;0;cast;Fireball",
  "cast fourth: " .. tostring(lastF()))
check(cause(function() state.channels.player = { name = "Drink" } end, function() state.channels.player = nil end)
  == "x;F;0;cast;Drink", "channel: " .. tostring(lastF()))
-- Zone: only within 3 s, also from a non-login PLAYER_ENTERING_WORLD.
check(cause(function() Fire("ZONE_CHANGED_NEW_AREA"); Step(3.5) end) == "x;F;0;stopped", "zone after 3 s")
check(cause(function() Fire("PLAYER_ENTERING_WORLD", false, false) end) == "x;F;0;zone", "entering world")
check(cause(function() Fire("PLAYER_ENTERING_WORLD", true, false) end) == "x;F;0;stopped", "login counted as a zone change")
check(cause(function() Fire("PLAYER_ENTERING_WORLD", MakeSecret("boolean"), false) end) == "x;F;0;stopped", "secret login flag")
-- A recent own spell counts, melee auto-attack and other units do not.
check(cause(function() Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 133) end) == "x;F;0;cast;Fireball", "spell: " .. tostring(lastF()))
check(cause(function() Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 133); Step(1) end) == "x;F;0;stopped", "spell after 0.5 s")
check(cause(function() Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 6603) end) == "x;F;0;stopped", "auto-attack counted")
check(cause(function() Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-1", 133) end) == "x;F;0;stopped", "other unit's spell counted")
-- Secret spell ID: a cast with no detail; secret cast name: the same; long names cut to 30 bytes.
check(cause(function() Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", MakeSecret("number")) end) == "x;F;0;cast", "secret spell id: " .. tostring(lastF()))
check(cause(function() state.casts.player = { name = MakeSecret("string") } end, none) == "x;F;0;cast", "secret cast name: " .. tostring(lastF()))
check(cause(function() state.casts.player = { name = "Summon Felsteed Of The Burning Legion; Now" } end, none)
  == "x;F;0;cast;Summon Felsteed Of The Burning", "long cast name: " .. tostring(lastF()))
-- Missing cast APIs: no error, stopped.
local realCast, realChan = UnitCastingInfo, UnitChannelInfo
UnitCastingInfo, UnitChannelInfo = nil, nil
check(cause() == "x;F;0;stopped", "missing cast APIs")
UnitCastingInfo, UnitChannelInfo = realCast, realChan
-- Secret death / taxi readings are not causes.
local realDead = UnitIsDeadOrGhost
UnitIsDeadOrGhost = function() return MakeSecret("boolean") end
check(cause(function() state.taxi = true end, none) == "x;F;0;taxi", "secret death reading")
UnitIsDeadOrGhost = realDead

---------------------------------------------------------------------------
-- Combat: nothing sent, one flush at regen when the state differs
---------------------------------------------------------------------------
begin(); Step(2)
c = countF()
startCombat()
check(not Follow.Ticking(), "sampler in combat")
stop()
check(Follow.me.cause == "combat", "cause in combat: " .. tostring(Follow.me.cause))
Step(5)
check(countF() == c, "0 sent in combat")
begin(); stop(); begin(); stop()
Step(2)
check(countF() == c, "messages in combat")
endCombat()
check(countF() == c + 1 and lastF() == "x;F;0;combat", "no flush at regen: " .. tostring(lastF()))
Step(2)
check(countF() == c + 1, "second flush")
-- Re-followed before combat ends: the state matches the last sent 1, nothing goes out.
begin(); Step(2)
c = countF()
startCombat(); stop(); begin(); endCombat(); Step(2)
check(countF() == c and Follow.Ticking(), "flush without a change, or sampler not back")
-- Combat start and end while following and nothing changed: nothing.
startCombat(); endCombat(); Step(2)
check(countF() == c, "regen flush without a change")
-- The hold still applies to an end just before regen.
startCombat(); stop(); state.combat = false; Fire("PLAYER_REGEN_ENABLED")
check(countF() == c, "hold skipped at regen")
Step(1)
check(countF() == c + 1 and lastF() == "x;F;0;combat", "held 0 not sent after regen: " .. tostring(lastF()))
Step(4)

---------------------------------------------------------------------------
-- Stuck sampler (Pri leads, so the cue may show)
---------------------------------------------------------------------------
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(ns.LeadName() == PRI and not ns.IsLead(), "Pri not the lead")
Step(14)
state.near.party1 = { [2] = false }
state.moving = true
begin(); Step(2)
state.moving = false
c = countF()
Step(3)
check(countF() == c and not Follow.me.stuck, "stuck before the threshold")
Step(1)
check(countF() == c + 1 and lastF() == "x;F;2" and Follow.me.stuck, "no 2 at 4 s: " .. tostring(lastF()))
check(cueShown() and Follow.cue.text.text == "Press your follow key to follow Pri Cuthbridge", "cue on stuck: " .. tostring(Follow.cue.text.text))
e = entry(ME)
check(e and e[2] == "F?" and e[6] == "stuck 0 s ago", "own stuck entry: " .. tostring(e and e[6]))
Step(10)
check(countF() == c + 1, "2 repeated while still stuck")
-- Moving again: 1; stuck again only 10 s after the last 2.
state.moving = true
Step(1)
check(countF() == c + 2 and lastF() == "x;F;1;Pri Cuthbridge" and not Follow.me.stuck, "no 1 after moving: " .. tostring(lastF()))
state.moving = false
Step(4)
check(countF() == c + 3 and lastF() == "x;F;2", "no second episode after the cooldown: " .. tostring(lastF()))
state.moving = true; Step(1)
check(lastF() == "x;F;1;Pri Cuthbridge", "1 after the second episode")
state.moving = false; Step(4)
check(countF() == c + 4, "stuck again inside the cooldown")
Step(5)
check(countF() == c + 5 and lastF() == "x;F;2", "stuck after the cooldown: " .. tostring(lastF()))
state.moving = true; Step(1)
Step(14)
c = countF()
-- In range, secret, missing or raising range API: no 2.
state.moving = false
state.near.party1 = true
Step(6)
check(countF() == c, "stuck while in range")
state.near.party1 = { [2] = MakeSecret("boolean") }
Step(6)
check(countF() == c, "stuck from a secret range")
local realCID = CheckInteractDistance
CheckInteractDistance = nil
Step(6)
CheckInteractDistance = function() error("boom") end
Step(6)
check(countF() == c, "stuck with the range API missing or raising")
CheckInteractDistance = realCID
-- Moving samples reset the count.
state.near.party1 = { [2] = false }
state.moving = true; Step(1); state.moving = false
Step(3); state.moving = true; Step(1); state.moving = false; Step(3)
check(countF() == c, "count not reset by a move")
Step(1)
check(countF() == c + 1 and lastF() == "x;F;2", "stuck after the reset")
state.moving = true; Step(1)
Step(14)
-- The threshold option.
ns.SetOption("stuckSecs", 2)
c = countF()
state.moving = false
Step(2)
check(countF() == c + 1 and lastF() == "x;F;2", "stuckSecs 2 not used")
ns.SetOption("stuckSecs", 4)
state.moving = true; Step(1)
Step(14)
-- A realm-suffixed team name is stripped: sent plain and sampled on its own unit.
state.leader = "party2"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(ns.LeadName() == VF, "Vf not the lead")
stop(); Step(2); Fire("AUTOFOLLOW_BEGIN", "Pri Cuthbridge-Realm"); Step(2)
check(lastF() == "x;F;1;Pri Cuthbridge" and Follow.me.target == PRI, "realm suffix kept: " .. tostring(lastF()))
c = countF()
state.near.party1, state.near.party2 = { [2] = false }, true
state.moving = false
Step(4)
check(countF() == c + 1 and lastF() == "x;F;2", "stuck not sampled on Pri's unit: " .. tostring(lastF()))
state.moving = true; Step(1)
state.near.party2 = nil
Step(14)
-- An unknown suffixed name is kept whole (names are opaque).
stop(); Step(2); Fire("AUTOFOLLOW_BEGIN", "Nobody Known-Realm"); Step(2)
check(lastF() == "x;F;1;Nobody Known-Realm", "unknown name stripped: " .. tostring(lastF()))
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
Step(14)
-- The followed unit: the lead's when the target is not grouped with us.
stop(); Step(2); begin("Nobody Known"); Step(2)
c = countF()
state.moving = false
Step(4)
check(countF() == c + 1 and lastF() == "x;F;2", "lead unit not used as a fallback: " .. tostring(lastF()))
state.moving = true; Step(1)
Step(14)
-- END stops the sampler, combat pauses it, regen resumes it.
stop(); Step(2)
check(not Follow.Ticking() and LiveTickers() == 0, "sampler after end")
begin(); Step(2)
startCombat()
check(not Follow.Ticking() and LiveTickers() == 0, "sampler during combat")
c = countF()
state.moving = false
Step(6)
check(countF() == c, "sample taken in combat")
endCombat()
check(Follow.Ticking() and LiveTickers() == 1, "sampler not back after combat")
Step(4)
check(countF() == c + 1 and lastF() == "x;F;2", "no stuck after combat: " .. tostring(lastF()))
state.moving = true; Step(1)
Step(14)
-- Secret movement: the sampler stops for the session.
state.speedSecret = true
c = countF()
Step(1)
check(ns.moveSecret and not Follow.Ticking(), "sampler kept with secret movement")
stop(); Step(2); begin(); Step(6)
check(not Follow.Ticking() and countF() == c + 2 and lastF() == "x;F;1;Pri Cuthbridge", "sampler restarted with secret movement")
state.speedSecret, ns.moveSecret = false, false
stop(); Step(2); begin(); Step(2)
check(Follow.Ticking(), "sampler not back once movement is plain")
stop(); Step(2)
state.moving, state.near.party1 = false, nil
Step(14)

---------------------------------------------------------------------------
-- Cue rules (Pri leads)
---------------------------------------------------------------------------
state.bindings["CLICK MamaFollow:LeftButton"] = "F11"
local function flashed() return flashes end
check(cueShown(), "no cue from the sampler section's end")
Follow.HideCue()
begin(); Step(2)
check(not cueShown(), "cue on begin")
local fl = flashed()
stop()
check(cueShown() and Follow.cue.text.text == "Press F11 to follow Pri Cuthbridge", "cue on stop: " .. tostring(Follow.cue.text.text))
check(flashed() == fl, "flashed without followFlash")
e = entry(ME)
check(e and e[2] == "F!" and e[3] == 1 and e[4] == 0.3 and e[5] == 0.3 and e[6] == "not following: stopped (moved by hand or stuck), 0 s ago",
  "own F! entry: " .. tostring(e and e[6]))
Step(29.5)
check(cueShown(), "cue hidden early")
Step(0.5)
check(not cueShown(), "cue not hidden after 30 s")
Step(4)
-- BEGIN, combat and death hide it; a later timeout does not hide a newer cue.
begin(); Step(2); stop()
check(cueShown(), "cue before begin")
begin()
check(not cueShown(), "cue kept on begin")
Step(2); stop()
check(cueShown(), "cue before combat")
startCombat()
check(not cueShown(), "cue kept in combat")
endCombat(); Step(2)
begin(); Step(2); stop()
Fire("PLAYER_DEAD")
check(not cueShown(), "cue kept on death")
Step(4)
begin(); Step(2); stop(); Step(20); begin(); Step(2); stop(); Step(10.5)
check(cueShown(), "older timeout hid a newer cue")
Step(20)
check(not cueShown(), "newer cue never hidden")
Step(4)
-- Zone shows it out of combat only; died, taxi, cast and combat never.
begin(); Step(2); Fire("ZONE_CHANGED_NEW_AREA"); stop()
check(cueShown(), "no cue on a zone change")
Follow.HideCue(); Step(6)
begin(); Step(2); startCombat(); Fire("ZONE_CHANGED_NEW_AREA"); stop()
check(not cueShown(), "cue on a zone change in combat")
endCombat(); Step(6)
for _, setup in ipairs({ function() state.dead.player = true end, function() state.taxi = true end,
  function() state.casts.player = { name = "Fireball" } end, function() startCombat() end }) do
  begin(); Step(2); setup(); stop()
  check(not cueShown(), "cue on a cause other than stopped or zone")
  none(); Fire("PLAYER_REGEN_ENABLED"); Step(6)
end
-- Option off, no binding, flash option, and never when we lead.
ns.SetOption("followCue", false)
begin(); Step(2); stop()
check(not cueShown(), "cue with the option off")
ns.SetOption("followCue", true)
state.bindings["CLICK MamaFollow:LeftButton"] = nil
ns.SetOption("followFlash", true)
fl = flashed()
Step(6); begin(); Step(2); stop()
check(cueShown() and Follow.cue.text.text == "Press your follow key to follow Pri Cuthbridge", "generic cue text: " .. tostring(Follow.cue.text.text))
check(flashed() == fl + 1, "no flash with followFlash")
ns.SetOption("followFlash", false)
Follow.HideCue(); Step(6)
-- Missing FlashClientIcon never raises.
ns.SetOption("followFlash", true)
local realFlash = FlashClientIcon
FlashClientIcon = nil
begin(); Step(2); stop()
check(cueShown(), "cue without FlashClientIcon")
FlashClientIcon = realFlash
ns.SetOption("followFlash", false)
Follow.HideCue(); Step(6)
state.leader = "player"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(ns.IsLead(), "not the lead again")
Step(14)
begin(); Step(2); stop()
check(not cueShown(), "cue on the lead window")
Step(6)
-- Stuck on the lead window: 2 is sent, but no cue.
state.moving, state.near.party1 = false, { [2] = false }
begin(); Step(5)
check(lastF() == "x;F;2" and not cueShown(), "cue for a stuck lead window")
state.moving, state.near.party1 = true, nil
Step(1); stop(); Step(2); state.moving = false
Step(14)
-- The command shows it 5 s whatever the option and the lead.
ns.SetOption("followCue", false)
ns.RunCommand("follow cue")
check(cueShown() and lastPrinted():find("cue: Press your follow key to follow Han Jaconelli", 1, true), "follow cue command: " .. lastPrinted())
Step(5)
check(not cueShown(), "command cue not hidden after 5 s")
ns.SetOption("followCue", true)

---------------------------------------------------------------------------
-- Receiver: records, row entries, alert on 2 only
---------------------------------------------------------------------------
check(entry(PRI) == nil and entry(VF) == nil, "entries before any message")
Deliver(PRI, "x;F;1;Han Jaconelli")
local rec = Follow.records[PRI]
check(rec and rec.state == 1 and rec.target == ME and rec.time == GetTime(), "1 record")
e = entry(PRI)
check(e and e[2] == "" and e[6] == "following Han Jaconelli" and e[7] == 5, "following entry: " .. tostring(e and e[6]))
Deliver(PRI, "x;F;1")
check(entry(PRI)[6] == "following ?", "bare 1: " .. entry(PRI)[6])
local warns, snd = #warnings, #sounds
Deliver(PRI, "x;F;0;stopped")
rec = Follow.records[PRI]
check(rec.state == 0 and rec.cause == "stopped" and rec.detail == "", "0 record")
e = entry(PRI)
check(e and e[2] == "F!" and e[3] == 1 and e[4] == 0.3 and e[5] == 0.3 and e[7] == 5
  and e[6] == "not following: stopped (moved by hand or stuck), 0 s ago", "F! entry: " .. tostring(e and e[6]))
Advance(12)
check(entry(PRI)[6]:find(", 12 s ago", 1, true), "age: " .. entry(PRI)[6])
Deliver(PRI, "x;F;0;cast;Drink")
check(entry(PRI)[6] == "not following: cast Drink, 0 s ago", "cast detail: " .. entry(PRI)[6])
Deliver(PRI, "x;F;0;died")
check(entry(PRI)[6] == "not following: died, 0 s ago", "died text: " .. entry(PRI)[6])
Deliver(PRI, "x;F;0;newcause;x")
check(entry(PRI)[6] == "not following: newcause x, 0 s ago", "unknown cause: " .. entry(PRI)[6])
Deliver(PRI, "x;F;0")
check(entry(PRI)[6]:find("^not following: stopped", 1), "0 without a cause: " .. entry(PRI)[6])
check(#warnings == warns and #sounds == snd, "alert on 0 or 1")
-- Stuck: F? and, with the option on (off by default), one alert on the lead, then not again for 15 s.
ns.SetOption("stuckAlert", true)
Deliver(PRI, "x;F;2")
rec = Follow.records[PRI]
check(rec.state == 2, "2 record")
e = entry(PRI)
check(e and e[2] == "F?" and e[3] == 1 and e[4] == 0.6 and e[5] == 0.2 and e[6] == "stuck 0 s ago" and e[7] == 5, "F? entry: " .. tostring(e and e[6]))
check(#warnings == warns + 1 and warnings[#warnings] == "Slot 2 Pri Cuthbridge is stuck behind you" and #sounds == snd + 1,
  "stuck alert: " .. tostring(warnings[#warnings]))
check(ns.Rows.IsFlashing(PRI), "row not flashing")
Advance(14)
Deliver(PRI, "x;F;2")
check(#warnings == warns + 1, "alerted twice within 15 s")
Advance(1)
Deliver(PRI, "x;F;2")
check(#warnings == warns + 2, "no alert after 15 s")
check(entry(PRI)[6] == "stuck 0 s ago", "stuck age")
-- Another sender has its own spacing; an unknown slot still alerts by name.
Deliver(VF, "x;F;2")
check(#warnings == warns + 3 and warnings[#warnings] == "Slot 3 Vf Pr is stuck behind you", "second sender: " .. tostring(warnings[#warnings]))
Deliver("Zz Yy", "x;F;2")
check(#warnings == warns + 4 and warnings[#warnings] == "Zz Yy is stuck behind you", "unknown sender: " .. tostring(warnings[#warnings]))
Advance(20)
-- Option off: icon, no alert. Not the lead: the same.
ns.SetOption("stuckAlert", false)
Deliver(PRI, "x;F;2")
check(#warnings == warns + 4 and entry(PRI)[2] == "F?", "alert with the option off")
ns.SetOption("stuckAlert", true)
Advance(20)
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
Deliver(VF, "x;F;2")
check(#warnings == warns + 4 and entry(VF)[2] == "F?", "alert on a non-lead window")
-- The lead's own row never shows F!; a non-lead grouped member does.
Deliver(PRI, "x;F;0;stopped")
Deliver(VF, "x;F;0;stopped")
check(entry(PRI) == nil and entry(VF)[2] == "F!", "F! on the lead or missing on a member")
state.leader = "player"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(entry(PRI)[2] == "F!", "F! missing once Pri no longer leads")
-- Malformed messages are ignored.
for _, bad in ipairs({ "x;F;5", "x;F;abc", "x;F;", "x;F", "x;F;1.5;x" }) do
  Deliver(PRI, bad)
  check(Follow.records[PRI].state == 0, "malformed accepted: " .. bad)
end
-- Alone we show no F! on our own row; in a group, as a non-lead, we do.
state.group = {}
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(Follow.records[PRI] == nil and Follow.records[VF] == nil and Follow.records["Zz Yy"] == nil, "records kept after leaving")
Step(14)
begin(); Step(2); stop(); Step(2)
check(entry(ME) == nil, "own F! while alone")
state.group = { "party1", "party2" }
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(entry(ME) and entry(ME)[2] == "F!", "own F! missing as a grouped non-lead")
-- Members who left are pruned, current ones kept.
Deliver(PRI, "x;F;0;stopped")
Deliver(VF, "x;F;1;Han Jaconelli")
state.group = { "party1" }
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(Follow.records[PRI] and Follow.records[VF] == nil, "prune")
state.group = { "party1", "party2" }
Fire("GROUP_ROSTER_UPDATE"); Flush()

---------------------------------------------------------------------------
-- Command, status line, probe
---------------------------------------------------------------------------
Deliver(VF, "x;F;1;Pri Cuthbridge")
Advance(3)
local p = #printed
ns.RunCommand("follow")
check(#printed == p + 3, "follow lines: " .. (#printed - p))
check(printed[p + 1]:find("you: not following: stopped (moved by hand or stuck), told 0, stuck sampler off", 1, true), "own line: " .. printed[p + 1])
check(printed[p + 2]:find("slot 2 Pri Cuthbridge: not following: stopped (moved by hand or stuck) (3 s ago)", 1, true), "Pri line: " .. printed[p + 2])
check(printed[p + 3]:find("slot 3 Vf Pr: following Pri Cuthbridge (3 s ago)", 1, true), "Vf line: " .. printed[p + 3])
Follow.records[VF] = nil
ns.RunCommand("follow")
check(lastPrinted():find("slot 3 Vf Pr: no follow message yet", 1, true), "line without a record: " .. lastPrinted())
p = #printed
ns.RunCommand("status")
local found = false
for i = p + 1, #printed do if printed[i]:find("follow: not following: stopped (moved by hand or stuck), told 0, stuck sampler off", 1, true) then found = true end end
check(found, "no follow status line")

state.bindings["CLICK MamaFollow:LeftButton"] = "F11"
local function has(lines, s) for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end return false end
local lines = ns.probes.follow[1]()
check(#lines >= 8 and has(lines, "GetBindingKey(CLICK MamaFollow:LeftButton): F11 (string)"), "probe binding line: " .. table.concat(lines, " | "))
check(has(lines, "FlashClientIcon: function") and has(lines, "IsPlayerMoving(): false (boolean)") and has(lines, "GetUnitSpeed(player): 0 (number)"),
  "probe API lines: " .. table.concat(lines, " | "))
check(has(lines, "CheckInteractDistance(party1, 2): true (boolean)") and has(lines, "AUTOFOLLOW_BEGIN valid: true")
  and has(lines, "AUTOFOLLOW_END valid: true") and lines[#lines]:find("^state: ", 1), "probe range/event/state lines: " .. table.concat(lines, " | "))
local out = {}
ns.probes.follow[1](out)
check(#out == #lines, "probe did not fill the table")
state.speedSecret = true
state.group = {}
Fire("GROUP_ROSTER_UPDATE"); Flush()
lines = ns.probes.follow[1]()
check(has(lines, "GetUnitSpeed(player): <secret number>") and has(lines, "CheckInteractDistance(lead, 2): not grouped under a lead"),
  "probe secret / alone: " .. table.concat(lines, " | "))
state.speedSecret = false

print("FOLLOW TESTS PASSED")
