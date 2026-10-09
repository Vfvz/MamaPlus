-- Tests for Death.lua and DeathDesk.lua: options and registration, self-res
-- gating (absent API, error, nil, secret, non-empty), own state a/d/g from
-- events and the 1 s re-read, the R heartbeat field and its end-time
-- encoding, the 5 s corpse/spirit flag hold, the prompt (texts, buttons,
-- Escape, a parent hide), click and timer outcomes (ok on the state
-- change, a late ok, unchanged, FORBIDDEN naming the call, an unrelated
-- FORBIDDEN), a death in combat, auto-release gating (option, Hardcore,
-- secret ruleset, disabled, self-res; no click record needed) and the gates
-- asked again at expiry, the greyed toggle after a blocked timer path and
-- "death reset", the R;r hold and its expiry, R;x, R;c from the lead only,
-- RESURRECT_REQUEST, auto-retrieve (corpse, delay, lead alive, 3 tries, each
-- announced), the healer report (by spell ID, repeat presses, FAILED_QUIET),
-- desk rows/footer/WIPE/cancel, coalesced alerts, providers, commands (with
-- their own outcome keys), status line and probe.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

-- Handler errors are collected; none are expected.
local errors = {}
function geterrorhandler() return function(err) errors[#errors + 1] = tostring(err) end end

-- Extra mock APIs (before LoadModule): spell names for the healer report.
state.spells = { [2006] = "Resurrection", [7328] = "Redemption", [2008] = "Ancestral Spirit", [20484] = "Rebirth",
  [133] = "Fireball" }

LoadModule("Death.lua")
LoadModule("DeathDesk.lua")
local Death, Desk = ns.Death, ns.DeathDesk
local me = Death.me
local MF = MamaForever
local ME, PRI, VF = "Han Jaconelli", "Pri Cuthbridge", "Vf Pr"
local BUILD = "70205"

local function rSent() local out = {}; for _, s in ipairs(Sent("R")) do out[#out + 1] = s.payload end; return out end
local function lastR() local l = rSent(); return l[#l] end
local function countR() return #rSent() end
local function countH() return #Sent("H") end
local function lastH() local s = LastSent("H"); return s and s.payload end
local function fieldR(payload) return payload and payload:match(";R=([^;]*)") end
local function called(name) local n = 0; for _, c in ipairs(calls) do if c == name then n = n + 1 end end; return n end
local function lastPrinted() return printed[#printed] or "" end
local function findPrint(s, from)
  for i = #printed, from or 1, -1 do if printed[i]:find(s, 1, true) then return i end end
end
local function probe(key) return ns.db.deathProbe and ns.db.deathProbe[BUILD] and ns.db.deathProbe[BUILD][key] end
local function die() state.dead.player = true; Fire("PLAYER_DEAD") end
local function revive() state.dead.player, state.ghost.player = nil, nil; Fire("PLAYER_UNGHOST"); Step(4) end
local function hb(name, R, extra) Deliver(name, "x;H;0.1.0;-;100;-" .. (R and (";R=" .. R) or "") .. (extra or "")) end
local function entry(name, kind) for _, e in ipairs(ns.Rows.Entries(name)) do if e[1] == kind then return e end end end
local function clickRelease() Death.prompt.release:RunScript("OnClick") end
local function clickRetrieve() Death.prompt.retrieve:RunScript("OnClick") end
local function clearProbe() ns.db.deathProbe = {} end
-- Beats run every BEAT seconds from T_LOGIN + FIRST_BEAT (the mock's
-- NextBeat reads both from Status): step past the next one when it would
-- land inside a window of secs seconds, so the countH() deltas are exact.
local function beatFree(secs)
  local gap = NextBeat() - GetTime()
  if gap < secs + 4 then Step(gap + 3.5) end -- past the beat and its 3 s send gap
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
Login({ "party1", "party2" })
Step(14) -- the login heartbeats empty the limiter's bucket; let it refill
check(ns.db.deathDesk == true and ns.db.deathAlert == true and ns.db.autoRelease == false and ns.db.autoReleaseSecs == 30
  and ns.db.autoRetrieve == false, "defaults")
local specs = {}
for _, s in ipairs(ns.optionSpecs) do specs[s.key] = s end
check(specs.deathAlert.section == "Alerts to the lead" and specs.deathDesk.section == "Death", "sections")
check(specs.autoRelease.enabledWhen and specs.autoRetrieve.enabledWhen and specs.autoRelease.onChange
  and specs.autoRelease.note:find("RepopMe() from a timer was blocked", 1, true) and specs.autoRelease.note:find("death reset", 1, true)
  and specs.autoRetrieve.note:find("RetrieveCorpse()", 1, true), "enabledWhen/note/onChange")
local s = specs.autoReleaseSecs
check(s.type == "number" and s.min == 5 and s.max == 120 and s.step == 5 and s.section == "Death", "autoReleaseSecs option")
check(specs.autoRelease.enabledWhen() == true and specs.autoRetrieve.enabledWhen() == true, "enabledWhen on a normal realm")
state.hardcore = true
check(specs.autoRelease.enabledWhen() == false and specs.autoRetrieve.enabledWhen() == false, "enabledWhen on Hardcore")
local gameRule = C_GameRules.IsGameRuleActive
C_GameRules.IsGameRuleActive = nil
state.hardcore = "secret"; check(specs.autoRelease.enabledWhen() == false, "enabledWhen with a secret ruleset")
C_GameRules.IsGameRuleActive = gameRule
state.hardcore = false
check(ns.commands.death and ns.ops.R and ns.probes.death, "command, receiver or probe missing")
check(Death.prompt == MamaPlusDeathPrompt and UISpecialFrames[1] == "MamaPlusDeathPrompt", "prompt frame")
check(Desk.frame == MamaPlusDeathDesk and not Desk.frame:IsShown(), "desk frame")
check(Death.sentEvent == true, "UNIT_SPELLCAST_SENT not registered")
check(me.state == "a" and not Death.prompt:IsShown(), "initial state")

---------------------------------------------------------------------------
-- Self-res gating
---------------------------------------------------------------------------
check(Death.SelfRes() == "none", "empty options")
state.selfRes = { "Soulstone" }
local sr, why = Death.SelfRes()
check(sr == "blocked" and why == "available", "non-empty options")
state.selfRes = nil; check(Death.SelfRes() == "blocked", "nil options")
state.selfRes = MakeSecret("table"); check(Death.SelfRes() == "blocked", "secret options")
local realApi = C_DeathInfo.GetSelfResurrectOptions
C_DeathInfo.GetSelfResurrectOptions = function() error("boom") end
check(Death.SelfRes() == "blocked", "erroring API")
C_DeathInfo = nil
sr, why = Death.SelfRes()
check(sr == "blocked" and why == "no API", "absent API")
C_DeathInfo = { GetSelfResurrectOptions = realApi }
state.selfRes = {}

---------------------------------------------------------------------------
-- Own state, field R, prompt
---------------------------------------------------------------------------
check(not fieldR(";" .. table.concat(ns.Status.Local().fields, ";")), "R field while alive")
local h = countH()
die()
check(me.state == "d" and me.diedAt == GetTime(), "dead state")
check(Death.prompt:IsShown() and Death.prompt.title:GetText() == "You died", "prompt on death")
check(Death.prompt.release:IsShown() and not Death.prompt.retrieve:IsShown(), "buttons while dead")
check(me.releaseAt == nil and not Death.prompt.text:GetText():find("auto"), "armed with the option off")
Step(1)
check(countH() == h + 1 and fieldR(lastH()) == "d.-", "H after death: " .. tostring(lastH()))
check(entry(ME, "death") and entry(ME, "death")[2] == "" and entry(ME, "death")[6]:find("dead 0:0"), "own tooltip line")
state.selfRes = { "Soulstone" }; Death.UpdatePrompt()
check(Death.prompt.text:GetText():find("Soulstone available: auto-release off", 1, true), "soulstone line")
state.selfRes = {}
state.recoveryDelay = 30; Death.UpdatePrompt()
check(Death.prompt.text:GetText():find("wait 30 s", 1, true), "wait line")
state.recoveryDelay = 0
-- Corpse flag: shown at once, told after a 15 s hold.
beatFree(18)
h = countH()
Fire("CORPSE_IN_RANGE")
check(me.corpse and ns.Status.Local().fields.R == "dc.-", "corpse flag")
Step(14.5)
check(countH() == h, "flag sent before the hold")
Step(2)
check(countH() == h + 1 and fieldR(lastH()) == "dc.-", "flag not sent after the hold: " .. tostring(lastH()))
-- A flap within the hold is one send with the final value.
beatFree(20)
h = countH()
Fire("CORPSE_OUT_OF_RANGE"); Step(1); Fire("CORPSE_IN_RANGE"); Step(1); Fire("CORPSE_OUT_OF_RANGE")
Step(17)
check(countH() == h + 1 and fieldR(lastH()) == "d.-", "flap: " .. (countH() - h) .. " " .. tostring(lastH()))
beatFree(18)
Fire("AREA_SPIRIT_HEALER_IN_RANGE"); Step(17)
check(me.spirit and fieldR(lastH()) == "ds.-", "spirit flag: " .. tostring(lastH()))
Fire("AREA_SPIRIT_HEALER_OUT_OF_RANGE"); Step(17)
-- Click Release: ghost after the 1 s re-read, outcome ok.
clickRelease()
check(called("RepopMe") == 1, "RepopMe not called")
Step(2.5)
check(me.state == "g" and probe("repopClick") == "ok", "release outcome: " .. tostring(probe("repopClick")))
check(Death.prompt.title:GetText() == "ghost: corpse far" and Death.prompt.retrieve:IsShown()
  and not Death.prompt.release:IsShown(), "ghost prompt: " .. tostring(Death.prompt.title:GetText()))
check(fieldR(lastH()) == "g.-", "H after release: " .. tostring(lastH()))
Fire("CORPSE_IN_RANGE")
check(Death.prompt.title:GetText() == "ghost: corpse near", "corpse near title")
check(entry(ME, "ghost") and entry(ME, "ghost")[2] == "G" and entry(ME, "ghost")[7] == 3
  and entry(ME, "ghost")[6]:find("corpse near", 1, true), "G entry")
-- Retrieve with a delay is refused, then works.
state.recoveryDelay = 12
clickRetrieve()
check(called("RetrieveCorpse") == 0 and lastPrinted():find("corpse recovery in 12 s", 1, true), "retrieve with delay")
state.recoveryDelay = 0
clickRetrieve()
check(called("RetrieveCorpse") == 1, "RetrieveCorpse not called")
Step(2.5)
check(me.state == "a" and probe("retrieveClick") == "ok" and not Death.prompt:IsShown(), "retrieve outcome")
check(not me.corpse and not fieldR(";" .. table.concat(ns.Status.Local().fields, ";")), "flags after revive")
check(LiveTickers() == 0, "own ticker still running while alive")
-- PLAYER_ALIVE reads the state (ghost after a release, alive after a res).
die(); state.dead.player = nil; state.ghost.player = true; Fire("PLAYER_ALIVE")
check(me.state == "g", "PLAYER_ALIVE -> ghost")
state.ghost.player = nil; Fire("PLAYER_ALIVE")
check(me.state == "a", "PLAYER_ALIVE -> alive")
-- Blocked click: RepopMe does nothing -> button hidden, the game's popup.
clearProbe()
state.repopBlocked = true
die(); clickRelease(); Step(4.5)
check(me.state == "d" and probe("repopClick") == nil and Death.prompt.release:IsShown(), "outcome before the 5 s window")
Step(1)
check(me.state == "d" and probe("repopClick") == "blocked", "blocked click outcome")
check(not Death.prompt.release:IsShown() and Death.prompt.text:GetText():find("use the game's own popup", 1, true)
  and findPrint("use the game's own popup"), "blocked click prompt")
state.repopBlocked = nil
revive(); clearProbe()
-- ADDON_ACTION_FORBIDDEN naming us during the 2 s is a blocked outcome.
die(); clickRelease()
Fire("ADDON_ACTION_FORBIDDEN", "MamaPlus", "RepopMe()")
Step(2.5)
check(probe("repopClick") == "blocked" and me.state == "g", "FORBIDDEN outcome")
revive(); clearProbe()
-- A blocked action that is not ours (FollowUnit) inside the window does not speak for the call.
die(); clickRelease()
Fire("ADDON_ACTION_FORBIDDEN", "MamaPlus", "FollowUnit()")
Step(2.5)
check(probe("repopClick") == "ok" and me.state == "g", "unrelated FORBIDDEN counted: " .. tostring(probe("repopClick")))
revive(); clearProbe()
-- A hide through a parent (Alt+Z, a cinematic) leaves the frame itself shown: not a close.
die()
Death.prompt:RunScript("OnHide")
check(not me.closed and Death.prompt:IsShown(), "parent hide closed the prompt")
-- Escape closes the prompt; it comes back on the next death.
Death.prompt:Hide()
check(me.closed and not Death.prompt:IsShown(), "prompt closed")
Death.UpdatePrompt()
check(not Death.prompt:IsShown(), "prompt reopened by a refresh")
revive(); die()
check(Death.prompt:IsShown(), "prompt not back on the next death")
revive()

---------------------------------------------------------------------------
-- Dying in combat (the usual case): the H waits in the limiter for the chat
-- lockdown to lift, the prompt and the desk show at once, a countdown arms.
---------------------------------------------------------------------------
beatFree(10)
h = countH()
state.combat, state.lockdown = true, true
Fire("PLAYER_REGEN_DISABLED")
die(); Step(3)
check(Death.prompt:IsShown() and Desk.frame:IsShown(), "prompt or desk missing on a combat death")
check(countH() == h and ns.PendingCount() == 1, "H during the chat lockdown: " .. (countH() - h) .. " sent, " .. ns.PendingCount() .. " pending")
state.combat, state.lockdown = false, false
Fire("PLAYER_REGEN_ENABLED"); Step(1.5)
check(fieldR(lastH()) == "d.-" and ns.PendingCount() == 0, "H after combat: " .. tostring(lastH()))
check(Desk.frame.body:GetText():find("1 Han Jaconelli dead", 1, true), "desk row after combat: " .. tostring(Desk.frame.body:GetText()))
revive()
-- With auto-release on: armed in combat, the end time goes out after combat, the release fires.
ns.SetOption("autoRelease", true)
beatFree(45)
state.combat, state.lockdown = true, true
Fire("PLAYER_REGEN_DISABLED")
die()
check(me.releaseAt ~= nil and me.releaseEnd ~= nil, "not armed on a combat death")
local endInCombat = me.releaseEnd
Step(3)
state.combat, state.lockdown = false, false
Fire("PLAYER_REGEN_ENABLED"); Step(1.5)
check(fieldR(lastH()) == "d." .. endInCombat, "end time after combat: " .. tostring(lastH()))
Step(30)
check(me.state == "g" and probe("repopAuto") == "ok" and ns.db.autoRelease == true, "auto-release after a combat death")
revive(); clearProbe()
ns.SetOption("autoRelease", false)

---------------------------------------------------------------------------
-- Auto-release: gating
---------------------------------------------------------------------------
ns.SetOption("autoRelease", true)
state.hardcore = true; die()
check(me.releaseAt == nil, "armed on Hardcore"); revive()
local gameRule2 = C_GameRules.IsGameRuleActive
C_GameRules.IsGameRuleActive = nil; state.hardcore = "secret"; die()
check(me.releaseAt == nil, "armed with a secret ruleset"); revive()
C_GameRules.IsGameRuleActive = gameRule2; state.hardcore = false
MF.db.disabled[ME] = true; die()
check(me.releaseAt == nil, "armed while disabled"); revive()
MF.db.disabled[ME] = nil
state.selfRes = { "Soulstone" }; die()
check(me.releaseAt == nil and Death.prompt.text:GetText():find("Soulstone", 1, true), "armed with a self-res option"); revive()
state.selfRes = {}
ns.SetOption("autoRelease", false); die()
check(me.releaseAt == nil, "armed with the option off"); revive()
ns.SetOption("autoRelease", true)

---------------------------------------------------------------------------
-- Auto-release: countdown, end-time field, one send, expiry. No hand click
-- is needed first (deathProbe is empty here): the toggle is a plain opt-in
-- and the first timer attempt on a build is its own probe.
---------------------------------------------------------------------------
local rp = called("RepopMe")
beatFree(40)
local p = #printed
h = countH()
die()
local endExpected = GetServerTime() + 30
check(me.releaseAt == GetTime() + 30 and me.releaseEnd == endExpected, "countdown armed")
check(findPrint("auto-release in 30 s", p), "arm line")
check(Death.prompt.text:GetText():find("auto-release in 30 s", 1, true), "prompt countdown")
Step(1.5)
check(countH() == h + 1 and fieldR(lastH()) == "d." .. endExpected, "end time field: " .. tostring(lastH()))
Step(27.5)
-- No further change send; a beat in the window repeats the same end time.
check(countH() <= h + 2 and called("RepopMe") == rp + 0, "sent again or released early: " .. (countH() - h))
for i = h + 1, countH() do check(fieldR(Sent("H")[i].payload) == "d." .. endExpected, "end time changed") end
check(Death.prompt.text:GetText():find("auto-release in 1 s", 1, true), "countdown text: " .. Death.prompt.text:GetText())
Step(1.5)
check(called("RepopMe") == rp + 1 and me.releaseAt == nil, "not released at expiry")
Step(2.5)
check(me.state == "g" and probe("repopAuto") == "ok" and ns.db.autoRelease == true, "auto outcome")
revive()
-- autoReleaseSecs is clamped.
ns.SetOption("autoReleaseSecs", 3); die(); check(me.releaseAt == GetTime() + 5, "clamp low"); revive()
ns.SetOption("autoReleaseSecs", 500); die(); check(me.releaseAt == GetTime() + 120, "clamp high"); revive()
ns.SetOption("autoReleaseSecs", 30)

---------------------------------------------------------------------------
-- Auto-release: cancels
---------------------------------------------------------------------------
-- R;c from a non-lead is ignored; from the lead it cancels.
die()
Deliver(PRI, "x;R;c")
check(me.releaseAt ~= nil, "cancelled by a non-lead")
state.leader = "party1"
check(ns.LeadName() == PRI, "lead not Pri")
Deliver(PRI, "x;R;c")
check(me.releaseAt == nil and lastPrinted():find("cancelled by the lead", 1, true), "not cancelled by the lead")
Step(35)
check(me.state == "d" and called("RepopMe") == rp + 1, "released after the lead's cancel")
state.leader = "player"
revive()
-- Local RESURRECT_REQUEST drops it and shows the offer; the offer expires after 60 s.
die()
Fire("RESURRECT_REQUEST", "Pri Cuthbridge")
check(me.releaseAt == nil and me.offer == PRI, "offer did not cancel")
check(Death.prompt.text:GetText():find("res offered by Pri Cuthbridge", 1, true), "offer line")
Step(1.5)
check(fieldR(lastH()) == "do.-", "offer flag: " .. tostring(lastH()))
check(entry(ME, "res") and entry(ME, "res")[2] == "RES" and entry(ME, "res")[7] == 9, "RES entry")
Step(59)
check(me.offer == nil and not entry(ME, "res"), "offer kept past 60 s")
Fire("RESURRECT_REQUEST", MakeSecret("string"))
check(me.offer == "?", "secret offerer")
revive()
-- A click releases at once and ends the countdown.
die(); clickRelease()
check(called("RepopMe") == rp + 2 and me.releaseAt == nil, "click did not release")
Step(2.5); revive()
-- A parent hide (Alt+Z) keeps the countdown; Escape cancels.
die(); Death.prompt:RunScript("OnHide")
check(me.releaseAt ~= nil and not me.closed, "parent hide cancelled")
Death.prompt:Hide()
check(me.releaseAt == nil and lastPrinted():find("prompt closed", 1, true), "Escape did not cancel")
Step(35); check(called("RepopMe") == rp + 2, "released after Escape")
revive()
-- The option going off mid-countdown cancels; Mama disabled at expiry skips the release.
die(); ns.SetOption("autoRelease", false)
check(me.releaseAt == nil and lastPrinted():find("cancelled: option off", 1, true), "option off did not cancel")
Step(35); check(called("RepopMe") == rp + 2, "released after the option went off")
revive(); ns.SetOption("autoRelease", true)
die(); MF.db.disabled[ME] = true; p = #printed; Step(31)
check(called("RepopMe") == rp + 2 and me.state == "d" and findPrint("auto-release skipped: Mama disabled", p), "released while disabled")
MF.db.disabled[ME] = nil; revive()
-- A self-res option appearing while armed cancels.
die(); state.selfRes = { "Soulstone" }; Fire("SELF_RES_SPELL_CHANGED")
check(me.releaseAt == nil, "self-res change did not cancel")
state.selfRes = {}; revive()

---------------------------------------------------------------------------
-- Auto-release: the R;r hold (20 s), lifted by R;x, dropped by an offer
---------------------------------------------------------------------------
die()
Step(20)
Deliver(PRI, "x;R;r;Resurrection;Han Jaconelli")
check(Death.resCasts[PRI] and Death.resCasts[PRI].spell == "Resurrection", "res cast not recorded")
Step(10.5)
check(called("RepopMe") == rp + 2 and me.releaseAt ~= nil, "released during the hold")
check(Death.prompt.text:GetText():find("auto-release held", 1, true), "hold text")
Step(9)
check(called("RepopMe") == rp + 2, "released before the hold expired")
Step(1.5)
check(called("RepopMe") == rp + 3, "not released after the hold expired")
Step(2.5); revive()
-- R;x lifts the hold early (from the caster only).
die(); Step(25)
Deliver(PRI, "x;R;r;Redemption;Vf Pr"); Step(5.5)
check(called("RepopMe") == rp + 3, "released during the second hold")
Deliver(VF, "x;R;x"); Step(0.5)
check(called("RepopMe") == rp + 3, "another sender's x lifted the hold")
Deliver(PRI, "x;R;x"); Step(0.5)
check(called("RepopMe") == rp + 4, "x did not lift the hold")
Step(2.5); revive()
-- The offer during a hold drops the release for good.
die(); Step(25)
Deliver(PRI, "x;R;r;Resurrection;Han Jaconelli")
Fire("RESURRECT_REQUEST", "Pri Cuthbridge")
Step(40)
check(called("RepopMe") == rp + 4 and me.state == "d", "released after an offer")
revive()

---------------------------------------------------------------------------
-- Auto-release: a blocked timer path turns the option off
---------------------------------------------------------------------------
state.repopBlocked = true
p = #printed
die(); Step(31)
check(called("RepopMe") == rp + 5, "blocked path not tried")
Step(5.5)
check(probe("repopAuto") == "blocked" and ns.db.autoRelease == false, "blocked auto outcome")
check(findPrint("auto-release turned off", p) and #printed - p <= 6, "no single off line")
check(findPrint("death reset", p), "off line without the reset hint")
-- The toggle is greyed (its note names the reset); the other one is not.
check(specs.autoRelease.enabledWhen() == false and specs.autoRetrieve.enabledWhen() == true, "toggle not greyed after a blocked timer path")
state.repopBlocked = nil
revive()
-- Turned on behind the panel's back (saved variables): nothing arms, one visible line per session.
ns.SetOption("autoRelease", true); p = #printed; die()
check(me.releaseAt == nil and findPrint("auto-release is off: RepopMe() from a timer was blocked", p), "armed after a blocked outcome on this build")
revive(); p = #printed; die()
check(me.releaseAt == nil and not findPrint("auto-release is off", p + 1), "blocked line repeated")
revive()
-- /mama plus death reset forgets the record: the toggle is live again and the next death arms.
p = #printed
ns.RunCommand("death reset")
check(probe("repopAuto") == nil and specs.autoRelease.enabledWhen() == true
  and findPrint("death outcomes for build 70205 cleared (were repopClick=ok repopAuto=blocked retrieveClick=-", p),
  "death reset: " .. tostring(probe("repopAuto")))
die(); check(me.releaseAt ~= nil, "not armed after the reset"); revive()
-- A release the server acknowledges late (3.5 s after the call) is still "ok", not "blocked".
state.repopBlocked = true
die(); Step(31)
check(called("RepopMe") == rp + 6 and me.state == "d", "slow release: not called")
Step(2.5)
state.repopBlocked = nil; state.dead.player, state.ghost.player = nil, true
Step(1)
check(me.state == "g" and probe("repopAuto") == "ok" and ns.db.autoRelease == true, "slow release outcome: " .. tostring(probe("repopAuto")))
revive(); clearProbe()
ns.SetOption("autoRelease", false)

---------------------------------------------------------------------------
-- Auto-retrieve
---------------------------------------------------------------------------
local function ghost() die(); state.dead.player = nil; state.ghost.player = true; Fire("PLAYER_ALIVE") end
ns.SetOption("autoRetrieve", true)
local rc = called("RetrieveCorpse")
ghost(); Step(3)
check(called("RetrieveCorpse") == rc, "retrieved without the corpse in range")
state.recoveryDelay = 5
Fire("CORPSE_IN_RANGE"); Step(3)
check(called("RetrieveCorpse") == rc, "retrieved during the recovery delay")
check(Death.prompt.text:GetText():find("auto-retrieve on", 1, true) and Death.prompt.text:GetText():find("wait 5 s", 1, true),
  "prompt without the auto-retrieve line: " .. tostring(Death.prompt.text:GetText()))
state.recoveryDelay = 0
state.leader = "party1"; hb(PRI, "g.-"); Step(3)
check(called("RetrieveCorpse") == rc and Death.prompt.text:GetText():find("waiting for the lead", 1, true), "lead a ghost")
p = #printed
hb(PRI, nil); Step(1.5)
check(called("RetrieveCorpse") == rc + 1 and findPrint("auto-retrieve: try 1 of 3", p), "not retrieved (or not announced) with the lead alive")
Step(2.5)
check(me.state == "a" and probe("retrieveAuto") == "ok", "auto-retrieve outcome")
state.leader = "player"
-- Hardcore: never.
state.hardcore = true; ghost(); Fire("CORPSE_IN_RANGE"); Step(3)
check(called("RetrieveCorpse") == rc + 1, "retrieved on Hardcore"); state.hardcore = false; revive()
-- Three tries 5 s apart, then the option goes off.
state.retrieveBlocked = true
p = #printed
ghost(); Fire("CORPSE_IN_RANGE"); Step(1.5)
check(called("RetrieveCorpse") == rc + 2, "first try")
Step(4); check(called("RetrieveCorpse") == rc + 2, "second try too early")
Step(1.5); check(called("RetrieveCorpse") == rc + 3, "second try")
Step(5); check(called("RetrieveCorpse") == rc + 4, "third try")
Step(5.5)
check(probe("retrieveAuto") == "blocked" and ns.db.autoRetrieve == false and findPrint("auto-retrieve turned off", p),
  "blocked retrieve outcome")
check(specs.autoRetrieve.enabledWhen() == false and specs.autoRelease.enabledWhen() == true, "retrieve toggle not greyed")
Step(10); check(called("RetrieveCorpse") == rc + 4, "tried after the option went off")
state.retrieveBlocked = nil
revive(); ns.RunCommand("death reset")
check(probe("retrieveAuto") == nil and specs.autoRetrieve.enabledWhen() == true, "retrieve toggle still greyed after the reset")

---------------------------------------------------------------------------
-- Healer report
---------------------------------------------------------------------------
Step(14)
local r = countR()
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-1", 2006)
check(countR() == r + 1 and lastR() == "x;R;r;Resurrection;Vf Pr", "res cast report: " .. tostring(lastR()))
Step(2)
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-2", 2006)
check(countR() == r + 1, "x for another cast")
Fire("UNIT_SPELLCAST_FAILED", "party1", "Cast-1", 2006)
check(countR() == r + 1, "x for another unit")
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", 2006)
check(countR() == r + 2 and lastR() == "x;R;x", "no x for the failed cast")
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", 2006)
check(countR() == r + 2, "x twice")
Step(2)
Fire("UNIT_SPELLCAST_SENT", "player", "", "Cast-3", 20484); Step(2)
check(lastR() == "x;R;r;Rebirth;?", "empty target: " .. tostring(lastR()))
Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-3", 20484); Step(2)
check(lastR() == "x;R;x", "no x for the interrupted cast")
Fire("UNIT_SPELLCAST_SENT", "player", MakeSecret("string"), "Cast-4", 2008); Step(2)
check(lastR() == "x;R;r;Ancestral Spirit;?", "secret target: " .. tostring(lastR()))
r = countR()
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-5", 133)
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-6", MakeSecret("number"))
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-7", 99999)
Fire("UNIT_SPELLCAST_SENT", "party1", "Vf Pr", "Cast-8", 2006)
check(countR() == r, "report for a non-res, secret, unknown or other unit's spell")
-- A secret cast GUID: the report goes out, no x can match it.
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", MakeSecret("string"), 7328); Step(2)
check(lastR() == "x;R;r;Redemption;Vf Pr", "secret guid report")
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-9", 7328)
check(lastR() == "x;R;r;Redemption;Vf Pr", "x without a matching guid")
-- A repeat press: a second SENT for the same spell, quietly failed, does not end the first cast's hold.
Step(16)   -- earlier casts whose end was never seen are forgotten
r = countR()
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-A", 2006); Step(2)
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-B", 2006); Step(2)
check(countR() == r + 2, "two reports")
Fire("UNIT_SPELLCAST_FAILED_QUIET", "player", "Cast-B", 2006); Step(2)
check(countR() == r + 2, "x while the first cast is still in flight")
Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-A", 2006); Step(2)
check(countR() == r + 3 and lastR() == "x;R;x", "no x once nothing is in flight")
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-B", 2006); Step(2)
check(countR() == r + 3, "x twice")
-- A finished cast ends quietly (its target gets RESURRECT_REQUEST); a rank the client has no name for uses the label.
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-C", 2010); Step(2)
check(lastR() == "x;R;r;Resurrection;Vf Pr", "rank 2 by ID with the label: " .. tostring(lastR()))
r = countR()
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-C", 2010); Step(2)
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-C", 2010); Step(2)
check(countR() == r and Death.ownCasts["Cast-C"] == nil, "x after a success")
Fire("UNIT_SPELLCAST_SENT", "player", "Vf Pr", "Cast-D", 20777); Step(2)
check(lastR() == "x;R;r;Ancestral Spirit;Vf Pr", "rank 5 by ID: " .. tostring(lastR()))
Fire("UNIT_SPELLCAST_FAILED", "player", "Cast-D", 20777); Step(2)
check(lastR() == "x;R;x", "no x for the ranked cast")

---------------------------------------------------------------------------
-- Desk: rows, alert, d -> g, footer, WIPE, cancel button
---------------------------------------------------------------------------
check(ns.IsLead() and Desk.Update() == false and not Desk.frame:IsShown(), "desk shown with nobody dead")
local warns = #warnings
hb(PRI, "d.-", ";k=PRIEST;l=20")
check(Desk.frame:IsShown() and Desk.frame.title:GetText() == "Deaths", "desk not shown on a death")
check(Desk.frame.body:GetText() == "2 Pri Cuthbridge dead 0:00", "row: " .. tostring(Desk.frame.body:GetText()))
check(Desk.frame.footer:GetText() == "nobody alive can resurrect: corpse run", "footer: " .. tostring(Desk.frame.footer:GetText()))
check(not Desk.frame.cancel:IsShown(), "cancel button without a countdown")
check(#warnings == warns, "alert before the 3 s coalescing")
Step(3.5)
check(#warnings == warns + 1 and warnings[#warnings] == "slot 2 Pri Cuthbridge died", "alert: " .. tostring(warnings[#warnings]))
check(ns.Rows.IsFlashing(PRI), "row not flashing")
Step(40)
check(Desk.frame.body:GetText() == "2 Pri Cuthbridge dead 0:43", "age: " .. tostring(Desk.frame.body:GetText()))
-- dead -> ghost: no second alert, G icon.
hb(PRI, "gc.-", ";k=PRIEST;l=20"); Step(3.5)
check(#warnings == warns + 1, "re-alerted on ghost")
check(Desk.frame.body:GetText() == "2 Pri Cuthbridge ghost 0:47, corpse near", "ghost row: " .. tostring(Desk.frame.body:GetText()))
check(entry(PRI, "ghost") and entry(PRI, "ghost")[2] == "G" and entry(PRI, "ghost")[6]:find("corpse near", 1, true), "G entry")
hb(PRI, "gso.-"); Step(0.5)
check(Desk.frame.body:GetText():find("corpse far, spirit healer near, res offered", 1, true), "flags row")
check(entry(PRI, "res") and entry(PRI, "res")[2] == "RES", "RES entry")
-- Countdown row and the cancel button.
hb(PRI, "d." .. (GetServerTime() + 12)); Step(0.5)
check(Desk.frame.body:GetText():find("dead 0:4%d, auto%-release 1[12] s"), "countdown row: " .. tostring(Desk.frame.body:GetText()))
check(Desk.frame.cancel:IsShown(), "cancel button hidden")
Step(5)
check(Desk.frame.body:GetText():find("auto%-release [67] s"), "countdown not counting down")
local rc2 = countR()
Desk.frame.cancel:RunScript("OnClick")
check(countR() == rc2 + 1 and lastR() == "x;R;c", "cancel not sent")
Step(8)
check(not Desk.frame.body:GetText():find("auto%-release") and not Desk.frame.cancel:IsShown(), "countdown past its end")
-- Footer: who can res, with the class rules.
hb(VF, nil, ";k=DRUID;l=20"); Step(0.5)
check(Desk.frame.footer:GetText() == "Can res: Vf Pr (Druid, Rebirth: combat only)", "druid footer: " .. tostring(Desk.frame.footer:GetText()))
hb(VF, nil, ";k=DRUID;l=19"); Step(0.5)
check(Desk.frame.footer:GetText():find("nobody", 1, true), "druid 19")
hb(VF, nil, ";k=PALADIN;l=12"); hb("Ab Cd", nil, ";k=SHAMAN;l=11"); Step(0.5)
check(Desk.frame.footer:GetText() == "Can res: Vf Pr (Paladin)", "paladin/shaman footer: " .. tostring(Desk.frame.footer:GetText()))
state.class.player = "PRIEST"
Desk.Update(); check(Desk.frame.footer:GetText() == "Can res: Han Jaconelli (Priest), Vf Pr (Paladin)", "own class: " .. tostring(Desk.frame.footer:GetText()))
state.level = 9; Desk.Update(); check(Desk.frame.footer:GetText() == "Can res: Vf Pr (Paladin)", "own level")
state.level = 12; state.class.player = "WARLOCK"
-- WIPE: everyone grouped is down, one coalesced alert.
hb(PRI, nil); hb(VF, nil); Step(3.5)
check(not Desk.frame:IsShown() and LiveTickers() == 0, "desk shown or ticking with everybody alive")
warns = #warnings
hb(PRI, "d.-"); Step(1); hb(VF, "g.-"); Step(1); die()
check(Desk.frame.title:GetText() == "|cffff4040WIPE|r" and Desk.wipe, "no WIPE title")
check(Desk.frame.body:GetText():find("^1 Han Jaconelli dead 0:00\n2 Pri Cuthbridge dead 0:02\n3 Vf Pr ghost 0:01, corpse far"),
  "wipe rows: " .. tostring(Desk.frame.body:GetText()))
Step(2)
check(#warnings == warns + 1 and warnings[#warnings] == "Team wipe: 3 dead", "wipe alert: " .. tostring(warnings[#warnings]))
revive()
check(Desk.frame.title:GetText() == "Deaths", "WIPE kept after a revive")
-- Several deaths in a burst, not a wipe: one alert naming them.
hb(PRI, nil); hb(VF, nil); Step(4)
warns = #warnings
hb(PRI, "d.-"); Step(1); hb(VF, "d.-"); Step(3)
check(#warnings == warns + 1 and warnings[#warnings] == "2 died: Pri Cuthbridge, Vf Pr", "burst alert: " .. tostring(warnings[#warnings]))
-- Option off, not the lead: hidden; the alert needs its own option.
ns.SetOption("deathDesk", false)
check(not Desk.frame:IsShown(), "desk with the option off")
ns.SetOption("deathDesk", true); Desk.Update()
check(Desk.frame:IsShown(), "desk back on")
state.leader = "party1"; Desk.Update()
check(not Desk.frame:IsShown() and LiveTickers() == 0, "desk on a non-lead")
hb(PRI, nil); hb(VF, nil); Step(4)
warns = #warnings
hb(PRI, "d.-"); Step(4)
check(#warnings == warns, "non-lead alerted")
state.leader = "player"
ns.SetOption("deathAlert", false)
hb(PRI, nil); Step(4); hb(PRI, "d.-"); Step(4)
check(#warnings == warns and Desk.frame:IsShown(), "alert with the option off")
ns.SetOption("deathAlert", true)
-- A grouped member without MamaPlus: the guarded unit read; secret -> nothing.
hb(PRI, nil); Step(4)
ns.Status.records[VF] = nil
state.dead.party2 = true; Desk.Update()
check(Desk.frame.body:GetText() == "3 Vf Pr ? (no MamaPlus)", "no-MamaPlus row: " .. tostring(Desk.frame.body:GetText()))
state.dead.party2 = MakeSecret("boolean"); Desk.Update()
check(not Desk.frame:IsShown(), "secret unit death shown")
state.dead.party2 = nil
-- The desk follows the status window's wheel scale (plain values only).
hb(PRI, "d.-"); Step(0.5)
MamaForeverStatus.GetScale = function(self) return self.scale or 1 end
MamaForeverStatus.SetScale = function(self, v) self.scale = v end
Desk.frame.GetScale = MamaForeverStatus.GetScale
Desk.frame.SetScale = MamaForeverStatus.SetScale
MamaForeverStatus:SetScale(1.5); Desk.Update()
check(Desk.frame:GetScale() == 1.5, "desk scale not following the status window")
MamaForeverStatus:SetScale(MakeSecret("number")); Desk.Update()
check(Desk.frame:GetScale() == 1.5, "secret scale applied")
MamaForeverStatus:SetScale(1); Desk.Update()
check(Desk.frame:GetScale() == 1, "desk scale not restored")
hb(PRI, "a.-"); Step(0.5)
-- Members who left are pruned from the alert memory.
check(Desk.down[PRI] == nil and Desk.since[PRI] == nil, "alive member kept in the down set")
hb(PRI, "d.-"); Step(4)
check(Desk.down[PRI], "down set")
ns.Status.records[PRI] = nil
state.group = { "party2" }; Fire("GROUP_ROSTER_UPDATE"); Step(0.5)
check(Desk.down[PRI] == nil, "left member kept")
state.group = { "party1", "party2" }; Fire("GROUP_ROSTER_UPDATE"); Step(4)

---------------------------------------------------------------------------
-- Commands, status line, probe
---------------------------------------------------------------------------
hb(PRI, "d.-"); Step(0.5)
p = #printed
ns.RunCommand("death")
check(findPrint("deaths:", p) and findPrint("2 Pri Cuthbridge dead", p) and findPrint("nobody alive", p), "death command")
p = #printed
ns.RunCommand("death release")
check(findPrint("not dead", p) and called("RepopMe") == rp + 6, "death release while alive")
ns.RunCommand("death retrieve")
check(findPrint("not a ghost", p), "death retrieve while alive")
rc2 = countR()
ns.RunCommand("death cancel")
check(countR() == rc2 + 1 and lastR() == "x;R;c", "death cancel as the lead")
state.leader = "party1"
ns.RunCommand("death cancel")
check(countR() == rc2 + 1 and lastPrinted():find("only the lead", 1, true), "death cancel as a non-lead")
state.leader = "player"
die(); ns.RunCommand("death release"); Step(2.5)
check(me.state == "g" and called("RepopMe") == rp + 7, "death release")
check(probe("repopCmd") == "ok" and probe("repopClick") == nil, "command outcome recorded under the click key")
Fire("CORPSE_IN_RANGE"); ns.RunCommand("death retrieve"); Step(2.5)
check(me.state == "a" and probe("retrieveCmd") == "ok" and probe("retrieveClick") == nil, "death retrieve")
p = #printed
ns.RunCommand("status")
check(findPrint("death: alive, auto-release off, auto-retrieve off, self-res none (none), repopClick=- repopAuto=- "
  .. "retrieveClick=- retrieveAuto=- repopCmd=ok retrieveCmd=ok", p), "status line")
local lines = ns.probes.death[1]()
local text = table.concat(lines, "\n")
check(text:find("RepopMe: function", 1, true) and text:find("C_DeathInfo.GetSelfResurrectOptions(): table with 0 entries", 1, true)
  and text:find("UnitIsDeadOrGhost(party1): false (boolean)", 1, true) and text:find("IsHardcore(): false", 1, true)
  and text:find("RESURRECT_REQUEST valid: true", 1, true) and text:find("UNIT_SPELLCAST_FAILED_QUIET valid: true", 1, true)
  and text:find("deathProbe[70205]: repopClick=- repopAuto=- retrieveClick=- retrieveAuto=- repopCmd=ok retrieveCmd=ok", 1, true),
  "probe lines:\n" .. text)
local out = {}
ns.probes.death[1](out)
check(#out == #lines, "probe out table")
-- A no-op from the typed command is recorded under its own key: the button stays.
state.repopBlocked = true
die(); ns.RunCommand("death release"); Step(5.5)
check(probe("repopCmd") == "blocked" and probe("repopClick") == nil and Death.prompt.release:IsShown()
  and findPrint("RepopMe() from the command was blocked"), "command no-op hid the button")
state.repopBlocked = nil
revive()
-- Secret unit reads and a missing API are described, never compared.
state.dead.party1 = MakeSecret("boolean"); RepopMe = nil
text = table.concat(ns.probes.death[1](), "\n")
check(text:find("UnitIsDeadOrGhost(party1): <secret boolean>", 1, true) and text:find("RepopMe: nil", 1, true), "probe secret/missing")
state.dead.party1 = nil
-- Missing RepopMe: the button is hidden, the command points at the popup.
die()
check(not Death.prompt.release:IsShown() and Death.prompt.text:GetText():find("game's own popup", 1, true), "missing API prompt")
revive()
check(#errors == 0, "handler errors: " .. table.concat(errors, " | "))
print("DEATH TESTS PASSED")
