-- Tests for Core.lua (and Alert.Lead): secret helpers and ns.Clean, the
-- event frame and listeners, timers and RunOutOfCombat, saved variables
-- and options, the command tree, the keyed limiter in front of Mama's
-- queue, the message dispatcher, team and lead helpers, Hardcore and
-- movement readers, blocked actions, probes, the LOGIN fallback and the
-- two load-time refusals (letter x taken, /mama plus taken).
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

-- Handler errors go through geterrorhandler(). The stock mock raises inside
-- xpcall's handler, which Lua 5.1 swallows ("error in error handling"), so
-- collect them instead: an unexpected one fails the file at the end.
local errors = {}
function geterrorhandler() return function(err) errors[#errors + 1] = tostring(err) end end
local function expectErrors(n, m)
  check(#errors == n, m .. ": " .. #errors .. " error(s): " .. table.concat(errors, " | "))
  wipe(errors)
end

-- Login with a 0.5 s step after grouping (the mock's Login() steps 1.5 s,
-- past the 1 s change debounce), so the limiter counts below start from a
-- known clock with nothing sent yet.
local function login(group)
  Fire("ADDON_LOADED", "Mama"); Fire("ADDON_LOADED", "MamaPlus")
  Fire("PLAYER_LOGIN"); Step(0.5)
  if group then state.group = group; Fire("GROUP_ROSTER_UPDATE"); Step(0.5) end
end
local function lastPrint() return mamaPrinted[#mamaPrinted] or "" end
local function findPrint(s, from)
  for i = #mamaPrinted, from or 1, -1 do if mamaPrinted[i]:find(s, 1, true) then return i end end
end
local SN, SS, ST = MakeSecret("number"), MakeSecret("string"), MakeSecret("boolean")

---------------------------------------------------------------------------
-- Secret helpers
---------------------------------------------------------------------------
check(ns.name == "MamaPlus" and ns.MF == MamaForever and ns.LETTER == "x", "namespace basics")
check(ns.IsSecret(SN) and ns.IsSecret(SS) and ns.IsSecret(ST), "IsSecret on sentinels")
check(not ns.IsSecret(5) and not ns.IsSecret("x") and not ns.IsSecret(nil) and not ns.IsSecret(false), "IsSecret on plain values")
check(ns.Plain(SN, 3) == 3 and ns.Plain(nil, 3) == 3 and ns.Plain(4, 3) == 4 and ns.Plain(false, 3) == false, "Plain")
check(ns.PlainOfType(SN, "number", 0) == 0 and ns.PlainOfType("5", "number", 0) == 0 and ns.PlainOfType(5, "number", 0) == 5,
  "PlainOfType")
check(ns.PlainNumber(SN) == nil and ns.PlainNumber("5") == nil and ns.PlainNumber(7) == 7, "PlainNumber")
check(ns.PlainTrue(ST) == false and ns.PlainTrue(SN) == false and ns.PlainTrue(nil) == false and ns.PlainTrue(false) == false
  and ns.PlainTrue(true) == true and ns.PlainTrue(0) == true, "PlainTrue")
local ok, v = ns.Try(function(a) return a * 2 end, 4)
check(ok == true and v == 8, "Try result")
check(ns.Try(nil) == false and ns.Try(function() error("boom") end) == false, "Try on a missing or raising API")
local isv = issecretvalue
issecretvalue = nil
check(ns.IsSecret(SN) == false, "IsSecret without issecretvalue")
issecretvalue = isv

-- Clean: colours, links, textures, delimiters, whitespace, UTF-8 safe cut.
check(ns.Clean(SS) == "" and ns.Clean(nil) == "" and ns.Clean({}) == "" and ns.Clean(true) == "", "Clean of secret/nil/table")
check(ns.Clean(12) == "12", "Clean of a number")
check(ns.Clean("|cff00ff00Hi|r; a:b=c|x") == "Hi a b c x", "Clean colours and delimiters: " .. ns.Clean("|cff00ff00Hi|r; a:b=c|x"))
check(ns.Clean("|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r x2") == "[Linen Cloth] x2", "Clean link")
check(ns.Clean("|TInterface\\Icons\\x:16|t go") == "go", "Clean texture")
check(ns.Clean("  a \t  b  ") == "a b", "Clean whitespace")
check(ns.Clean("abcdef", 3) == "abc" and ns.Clean("abc", 3) == "abc", "Clean cut")
check(ns.Clean("héllo", 2) == "h" and ns.Clean("héllo", 3) == "hé" and ns.Clean("héllo", 6) == "héllo", "Clean UTF-8 cut (2 bytes)")
check(ns.Clean("日本語", 4) == "日" and ns.Clean("日本語", 6) == "日本" and ns.Clean("日本語", 2) == "", "Clean UTF-8 cut (3 bytes)")

-- EventIsValid: a raising check is "not valid", a missing one is "valid".
local ceu = C_EventUtils
C_EventUtils = { IsEventValid = function() error("x") end }
check(ns.EventIsValid("A") == false, "raising IsEventValid")
C_EventUtils = nil
check(ns.EventIsValid("A") == true, "missing IsEventValid")
C_EventUtils = ceu

---------------------------------------------------------------------------
-- Events: validity guard, handler isolation, unit filter
---------------------------------------------------------------------------
local got = {}
check(ns.On("BOGUS", function() end) == false and ns.handlers.BOGUS == nil, "invalid event registered")
check(ns.On("ZONE_CHANGED", function(...) got = { n = select("#", ...), ... } end) == true, "On result")
check(ns.eventFrame.events.ZONE_CHANGED, "event not registered on the frame")
Fire("ZONE_CHANGED", 1, nil, "c")
check(got.n == 3 and got[1] == 1 and got[3] == "c", "handler args")
local second = 0
ns.On("ZONE_CHANGED", function() error("first boom") end)
ns.On("ZONE_CHANGED", function() second = second + 1 end)
Fire("ZONE_CHANGED")
check(second == 1, "handler after an erroring one did not run")
expectErrors(1, "handler error not reported")
local unitCalls = 0
check(ns.OnUnit("UNIT_AURA", "player", function() unitCalls = unitCalls + 1 end) == true, "OnUnit")
check(ns.OnUnit("BOGUS", "player", function() end) == false, "OnUnit on an invalid event")
Fire("UNIT_AURA", "party1"); check(unitCalls == 0, "unit event for another unit")
Fire("UNIT_AURA", "player"); check(unitCalls == 1, "unit event for player")
-- a raising RegisterEvent (an unknown name on a client without the validity check) is contained
local reg = ns.eventFrame.RegisterEvent
ns.eventFrame.RegisterEvent = function(self, e) if e == "NO_SUCH_EVENT" then error("unknown event") end return reg(self, e) end
check(ns.On("NO_SUCH_EVENT", function() end) == false and ns.handlers.NO_SUCH_EVENT == nil
  and not ns.eventFrame.events.NO_SUCH_EVENT, "raising RegisterEvent")
check(ns.On("ZONE_CHANGED_NEW_AREA", function() end) == true, "On after a refused registration")
ns.eventFrame.RegisterEvent = reg
local cf = CreateFrame
CreateFrame = function(...) local f = cf(...); f.RegisterUnitEvent = function() error("unknown event") end; return f end
check(ns.OnUnit("NO_SUCH_EVENT", "player", function() end) == false, "raising RegisterUnitEvent")
CreateFrame = cf
expectErrors(0, "registration errors reported instead of contained")

-- Listeners: local names, Mama names bridged (MF self stripped), isolation.
local localArgs
ns.Listen("T_LOCAL", function(...) localArgs = { ... } end)
ns.Fire("T_LOCAL", "a", 2)
check(localArgs[1] == "a" and localArgs[2] == 2, "local listener")
ns.Fire("NOBODY_LISTENS")
local statsArg
ns.Listen("STATS", function(a) statsArg = a end)
MamaForever:Fire("STATS", "Pri Cuthbridge")
check(statsArg == "Pri Cuthbridge", "Mama event not bridged")
ns.Listen("T_LOCAL", function() error("listener boom") end)
local after = 0
ns.Listen("T_LOCAL", function() after = after + 1 end)
ns.Fire("T_LOCAL")
check(after == 1, "listener after an erroring one")
expectErrors(1, "listener error not reported")

---------------------------------------------------------------------------
-- Timers and RunOutOfCombat
---------------------------------------------------------------------------
local ticks = 0
local t = ns.Ticker(1, function() ticks = ticks + 1 end)
check(LiveTickers() == 1, "NewTicker not used")
Step(3); check(ticks == 3, "ticker ticks: " .. ticks)
t:Cancel(); Step(2); check(ticks == 3, "cancelled ticker ticked")
local newTicker = C_Timer.NewTicker
C_Timer.NewTicker = nil
ticks = 0
t = ns.Ticker(1, function() ticks = ticks + 1 end)
Step(3); check(ticks == 3, "After-chain ticker: " .. ticks)
t:Cancel(); Step(3); check(ticks == 3, "cancelled After-chain ticked")
C_Timer.NewTicker = newTicker
local ran = false
ns.After(2, function() ran = true end)
Step(1.5); check(not ran, "After early"); Step(0.5); check(ran, "After late")

local runs = {}
check(ns.RunOutOfCombat("k", function() runs[#runs + 1] = "now" end) == true and runs[1] == "now", "runs now out of combat")
state.combat = true
check(ns.RunOutOfCombat("k", function() runs[#runs + 1] = "old" end) == false, "deferred in combat")
ns.RunOutOfCombat("k", function() runs[#runs + 1] = "new" end)
ns.RunOutOfCombat("k2", function() runs[#runs + 1] = "k2" end)
check(#runs == 1, "ran in combat")
state.combat = false
Fire("PLAYER_REGEN_ENABLED")
local seen = {}
for _, r in ipairs(runs) do seen[r] = (seen[r] or 0) + 1 end
check(#runs == 3 and seen.new == 1 and seen.k2 == 1 and not seen.old, "regen queue: " .. table.concat(runs, ","))
Fire("PLAYER_REGEN_ENABLED"); check(#runs == 3, "regen queue ran twice")

---------------------------------------------------------------------------
-- Saved variables and options
---------------------------------------------------------------------------
local dbReady = false
ns.Listen("DB_READY", function() dbReady = ns.db ~= nil end)
check(ns.db == nil, "db before ADDON_LOADED")
ns.AddDefaults({ tNum = 7, tFlag = true, tAlert = true, debug = "no" })
check(ns.defaults.debug == false and ns.defaults.tNum == 7, "AddDefaults: first default wins")
local changes = {}
ns.AddOption({ key = "tNum", label = "T num", section = "Test", type = "number", min = 0, max = 10, step = 1,
  onChange = function(val) changes[#changes + 1] = val end })
MamaPlusDB = { durWarn = 50 }   -- a saved value survives, missing keys get defaults
Fire("ADDON_LOADED", "Other")
check(ns.db == nil and not dbReady, "db from another addon's load")
login()
check(dbReady and ns.db == MamaPlusDB and ns.db.durWarn == 50 and ns.db.tNum == 7 and ns.db.rowIcons == true
  and ns.db.debug == false, "saved variables")
check(ns.handlers.ADDON_LOADED == nil and not ns.eventFrame.events.ADDON_LOADED, "ADDON_LOADED still registered")
check(ns.loggedIn and findPrint("MamaPlus 0.1.0 loaded"), "LOGIN line")
ns.SetOption("durWarn", 25)
ns.SetOption("tNum", 9)
check(ns.db.tNum == 9 and changes[1] == 9, "SetOption + onChange")
check(ns.Setting("tNum", 1) == 9 and ns.Setting("missing", 1) == 1, "Setting")
ns.db.tNum = "9"; check(ns.Setting("tNum", 1) == 1, "Setting on a non-number")
ns.db.tNum = SN; check(ns.Setting("tNum", 1) == 1, "Setting on a secret")
ns.db.tNum = 9
check(ns.OptionOn("tFlag") and ns.OptionOn("rowIcons") and not ns.OptionOn("debug") and not ns.OptionOn("missing"), "OptionOn")
ns.db.tFlag = SN; check(not ns.OptionOn("tFlag"), "OptionOn on a secret"); ns.db.tFlag = true

-- Print/Debug sanitise every argument.
ns.Print("a", SN, nil, 3)
check(lastPrint():find("a <secret number> nil 3", 1, true), "Print sanitising: " .. lastPrint())
local logN = #MamaForever.log
ns.Debug("hidden"); check(#MamaForever.log == logN, "Debug line while off")
ns.RunCommand("debug")
check(ns.db.debug == true and lastPrint():find("debug on", 1, true), "debug command on")
ns.Debug("shown", SS)
check(MamaForever.log[#MamaForever.log]:find("shown <secret string>", 1, true), "Debug line: " .. MamaForever.log[#MamaForever.log])
ns.RunCommand("debug"); check(ns.db.debug == false, "debug command off")

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
check(SLASH_MAMAPLUS1 == "/mamaplus" and SlashCmdList.MAMAPLUS == ns.RunCommand, "/mamaplus alias")
local plus = MamaForever.commands.plus
check(plus and plus.help:find("MamaPlus", 1, true), "/mama plus not registered")
local rests = {}
ns.AddCommand("TCore", "test command", function(rest) rests[#rests + 1] = rest end)
check(ns.commands.tcore and ns.commandOrder[#ns.commandOrder] == "tcore", "AddCommand lower-cases")
ns.RunCommand("  tCORE  a b  ")
check(rests[1] == "a b", "sub/rest parsing: '" .. tostring(rests[1]) .. "'")
plus.fn(MamaForever, "tcore x")
check(rests[2] == "x", "via /mama plus")
ns.RunCommand("tcore"); check(rests[3] == "", "empty rest")
local n = #mamaPrinted
ns.RunCommand("")
check(mamaPrinted[n + 1]:find("commands (", 1, true) and findPrint("tcore|r - test command", n + 1), "help")
n = #mamaPrinted
ns.RunCommand("nope")
check(mamaPrinted[n + 1]:find("unknown command: nope", 1, true) and #mamaPrinted > n + 1, "unknown command")
n = #mamaPrinted
ns.RunCommand(SS); check(mamaPrinted[n + 1]:find("commands (", 1, true), "secret message not treated as help")
ns.RunCommand(nil); ns.RunCommand(5)
ns.AddCommand("tboom", "raises", function() error("cmd boom") end)
ns.RunCommand("tboom")
expectErrors(1, "command error not reported")
local order = #ns.commandOrder
ns.AddCommand("tcore", "replaced", function() end)
check(#ns.commandOrder == order and ns.commands.tcore.help == "replaced", "re-adding a command")

local statusFired = 0
ns.Listen("STATUS_COMMAND", function() statusFired = statusFired + 1 end)
n = #mamaPrinted
ns.RunCommand("status")
local statusText = table.concat(mamaPrinted, "\n", n + 1)
check(statusText:find("comms on, slot %d+, token yes") and statusText:find("lead nil", 1, true), "status line: " .. statusText)
for _, field in ipairs({ "sent 0", "replaced 0", "held 0", "secret parts dropped 0", "pending 0", "blocked actions 0" }) do
  check(statusText:find(field, 1, true), "status counters: " .. field .. " missing in: " .. statusText)
end
check(statusFired == 1, "STATUS_COMMAND not fired")

---------------------------------------------------------------------------
-- Team helpers (alone)
---------------------------------------------------------------------------
check(ns.MyName() == "Han Jaconelli" and ns.MySlot() == 1 and ns.MyClass() == "WARLOCK" and ns.Version() == "0.1.0", "identity")
check(ns.Slots() == MamaForever.db.slots and ns.Slots()[2] == "Pri Cuthbridge", "Slots reads Mama's table at call time")
check(ns.SlotOf("Vf Pr") == 3 and ns.SlotOf("Nobody Here") == nil and ns.SlotOf(nil) == nil, "SlotOf")
check(ns.IsTeamMember("Vf Pr") and not ns.IsTeamMember("Nobody Here"), "IsTeamMember")
check(ns.UnitOf("Pri Cuthbridge") == nil and ns.UnitOf(nil) == nil, "UnitOf while alone")
check(ns.Who("Pri Cuthbridge") == "slot 2 Pri Cuthbridge" and ns.Who("Nobody Here") == "Nobody Here", "Who")
check(ns.Disabled() == false, "Disabled")
MamaForever.db.slot = SN; check(ns.MySlot() == 0, "secret slot"); MamaForever.db.slot = 1
check(ns.IsLead() == false and ns.LeadName() == nil, "lead while alone")

---------------------------------------------------------------------------
-- Limiter, while alone (whispers and team sends need no group; the beat
-- sends nothing ungrouped, so the bucket starts full here).
---------------------------------------------------------------------------
check(#mamaSent == 0 and ns.comms.sent == 0 and ns.PendingCount() == 0, "traffic before the limiter tests")
-- 7 quick sends with different keys: 6 go out now, the 7th after one refill (2 s)
local subs = { "I", "F", "G", "H", "Q", "A", "R" }
for _, sub in ipairs(subs) do check(ns.Whisper("Vf Pr", sub, "first") == true, "Whisper " .. sub) end
check(#mamaSent == 6 and ns.comms.sent == 6 and ns.PendingCount() == 1, "burst of 6: " .. #mamaSent)
for i = 1, 6 do
  check(mamaSent[i].kind == "whisper" and mamaSent[i].to == "Vf Pr" and mamaSent[i].payload == "x;" .. subs[i] .. ";first",
    "burst payload " .. i .. ": " .. mamaSent[i].payload)
end
Step(1.5); check(#mamaSent == 6, "7th sent before the refill")
Step(0.5); check(#mamaSent == 7 and mamaSent[7].payload == "x;R;first" and ns.PendingCount() == 0, "7th not sent after 2 s")
-- same key before the drain: the newest replaces the pending one; keys are per name for whispers
check(ns.Whisper("Vf Pr", "H", "a") and ns.Whisper("Vf Pr", "H", "b"), "queued whispers")
check(ns.PendingCount() == 1 and ns.comms.replaced == 1 and #mamaSent == 7, "same key not replaced")
check(ns.Whisper("Pri Cuthbridge", "H", "c") and ns.PendingCount() == 2 and ns.comms.replaced == 1, "whisper key per name")
Step(2)
check(#mamaSent == 8 and mamaSent[8].payload == "x;H;b" and mamaSent[8].to == "Vf Pr", "newest H not sent: " .. mamaSent[#mamaSent].payload)
Step(2)
check(#mamaSent == 9 and mamaSent[9].payload == "x;H;c" and mamaSent[9].to == "Pri Cuthbridge" and ns.PendingCount() == 0, "second key not sent")
-- priority: H queued before I with an empty bucket, I goes first
ns.Whisper("Vf Pr", "H", "p"); ns.Whisper("Vf Pr", "I", "p")
check(ns.PendingCount() == 2, "two pending")
Step(2); check(#mamaSent == 10 and mamaSent[10].payload == "x;I;p", "I not sent before H: " .. mamaSent[10].payload)
Step(2); check(#mamaSent == 11 and mamaSent[11].payload == "x;H;p", "H not sent after I")
-- chat lockdown holds the drain (retry every second), released when it ends
state.lockdown = true
check(ns.InLockdown() == true, "InLockdown")
ns.Whisper("Vf Pr", "G", "held")
Step(5)
check(#mamaSent == 11 and ns.comms.held >= 1 and ns.PendingCount() == 1, "sent during chat lockdown (held " .. ns.comms.held .. ")")
state.lockdown = false
Step(1)
check(#mamaSent == 12 and mamaSent[12].payload == "x;G;held", "not released after lockdown")
state.lockdown = ST; check(ns.InLockdown() == false, "secret lockdown answer treated as held"); state.lockdown = false
-- secret parts never reach Mama (and never raise): "" in their place, counted
local secretBefore = ns.comms.secret
check(ns.Whisper("Vf Pr", "A", SN, "x", SS, nil, 12, "a;b") == true, "whisper with secret parts refused")
check(ns.comms.secret == secretBefore + 2, "secret counter")
Step(2)
check(mamaSent[#mamaSent].payload == "x;A;;x;;;12;a,b", "secret part reached Mama: " .. mamaSent[#mamaSent].payload)
check(ns.Payload("Q", 5) == "x;Q;5" and ns.Payload("Q") == "x;Q" and ns.Payload("Q", true) == "x;Q;true", "Payload shapes")
-- team send while alone: whispers to online members through Mama's SendTeam
MamaForever.online["Vf Pr"] = true
Step(2)
check(ns.SendTeam("Q", 2589) == true, "SendTeam ungrouped")
check(mamaSent[#mamaSent].kind == "whisper" and mamaSent[#mamaSent].to == "Vf Pr" and mamaSent[#mamaSent].payload == "x;Q;2589",
  "SendTeam whisper")
MamaForever.online["Vf Pr"] = nil
-- preconditions: nothing queued, nothing sent
local sentN, pend = ns.comms.sent, ns.PendingCount()
check(ns.Send("I", 0) == false, "group send while alone")
check(ns.CanSend(true) == false and ns.CanSend(false) == true, "CanSend group/any")
check(ns.Whisper("Han Jaconelli", "H") == false and ns.Whisper(SS, "H") == false and ns.Whisper(nil, "H") == false,
  "whisper to self/secret/nil")
MamaForever.db.slot = 0
check(ns.Whisper("Vf Pr", "H") == false and ns.SendTeam("Q") == false and not ns.CanSend(false), "slot 0")
MamaForever.db.slot = 1
state.token = nil
check(ns.Whisper("Vf Pr", "H") == false and not ns.CanSend(false), "no token")
state.token = "tok"
MamaForever.db.disabled["Han Jaconelli"] = true
check(ns.Whisper("Vf Pr", "H") == false, "disabled")
MamaForever.db.disabled["Han Jaconelli"] = nil
ns.commsOff = true
check(ns.Whisper("Vf Pr", "H") == false and ns.SendTeam("Q") == false, "commsOff")
ns.commsOff = false
check(ns.comms.sent == sentN and ns.PendingCount() == pend, "a refused send reached the limiter")

---------------------------------------------------------------------------
-- Grouped: group sends, dispatcher
---------------------------------------------------------------------------
state.group = { "party1" }; Fire("GROUP_ROSTER_UPDATE"); Step(12)
check(ns.UnitOf("Pri Cuthbridge") == "party1" and ns.CanSend(true), "grouped")
local before = #mamaSent
check(ns.Send("G", 12, nil, "a;b", SN) == true, "group send")
check(#mamaSent == before + 1 and mamaSent[#mamaSent].kind == "group" and mamaSent[#mamaSent].payload == "x;G;12;;a,b;",
  "group payload: " .. mamaSent[#mamaSent].payload)
check(LastSent("G").payload == "x;G;12;;a,b;" and #Sent("G") == 3 and #Sent("Z") == 0, "Sent helper")

-- Event-style subs are keyed by their first part: a pending lead cancel R;c
-- (held here by a chat lockdown) is not swallowed by a later R;r or R;x, two
-- finds for different items both go out, and so do two answers to one asker.
-- State subs (H) keep one slot. R;c first: same priority, queued earlier.
-- Right after a 30 s beat (its H would take the H slot), then a full bucket.
local hn = #Sent("H")
repeat Step(0.5) until #Sent("H") > hn
Step(12)
local replaced, sentBefore = ns.comms.replaced, #mamaSent
state.lockdown = true
check(ns.Send("R", "c") and ns.Send("R", "r", "Resurrection", "Vf Pr"), "R sends")
check(ns.PendingCount() == 2 and ns.comms.replaced == replaced, "R;c replaced by R;r: pending " .. ns.PendingCount())
check(ns.Send("R", "x") and ns.PendingCount() == 3, "R;x keyed apart from R;c and R;r")
check(ns.Send("R", "c") and ns.PendingCount() == 3 and ns.comms.replaced == replaced + 1, "a second R;c not collapsed")
check(ns.Send("H", "s1") and ns.Send("H", "s2") and ns.PendingCount() == 4 and ns.comms.replaced == replaced + 2, "H not one slot")
MamaForever.online["Vf Pr"] = true
check(ns.SendTeam("Q", 2589) and ns.SendTeam("Q", 159) and ns.SendTeam("Q", 2589), "Q sends")
check(ns.PendingCount() == 6 and ns.comms.replaced == replaced + 3, "Q keyed by item: pending " .. ns.PendingCount())
check(ns.Whisper("Pri Cuthbridge", "A", 2589, 3, "-") and ns.Whisper("Pri Cuthbridge", "A", 159, 0, "-")
  and ns.Whisper("Pri Cuthbridge", "A", SN, 1, "-") and ns.Whisper("Pri Cuthbridge", "A", SN, 2, "-"), "A whispers")
check(ns.PendingCount() == 9 and ns.comms.replaced == replaced + 4,
  "A keyed by item per asker, a secret item under the plain key: pending " .. ns.PendingCount())
check(#mamaSent == sentBefore, "sent during the lockdown")
state.lockdown = false
Step(1)   -- the held drain retries every second
local function payloads(from)
  local out = {}
  for i = from + 1, #mamaSent do out[#out + 1] = mamaSent[i].payload end
  return out
end
local drained = payloads(sentBefore)
check(drained[1] == "x;R;c" and drained[2] == "x;R;r;Resurrection;Vf Pr" and drained[3] == "x;R;x" and drained[4] == "x;H;s2",
  "drain order: " .. table.concat(drained, " "))
Step(8)
check(ns.PendingCount() == 0, "all drained")
local seen = {}
for _, p in ipairs(payloads(sentBefore)) do seen[p] = (seen[p] or 0) + 1 end
check(seen["x;Q;2589"] == 2 and seen["x;Q;159"] == 2, "both finds sent (whisper + group each)")   -- Vf Pr online, Pri grouped
check(seen["x;A;2589;3;-"] == 1 and seen["x;A;159;0;-"] == 1 and seen["x;A;;2;-"] == 1 and not seen["x;A;;1;-"]
  and not seen["x;H;s1"], "answers: " .. table.concat(payloads(sentBefore), " "))
MamaForever.online["Vf Pr"] = nil

local recv = {}
ns.ops.T = function(sender, body) recv[#recv + 1] = { sender, body } end
local handler = MamaForever.messageHandlers.x
check(type(handler) == "function" and ns.commsOff == false, "letter x not installed")
Deliver("Pri Cuthbridge", "x;T;a;b")
check(#recv == 1 and recv[1][1] == "Pri Cuthbridge" and recv[1][2] == "a;b", "dispatch")
Deliver("Pri Cuthbridge", "x;T")
check(#recv == 2 and recv[2][2] == "", "dispatch without body")
Deliver("Stranger Dude", "x;T;1")
check(#recv == 3 and recv[3][1] == "Stranger Dude", "unknown-slot sender refused")
Deliver("Han Jaconelli", "x;T;own")
Deliver("Pri Cuthbridge", "x;Z;1")
Deliver("Pri Cuthbridge", "x;;1")
Deliver("Pri Cuthbridge", "y;T;1")
handler(MamaForever, "Pri Cuthbridge", SS)
handler(MamaForever, SS, "T;1")
handler(MamaForever, "Pri Cuthbridge", 5)
handler(MamaForever, nil, "T;1")
MamaForever.db.disabled["Han Jaconelli"] = true
Deliver("Pri Cuthbridge", "x;T;dis")
MamaForever.db.disabled["Han Jaconelli"] = nil
check(#recv == 3, "own name / unknown sub / secret / disabled dispatched: " .. #recv)
ns.ops.T = function() error("op boom") end
Deliver("Pri Cuthbridge", "x;T;1")
expectErrors(1, "op error not reported")
ns.ops.T = nil

---------------------------------------------------------------------------
-- Lead
---------------------------------------------------------------------------
check(ns.IsLead() == true and ns.LeadName() == "Han Jaconelli", "group leader is the lead")
state.leader = "party1"
check(ns.IsLead() == false and ns.LeadName() == "Pri Cuthbridge", "other group leader")
MamaForever.db.lead = "Han Jaconelli"
check(ns.IsLead() == true and ns.LeadName() == "Han Jaconelli", "explicit lead = me")
MamaForever.db.lead = "Pri Cuthbridge"; state.leader = "player"
check(ns.IsLead() == false and ns.LeadName() == "Pri Cuthbridge", "explicit lead = other")
MamaForever.db.lead = "Vf Pr"   -- not grouped: Mama ignores it
check(ns.IsLead() == true, "stale explicit lead")
MamaForever.db.lead = false
MamaForever.db.disabled["Han Jaconelli"] = true
check(ns.IsLead() == false and ns.Disabled() == true, "disabled window is never the lead")
MamaForever.db.disabled["Han Jaconelli"] = nil
local inGroup = IsInGroup
IsInGroup = function() return ST end
check(ns.IsLead() == false and ns.LeadName() == nil, "secret IsInGroup")
IsInGroup = inGroup

-- Alert.Lead: option on and this window is the lead.
local snd = #sounds
check(ns.LeadAlert("tAlert", "lead alert", "Pri Cuthbridge") == true and #sounds == snd + 1 and warnings[#warnings] == "lead alert",
  "LeadAlert on the lead")
ns.db.tAlert = false
check(ns.LeadAlert("tAlert", "x") == false and #sounds == snd + 1, "LeadAlert with the option off")
check(ns.LeadAlert(nil, "y") == true and #sounds == snd + 2, "LeadAlert without an option key")
state.leader = "party1"
check(ns.LeadAlert(nil, "z") == false and #sounds == snd + 2, "LeadAlert on a non-lead")
state.leader = "player"
check(ns.Alert("called") == true and ns.Alert.last == "called", "Alert callable")

---------------------------------------------------------------------------
-- Hardcore and movement readers
---------------------------------------------------------------------------
-- A secret boolean reads as type "boolean" (as in game): the readers must
-- recognise it through issecretvalue, so count that it was asked.
local asked = 0
local isvReal = issecretvalue
issecretvalue = function(v) asked = asked + 1; return isvReal(v) end
state.hardcore = true; check(ns.IsHardcore() == true, "hardcore true")
state.hardcore = false; check(ns.IsHardcore() == false, "hardcore false")
local gameRule, hcActive = C_GameRules.IsGameRuleActive, C_GameRules.IsHardcoreActive
C_GameRules.IsGameRuleActive = nil
state.hardcore = "secret"; asked = 0
check(ns.IsHardcore() == nil and asked > 0, "secret hardcore not nil, or issecretvalue not asked (" .. asked .. ")")
C_GameRules.IsGameRuleActive = gameRule
check(ns.IsHardcore() == false, "secret first answer: the second API's plain answer counts")
C_GameRules.IsHardcoreActive = nil
state.hardcore = true; check(ns.IsHardcore() == true, "IsGameRuleActive fallback")
C_GameRules.IsHardcoreActive = function() error("nope") end
check(ns.IsHardcore() == true, "raising IsHardcoreActive")
C_GameRules.IsHardcoreActive, C_GameRules.IsGameRuleActive = nil, nil
check(ns.IsHardcore() == nil, "no API -> nil")
C_GameRules.IsHardcoreActive, C_GameRules.IsGameRuleActive = hcActive, gameRule
state.hardcore = false

state.moving = false; check(ns.Moving() == false, "not moving")
state.moving = true; check(ns.Moving() == true, "moving")
local ipm, gus = IsPlayerMoving, GetUnitSpeed
IsPlayerMoving = nil
check(ns.Moving() == true, "GetUnitSpeed fallback moving")
state.moving = false; check(ns.Moving() == false, "GetUnitSpeed fallback still")
IsPlayerMoving = ipm
check(ns.moveSecret == false, "moveSecret before a secret sample")
n = #mamaPrinted
state.speedSecret = true; asked = 0
check(ns.Moving() == nil and ns.moveSecret == true and asked > 0, "secret movement not nil, or issecretvalue not asked (" .. asked .. ")")
check(#mamaPrinted == n + 1 and lastPrint():find("movement is secret", 1, true), "secret movement line")
check(ns.Moving() == nil and #mamaPrinted == n + 1, "secret movement line printed twice")
state.speedSecret = false
check(ns.Moving() == false, "movement after a secret sample")
GetUnitSpeed, IsPlayerMoving = nil, nil
check(ns.Moving() == nil, "no movement API")
GetUnitSpeed, IsPlayerMoving = gus, ipm
issecretvalue = isvReal

---------------------------------------------------------------------------
-- Blocked actions and probes
---------------------------------------------------------------------------
local blockedArgs = {}
ns.OnBlocked(function(func) blockedArgs[#blockedArgs + 1] = func end)
Fire("ADDON_ACTION_FORBIDDEN", "MamaPlus", "RepopMe()")
check(ns.blocked.count == 1 and ns.blocked.last == "RepopMe()" and blockedArgs[1] == "RepopMe()", "blocked action")
Fire("ADDON_ACTION_BLOCKED", "TeamWatch", "x")
Fire("ADDON_ACTION_FORBIDDEN", SS, "y")
Fire("ADDON_ACTION_FORBIDDEN", "MamaPlus", SS)
check(ns.blocked.count == 1 and #blockedArgs == 1, "other addon or secret args counted")
Fire("ADDON_ACTION_BLOCKED", "MamaPlus", "RetrieveCorpse()")
check(ns.blocked.count == 2 and ns.blocked.last == "RetrieveCorpse()" and #blockedArgs == 2, "ADDON_ACTION_BLOCKED")

ns.AddProbe("tcore", function() end); ns.AddProbe("tcore", function() end); ns.AddProbe("tcomms", function() end)
check(#ns.probes.tcore == 2 and #ns.probes.tcomms == 1, "probes")
check(ns.probeOrder[#ns.probeOrder - 1] == "tcore" and ns.probeOrder[#ns.probeOrder] == "tcomms", "probe order")

---------------------------------------------------------------------------
-- LOGIN fallback: PLAYER_LOGIN without Mama's LOGIN reaching us
---------------------------------------------------------------------------
local logins = 0
ns.Listen("LOGIN", function() logins = logins + 1 end)
ns.loggedIn = false
n = #mamaPrinted
ns.eventFrame:GetScript("OnEvent")(ns.eventFrame, "PLAYER_LOGIN")
check(logins == 0 and #mamaPrinted == n, "fallback ran in the same frame")
Step(0.5)
check(ns.loggedIn and logins == 1 and findPrint("login chain did not reach MamaPlus", n + 1), "LOGIN fallback")
n = #mamaPrinted
ns.eventFrame:GetScript("OnEvent")(ns.eventFrame, "PLAYER_LOGIN"); Step(0.5)
check(logins == 1 and not findPrint("did not reach", n + 1), "fallback ran although LOGIN had arrived")

---------------------------------------------------------------------------
-- Load-time refusals: a second Core in its own namespace sees letter x and
-- /mama plus already taken (by the first one).
---------------------------------------------------------------------------
local handlerX = MamaForever.messageHandlers.x
n = #mamaPrinted
local ns2 = {}
assert(loadfile((TEST_ADDON_DIR or "./") .. "Core.lua"))("MamaPlus", ns2)
SlashCmdList.MAMAPLUS = ns.RunCommand
check(ns2.commsOff == true and MamaForever.messageHandlers.x == handlerX, "letter x taken: comms not off or handler replaced")
check(findPrint("already uses message letter x", n + 1), "letter taken line")
check(findPrint("/mama plus is already taken", n + 1), "plus taken line")
check(MamaForever.commands.plus == plus, "plus command replaced")
check(ns2.Send("I") == false and ns2.Whisper("Vf Pr", "I") == false and ns2.SendTeam("Q") == false, "sends with comms off")

expectErrors(0, "unexpected handler errors")
print("CORE TESTS PASSED")
