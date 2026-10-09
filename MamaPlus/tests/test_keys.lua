-- Tests for Keys.lua: binding header and labels at file scope, the seven
-- secure buttons made at LOGIN (type macro, useOnKeyDown false) or, after
-- a login in combat, at PLAYER_REGEN_ENABLED (nothing made or written
-- before, the keys command says so, a TEAM_CHANGED meanwhile is harmless),
-- macro texts per roster (we lead, lead grouped, explicit lead, slot not
-- grouped, empty slot, alone), PLAYER_ENTERING_WORLD refresh,
-- write-on-change (no SetAttribute on a refresh with nothing new), combat
-- deferral (nothing written in combat, applied at PLAYER_REGEN_ENABLED),
-- the dead-key line once per 5 s on key-up only, the keys command, the
-- probe, and Bindings.xml listing exactly the seven buttons while the TOC
-- does not list it.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

LoadModule("Keys.lua")
local NAMES = { "MamaPlusTargetLead", "MamaPlusTarget1", "MamaPlusTarget2", "MamaPlusTarget3", "MamaPlusTarget4",
  "MamaPlusTarget5", "MamaPlusStopFollow" }
local function text(name) return _G[name]:GetAttribute("macrotext") end
local function writes() local n = 0; for _, name in ipairs(NAMES) do n = n + (_G[name].counters.SetAttribute or 0) end return n end
local function lastPrinted() return printed[#printed] or "" end
local function roster(group) state.group = group; Fire("GROUP_ROSTER_UPDATE") end

-- Labels at file scope, before login; no button yet.
check(BINDING_HEADER_MAMAPLUS == "Mama-forever Plus", "header")
check(_G["BINDING_NAME_CLICK MamaPlusTargetLead:LeftButton"] == "Target lead", "lead label")
for n = 1, 5 do
  check(_G["BINDING_NAME_CLICK MamaPlusTarget" .. n .. ":LeftButton"] == "Target slot " .. n, "slot label " .. n)
end
check(_G["BINDING_NAME_CLICK MamaPlusStopFollow:LeftButton"] == "Stop following", "stop label")
check(_G.MamaPlusTargetLead == nil and ns.commands.keys and ns.probes.keys, "buttons before login, command or probe")

-- LOGIN in combat (a /reload mid-fight): no button is made, the keys
-- command says so, a TEAM_CHANGED in the meantime is harmless, and the
-- buttons appear with the right text at PLAYER_REGEN_ENABLED.
-- Slots: 1 us (player), 2 Pri (party1), 3 Vf (party2); we are the group leader.
state.combat = true
Login({ "party1" })
for _, name in ipairs(NAMES) do check(_G[name] == nil, "button made in combat: " .. name) end
local n = #printed
ns.RunCommand("keys")
check(#printed == n + 1 and lastPrinted():find("not made yet", 1, true), "keys command before the buttons: " .. lastPrinted())
MamaForever:Fire("TEAM_CHANGED")
check(_G.MamaPlusTarget1 == nil, "TEAM_CHANGED in combat made a button")
state.combat = false
Fire("PLAYER_REGEN_ENABLED")
for _, name in ipairs(NAMES) do check(_G[name] ~= nil, "button missing after regen: " .. name) end
check(writes() == #NAMES * 3, "attribute writes after regen: " .. writes()) -- type, useOnKeyDown, macrotext each
check(text("MamaPlusTargetLead") == "/target player" and text("MamaPlusTarget1") == "/target player", "after regen: us")
check(text("MamaPlusTarget2") == "/target party1" and text("MamaPlusTarget3") == "", "after regen: slots 2 and 3")
check(text("MamaPlusStopFollow") == "/follow player", "after regen: stop follow")

-- Vf joins as party2: the buttons are rebuilt from the roster.
roster({ "party1", "party2" })
for _, name in ipairs(NAMES) do
  local b = _G[name]
  check(b and b.template == "SecureActionButtonTemplate" and b.kind == "Button", "button " .. name)
  check(b.attributes.type == "macro" and b.attributes.useOnKeyDown == false, "attributes " .. name)
end
check(text("MamaPlusTargetLead") == "/target player", "lead is us: " .. tostring(text("MamaPlusTargetLead")))
check(text("MamaPlusTarget1") == "/target player", "slot 1 is us")
check(text("MamaPlusTarget2") == "/target party1" and text("MamaPlusTarget3") == "/target party2", "grouped slots")
check(text("MamaPlusTarget4") == "" and text("MamaPlusTarget5") == "", "empty slots")
check(text("MamaPlusStopFollow") == "/follow player", "stop follow")

-- Write-on-change: a refresh with nothing new writes nothing.
local before = writes()
MamaForever:Fire("TEAM_CHANGED")
ns.Keys.Refresh()
check(writes() == before, "wrote on an unchanged refresh")

-- Group leader elsewhere, then Mama's explicit lead.
state.leader = "party1"
roster({ "party1", "party2" })
check(text("MamaPlusTargetLead") == "/target party1", "group leader: " .. tostring(text("MamaPlusTargetLead")))
MamaForever.db.lead = "Vf Pr"
MamaForever:Fire("TEAM_CHANGED")
check(text("MamaPlusTargetLead") == "/target party2", "explicit lead: " .. tostring(text("MamaPlusTargetLead")))

-- Slot 3 leaves: its key goes dead, the explicit lead falls back to the group leader.
roster({ "party1" })
check(text("MamaPlusTarget3") == "" and text("MamaPlusTarget2") == "/target party1", "slot left the group")
check(text("MamaPlusTargetLead") == "/target party1", "lead after slot 3 left")

-- Dead key: one line per 5 s on key-up, never on key-down.
n = #printed
MamaPlusTarget3:RunScript("PreClick", "LeftButton", true)
check(#printed == n, "printed on key-down")
MamaPlusTarget3:RunScript("PreClick", "LeftButton", false)
check(#printed == n + 1 and lastPrinted():find("slot 3 is not in the group", 1, true), "dead key line: " .. lastPrinted())
MamaPlusTarget3:RunScript("PreClick", "LeftButton", false)
check(#printed == n + 1, "dead key line repeated within 5 s")
Advance(5.5)
MamaPlusTarget3:RunScript("PreClick", "LeftButton", false)
check(#printed == n + 2, "dead key line not repeated after 5 s")
MamaPlusTarget2:RunScript("PreClick", "LeftButton", false)
check(#printed == n + 2, "live key printed")

-- Alone: everything but ourselves goes dead, the lead key targets us.
MamaForever.db.lead = false; state.leader = "player"
roster({})
check(text("MamaPlusTargetLead") == "/target player" and text("MamaPlusTarget1") == "/target player", "alone: self")
check(text("MamaPlusTarget2") == "" and text("MamaPlusTarget3") == "", "alone: slots dead")

-- PLAYER_ENTERING_WORLD refreshes from the roster without a TEAM_CHANGED.
roster({ "party1", "party2" })
MamaForever.roster["Vf Pr"] = "party3"
Fire("PLAYER_ENTERING_WORLD")
check(text("MamaPlusTarget3") == "/target party3", "entering world refresh: " .. tostring(text("MamaPlusTarget3")))
MamaForever.roster["Vf Pr"] = "party2"
Fire("PLAYER_ENTERING_WORLD")
check(text("MamaPlusTarget3") == "/target party2", "entering world refresh back")

-- Combat: a roster change writes nothing until PLAYER_REGEN_ENABLED.
state.combat = true
before = writes()
roster({ "party1" })
Fire("PLAYER_ENTERING_WORLD")
check(writes() == before and text("MamaPlusTarget3") == "/target party2", "wrote in combat")
local probeLines = ns.probes.keys[1]({})
check(probeLines[#probeLines] == "pending refresh: true", "pending flag: " .. tostring(probeLines[#probeLines]))
n = #printed
ns.RunCommand("keys")
check(lastPrinted():find("waits for combat", 1, true), "keys command in combat: " .. lastPrinted())
state.combat = false
Fire("PLAYER_REGEN_ENABLED")
check(text("MamaPlusTarget3") == "" and writes() == before + 1, "not applied after combat")
Fire("PLAYER_REGEN_ENABLED")
check(writes() == before + 1, "regen without a pending refresh wrote")

-- Command: one line per button with the bound key and the text.
state.bindings["CLICK MamaPlusTarget2:LeftButton"] = "CTRL-2"
n = #printed
ns.RunCommand("keys")
check(#printed == n + 7, "keys command lines: " .. (#printed - n))
local found = 0
for i = n + 1, #printed do
  if printed[i]:find("MamaPlusTarget2 [CTRL-2]: /target party1", 1, true) then found = found + 1 end
  if printed[i]:find("MamaPlusTarget3 [unbound]: (empty", 1, true) then found = found + 1 end
  if printed[i]:find("MamaPlusStopFollow [unbound]: /follow player", 1, true) then found = found + 1 end
end
check(found == 3, "keys command content: " .. found)

-- Probe: GetBindingKey per action, appended to the table given.
local function has(lines, s) for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end return false end
local out = {}
local lines = ns.probes.keys[1](out)
check(#lines >= 8 and #out == #lines, "probe lines: " .. #lines .. " (out " .. #out .. ")")
check(has(lines, "GetBindingKey(CLICK MamaPlusTarget2:LeftButton): CTRL-2; macrotext: /target party1"),
  "probe line: " .. table.concat(lines, " | "))
check(has(lines, "MamaPlusTargetLead:LeftButton): unbound") and has(lines, "pending refresh: false"), "probe lead/tail: " .. table.concat(lines, " | "))
GetBindingKey = function() error("gone") end
check(has(ns.probes.keys[1](), "error or missing"), "probe with a raising API")

-- Bindings.xml lists exactly the seven buttons under our header; the TOC does not list it.
local dir = TEST_ADDON_DIR or "./"
local f = assert(io.open(dir .. "Bindings.xml")); local xml = f:read("*a"); f:close()
local entries = {}
for name, category in xml:gmatch('<Binding name="([^"]+)" category="([^"]+)"') do
  entries[#entries + 1] = name
  check(category == "BINDING_HEADER_MAMAPLUS", "category of " .. name)
end
check(#entries == 7, "binding entries: " .. #entries)
for i, name in ipairs(NAMES) do
  check(entries[i] == "CLICK " .. name .. ":LeftButton", "binding " .. i .. ": " .. tostring(entries[i]))
  check(type(_G["BINDING_NAME_" .. entries[i]]) == "string", "label for " .. entries[i])
end
check(xml:find("must%s+NOT be listed"), "Bindings.xml comment about the TOC")
for line in io.lines(dir .. "MamaPlus.toc") do check(not line:find("Bindings.xml", 1, true), "TOC lists Bindings.xml") end

print("keys OK")
