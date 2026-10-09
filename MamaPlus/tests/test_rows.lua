-- Tests for Rows.lua (and Alert.Fire): decoration once per row and only
-- out of combat (no region creation, no anchors, no attributes in combat;
-- text, show and hide still update), the width budget (name first, 84 px
-- strip at most, entries by priority, the rest tooltip-only, no +N),
-- priority order, tooltip lines and GameTooltip:Show, Refresh coalescing,
-- Flash, the rowIcons option and the icons/test commands.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end
local errors = {}
function geterrorhandler() return function(err) errors[#errors + 1] = tostring(err) end end

local Rows = ns.Rows
-- A provider fed from a table the test controls: extra[name] = { entries }.
local extra, providerCalls = {}, 0
Rows.AddProvider(function(name, out)
  providerCalls = providerCalls + 1
  for _, e in ipairs(extra[name] or {}) do out[#out + 1] = { e[1], e[2], e[3], e[4], e[5], e[6], e[7] } end
end)
local boomCalls = 0
Rows.AddProvider(function() boomCalls = boomCalls + 1; error("provider boom") end)   -- reported once, then skipped
local function E(kind, text, prio, tip, r, g, b) return { kind, text, r or 1, g or 1, b or 1, tip, prio } end
local function strip(s) return (s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
local function row(i) return _G["MamaForeverStatusRow" .. i] end
local function refresh() Rows.Refresh(); Step(0.5) end   -- the coalesced refresh runs on the next tick
-- Counters on each row (regions created, anchors set, attributes written):
-- a snapshot before an action and unchanged() after it say "nothing more".
-- ignoreAttr: Mama's own refresh writes its unit attribute each time.
local snap = {}
local function snapshot()
  for i = 1, 3 do local c = row(i).counters; snap[i] = { c.CreateFontString, c.CreateTexture, c.SetPoint, c.SetAttribute } end
end
local function unchanged(m, ignoreAttr)
  for i = 1, 3 do
    local c = row(i).counters
    check(c.CreateFontString == snap[i][1] and c.CreateTexture == snap[i][2] and c.SetPoint == snap[i][3]
      and (ignoreAttr or c.SetAttribute == snap[i][4]), m .. " (row " .. i .. ")")
  end
end

state.leader = "party1"   -- Pri Cuthbridge leads: her row carries Mama's star
Login({ "party1", "party2" })

---------------------------------------------------------------------------
-- Decoration: once per row, from Mama's RefreshStatus post-hook (Mama
-- refreshes at LOGIN, on TEAM_CHANGED and on GROUP_ROSTER_UPDATE)
---------------------------------------------------------------------------
local r1, r2, r3 = row(1), row(2), row(3)
check(r1 and r2 and r3 and row(4) == nil and MamaForever.rowsRefreshed == 3, "three rows after login: " .. MamaForever.rowsRefreshed .. " refreshes")
for i = 1, 3 do
  local r = row(i)
  check(r.plus and r.flash and r.plusHooked == true and #r.hooks.OnEnter == 1, "row " .. i .. " not decorated")
  check(r.plus.parent == r and r.flash.parent == r, "row " .. i .. " strip or flash made elsewhere")
end
check(r2.name.text == "Pri Cuthbridge |cFFFFD100*|r", "lead star: " .. tostring(r2.name.text))
local p = r1.plus.points[1]
check(p[1] == "RIGHT" and p[2] == r1.bags and p[3] == "LEFT" and p[4] == -3, "plus anchored to the bag count")
check(#r1.name.points == 2 and r1.name.points[1][1] == "LEFT" and r1.name.points[1][2] == 28
  and r1.name.points[2][1] == "RIGHT" and r1.name.points[2][2] == r1.plus and r1.name.points[2][4] == -2, "name re-anchored to the strip")
check(r1.flash.shown == false and r1.flash.color[1] == 1 and r1.flash.color[4] == 0.35, "flash texture hidden")
check(r1.plus.text == "" and r1.plusEntries and #r1.plusEntries == 0, "empty strip")
-- Decorating again creates and anchors nothing more; our own Apply writes no attribute.
snapshot()
MamaForever:RefreshStatus()
unchanged("decorated twice", true)
check(#r1.hooks.OnEnter == 1, "tooltip hooked twice")
snapshot()
Rows.Apply()
unchanged("Apply created a region or wrote an attribute")

---------------------------------------------------------------------------
-- Combat: nothing created, text still updates, undecorated rows wait
---------------------------------------------------------------------------
snapshot()
state.combat = true
extra["Pri Cuthbridge"] = { E("idle", "IDLE", 4, "in combat and standing still", 1, 0.2, 0.2) }
MamaForever:RefreshStatus()       -- Mama returns early; our post-hook still runs
refresh()
unchanged("regions created in combat")
check(r2.plus.text == "|cffff3333IDLE|r", "text not updated in combat: " .. tostring(r2.plus.text))
-- a row we have not decorated yet (made by Mama without a refresh reaching us) is skipped in combat
local r4 = CreateFrame("Button", "MamaForeverStatusRow4", MamaStatusFrame, "SecureActionButtonTemplate")
r4.bags = r4:CreateFontString(); r4.name = r4:CreateFontString(); r4.name:SetPoint("LEFT", 28, 0)
r4.counters, r4.slot = {}, 4
r4:SetScript("OnEnter", function() GameTooltip:AddLine("Slot 4"); GameTooltip:Show() end)
MamaForever:RefreshStatus(); refresh()
check(r4.plus == nil and next(r4.counters) == nil and r4.plusHooked == nil, "undecorated row touched in combat")
Rows.Flash("Pri Cuthbridge", 1); Step(0.5)   -- the refresh runs; the 1.1 s hide does not yet
check(r2.flash.shown == true, "flash hidden in combat on a decorated row")
unchanged("flash created regions in combat")
state.combat = false
Fire("PLAYER_REGEN_ENABLED")      -- Mama's pending refresh runs, our hook decorates
check(MamaForever.pendingRefresh == false and r4.plus and r4.flash and r4.plusHooked and r4.counters.CreateFontString == 1
  and r4.counters.CreateTexture == 1 and r4.counters.SetPoint == 3, "row not decorated after combat")
check(r4.counters.SetAttribute == nil and r4.plus.text == "" and r4.plusEntries == nil, "nameless row: attribute set or entries")
check(r2.flash.shown == true, "flash cleared early")
Step(1)
check(r2.flash.shown == false, "flash not cleared")

---------------------------------------------------------------------------
-- Budget: 154 px minus the name (6 px/char, star included) minus 4, at
-- most 84; entries by priority while they fit, the rest in the tooltip
---------------------------------------------------------------------------
extra["Pri Cuthbridge"] = { E("far", "FAR", 6, "out of follow range", 1, 0.3, 0.3), E("idle", "IDLE", 4, "idle", 1, 0.2, 0.2),
  E("level", "12", 8, "level 12"), E("follow", "F!", 5, "not following: stopped", 1, 0.3, 0.3) }
Deliver("Pri Cuthbridge", "x;H;0.1.0;a;100;-")    -- AFK from Status, prio 11
refresh()
-- "Pri Cuthbridge *" = 16 chars = 96 px -> budget 54: IDLE 24, F! 39, FAR 60 (no), 12 54 (yes), AFK (no)
check(strip(r2.plus.text) == "IDLE F! 12", "strip: " .. strip(r2.plus.text))
check(not r2.plus.text:find("+", 1, true), "+N in the strip")
check(r2.name.text:find("*", 1, true), "star lost")
local ent = r2.plusEntries
check(#ent == 5 and ent[1][1] == "idle" and ent[2][1] == "follow" and ent[3][1] == "far" and ent[4][1] == "level"
  and ent[5][1] == "afk", "entries sorted by prio")
GameTooltip:Hide()
local shows = GameTooltip.shows
r2:RunScript("OnEnter")
check(GameTooltip.lines[1] == "Slot 2: Pri Cuthbridge", "Mama's line first")
check(#GameTooltip.lines == 6 and GameTooltip.lines[2] == "IDLE: idle" and GameTooltip.lines[3] == "F!: not following: stopped"
  and GameTooltip.lines[4] == "FAR: out of follow range" and GameTooltip.lines[5] == "12: level 12" and GameTooltip.lines[6] == "AFK: AFK",
  "tooltip lines: " .. table.concat(GameTooltip.lines, " / "))
check(GameTooltip.shows == shows + 2, "GameTooltip:Show not called by our hook")
GameTooltip:Hide()
-- text "" is tooltip-only (no "x: " prefix), an entry without tip has no line
extra["Vf Pr"] = { E("lvl", "", 8, "level 9 (2 below)"), E("quiet", "Q", 9, nil), E("ten", "AB", 7, "ten") }
refresh()
check(strip(r3.plus.text) == "AB Q", "empty text in the strip: " .. strip(r3.plus.text))
shows = GameTooltip.shows
r3:RunScript("OnEnter")
check(#GameTooltip.lines == 3 and GameTooltip.lines[2] == "AB: ten" and GameTooltip.lines[3] == "level 9 (2 below)",
  "tooltip-only line: " .. table.concat(GameTooltip.lines, " / "))
GameTooltip:Hide()
-- "Vf Pr" (30 px) would leave 120: clamped to 84 -> 5 of 10 "AB" entries (12 px + 3 gap each)
extra["Vf Pr"] = {}
for i = 1, 10 do extra["Vf Pr"][i] = E("e" .. i, "AB", i, "entry " .. i) end
refresh()
local shown = select(2, strip(r3.plus.text):gsub("AB", ""))
check(shown == 5 and #r3.plusEntries == 10, "clamped strip: " .. shown .. " shown")
-- "Han Jaconelli" (78 px) leaves 72: a 12-char entry fits exactly, a 13-char one does not
extra["Han Jaconelli"] = { E("a", "ABCDEFGHIJKLM", 1, "13"), E("b", "ABCDEFGHIJKL", 2, "12") }
refresh()
check(strip(r1.plus.text) == "ABCDEFGHIJKL", "fit at the edge: " .. strip(r1.plus.text))
-- a name wider than the row leaves no strip at all
r1.name:SetText(string.rep("x", 30))
extra["Han Jaconelli"] = { E("a", "X", 1, "x") }
refresh()
check(r1.plus.text == "" and #r1.plusEntries == 1, "strip with no budget")
extra["Han Jaconelli"] = nil
MamaForever:RefreshStatus()
check(r1.name.text == "Han Jaconelli" and r1.plus.text == "", "name restored by Mama")

---------------------------------------------------------------------------
-- Entries: priority, then registration order; Refresh coalesced per frame
---------------------------------------------------------------------------
extra["Vf Pr"] = { E("p5", "A", 5), E("p1", "B", 1), E("p3a", "C", 3), E("p3b", "D", 3), E("none", "E", nil) }
local e = Rows.Entries("Vf Pr")
local order = {}
for i, x in ipairs(e) do order[i] = x[1] end
check(table.concat(order, " ") == "p1 p3a p3b p5 none", "prio order: " .. table.concat(order, " "))
check(#Rows.Entries(nil) == 0 and #Rows.Entries("Nobody Here") == 0, "entries for nil/unknown")
r4.fullName = "Ab Cd"
providerCalls = 0
Rows.Refresh(); Rows.Refresh(); Rows.Refresh()
check(providerCalls == 0, "Refresh ran in the same frame")
Step(0.5)
check(providerCalls == 4, "three Refresh calls = one Apply over 4 rows: " .. providerCalls)
extra["Vf Pr"] = nil

---------------------------------------------------------------------------
-- Flash and Alert.Fire
---------------------------------------------------------------------------
Rows.Flash("Pri Cuthbridge", 2)
check(Rows.IsFlashing("Pri Cuthbridge") and not Rows.IsFlashing("Vf Pr") and not Rows.IsFlashing(nil), "IsFlashing")
Step(0.5); check(r2.flash.shown == true, "flash not shown")
Step(1); check(r2.flash.shown == true, "flash ended early")
Step(1.5); check(r2.flash.shown == false and not Rows.IsFlashing("Pri Cuthbridge"), "flash not hidden after 2 s")
Rows.Flash(nil, 1); Rows.Flash("Nobody Here", 1); Step(1.5)
local snd, warn = #sounds, #warnings
check(ns.Alert.Fire("Pri Cuthbridge is idle", "Pri Cuthbridge", 1) == true, "Alert.Fire result")
check(#sounds == snd + 1 and sounds[#sounds] == SOUNDKIT.RAID_WARNING and #warnings == warn + 1
  and warnings[#warnings] == "Pri Cuthbridge is idle" and mamaPrinted[#mamaPrinted] == "|cFF99E5FF+|r |cffff4040Pri Cuthbridge is idle|r"
  and ns.Alert.last == "Pri Cuthbridge is idle", "Alert outputs")
Step(0.5); check(r2.flash.shown == true, "alert flash")
Step(1.5); check(r2.flash.shown == false, "alert flash not cleared")
local rn = RaidNotice_AddMessage
RaidNotice_AddMessage = nil
check(ns.Alert.Fire("no raid frame") == false and mamaPrinted[#mamaPrinted]:find("no raid frame", 1, true), "Alert without RaidNotice")
RaidNotice_AddMessage = rn
check(ns.Alert.FLASH_TIME == 3, "default flash length")

---------------------------------------------------------------------------
-- rowIcons off clears the strip, the tooltip lines and the flash
---------------------------------------------------------------------------
extra["Pri Cuthbridge"] = { E("idle", "IDLE", 4, "idle") }
Deliver("Pri Cuthbridge", "x;H;0.1.0;-;100;-")   -- AFK gone
Rows.Flash("Pri Cuthbridge", 60)
ns.SetOption("rowIcons", false); Step(0.5)
check(r2.plus.text == "" and r2.plusEntries == nil and r2.flash.shown == true, "icons off (the alert flash stays)")
shows = GameTooltip.shows
r2:RunScript("OnEnter")
check(#GameTooltip.lines == 1 and GameTooltip.shows == shows + 1, "tooltip lines with icons off")
GameTooltip:Hide()
ns.RunCommand("icons on"); Step(0.5)
check(ns.db.rowIcons == true and strip(r2.plus.text) == "IDLE" and r2.flash.shown == true
  and mamaPrinted[#mamaPrinted]:find("row icons on", 1, true), "icons command on")
ns.RunCommand("icons off"); check(ns.db.rowIcons == false, "icons command off")
ns.RunCommand("icons"); check(ns.db.rowIcons == false and mamaPrinted[#mamaPrinted]:find("row icons off", 1, true), "icons command status")
ns.RunCommand("icons ON"); check(ns.db.rowIcons == true, "icons command case")
Rows.flashUntil["Pri Cuthbridge"] = nil
refresh()
check(r2.flash.shown == false, "flash after icons on")

---------------------------------------------------------------------------
-- /mama plus test: sound, warning, TEST icon and a flash on the own row
---------------------------------------------------------------------------
snd, warn = #sounds, #warnings
ns.RunCommand("test"); Step(0.5)
check(#sounds == snd + 1 and #warnings == warn + 1 and warnings[#warnings] == "MamaPlus test: alerts work on this window", "test alert")
check(strip(r1.plus.text) == "TEST" and r1.flash.shown == true, "TEST icon/flash on the own row: " .. strip(r1.plus.text))
check(strip(r2.plus.text) == "IDLE" and r2.flash.shown == false, "TEST leaked to another row")
local te = r1.plusEntries[1]
check(te[1] == "test" and te[6] == "alert check" and te[7] == 99 and te[3] == 1 and te[4] == 1 and te[5] == 1, "TEST entry")
Step(3.5)
check(r1.plus.text == "" and r1.flash.shown == false, "TEST icon not cleared after 3 s: " .. tostring(r1.plus.text))

check(#errors == 1 and errors[1]:find("provider boom", 1, true) and boomCalls == 1,
  "a raising provider is reported once and then skipped: " .. table.concat(errors, " | ") .. " calls " .. boomCalls)

-- Regression: when GetUnboundedStringWidth is missing or secret, the
-- fallback width estimate counts the visible text only; it once counted
-- Mama's " |cFFFFD100*|r" on the lead's row too (13 bytes = 78 px), which
-- collapsed the budget to 0 and left the lead's row without icons.
r2.name.GetUnboundedStringWidth = function() return nil end
refresh()
check(strip(r2.plus.text) == "IDLE", "fallback width estimate counts Mama's colour codes: strip '" .. strip(r2.plus.text) .. "'")

print("ROWS TESTS PASSED")
