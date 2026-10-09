-- Self-checks for tests/mock.lua, the contracts the module tests lean on:
-- secret sentinels (issecretvalue, type() as the client reports it), the
-- widget allowlist (unknown method nil, template mixin, mock helper), the
-- 255-byte wire limit behind Mama's envelope, the 0.05 s clock (Step exact,
-- Flush zero-delay only, Advance runs what is due before the jump, due
-- order, a ticker and a timer due together in creation order), the login
-- helpers (T_LOGIN, NextBeat) and Mama's refreshes at LOGIN/TEAM_CHANGED.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end   -- float sums differ from the tick clock by an ulp

---------------------------------------------------------------------------
-- Secrets
---------------------------------------------------------------------------
local sb, sn, ss, st = MakeSecret("boolean"), MakeSecret("number"), MakeSecret("string"), MakeSecret()
check(issecretvalue(sb) and issecretvalue(sn) and issecretvalue(ss) and issecretvalue(st), "sentinels are secret")
check(not issecretvalue(nil) and not issecretvalue(false) and not issecretvalue(0) and not issecretvalue("") and not issecretvalue({}),
  "plain values are not secret")
check(type(sb) == "boolean" and type(sn) == "number" and type(ss) == "string" and type(st) == "table", "type() reports the kind")
check(type(nil) == "nil" and type(false) == "boolean" and type(print) == "function" and type({}) == "table", "type() on plain values")
check(MakeSecret("boolean") ~= sb, "sentinels are distinct")

---------------------------------------------------------------------------
-- Widgets: the real API as no-ops, anything else nil, templates, helpers
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
check(f.SetFrameStrata and f.RegisterEvent and f.CreateFontString and f.RunScript, "Frame methods")
check(f.SetBackdrop == nil and f.SetChecked == nil and f.SetScrollChild == nil and f.SetJustifyV == nil and f.SetTexture == nil,
  "Frame has no backdrop, check, scroll, text or texture methods")
check(not pcall(function() f:SetJustifyV("TOP") end), "a wrong call raises")
local bd = CreateFrame("Frame", nil, f, "BackdropTemplate")
check(bd.SetBackdrop and bd.SetBackdropColor and bd.SetBackdropBorderColor, "BackdropTemplate mixin")
local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
check(cb.SetChecked and cb.SetHitRectInsets and cb.SetEnabled and cb.SetText and cb.SetScrollChild == nil, "CheckButton methods")
local eb = CreateFrame("EditBox", nil, f)
check(eb.SetMultiLine and eb.HighlightText and eb.SetFontObject and eb.SetWordWrap == nil, "EditBox methods")
local fs, tx = f:CreateFontString(), f:CreateTexture()
check(fs.kind == "FontString" and tx.kind == "Texture" and fs.parent == f, "region kinds")
check(fs.SetText and fs.GetUnboundedStringWidth and fs.SetJustifyV and fs.SetColorTexture == nil and fs.RegisterEvent == nil,
  "FontString methods")
check(tx.SetColorTexture and tx.SetTexCoord and tx.SetText == nil and tx.CreateTexture == nil, "Texture methods")
fs:SetText("|cffff0000ab|r"); check(fs:GetUnboundedStringWidth() == 12, "width ignores colour codes")
check(CreateFrame("StatusBar").SetMinMaxValues and CreateFrame("StatusBar").Whatever, "an unlisted kind stays permissive")

---------------------------------------------------------------------------
-- Wire limit: payload + Mama's 40-byte envelope must fit 255
---------------------------------------------------------------------------
Login({ "party1" })
local MF = MamaForever
check(pcall(MF.SendGroup, MF, "x;T;" .. string.rep("a", 211)), "215-byte payload refused")
check(not pcall(MF.SendGroup, MF, "x;T;" .. string.rep("a", 212)), "216-byte payload accepted")
check(not pcall(MF.SendWhisper, MF, "Vf Pr", "x;T;" .. string.rep("a", 212)), "216-byte whisper accepted")

