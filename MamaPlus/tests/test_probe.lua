-- Tests for Probe.lua: the window text holds the core lines (build, secrets,
-- presence, C_Secrets predicates, events, Mama state), secret values render
-- as <secret type>, every line is also printed, a section runs alone, the
-- three probe fn shapes and a raising fn, the read-only edit box, unknown
-- section, and the comms probe: not grouped, 40 PARTY messages over
-- Step(25) with each result code printed, the first non-Success summary,
-- prefix registered once, no concurrent run, no protected call.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end

---------------------------------------------------------------------------
-- Extra mock APIs (before LoadModule)
---------------------------------------------------------------------------
function UnitHealth() return MakeSecret("number") end
C_Secrets.ShouldUnitStatsBeSecret = function() return false end
C_Secrets.ShouldAurasBeSecret = function() return MakeSecret("boolean") end
C_Secrets.ShouldBroken = function() error("boom") end
-- Not a Should* predicate: listed by type, never called (unknown signature).
local brokenCalls = 0
C_Secrets.Broken = function() brokenCalls = brokenCalls + 1; error("boom") end
C_Secrets.Version = 3
local sentAddon, registered = {}, 0
C_ChatInfo.RegisterAddonMessagePrefix = function() registered = registered + 1; return 0 end
C_ChatInfo.SendAddonMessage = function(prefix, text, channel)
  sentAddon[#sentAddon + 1] = { prefix = prefix, text = text, channel = channel, at = GetTime() }
  local n = #sentAddon
  if n == 25 then return MakeSecret("number") end
  if n >= 31 then return 3 end
  return 0
end

LoadModule("Probe.lua")
check(ns.commands.probe and ns.probes.core, "command or core probe missing")
Login({ "party1", "party2" })

-- A module section in every shape: add(name, value), out table (plus a
-- returned copy, like Death.lua), returned list only, and a raising fn.
ns.AddProbe("shape", function(out) out("alpha", 1); out("sec", MakeSecret("string")); out("none", nil) end)
ns.AddProbe("shape", function(out) out[#out + 1] = "beta: 2"; return { "beta: 2" } end)
ns.AddProbe("shape", function() return { "|cff00ff00gamma|r: 3" } end)
ns.AddProbe("shape", function() error("boom") end)

local function has(text, s) return text:find(s, 1, true) ~= nil end

---------------------------------------------------------------------------
-- Every section
---------------------------------------------------------------------------
local before = #mamaPrinted
ns.RunCommand("probe")
local f = MamaPlusProbe
check(f and f:IsShown() and f.edit, "window not shown")
local text = f.edit:GetText()
check(has(text, "MamaPlus probe 0.1.0 "), "header: " .. text:sub(1, 40))
check(has(text, "== core ==") and has(text, "build: 1.60.1 70205 Oct 1 2026") and has(text, "interface: 16001")
  and has(text, "WOW_PROJECT_ID: 18") and has(text, "LE_EXPANSION_LEVEL_CURRENT: 0"), "core lines")
check(has(text, "type(issecretvalue): function") and has(text, "UnitHealth(player): <secret number>")
  and has(text, "UnitName(player): Han") and has(text, "UnitGUID(player): Player-4620-AAA"), "secret/plain units")
check(has(text, "C_Secrets: table") and has(text, "TooltipDataProcessor: nil") and has(text, "GetUnitSpeed: function")
  and has(text, "Settings.RegisterCanvasLayoutSubcategory: function") and has(text, "Enum.SendAddonMessageResult: table"),
  "presence")
check(has(text, "C_Secrets.ShouldUnitStatsBeSecret(): false") and has(text, "C_Secrets.ShouldAurasBeSecret(): <secret boolean>")
  and has(text, "C_Secrets.ShouldBroken(): error"), "C_Secrets predicates")
check(has(text, "C_Secrets.Broken: function") and not has(text, "C_Secrets.Broken()") and brokenCalls == 0
  and has(text, "C_Secrets.Version: number"), "non-predicate C_Secrets members listed by type only")
check(has(text, "ns.IsHardcore(): false") and has(text, "ns.Moving(): false"),
  "hardcore/moving")
check(has(text, "ADDON_ACTION_FORBIDDEN valid: true") and has(text, "UNIT_SPELLCAST_SENT valid: true"), "events")
check(has(text, "Mama version: 1.1.0") and has(text, "slot: 1") and has(text, "token: yes")
  and has(text, "lead: Han Jaconelli (this window)") and has(text, "comms: on") and has(text, "messages: sent ") and has(text, "blocked actions: 0"), "Mama state")
check(text:find("== core ==", 1, true) < text:find("== shape ==", 1, true), "core not first")
check(has(text, "alpha: 1") and has(text, "sec: <secret string>") and has(text, "none: nil"), "add shape")
check(select(2, text:gsub("beta: 2", "")) == 1 and has(text, "gamma: 3") and not has(text, "|cff00ff00")
  and has(text, "error: ") and has(text, "boom"), "out/return shapes, colour strip, raising fn")
-- Every window line was printed too, in order.
local lines = {}
for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
check(#mamaPrinted - before == #lines, "printed " .. (#mamaPrinted - before) .. " lines for " .. #lines)
check(has(mamaPrinted[before + 1], lines[1]) and has(mamaPrinted[#mamaPrinted], lines[#lines]), "printed order")
-- The secret never reached a print or the window as a raw value.
check(not text:find("\0"), "raw secret string in the window")

---------------------------------------------------------------------------
-- One section, unknown section, read-only box
---------------------------------------------------------------------------
ns.RunCommand("probe SHAPE")
text = f.edit:GetText()
check(not has(text, "== core ==") and has(text, "== shape ==") and has(text, "alpha: 1"), "single section")
check(MamaPlusProbe == f, "window recreated")
ns.RunCommand("probe bogus")
local last = mamaPrinted[#mamaPrinted]
check(has(last, "unknown probe section: bogus") and has(last, "core, ") and has(last, "shape") and has(last, "comms"),
  "unknown section: " .. last)
f.edit:SetText("junk"); f.edit:RunScript("OnTextChanged", true)
check(f.edit:GetText() == f.text and has(f.text, "== shape =="), "edit not restored")
f.edit:RunScript("OnEscapePressed")
check(UISpecialFrames[#UISpecialFrames] == "MamaPlusProbe", "not in UISpecialFrames")
check(f.scripts.OnEscapePressed == nil and f.edit.scripts.OnEscapePressed, "escape handler on the edit box")

---------------------------------------------------------------------------
-- Comms probe
---------------------------------------------------------------------------
state.group = {}; Fire("GROUP_ROSTER_UPDATE")
ns.RunCommand("probe comms")
check(has(mamaPrinted[#mamaPrinted], "not in a group") and #sentAddon == 0 and not ns.Probe.running, "ungrouped")

state.group = { "party1" }; Fire("GROUP_ROSTER_UPDATE")
-- Mama's per-character off switch: no addon messages out, even from the probe.
MamaForever.db.disabled["Han Jaconelli"] = true
ns.RunCommand("probe comms")
check(has(mamaPrinted[#mamaPrinted], "Mama is disabled") and #sentAddon == 0 and not ns.Probe.running, "disabled")
MamaForever.db.disabled["Han Jaconelli"] = nil
local t0 = GetTime()
ns.RunCommand("probe comms")
check(registered == 1 and ns.Probe.running, "prefix not registered / not running")
check(has(f.edit:GetText(), "RegisterAddonMessagePrefix(MAMAPLUSP): 0"), "register line")
ns.RunCommand("probe comms")
check(has(mamaPrinted[#mamaPrinted], "already running"), "concurrent run")
Step(5)
check(#sentAddon == 20, "fast phase sent " .. #sentAddon)
Step(19)
check(#sentAddon == 39 and ns.Probe.running, "slow phase sent " .. #sentAddon)
Step(1)
check(#sentAddon == 40 and not ns.Probe.running and registered == 1, "sent " .. #sentAddon)
check(sentAddon[40].at - t0 >= 24 and sentAddon[40].at - t0 <= 25, "timing: " .. (sentAddon[40].at - t0))
check(sentAddon[20].at - t0 <= 5 and sentAddon[21].at - t0 > 5, "phase boundary")
for i, s in ipairs(sentAddon) do
  check(s.prefix == "MAMAPLUSP" and s.channel == "PARTY" and s.text == "p;" .. i, "message " .. i)
end
text = f.edit:GetText()
check(has(text, "== comms ==") and text:find("comms 1/40 %+[%d.]+ s: 0\n") and text:find("comms 40/40 %+[%d.]+ s: 3\n"),
  "comms lines in window")
check(text:find("comms 25/40 %+[%d.]+ s: <secret number>"), "secret code")
check(text:find("comms probe done: 40 sent in [%d.]+ s; first non%-Success: <secret number> at message 25 %(%+[%d.]+ s%)"),
  "summary: " .. text:match("comms probe done[^\n]*"))
check(select(2, text:gsub("comms %d+/40", "")) == 40, "40 result lines")
check(has(mamaPrinted[#mamaPrinted], "comms probe done"), "summary printed")
Step(30)
check(#sentAddon == 40, "sent after done")

-- All Success and a second run (prefix stays registered once).
C_ChatInfo.SendAddonMessage = function(prefix, text, channel)
  sentAddon[#sentAddon + 1] = { prefix = prefix, text = text, channel = channel, at = GetTime() }
  return 0
end
ns.RunCommand("probe comms"); Step(25)
-- Message 40 is due at 24.25 s (5.25 + 19) and the 0.25 s ticker sends it then.
check(#sentAddon == 80 and registered == 1 and f.edit:GetText():find("40 sent in 24%.25 s; all Success"), "second run")

-- Nothing protected or world-changing was called, nothing went through Mama's letter.
check(#calls == 0, "protected calls: " .. table.concat(calls, ","))
check(#Sent("p") == 0, "probe traffic through Mama")
print("probe OK")
