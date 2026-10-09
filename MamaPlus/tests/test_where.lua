-- Tests for Where.lua: option and commands, heartbeat fields (level, XP
-- and rested rounding, zone/subzone 20-byte cut, class) and flags (taxi,
-- resting) with secret or missing APIs, Changed() on the six events and a
-- real heartbeat after a level-up, row entries: level tooltip-only / red
-- below the gate / orange levelGap below the lead (own level on the lead
-- window, the lead's record elsewhere), ZONE against the lead's zone, FLY,
-- FAR only on the lead window from the 2 s sampler (plain false only,
-- secret ignored, frozen while either side fights, ticker only while lead
-- and grouped), the gate command, its message and the G receiver, the
-- where command, the status line and the probe.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

-- Other units fight independently of us: state.fight[unit] = true.
state.fight = {}
function UnitAffectingCombat(u)
  if u == "player" then return state.combat end
  return state.fight[u] or false
end

LoadModule("Where.lua")
local Where = ns.Where
local ME, PRI, VF = "Han Jaconelli", "Pri Cuthbridge", "Vf Pr"

local function field(k)
  return ns.Status.Local().fields[k]
end
local function flags() return ns.Status.Local().flags end
local function entry(name, kind)
  for _, e in ipairs(ns.Rows.Entries(name)) do if e[1] == kind then return e end end
  return nil
end
local function red(e) return e and e[3] == 1 and e[4] == 0.3 and e[5] == 0.3 end
local function orange(e) return e and e[3] == 1 and e[4] == 0.6 and e[5] == 0.2 end
local function beat(sender, body) Deliver(sender, "x;H;0.1.0;" .. body) end
local function lastPrinted() return printed[#printed] or "" end

---------------------------------------------------------------------------
-- Fields and flags before login (pure readings)
---------------------------------------------------------------------------
Login({ "party1", "party2" })
check(ns.db.levelGap == 3, "default levelGap")
local specs = {}
for _, s in ipairs(ns.optionSpecs) do specs[s.key] = s end
local g = specs.levelGap
check(g and g.type == "number" and g.min == 1 and g.max == 20 and g.step == 1 and g.section == "Team rows", "levelGap option")
check(ns.commands.where and ns.commands.gate and ns.ops.G, "commands or receiver missing")

check(field("l") == "12", "level field: " .. tostring(field("l")))
check(field("x") == "30", "xp field: " .. tostring(field("x")))
check(field("r") == nil, "rested field with no rest: " .. tostring(field("r")))
check(field("z") == "Durotar" and field("s") == "Razor Hill", "zone fields")
check(field("k") == "WARLOCK", "class field")
check(flags() == "-", "flags at rest: " .. flags())
-- Rounding: 333/1000 = 33.3% -> 30; rested 450/1000 = 45% -> 40; 95 rested -> 9% -> 0 -> absent.
state.xp, state.exhaustion = 333, 450
check(field("x") == "30" and field("r") == "40", "rounding: " .. tostring(field("x")) .. " " .. tostring(field("r")))
state.exhaustion = 95
check(field("r") == nil, "rested below 10% sent")
state.exhaustion = 1500
check(field("r") == "150", "rested above a level")
state.exhaustion, state.xp = 0, 300
-- Max level: UnitXPMax 0 -> no xp field, no error.
state.xpMax = 0
check(field("x") == nil and field("l") == "12", "xp at max level")
state.xpMax = 1000
-- Zone and subzone cut to 20 bytes without splitting a character; delimiters replaced.
state.zone, state.subzone = "Thousand Needles Far Away Place", "Désolation: des; Dragons=tout"
check(field("z") == "Thousand Needles Far" and #field("s") <= 20 and not field("s"):find("[;:=]"),
  "zone cut: " .. tostring(field("z")) .. " / " .. tostring(field("s")))
state.zone, state.subzone = "Durotar", "Razor Hill"
-- Flags
state.taxi, state.resting = true, true
check(flags():find("t", 1, true) and flags():find("i", 1, true), "taxi/resting flags: " .. flags())
state.taxi, state.resting = false, false
-- Secret or missing readings give nothing and never raise.
local realLevel, realZone, realTaxi = UnitLevel, GetZoneText, UnitOnTaxi
UnitLevel = function() return MakeSecret("number") end
GetZoneText = nil
UnitOnTaxi = function() return MakeSecret("boolean") end
state.xp = MakeSecret("number")
check(field("l") == nil and field("z") == nil and field("x") == nil and flags() == "-", "secret/missing readings leaked")
UnitLevel, GetZoneText, UnitOnTaxi = realLevel, realZone, realTaxi
state.xp = 300

---------------------------------------------------------------------------
-- Changed() on each event; a level-up reaches the group
---------------------------------------------------------------------------
local changes = 0
local origChanged = ns.Status.Changed
ns.Status.Changed = function() changes = changes + 1; return origChanged() end
for _, e in ipairs({ "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_UPDATE_RESTING",
  "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED" }) do
  local before = changes
  Fire(e)
  check(changes == before + 1, "no Changed on " .. e)
end
Fire("BOGUS")
check(changes == 6, "Changed on an unrelated event")
ns.Status.Changed = origChanged
Step(9)   -- the debounced send finds nothing changed; the first beat (T_LOGIN + 8) goes out
check(#Sent("H") == 2 and LastSent("H").payload:find("l=12", 1, true), "grouping send and first beat: " .. #Sent("H") .. " " .. tostring(LastSent("H") and LastSent("H").payload))
local n = #Sent("H")
state.level = 13
Fire("PLAYER_LEVEL_UP", 13)
Step(4)
check(#Sent("H") == n + 1 and LastSent("H").payload:find(";l=13;", 1, true), "level-up not sent: " .. tostring(LastSent("H").payload))
state.level = 12

---------------------------------------------------------------------------
-- Level entries on the lead window (we lead: group leader is not party1/2)
---------------------------------------------------------------------------
check(ns.IsLead(), "not lead")
beat(PRI, "-;100;-;l=10;x=50;r=20;z=Durotar;s=Razor Hill;k=PRIEST")
beat(VF, "-;100;-;l=9;x=5;z=Durotar;s=Valley of Trials;k=WARLOCK")
Flush()
local e = entry(PRI, "level")
check(e and e[2] == "" and e[6] == "level 10, 50% xp, rested 20%" and e[7] == 8, "lead gap 2: not tooltip-only: " .. tostring(e and e[6]))
e = entry(VF, "level")
check(e and e[2] == "9" and orange(e) and e[6] == "level 9, 5% xp, the lead is 12", "gap 3 not orange: " .. tostring(e and e[6]))
e = entry(ME, "level")
check(e and e[2] == "" and e[6] == "level 12, 30% xp", "own level entry: " .. tostring(e and e[6]))
-- levelGap option
ns.SetOption("levelGap", 4)
check(entry(VF, "level")[2] == "", "levelGap 4 still orange")
ns.SetOption("levelGap", 1)
check(entry(PRI, "level")[2] == "10" and orange(entry(PRI, "level")), "levelGap 1 not orange")
ns.SetOption("levelGap", 3)
-- A record without a level: no level entry; a bad level: tooltip-only text with it, no error.
beat(VF, "-;100;-;z=Durotar")
check(entry(VF, "level") == nil, "level entry without a level")
beat(VF, "-;100;-;l=abc;z=Durotar")
check(entry(VF, "level") == nil, "level entry with a bad level")
beat(VF, "-;100;-;l=9;x=5;z=Durotar;s=Valley of Trials;k=WARLOCK")

---------------------------------------------------------------------------
-- Gate: command, message, receiver
---------------------------------------------------------------------------
check(Where.Gate() == nil, "gate before any command")
ns.RunCommand("gate 11")
check(ns.db.gates and ns.db.gates.Horde == 11 and Where.Gate() == 11, "gate not stored per faction")
check(lastPrinted():find("level gate 11", 1, true), "gate line: " .. lastPrinted())
Step(4) -- the limiter's bucket refills with time
check(LastSent("G") and LastSent("G").payload == "x;G;11" and LastSent("G").kind == "group", "gate not sent: " .. tostring(LastSent("G") and LastSent("G").payload))
e = entry(PRI, "level")
check(e and e[2] == "10" and red(e) and e[6]:find("below the gate of 11", 1, true), "level 10 not red under gate 11: " .. tostring(e and e[6]))
check(red(entry(VF, "level")), "level 9 not red under gate 11")
e = entry(ME, "level")
check(e and e[2] == "" and not red(e), "own level 12 red under gate 11")
-- Red beats orange.
ns.SetOption("levelGap", 1)
check(red(entry(PRI, "level")), "orange beat red")
ns.SetOption("levelGap", 3)
-- Bad values: usage line, nothing sent, gate kept.
local sentG = #Sent("G")
for _, bad in ipairs({ "abc", "-5", "100", "2.5" }) do
  ns.RunCommand("gate " .. bad)
  Step(4)
  check(lastPrinted():find("usage", 1, true) and Where.Gate() == 11 and #Sent("G") == sentG, "bad gate " .. bad)
end
-- Plain "gate" prints the value, sends nothing.
ns.RunCommand("gate")
Step(4)
check(lastPrinted():find("level gate 11", 1, true) and #Sent("G") == sentG, "gate query")
ns.RunCommand("gate off")
check(lastPrinted():find("no level gate", 1, true), "gate off line")
Step(4)
check(Where.Gate() == nil and ns.db.gates.Horde == nil and LastSent("G").payload == "x;G;0", "gate off: " .. tostring(LastSent("G").payload))
check(entry(PRI, "level")[2] == "", "level still red after gate off")
-- Receiver: any team member sets the same value; malformed is ignored.
Deliver(PRI, "x;G;14")
check(Where.Gate() == 14 and lastPrinted():find("level gate 14", 1, true) and lastPrinted():find("slot 2", 1, true), "G not applied: " .. lastPrinted())
Flush()
check(red(entry(ME, "level")) and entry(ME, "level")[2] == "12", "own level 12 not red under gate 14")
for _, bad in ipairs({ "x;G;abc", "x;G;-1", "x;G;", "x;G;200" }) do
  Deliver(PRI, bad)
  check(Where.Gate() == 14, "bad G applied: " .. bad)
end
Deliver(VF, "x;G;0")
check(Where.Gate() == nil, "G off not applied")
Flush()
-- Another faction keeps its own gate.
ns.db.gates.Alliance = 30
check(Where.Gate() == nil, "other faction's gate used")
ns.db.gates.Alliance = nil

---------------------------------------------------------------------------
-- Not the lead: the lead's record gives level and zone
---------------------------------------------------------------------------
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(not ns.IsLead() and ns.LeadName() == PRI, "lead not Pri")
-- Lead level 10: Vf (9) gap 1 -> tooltip-only; a level 7 member -> orange; we (12) -> tooltip-only.
check(entry(VF, "level")[2] == "" and entry(ME, "level")[2] == "", "orange without a gap under the lead's level")
beat(VF, "-;100;-;l=7;z=Durotar")
check(orange(entry(VF, "level")) and entry(VF, "level")[2] == "7" and entry(VF, "level")[6]:find("the lead is 10", 1, true), "7 vs lead 10 not orange")
-- The lead's record vanishes: no orange anywhere.
ns.Status.records[PRI] = nil
check(entry(VF, "level")[2] == "", "orange without a lead record")
beat(PRI, "-;100;-;l=10;x=50;r=20;z=Durotar;s=Razor Hill;k=PRIEST")
-- Explicit Mama lead (ourselves) counts as the lead window.
MamaForever.db.lead = ME
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(ns.IsLead() and entry(VF, "level")[6]:find("the lead is 12", 1, true), "explicit lead not used")
MamaForever.db.lead = false
state.leader = "player"
Fire("GROUP_ROSTER_UPDATE"); Flush()
beat(VF, "-;100;-;l=9;x=5;z=Durotar;s=Valley of Trials;k=WARLOCK")

---------------------------------------------------------------------------
-- ZONE and FLY
---------------------------------------------------------------------------
check(ns.IsLead(), "not lead again")
e = entry(PRI, "zone")
check(e and e[2] == "" and e[6] == "Durotar: Razor Hill" and e[7] == 7, "same zone not tooltip-only: " .. tostring(e and e[6]))
beat(VF, "-;100;-;l=9;z=The Barrens;s=Crossroads")
e = entry(VF, "zone")
check(e and e[2] == "ZONE" and orange(e) and e[6] == "The Barrens: Crossroads (the lead is in Durotar)", "other zone: " .. tostring(e and e[6]))
beat(VF, "-;100;-;l=9;z=The Barrens")
check(entry(VF, "zone")[6]:find("^The Barrens %(", 1), "zone without a subzone: " .. entry(VF, "zone")[6])
beat(VF, "-;100;-;l=9")
check(entry(VF, "zone") == nil, "zone entry without a zone")
-- Our own zone against the lead's record when we are not the lead.
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(entry(ME, "zone")[2] == "", "own zone flagged in the lead's zone")
state.zone = "Orgrimmar"
check(entry(ME, "zone")[2] == "ZONE" and entry(PRI, "zone")[2] == "", "own zone not flagged outside the lead's zone")
state.zone = "Durotar"
-- No lead record: no ZONE.
ns.Status.records[PRI] = nil
beat(VF, "-;100;-;l=9;z=The Barrens")
check(entry(VF, "zone")[2] == "", "ZONE without a lead record")
beat(PRI, "-;100;-;l=10;x=50;r=20;z=Durotar;s=Razor Hill;k=PRIEST")
state.leader = "player"
Fire("GROUP_ROSTER_UPDATE"); Flush()
-- Alone: no lead, so no ZONE and no orange, but the tooltip lines stay.
state.group = {}
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(entry(ME, "level")[2] == "" and entry(ME, "zone")[6] == "Durotar: Razor Hill", "entries while alone")
state.group = { "party1", "party2" }
Fire("GROUP_ROSTER_UPDATE"); Flush()
beat(VF, "-;100;-;l=9;z=Durotar")
-- FLY from the flag; own row from UnitOnTaxi.
beat(VF, "t;100;-;l=9;z=Durotar")
e = entry(VF, "fly")
check(e and e[2] == "FLY" and e[3] == 0.6 and e[4] == 0.8 and e[5] == 1 and e[7] == 14, "FLY entry")
beat(VF, "-;100;-;l=9;z=Durotar")
check(entry(VF, "fly") == nil and entry(ME, "fly") == nil, "FLY without the flag")
state.taxi = true
check(entry(ME, "fly"), "own FLY")
state.taxi = false

---------------------------------------------------------------------------
-- FAR: sampler on the lead window only, plain false only, frozen in combat
---------------------------------------------------------------------------
check(ns.IsLead() and Where.Ticking() and LiveTickers() == 1 and tickers[#tickers].d == 2, "far sampler not running on the lead")
check(entry(PRI, "far") == nil, "FAR while in range")
state.near.party1 = { [4] = false }
Step(2)
e = entry(PRI, "far")
check(e and e[2] == "FAR" and red(e) and e[7] == 6, "no FAR out of range")
check(entry(VF, "far") == nil, "FAR on the wrong row")
state.near.party1 = true
Step(2)
check(entry(PRI, "far") == nil, "FAR kept in range")
-- Secret or nil answers never show FAR (and clear a previous one).
state.near.party1 = { [4] = false }
Step(2)
check(entry(PRI, "far"), "FAR before secret")
state.near.party1 = { [4] = MakeSecret("boolean") }
Step(2)
check(entry(PRI, "far") == nil, "FAR from a secret answer")
state.near.party1 = { [4] = false }
Step(2)
check(entry(PRI, "far"), "FAR before a missing API")
local realCID = CheckInteractDistance
CheckInteractDistance = nil
Step(2)
check(entry(PRI, "far") == nil, "FAR with the API missing")
CheckInteractDistance = function() error("boom") end
Step(2)
check(entry(PRI, "far") == nil, "FAR with the API raising")
CheckInteractDistance = realCID
-- The other side fights: its sample is skipped, so the icon freezes.
Step(2)
check(entry(PRI, "far"), "FAR before the member fights")
state.fight.party1 = true
state.near.party1 = true
Step(4)
check(entry(PRI, "far"), "FAR cleared while the member fights")
state.fight.party1 = false
Step(2)
check(entry(PRI, "far") == nil, "FAR kept after the member's fight")
state.fight.party1 = true
state.near.party1 = { [4] = false }
Step(4)
check(entry(PRI, "far") == nil, "FAR set while the member fights")
state.fight.party1 = false
state.near.party1 = { [4] = MakeSecret("boolean") }
Step(2)
check(entry(PRI, "far") == nil, "FAR from a secret after a fight")
state.near.party1 = { [4] = false }
Step(2)
check(entry(PRI, "far"), "FAR after the member's fight")
-- We fight: the ticker stops, the icon freezes, it resumes after combat.
state.combat = true
Fire("PLAYER_REGEN_DISABLED")
check(not Where.Ticking() and LiveTickers() == 0, "sampler running in combat")
state.near.party1 = true
Step(4)
check(entry(PRI, "far"), "FAR cleared during our combat")
Where.SampleFar()
check(entry(PRI, "far"), "sample taken in combat")
state.combat = false
Fire("PLAYER_REGEN_ENABLED")
check(Where.Ticking() and LiveTickers() == 1, "sampler not back after combat")
Flush()
check(entry(PRI, "far") == nil, "FAR kept after combat")
-- Not the lead: no sampler, no FAR, the set is cleared.
state.near.party1 = { [4] = false }
Step(2)
check(entry(PRI, "far"), "FAR before losing the lead")
state.leader = "party1"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(not Where.Ticking() and LiveTickers() == 0 and next(Where.far) == nil and entry(PRI, "far") == nil, "sampler or FAR on a non-lead window")
Step(6)
check(entry(PRI, "far") == nil and entry(VF, "far") == nil, "FAR sampled on a non-lead window")
state.leader = "player"
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(Where.Ticking() and entry(PRI, "far"), "sampler not back as lead")
-- A member who left is dropped from the set; leaving the group stops the sampler.
state.group = { "party2" }
Fire("GROUP_ROSTER_UPDATE"); Flush()
Step(2)
check(Where.far[PRI] == nil and entry(PRI, "far") == nil, "left member kept in the far set")
state.group = {}
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(not Where.Ticking() and LiveTickers() == 0, "sampler running while alone")
-- Mama disabled on this window: not the lead.
state.group = { "party1", "party2" }
MamaForever.db.disabled[ME] = true
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(not Where.Ticking(), "sampler while disabled")
MamaForever.db.disabled[ME] = nil
Fire("GROUP_ROSTER_UPDATE"); Flush()
check(Where.Ticking(), "sampler not back after enabling")
state.near.party1 = true
Step(2)

---------------------------------------------------------------------------
-- where command, status line, probe
---------------------------------------------------------------------------
beat(VF, "ti;100;-;l=9;x=5;z=The Barrens;s=Crossroads")
local p = #printed
ns.RunCommand("where")
check(#printed == p + 3, "where lines: " .. (#printed - p))
check(printed[p + 1]:find("slot 1 Han Jaconelli: level 12, 30% xp, Durotar: Razor Hill", 1, true), "own where line: " .. printed[p + 1])
check(printed[p + 2]:find("slot 2 Pri Cuthbridge: level 10, 50% xp, rested 20%, Durotar: Razor Hill", 1, true), "Pri where line: " .. printed[p + 2])
check(printed[p + 3]:find("slot 3 Vf Pr: level 9, 5% xp, The Barrens: Crossroads, flying, resting", 1, true), "Vf where line: " .. printed[p + 3])
ns.Status.records[VF] = nil
ns.RunCommand("where")
check(lastPrinted():find("slot 3 Vf Pr: no heartbeat yet", 1, true), "where without a record: " .. lastPrinted())

p = #printed
ns.RunCommand("status")
local found = false
for i = p + 1, #printed do if printed[i]:find("where: gate nil, lead level 12, far 0, far sampler on", 1, true) then found = true end end
check(found, "no where status line")

local function has(lines, s) for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end return false end
local lines = ns.probes.where[1]()
check(type(lines) == "table" and #lines >= 11 and has(lines, "UnitLevel(player): 12 (number)"), "probe lines: " .. tostring(lines[1]))
check(has(lines, "CheckInteractDistance") and has(lines, "PLAYER_LEVEL_UP valid: true"), "probe event lines: " .. table.concat(lines, " | "))
local out = {}
ns.probes.where[1](out)
check(#out == #lines, "probe did not fill the table")
UnitLevel = function() return MakeSecret("number") end
GetZoneText = nil
lines = ns.probes.where[1]()
check(has(lines, "UnitLevel(player): <secret number>") and has(lines, "GetZoneText(): error or missing"), "probe secret/missing: " .. table.concat(lines, " | "))
UnitLevel, GetZoneText = realLevel, realZone

print("WHERE TESTS PASSED")