---------------------------------------------------------------------------
-- Clock and timers
---------------------------------------------------------------------------
local log = {}
local t0 = GetTime()
local function at(tag) log[#log + 1] = string.format("%s%.2f", tag, GetTime() - t0) end
C_Timer.After(0.25, function() at("a") end)
C_Timer.After(0, function() at("z") end)
C_Timer.After(0.1, function() at("b") end)
Flush()
check(table.concat(log, " ") == "z0.00" and GetTime() == t0, "Flush runs the zero-delay timer only, clock still: " .. table.concat(log, " "))
Step(0.1)
check(table.concat(log, " ") == "z0.00 b0.10", "0.1 s timer at 0.1 s: " .. table.concat(log, " "))
Step(0.1)
check(table.concat(log, " ") == "z0.00 b0.10" and near(GetTime(), t0 + 0.2), "0.25 s timer early")
Step(0.05)
check(log[#log] == "a0.25", "0.25 s timer at 0.25 s: " .. log[#log])
-- Due order, not insertion order; a timer queued with no delay by a due timer runs in the same tick.
log = {}
C_Timer.After(0.2, function() log[#log + 1] = "late" end)
C_Timer.After(0.1, function() log[#log + 1] = "early"; C_Timer.After(0, function() log[#log + 1] = "chained" end) end)
Step(0.2)
check(table.concat(log, " ") == "early chained late", "due order: " .. table.concat(log, " "))
-- Advance runs what is due now, then jumps; what fell due inside the jump waits for the next Step/Flush.
log = {}
C_Timer.After(0, function() log[#log + 1] = "now" end)
C_Timer.After(1, function() log[#log + 1] = "inside" end)
Advance(5)
check(table.concat(log, " ") == "now" and near(GetTime(), t0 + 5.45), "Advance: " .. table.concat(log, " ") .. " at " .. (GetTime() - t0))
Flush()
check(table.concat(log, " ") == "now inside", "late timer after the jump: " .. table.concat(log, " "))
-- A ticker is an After chain: due together with a timer, creation order decides; Cancel stops it.
log = {}
local tk = C_Timer.NewTicker(1, function() log[#log + 1] = "tick" end)
C_Timer.After(1, function() log[#log + 1] = "timer" end)
Step(1)
check(table.concat(log, " ") == "tick timer", "ticker before the later timer: " .. table.concat(log, " "))
Step(1)
check(#log == 3 and log[3] == "tick" and LiveTickers() >= 1, "ticker re-armed")
tk:Cancel(); Step(2)
check(#log == 3, "cancelled ticker ran")
check(near(math.floor(GetTime() * 20 + 0.5) / 20, GetTime()), "clock on a 0.05 s tick")

---------------------------------------------------------------------------
-- Login helpers and Mama's refreshes
---------------------------------------------------------------------------
check(T_LOGIN == 1000 and ns.Status.BEAT == 30, "T_LOGIN")
check(NextBeat() == T_LOGIN + (ns.Status.FIRST_BEAT or 8) + 30 * math.ceil((GetTime() - T_LOGIN - 8) / 30), "NextBeat: " .. NextBeat())
local before = #Sent("H")
PastBeat()
check(#Sent("H") == before + 1 and near(NextBeat() - GetTime(), 27), "PastBeat lands 3 s past a beat: " .. (NextBeat() - GetTime()))
local refreshes = MF.rowsRefreshed
state.group = { "party1", "party2" }; Fire("GROUP_ROSTER_UPDATE")
check(MF.rowsRefreshed == refreshes + 2, "two refreshes per roster change (TEAM_CHANGED + GROUP_ROSTER_UPDATE)")
check(MamaForeverStatusRow1 and MamaForeverStatusRow3 and MamaForeverStatusRow3.unit == "party2", "rows from Mama's slots")

print("HARNESS TESTS PASSED")
