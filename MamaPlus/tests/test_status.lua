-- Tests for Status.lua: local readings (flags, durability, dialogs,
-- fields), the H encoder and its 200 B cap, Changed() debounce and the
-- 3 s gap, the 30 s beat, roster-change sends, MEMBER_SEEN, stale and
-- prune, dialog TTLs, the PLAYER_FLAGS_CHANGED unit filter, durability
-- quantization, the receiver, the HEARTBEAT event and the row icons.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

-- Handler errors are collected (the stock mock's error handler raises inside
-- xpcall, which Lua 5.1 swallows); none are expected in this file.
local errors = {}
function geterrorhandler() return function(err) errors[#errors + 1] = tostring(err) end end

-- Login with a 0.5 s step after grouping (the mock's Login() steps 1.5 s,
-- past the 1 s change debounce) so the first change send is observed below.
-- T_LOGIN feeds the mock's NextBeat/PastBeat: beats run at T_LOGIN +
-- FIRST_BEAT and every BEAT seconds after that.
local function login(group)
  Fire("ADDON_LOADED", "Mama"); Fire("ADDON_LOADED", "MamaPlus")
  T_LOGIN = GetTime()
  Fire("PLAYER_LOGIN"); Step(0.5)
  if group then state.group = group; Fire("GROUP_ROSTER_UPDATE"); Step(0.5) end
end
-- Steps onto the next beat (it fires) and 3 s past it: the following 27 s
-- hold no beat and no send gap.
local pastBeat = PastBeat
local function countH() return #Sent("H") end
local function lastH() local s = LastSent("H"); return s and s.payload end
local function findPrint(s, from)
  for i = #mamaPrinted, from or 1, -1 do if mamaPrinted[i]:find(s, 1, true) then return i end end
end

local Status, ME = ns.Status, "Han Jaconelli"
check(Status.BEAT == 30 and Status.STALE == 75, "beat/stale constants")

---------------------------------------------------------------------------
-- Providers, registered before login like feature files do
---------------------------------------------------------------------------
local zone, taxi, big = true, false, false
Status.AddField("z", function() return zone and state.zone or nil end)
Status.AddField("n", function() return 12 end)                        -- number -> string
Status.AddField("w", function() return "a;b:c|d=e" end)               -- cleaned
Status.AddField("s", function() return MakeSecret("string") end)      -- dropped
Status.AddField("e", function() error("boom") end)                    -- dropped
Status.AddField("L", function() return string.rep("x", 40) end)       -- cut to 24 bytes
for i = 1, 8 do Status.AddField("b" .. i, function() return big and string.rep("y", 24) or nil end) end
Status.AddFlag("t", function() return taxi end)
Status.AddFlag("s", function() return MakeSecret("boolean") end)      -- never set
Status.AddFlag("e", function() error("boom") end)                     -- never set

login({ "party1" })
check(countH() == 0, "H before the change send")
Step(1)   -- the TEAM_CHANGED change send, 1 s after grouping
check(countH() == 1 and LastSent("H").kind == "group", "one H after grouping: " .. countH())
local base = "x;H;0.1.0;-;50;-;z=Durotar;n=12;w=a b c d e;L=" .. string.rep("x", 24)
check(lastH() == base, "H payload: " .. tostring(lastH()))

---------------------------------------------------------------------------
-- Local readings
---------------------------------------------------------------------------
local loc = Status.Local()
check(loc.version == "0.1.0" and loc.flags == "-" and loc.dur == 50 and loc.dialogs == "-" and loc.me == true
  and loc.time == GetTime(), "Local")
check(#loc.list == 4 and loc.list[1] == "z=Durotar" and loc.list[2] == "n=12" and loc.list[3] == "w=a b c d e"
  and loc.list[4] == "L=" .. string.rep("x", 24), "list: " .. table.concat(loc.list, ","))
check(loc.fields.z == "Durotar" and loc.fields.n == "12" and loc.fields.L == string.rep("x", 24)
  and Status.Field(ME, "n") == "12", "own fields map")
check(Status.RecordFor(ME) and Status.RecordFor(ME).me, "RecordFor me")
state.combat = true; state.dead.player = true; state.afk = true; taxi = true
check(Status.Local().flags == "cdat", "flags: " .. Status.Local().flags)
check(Status.HasFlag(ME, "d") and not Status.HasFlag(ME, "x"), "HasFlag on the own record")
state.combat = false; state.dead.player = nil; state.afk = false; taxi = false
check(Status.Local().flags == "-", "flags cleared")

check(Status.MinDurability() == 50, "min durability")
state.dur[5] = { 52, 100 }; check(Status.MinDurability() == 50, "quantized down")
state.dur[5] = { 99, 100 }; check(Status.MinDurability() == 80, "lowest item wins")
state.dur[7] = { 0, 100 }; check(Status.MinDurability() == 0, "zero")
state.dur = {}; check(Status.MinDurability() == 100, "no durable items")
state.dur = { [5] = { MakeSecret("number"), 100 }, [7] = { 30, 100 } }
check(Status.MinDurability() == 30, "secret slot not skipped")
state.dur = { [5] = { 50, 100 }, [7] = { 80, 100 } }
local gid = GetInventoryItemDurability
GetInventoryItemDurability = function() error("x") end; check(Status.MinDurability() == 100, "raising API")
GetInventoryItemDurability = nil
check(Status.Local().dur == nil and Status.Parts(Status.Local())[3] == "?", "missing API -> ?")
GetInventoryItemDurability = gid

-- 200 B cap: trailing fields are dropped, the four fixed parts stay.
big = true
local parts = Status.Parts(Status.Local())
local payload = ns.Payload("H", unpack(parts))
check(#payload <= 200 and #parts == 12 and parts[12] == "b4=" .. string.rep("y", 24),
  "cap: " .. #parts .. " parts, " .. #payload .. " bytes")
check(parts[1] == "0.1.0" and parts[2] == "-" and parts[3] == "50" and parts[4] == "-", "fixed parts")
big = false

---------------------------------------------------------------------------
-- Receiver: round trip, HEARTBEAT event, malformed messages
---------------------------------------------------------------------------
local beats = {}
ns.Listen("HEARTBEAT", function(sender, rec, old) beats[#beats + 1] = { sender, rec, old } end)
state.afk = true
parts = Status.Parts(Status.Local())
state.afk = false
Deliver("Pri Cuthbridge", ns.Payload("H", unpack(parts)))
local rec = Status.records["Pri Cuthbridge"]
check(rec and rec.version == "0.1.0" and rec.flags == "a" and rec.dur == 50 and rec.dialogs == "-" and rec.time == GetTime()
  and rec.sender == "Pri Cuthbridge" and not rec.me, "decoded record")
check(rec.fields.z == "Durotar" and rec.fields.n == "12" and rec.fields.w == "a b c d e" and rec.fields.L == string.rep("x", 24)
  and rec.fields.s == nil, "decoded fields")
check(Status.RecordFor("Pri Cuthbridge") == rec and Status.Field("Pri Cuthbridge", "z") == "Durotar"
  and Status.Field("Pri Cuthbridge", "q") == nil and Status.Field("Nobody Here", "z") == nil, "RecordFor/Field")
check(Status.HasFlag("Pri Cuthbridge", "a") and not Status.HasFlag("Pri Cuthbridge", "d") and not Status.HasFlag("Nobody Here", "a"),
  "HasFlag")
check(#beats == 1 and beats[1][1] == "Pri Cuthbridge" and beats[1][2] == rec and beats[1][3] == nil, "HEARTBEAT first")
Advance(1)
Deliver("Pri Cuthbridge", "x;H;0.0.9;d;abc;TR;l=12;q=5;z=a=b;junk")
local rec2 = Status.records["Pri Cuthbridge"]
check(rec2 ~= rec and rec2.version == "0.0.9" and rec2.flags == "d" and rec2.dur == nil and rec2.dialogs == "TR", "second record")
check(rec2.fields.l == "12" and rec2.fields.q == "5" and rec2.fields.z == "a=b" and rec2.fields.junk == nil and rec2.fields.n == nil,
  "unknown keys kept, old fields gone")
check(#beats == 2 and beats[2][2] == rec2 and beats[2][3] == rec, "HEARTBEAT with the old record")
Deliver("Pri Cuthbridge", "x;H;0.1.0;-")
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;50")
Deliver("Pri Cuthbridge", "x;H")
check(Status.records["Pri Cuthbridge"] == rec2 and #beats == 2, "short H accepted")
Deliver("Han Jaconelli", "x;H;0.1.0;-;50;-")
check(Status.records["Han Jaconelli"] == nil, "own H recorded")
check(Status.RecordFor("Nobody Here") == nil, "record for a stranger")

---------------------------------------------------------------------------
-- Beat: 8 s after LOGIN, then every 30 s, forced even when unchanged
---------------------------------------------------------------------------
local n = countH()
Step(70)   -- beats at T+8, T+38, T+68
check(countH() == n + 3, "beats in 70 s: " .. (countH() - n))
check(lastH() == base and LastSent("H").kind == "group", "beat payload: " .. tostring(lastH()))

---------------------------------------------------------------------------
-- Changed(): 1 s debounce, unchanged content sends nothing, 3 s gap
---------------------------------------------------------------------------
pastBeat()
n = countH()
state.afk = true
for _ = 1, 5 do Status.Changed() end
Step(0.5); check(countH() == n, "change sent before the 1 s debounce")
Step(1)
check(countH() == n + 1 and lastH():find("^x;H;0%.1%.0;a;50;%-"), "5 quick Changed -> 1 send: " .. (countH() - n) .. " " .. tostring(lastH()))
-- a change 0.5 s after that send waits for the 3 s gap, then goes out once
state.afk = false
Status.Changed()
Step(1.5); check(countH() == n + 1, "second change sent inside the 3 s gap")
Step(1); check(countH() == n + 2 and lastH() == base, "second change not sent after the gap: " .. tostring(lastH()))
Status.Changed(); Status.Changed(); Step(3)
check(countH() == n + 2, "unchanged content sent")
check(Status.Send(false) == false, "Send(false) with unchanged content")

---------------------------------------------------------------------------
-- MEMBER_SEEN: an ungrouped member gets one H whisper after 1 s, a grouped
-- one feeds the change send
---------------------------------------------------------------------------
local w = #mamaSent
MamaForever:Fire("MEMBER_SEEN", "Vf Pr")
Step(0.5); check(#mamaSent == w, "whisper before 1 s")
Step(0.5)
check(#mamaSent == w + 1 and mamaSent[#mamaSent].kind == "whisper" and mamaSent[#mamaSent].to == "Vf Pr"
  and mamaSent[#mamaSent].payload == base, "MEMBER_SEEN whisper: " .. tostring(mamaSent[#mamaSent].payload))
state.afk = true
MamaForever:Fire("MEMBER_SEEN", "Pri Cuthbridge")
Step(1.5)
check(#mamaSent == w + 2 and mamaSent[#mamaSent].kind == "group" and lastH():find("^x;H;0%.1%.0;a;"), "MEMBER_SEEN grouped")
MamaForever:Fire("MEMBER_SEEN", MakeSecret("string")); MamaForever:Fire("MEMBER_SEEN", nil)
Step(1.5)
check(#mamaSent == w + 2, "MEMBER_SEEN with a secret or nil name")

---------------------------------------------------------------------------
-- TEAM_CHANGED: only a real roster change triggers a send
---------------------------------------------------------------------------
state.afk = false            -- content differs from the last send, nobody called Changed()
n = countH()
for _ = 1, 8 do MamaForever:Fire("TEAM_CHANGED") end
Step(5)
check(countH() == n, "TEAM_CHANGED with the same roster sent H")
state.group = { "party1", "party2" }
Fire("GROUP_ROSTER_UPDATE"); Fire("GROUP_ROSTER_UPDATE"); Fire("GROUP_ROSTER_UPDATE")
Step(1.5)
check(countH() == n + 1 and lastH() == base, "real roster change: " .. (countH() - n) .. " " .. tostring(lastH()))
-- a newcomer gets the unchanged message once (it has no record of us yet), a leaver nothing
pastBeat()
n = countH()
state.group = { "party1", "party2", "party3" }
Fire("GROUP_ROSTER_UPDATE"); Step(1.5)
check(countH() == n + 1 and lastH() == base, "unchanged H not resent for a newcomer: " .. (countH() - n))
Step(3)
state.group = { "party1", "party2" }
Fire("GROUP_ROSTER_UPDATE"); Step(3)
check(countH() == n + 1, "unchanged H resent for a leaver")
-- a grouped member that reloaded (MEMBER_SEEN) gets it too, once
MamaForever:Fire("MEMBER_SEEN", "Pri Cuthbridge"); Step(1.5)
check(countH() == n + 2 and lastH() == base, "unchanged H not resent for a grouped member that reloaded")
Step(3)

---------------------------------------------------------------------------
-- Stale (grouped members only, not during our own chat lockdown) and prune
---------------------------------------------------------------------------
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;-"); Deliver("Ab Cd", "x;H;0.1.0;-;100;-")
check(not Status.IsStale("Pri Cuthbridge") and not Status.IsStale("Ab Cd") and not Status.IsStale(ME), "stale right away")
Step(75)
check(not Status.IsStale("Pri Cuthbridge"), "stale at exactly 75 s")
Step(0.5)
check(Status.IsStale("Pri Cuthbridge") and not Status.IsStale("Ab Cd") and not Status.IsStale("Nobody Here"),
  "stale after 75 s: grouped only")
state.lockdown = true; check(not Status.IsStale("Pri Cuthbridge"), "stale during our own chat lockdown"); state.lockdown = false
local e = ns.Rows.Entries("Pri Cuthbridge")
check(e[1] and e[1][1] == "live" and e[1][2] == "!" and e[1][3] == 1 and e[1][4] == 0.3 and e[1][7] == 1
  and e[1][6]:find("no message for 76 s", 1, true), "! icon: " .. tostring(e[1] and e[1][6]))
n = #mamaPrinted
ns.RunCommand("team")
check(findPrint("slot 2 Pri Cuthbridge: v0.1.0 flags - dur 100 dialogs -", n + 1) and findPrint("76 s ago, SILENT", n + 1),
  "team line for a silent member")
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;-")
check(not Status.IsStale("Pri Cuthbridge") and ns.Rows.Entries("Pri Cuthbridge")[1] == nil, "stale cleared by a heartbeat")
-- one live stale timer per sender (re-armed from the newest record), not one per heartbeat
local pendingTimers = #timers
for _ = 1, 5 do Advance(1); Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;-") end
check(#timers - pendingTimers <= 2, "stale timers pile up per heartbeat: " .. (#timers - pendingTimers))
Step(75); check(not Status.IsStale("Pri Cuthbridge"), "stale before 75 s after the last heartbeat")
Step(0.5); check(Status.IsStale("Pri Cuthbridge"), "stale 75 s after the last heartbeat")
pendingTimers = #timers
Step(5); check(#timers <= pendingTimers + 1, "stale timer chain runs on for a silent record: " .. #timers .. " > " .. pendingTimers)
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;-")

Deliver("Stranger Dude", "x;H;0.1.0;-;100;-")
check(Status.records["Stranger Dude"], "stranger not recorded")
Status.Prune()
check(Status.records["Stranger Dude"] == nil and Status.records["Ab Cd"] == nil and Status.records["Pri Cuthbridge"], "prune")
Deliver("Stranger Dude", "x;H;0.1.0;-;100;-"); Deliver("Vf Pr", "x;H;0.1.0;-;100;-")
state.group = { "party1" }; Fire("GROUP_ROSTER_UPDATE")
check(Status.records["Stranger Dude"] == nil and Status.records["Vf Pr"] and Status.records["Pri Cuthbridge"],
  "roster change did not prune (slot holders stay)")
Step(1.5)

---------------------------------------------------------------------------
-- Dialogs: letters in TSLR order, close events, TTLs 300/120/180/60
---------------------------------------------------------------------------
local function dlg() return Status.Local().dialogs end
Fire("TRADE_SHOW"); check(dlg() == "T", "trade dialog")
Fire("READY_CHECK"); check(dlg() == "TR", "ready check")
Fire("CONFIRM_SUMMON"); check(dlg() == "TSR", "summon")
Fire("START_LOOT_ROLL", 5); Fire("START_LOOT_ROLL", 6); check(dlg() == "TSLR", "loot roll")
Fire("CANCEL_LOOT_ROLL", 5); check(dlg() == "TSLR", "loot closed with one roll left")
Fire("CANCEL_LOOT_ROLL", 6); check(dlg() == "TSR", "loot roll closed")
Fire("READY_CHECK_CONFIRM", "party1"); check(dlg() == "TSR", "another unit's confirm closed ours")
Fire("READY_CHECK_CONFIRM", "player"); check(dlg() == "TS", "own confirm")
Fire("READY_CHECK"); Fire("READY_CHECK_FINISHED"); check(dlg() == "TS", "ready check finished")
Fire("TRADE_CLOSED"); check(dlg() == "S", "trade closed")
Fire("CANCEL_SUMMON"); check(dlg() == "-", "summon cancelled")
Fire("START_LOOT_ROLL", MakeSecret("number")); check(dlg() == "L", "secret roll id")
Fire("CANCEL_LOOT_ROLL", MakeSecret("number")); check(dlg() == "-", "secret cancel clears all")
pastBeat()
n = countH()
Fire("TRADE_SHOW"); Step(1.5)
check(countH() == n + 1 and lastH():find("^x;H;0%.1%.0;%-;50;T;"), "dialog change send: " .. tostring(lastH()))
e = ns.Rows.Entries(ME)
check(#e == 1 and e[1][1] == "dialog" and e[1][2] == "T" and e[1][6] == "waiting: trade" and e[1][7] == 10 and e[1][3] == 0.4, "T icon")
Fire("TRADE_CLOSED")
Fire("TRADE_SHOW"); Fire("CONFIRM_SUMMON"); Fire("START_LOOT_ROLL", 7); Fire("READY_CHECK")
check(dlg() == "TSLR", "all four")
Step(59.5); check(dlg() == "TSLR", "R expired early")
Step(0.5); check(dlg() == "TSL", "R not expired at 60 s")
Step(60); check(dlg() == "TL", "S not expired at 120 s")
Step(60); check(dlg() == "T", "L not expired at 180 s")
Step(119.5); check(dlg() == "T", "T expired early")
Step(0.5); check(dlg() == "-", "T not expired at 300 s")

---------------------------------------------------------------------------
-- PLAYER_FLAGS_CHANGED: only the player's
---------------------------------------------------------------------------
pastBeat()
n = countH()
state.afk = true
Fire("PLAYER_FLAGS_CHANGED", "party1"); Step(5)
check(countH() == n, "PLAYER_FLAGS_CHANGED for another unit sent")
Fire("PLAYER_FLAGS_CHANGED", "player"); Step(1.5)
check(countH() == n + 1 and lastH():find("^x;H;0%.1%.0;a;"), "AFK not sent")
state.afk = false; Fire("PLAYER_FLAGS_CHANGED", "player"); Step(3)
check(countH() == n + 2 and lastH() == base, "AFK end not sent")

---------------------------------------------------------------------------
-- Durability: a send only when the 5 % step changes
---------------------------------------------------------------------------
Step(3)
n = countH()
state.dur[5] = { 47, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(1.5)
check(countH() == n + 1 and lastH():find("^x;H;0%.1%.0;%-;45;"), "durability step not sent: " .. tostring(lastH()))
state.dur[5] = { 46, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Fire("UPDATE_INVENTORY_DURABILITY"); Step(3)
check(countH() == n + 1, "same 5 % step sent")
state.dur[5] = { 44, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(3)
check(countH() == n + 2 and lastH():find(";40;"), "next step not sent")
state.dur[5] = { 50, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(3)
check(countH() == n + 3 and lastH() == base, "repair not sent")
-- in combat a step sends nothing (the REGEN_ENABLED send carries the value); a durWarn crossing does
pastBeat()
n = countH()
state.combat = true
state.dur[5] = { 47, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(3)
check(countH() == n and Status.Local().dur == 45, "durability step sent in combat")
state.dur[5] = { 24, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(1.5)
check(countH() == n + 1 and lastH():find("^x;H;0%.1%.0;c;20;"), "durWarn crossing not sent in combat: " .. tostring(lastH()))
state.dur[5] = { 14, 100 }; Fire("UPDATE_INVENTORY_DURABILITY"); Step(3)
check(countH() == n + 1, "step below durWarn sent in combat")
state.combat = false
state.dur[5] = { 50, 100 }
Fire("PLAYER_REGEN_ENABLED"); Fire("UPDATE_INVENTORY_DURABILITY"); Step(1.5)
check(countH() == n + 2 and lastH() == base, "one send after combat: " .. (countH() - n) .. " " .. tostring(lastH()))
Step(3)

---------------------------------------------------------------------------
-- Row icons: X, TSLR, AFK, NN%, vX in that order
---------------------------------------------------------------------------
Deliver("Pri Cuthbridge", "x;H;0.0.9;da;20;TR;l=12")
e = ns.Rows.Entries("Pri Cuthbridge")
local kinds = {}
for i, x in ipairs(e) do kinds[i] = x[1] .. ":" .. x[2] end
check(table.concat(kinds, " ") == "dead:X dialog:TR afk:AFK dur:20% version:v0.0.9", "icons: " .. table.concat(kinds, " "))
check(e[1][3] == 1 and e[1][4] == 0.2 and e[1][6] == "dead" and e[1][7] == 2, "X red prio 2")
check(e[2][6] == "waiting: trade, ready check" and e[2][3] == 0.4 and e[2][5] == 1 and e[2][7] == 10, "dialog tip/colour/prio")
check(e[3][3] == 1 and e[3][4] == 0.8 and e[3][7] == 11 and e[3][6] == "AFK", "AFK yellow prio 11")
check(e[4][6] == "lowest item at 20% durability" and e[4][3] == 1 and e[4][4] == 0.3 and e[4][7] == 12, "durability tip/prio")
check(e[5][6] == "runs MamaPlus 0.0.9, you run 0.1.0" and e[5][3] == 1 and e[5][4] == 0.6 and e[5][7] == 15, "version tip/prio")
ns.SetOption("durWarn", 20); check(#ns.Rows.Entries("Pri Cuthbridge") == 4, "durWarn is strict")
ns.SetOption("durWarn", 25)
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;Z")
e = ns.Rows.Entries("Pri Cuthbridge")
check(#e == 1 and e[1][2] == "Z" and e[1][6] == "waiting: ?", "unknown dialog letter")
state.dead.player = true
e = ns.Rows.Entries(ME)
check(#e == 1 and e[1][2] == "X", "own X icon (never a version icon for me)")
state.dead.player = nil
n = #mamaPrinted
ns.RunCommand("team")
check(findPrint("slot 2 Pri Cuthbridge: v0.1.0 flags - dur 100 dialogs Z", n + 1), "team line for a member")
check(findPrint("slot 1 Han Jaconelli: v0.1.0 flags - dur 50 dialogs - L=", n + 1), "team line for me")
check(findPrint("slot 3 Vf Pr: v0.1.0 flags - dur 100 dialogs -", n + 1), "team line for an ungrouped slot holder")
check(Status.Send(false) == false or true, "Send callable")

---------------------------------------------------------------------------
-- The beat chain survives an error in the send path (Beat schedules the
-- next beat first; the error is reported, the next beat is normal)
---------------------------------------------------------------------------
pastBeat()
check(#errors == 0, "errors before the beat-error cases: " .. table.concat(errors, " | "))
n = countH()
local sendGroup = MamaForever.SendGroup
MamaForever.SendGroup = function() MamaForever.SendGroup = sendGroup; error("send boom") end
pastBeat()
check(countH() == n and #errors == 1 and errors[1]:find("send boom", 1, true), "SendGroup error not reported: " .. table.concat(errors, " | "))
wipe(errors)
pastBeat()
check(countH() == n + 1 and lastH() == base and #errors == 0, "beat after a SendGroup error: " .. (countH() - n))
local origParts = Status.Parts
Status.Parts = function() Status.Parts = origParts; error("parts boom") end
pastBeat()
check(countH() == n + 1 and #errors == 1 and errors[1]:find("parts boom", 1, true), "Parts error not reported: " .. table.concat(errors, " | "))
wipe(errors)
pastBeat()
check(countH() == n + 2 and lastH() == base and #errors == 0, "beat after a Parts error: " .. (countH() - n))

state.group = {}; Fire("GROUP_ROSTER_UPDATE"); Step(2)
check(Status.Send(true) == false and Status.SendTo("Vf Pr") == true, "ungrouped: no group send, whispers still work")

---------------------------------------------------------------------------
-- Rows refresh as Mama's do: at LOGIN, on TEAM_CHANGED and again on
-- GROUP_ROSTER_UPDATE (two per roster change), each row decorated once;
-- an ungrouped slot holder's whispered H still draws its icons.
---------------------------------------------------------------------------
local refreshes = MamaForever.rowsRefreshed
state.group = { "party1" }; Fire("GROUP_ROSTER_UPDATE"); Step(2)
check(MamaForever.rowsRefreshed == refreshes + 2, "refreshes per roster change: " .. (MamaForever.rowsRefreshed - refreshes))
state.group = {}; Fire("GROUP_ROSTER_UPDATE"); Step(2)
for i = 1, 3 do
  local r = _G["MamaForeverStatusRow" .. i]
  check(r and r.plus and r.counters.CreateFontString == 1 and r.counters.CreateTexture == 1, "row " .. i .. " decorated more than once")
end
Deliver("Vf Pr", "x;H;0.0.9;a;100;-"); Flush()
local r3 = MamaForeverStatusRow3
check(r3.fullName == "Vf Pr" and r3.unit == nil and r3.plus.text:find("v0.0.9", 1, true) and r3.plus.text:find("AFK", 1, true),
  "ungrouped slot holder's icons: " .. tostring(r3.plus.text))

check(#errors == 0, "unexpected handler errors: " .. table.concat(errors, " | "))

-- Regression: the own record is keyed like a received one (fields.z, not
-- the encoded { "z=Durotar", ... } array, which lives in list), so a module
-- reading RecordFor(me).fields.l or Status.Field(me, key) sees its own values.
check(Status.RecordFor(ME).fields.z == "Durotar", "own record fields are not keyed like received ones")
check(Status.Field(ME, "z") == "Durotar", "Status.Field for the own name")

print("STATUS TESTS PASSED")
